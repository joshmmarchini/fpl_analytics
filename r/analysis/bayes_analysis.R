#####################################################################
# Load libraries
#####################################################################
library(DBI)
library(duckdb)
library(here)
library(skimr)
library(tidyverse)
library(zoo)
library(ggrepel)
library(slider)
options(scipen = 999)


#####################################################################
# DB Connection & Data Load
#####################################################################

con <- dbConnect(
  duckdb(),
  dbdir    = here("duckdb", "fpl-insights.duckdb"),
  read_only = TRUE
)

gw_player <- dbGetQuery(con, "SELECT * FROM analytics.vw_gw_player_data")

elo_data <- dbGetQuery(con, "
  SELECT team, gameweek, opponent_elo
  FROM analytics.vw_team_gw_opponent_elo
")

cost <- dbGetQuery(con, "SELECT * FROM analytics.vw_player_cost_current")

dbDisconnect(con, shutdown = TRUE)


#####################################################################
# Parameters
#####################################################################

max_gw <- max(gw_player$gameweek)
min_gw <- min(gw_player$gameweek)

# Split: first 70% of season = prior, remainder = recent
prior_sample <- ceiling(0.70 * max_gw)   # Last GW of prior window
post_sample  <- prior_sample + 1          # First GW of recent window

# Minimum minutes: 50% of possible playing time per window
# Prior  = GW1 through prior_sample  = prior_sample games
# Recent = post_sample through max_gw = (max_gw - post_sample + 1) games
min_threshold_prior <- ceiling(0.5 * (prior_sample * 90))
min_threshold_post  <- ceiling(0.5 * ((max_gw - post_sample + 1) * 90))

# P(theta) thresholds for prob_good and prob_elite
threshold_good  <- 0.5   # "is this player hitting elite levels more than half the time?"
threshold_elite <- 0.6   # "buy now" signal

# GW targeting — change this each week
target_gw <- 28


#####################################################################
# ELO fixture weights
#####################################################################

# Normalise opponent ELO to mean = 1.0 across all matches.
# A match vs an above-average team gets weight > 1, below-average < 1.
mean_elo <- mean(elo_data$opponent_elo, na.rm = TRUE)

elo_weights <- elo_data %>%
  mutate(elo_weight = if_else(
    !is.na(opponent_elo) & mean_elo > 0,
    opponent_elo / mean_elo,
    1.0
  )) %>%
  select(team, gameweek, elo_weight)

# Attach to gw_player (DGW rows share the same GW-level weight)
gw_player <- gw_player %>%
  left_join(elo_weights, by = c("team", "gameweek")) %>%
  mutate(elo_weight = coalesce(elo_weight, 1.0))


#####################################################################
# Helper: aggregate_window
# Summarises a filtered dataframe to one row per player.
# Use for exploratory season-level summaries.
#####################################################################

aggregate_window <- function(df) {
  df %>%
    group_by(id, web_name, position, team) %>%
    summarise(
      fantasy_points = sum(total_points_gw, na.rm = TRUE),
      bonus_points   = sum(bonus_points_gw, na.rm = TRUE),
      bps            = sum(bps_gw, na.rm = TRUE),
      goals          = sum(goals, na.rm = TRUE),
      assists        = sum(assists, na.rm = TRUE),
      defcon_def     = sum(cbit,   na.rm = TRUE),
      defcon_mid_fwd = sum(cbitr,  na.rm = TRUE),
      matches        = n(),
      minutes_played = sum(minutes_played, na.rm = TRUE),
      xgi_total      = sum(xgi, na.rm = TRUE),
      xg_total       = sum(xg,  na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      xgi_per_90       = if_else(minutes_played > 0, (xgi_total / minutes_played) * 90, NA_real_),
      xg_per_90        = if_else(minutes_played > 0, (xg_total  / minutes_played) * 90, NA_real_),
      avg_min_per_game = minutes_played / matches,
      min_share_90     = avg_min_per_game / 90,
      defcon = case_when(
        position == "Defender"                    ~ defcon_def,
        position %in% c("Midfielder", "Forward") ~ defcon_mid_fwd,
        TRUE ~ 0
      ),
      defcon_per_90 = if_else(
        minutes_played > 0, (defcon / minutes_played) * 90, NA_real_
      )
    ) %>%
    select(-defcon_def, -defcon_mid_fwd)
}


#####################################################################
# Helper: estimate_prior
# Empirical Bayes: estimates Beta(alpha0, beta0) hyperparameters
# from the distribution of observed prior-window hit rates.
# Method of moments. Falls back to Beta(1, 1) if data is insufficient.
#####################################################################

estimate_prior <- function(k, n, min_games = 3) {
  eligible <- n >= min_games
  rates    <- ifelse(eligible & n > 0, k / n, NA_real_)
  rates    <- rates[!is.na(rates)]

  if (length(rates) < 5) return(list(alpha0 = 1, beta0 = 1))

  mu <- mean(rates)
  s2 <- var(rates)

  if (is.na(s2) || s2 <= 0 || mu <= 0 || mu >= 1) return(list(alpha0 = 1, beta0 = 1))

  conc <- mu * (1 - mu) / s2 - 1
  if (is.na(conc) || conc <= 0) return(list(alpha0 = 1, beta0 = 1))

  list(
    alpha0 = max(mu * conc, 0.5),
    beta0  = max((1 - mu) * conc, 0.5)
  )
}


#####################################################################
# Helper: compute_q3
# Computes the Q3 per-90 threshold for a position/metric combination
# in the prior and recent windows.  The threshold is derived from
# season-aggregate per-90 rates (total metric / total minutes) across
# qualifying players, matching the original analytical intent.
#####################################################################

compute_q3 <- function(gw_data, position_filter, metric_col,
                       prior_sample, post_sample,
                       min_minutes_prior, min_minutes_post) {

  agg_per90_q3 <- function(df, min_min) {
    df %>%
      group_by(id) %>%
      summarise(
        metric_total   = sum(.data[[metric_col]], na.rm = TRUE),
        minutes_played = sum(minutes_played, na.rm = TRUE),
        .groups = "drop"
      ) %>%
      filter(minutes_played >= min_min) %>%
      mutate(metric_per_90 = if_else(
        minutes_played > 0, metric_total / minutes_played * 90, NA_real_
      )) %>%
      pull(metric_per_90) %>%
      quantile(probs = 0.75, na.rm = TRUE)
  }

  list(
    prior = gw_data %>%
      filter(position == position_filter,
             gameweek <= prior_sample,
             minutes_played >= 30) %>%
      agg_per90_q3(min_minutes_prior),

    post = gw_data %>%
      filter(position == position_filter,
             gameweek >= post_sample,
             minutes_played >= 30) %>%
      agg_per90_q3(min_minutes_post)
  )
}


#####################################################################
# Helper: run_bayes
# Generic 7-step Beta-Binomial Bayesian pipeline.
#
# Each GW with >= min_minutes is a Bernoulli trial.
# Success = per-90 metric in that GW >= position/window Q3 threshold.
# Trials are ELO-weighted so performances against strong opponents
# carry more evidence than those against weak opponents.
# An empirical Bayes Beta prior is estimated from prior-window data.
#
# Returns one row per player with posterior quantities.
#####################################################################

run_bayes <- function(
  gw_data,
  position_filter,
  metric_col,
  q_prior,
  q_post,
  prior_sample,
  post_sample,
  min_minutes     = 30,
  use_elo_weights = TRUE,
  threshold_good  = 0.5,
  threshold_elite = 0.6
) {

  # Step 1: Filter, compute per-90, classify each GW as success/fail
  dat <- gw_data %>%
    filter(position == position_filter, minutes_played >= min_minutes) %>%
    select(id, web_name, gameweek, minutes_played, elo_weight,
           all_of(metric_col)) %>%
    rename(metric = all_of(metric_col)) %>%
    mutate(
      metric_per_90 = if_else(
        minutes_played > 0, (metric / minutes_played) * 90, NA_real_
      ),
      window = case_when(
        gameweek <= prior_sample ~ "prior",
        gameweek >= post_sample  ~ "recent",
        TRUE                     ~ NA_character_
      ),
      good = case_when(
        window == "prior"  & metric_per_90 >= q_prior ~ 1L,
        window == "recent" & metric_per_90 >= q_post  ~ 1L,
        TRUE ~ 0L
      ),
      trial_weight = if_else(use_elo_weights, elo_weight, 1.0)
    )

  # Step 2: Aggregate to player × window (ELO-weighted counts)
  window_agg <- dat %>%
    filter(!is.na(window)) %>%
    group_by(id, web_name, window) %>%
    summarise(
      n = sum(trial_weight,         na.rm = TRUE),
      k = sum(good * trial_weight,  na.rm = TRUE),
      .groups = "drop"
    )

  # Step 3: Reshape to wide format
  wide <- window_agg %>%
    pivot_wider(
      id_cols     = c(id, web_name),
      names_from  = window,
      values_from = c(n, k),
      values_fill = 0
    )

  # Ensure both windows are present even if one had no data
  if (!"n_prior"  %in% names(wide)) wide$n_prior  <- 0
  if (!"k_prior"  %in% names(wide)) wide$k_prior  <- 0
  if (!"n_recent" %in% names(wide)) wide$n_recent <- 0
  if (!"k_recent" %in% names(wide)) wide$k_recent <- 0

  # Steps 4 & 5: Empirical Bayes prior + update with prior-window evidence
  eb <- estimate_prior(wide$k_prior, wide$n_prior)

  wide <- wide %>%
    mutate(
      eb_alpha0   = eb$alpha0,
      eb_beta0    = eb$beta0,
      alpha_prior = eb$alpha0 + k_prior,
      beta_prior  = eb$beta0  + (n_prior - k_prior)
    )

  # Step 6: Update with recent-window evidence → posterior
  wide <- wide %>%
    mutate(
      alpha_post = alpha_prior + k_recent,
      beta_post  = beta_prior  + (n_recent - k_recent)
    )

  # Step 7: Posterior quantities
  wide %>%
    mutate(
      posterior_mean = alpha_post / (alpha_post + beta_post),
      ci_lower       = qbeta(0.05, alpha_post, beta_post),  # 90% credible interval
      ci_upper       = qbeta(0.95, alpha_post, beta_post),
      prob_good      = 1 - pbeta(threshold_good,  alpha_post, beta_post),
      prob_elite     = 1 - pbeta(threshold_elite, alpha_post, beta_post)
    ) %>%
    arrange(desc(prob_good), desc(posterior_mean))
}


#####################################################################
# Helper: rolling_bayes
# Sequential GW-by-GW Bayesian update using a single season-wide
# threshold.  Tracks how the posterior evolves over the season,
# revealing upward/downward trends that the two-window model misses.
# Uses Beta(1, 1) as the starting prior.
#####################################################################

rolling_bayes <- function(gw_data, position_filter, metric_col,
                          q_season, min_minutes = 30) {
  gw_data %>%
    filter(position == position_filter, minutes_played >= min_minutes) %>%
    select(id, web_name, gameweek, minutes_played, all_of(metric_col)) %>%
    rename(metric = all_of(metric_col)) %>%
    mutate(
      metric_per_90 = if_else(
        minutes_played > 0, (metric / minutes_played) * 90, NA_real_
      ),
      good = if_else(
        !is.na(metric_per_90) & metric_per_90 >= q_season, 1L, 0L
      )
    ) %>%
    arrange(id, gameweek) %>%
    group_by(id, web_name) %>%
    mutate(
      cum_k     = cumsum(replace_na(good, 0L)),
      cum_n     = row_number(),
      alpha_t   = 1 + cum_k,
      beta_t    = 1 + (cum_n - cum_k),
      post_mean = alpha_t / (alpha_t + beta_t),
      ci_lower  = qbeta(0.05, alpha_t, beta_t),
      ci_upper  = qbeta(0.95, alpha_t, beta_t)
    ) %>%
    ungroup()
}


#####################################################################
# Compute Q3 thresholds for each position/metric combination
#####################################################################

q3_mid_xgi   <- compute_q3(gw_player, "Midfielder", "xgi",
                             prior_sample, post_sample,
                             min_threshold_prior, min_threshold_post)
q3_mid_cbitr <- compute_q3(gw_player, "Midfielder", "cbitr",
                             prior_sample, post_sample,
                             min_threshold_prior, min_threshold_post)
q3_mid_xg    <- compute_q3(gw_player, "Midfielder", "xg",
                             prior_sample, post_sample,
                             min_threshold_prior, min_threshold_post)
q3_def_xgi   <- compute_q3(gw_player, "Defender", "xgi",
                             prior_sample, post_sample,
                             min_threshold_prior, min_threshold_post)
q3_def_cbit  <- compute_q3(gw_player, "Defender", "cbit",
                             prior_sample, post_sample,
                             min_threshold_prior, min_threshold_post)
q3_fwd_xgi   <- compute_q3(gw_player, "Forward", "xgi",
                             prior_sample, post_sample,
                             min_threshold_prior, min_threshold_post)


#####################################################################
# Run all Bayesian models
#####################################################################

cost_lookup <- cost %>% select(id = player_id, now_cost, team_name)

# 1) Midfielders: xGI (attacking involvement)
mids_xgi <- run_bayes(
  gw_player, "Midfielder", "xgi",
  q3_mid_xgi$prior, q3_mid_xgi$post,
  prior_sample, post_sample,
  threshold_good = threshold_good, threshold_elite = threshold_elite
) %>% left_join(cost_lookup, by = "id")

# 2) Midfielders: cbitr (defensive contribution)
mids_cbitr <- run_bayes(
  gw_player, "Midfielder", "cbitr",
  q3_mid_cbitr$prior, q3_mid_cbitr$post,
  prior_sample, post_sample,
  threshold_good = threshold_good, threshold_elite = threshold_elite
) %>% left_join(cost_lookup, by = "id")

# 3) Midfielders: xG (pure shooting quality)
mids_xg <- run_bayes(
  gw_player, "Midfielder", "xg",
  q3_mid_xg$prior, q3_mid_xg$post,
  prior_sample, post_sample,
  threshold_good = threshold_good, threshold_elite = threshold_elite
) %>% left_join(cost_lookup, by = "id")

# 4) Defenders: cbit (defensive contribution)
def_cbit <- run_bayes(
  gw_player, "Defender", "cbit",
  q3_def_cbit$prior, q3_def_cbit$post,
  prior_sample, post_sample,
  threshold_good = threshold_good, threshold_elite = threshold_elite
) %>% left_join(cost_lookup, by = "id")

# 5) Defenders: xGI (attacking involvement)
def_xgi <- run_bayes(
  gw_player, "Defender", "xgi",
  q3_def_xgi$prior, q3_def_xgi$post,
  prior_sample, post_sample,
  threshold_good = threshold_good, threshold_elite = threshold_elite
) %>% left_join(cost_lookup, by = "id")

# 6) Forwards: xGI
fwd_xgi <- run_bayes(
  gw_player, "Forward", "xgi",
  q3_fwd_xgi$prior, q3_fwd_xgi$post,
  prior_sample, post_sample,
  threshold_good = threshold_good, threshold_elite = threshold_elite
) %>% left_join(cost_lookup, by = "id")


#####################################################################
# Composite scores & cost-adjusted rankings
#####################################################################

# Midfielders: 60% attacking (xgi) + 40% defensive (cbitr)
mid_composite <- mids_xgi %>%
  select(id, web_name, now_cost, team_name,
         prob_elite_xgi  = prob_elite,
         prob_good_xgi   = prob_good,
         posterior_mean_xgi = posterior_mean,
         ci_lower_xgi    = ci_lower,
         ci_upper_xgi    = ci_upper) %>%
  left_join(
    mids_cbitr %>% select(id,
                          prob_elite_cbitr = prob_elite,
                          prob_good_cbitr  = prob_good),
    by = "id"
  ) %>%
  mutate(
    composite_score = 0.6 * coalesce(prob_elite_xgi,   0) +
                      0.4 * coalesce(prob_elite_cbitr,  0),
    # Points-per-million proxy: composite / price in £M (now_cost is in £0.1M units)
    value_score     = if_else(now_cost > 0,
                              composite_score / (now_cost / 10),
                              NA_real_)
  ) %>%
  arrange(desc(composite_score))

# Defenders: 50% attacking (xgi) + 50% defensive (cbit)
def_composite <- def_xgi %>%
  select(id, web_name, now_cost, team_name,
         prob_elite_xgi  = prob_elite,
         prob_good_xgi   = prob_good,
         posterior_mean_xgi = posterior_mean,
         ci_lower_xgi    = ci_lower,
         ci_upper_xgi    = ci_upper) %>%
  left_join(
    def_cbit %>% select(id,
                        prob_elite_cbit = prob_elite,
                        prob_good_cbit  = prob_good),
    by = "id"
  ) %>%
  mutate(
    composite_score = 0.5 * coalesce(prob_elite_xgi,  0) +
                      0.5 * coalesce(prob_elite_cbit,  0),
    value_score     = if_else(now_cost > 0,
                              composite_score / (now_cost / 10),
                              NA_real_)
  ) %>%
  arrange(desc(composite_score))

# Forwards: xGI only
fwd_composite <- fwd_xgi %>%
  select(id, web_name, now_cost, team_name,
         prob_elite_xgi  = prob_elite,
         prob_good_xgi   = prob_good,
         posterior_mean_xgi = posterior_mean,
         ci_lower_xgi    = ci_lower,
         ci_upper_xgi    = ci_upper) %>%
  mutate(
    composite_score = coalesce(prob_elite_xgi, 0),
    value_score     = if_else(now_cost > 0,
                              composite_score / (now_cost / 10),
                              NA_real_)
  ) %>%
  arrange(desc(composite_score))


#####################################################################
# Rolling Bayesian trends
#####################################################################

# Season-wide Q3 used as a single threshold across all GWs
q3_mid_xgi_season <- gw_player %>%
  filter(position == "Midfielder", minutes_played >= 30) %>%
  mutate(xgi_per_90 = xgi / minutes_played * 90) %>%
  pull(xgi_per_90) %>%
  quantile(probs = 0.75, na.rm = TRUE)

mid_xgi_trend <- rolling_bayes(
  gw_player, "Midfielder", "xgi", q3_mid_xgi_season
)


#####################################################################
# GW targeting
# Combines the Bayesian form signal with the upcoming fixture.
# elo_data covers the full GW1-38 schedule so future GW fixtures
# are already available without reopening the DB connection.
# Change target_gw at the top of the Parameters section each week.
#####################################################################

# Fixture favorability for every team in target_gw
# Values > 1 = easier than average fixture, < 1 = harder
gw_fixture <- elo_data %>%
  filter(gameweek == target_gw) %>%
  mutate(fixture_favorability = mean_elo / opponent_elo) %>%
  select(team_name = team, gw_opponent_elo = opponent_elo, fixture_favorability)

# Extract each player's latest posterior and 4-GW trend from rolling model
trend_summary <- mid_xgi_trend %>%
  arrange(id, gameweek) %>%
  group_by(id, web_name) %>%
  summarise(
    latest_post_mean = last(post_mean),
    trend_4gw        = last(post_mean) - nth(post_mean, max(1L, n() - 3L)),
    .groups = "drop"
  )

# Join form signal + fixture + trend into one GW target table
gw_targets_mid <- mid_composite %>%
  left_join(gw_fixture,     by = "team_name") %>%
  left_join(
    trend_summary %>% select(id, latest_post_mean, trend_4gw),
    by = "id"
  ) %>%
  mutate(
    # Primary buy signal: form × fixture (no fixture data → neutral weight of 1)
    gw_score = composite_score * coalesce(fixture_favorability, 1.0),
    ci_width = ci_upper_xgi - ci_lower_xgi,
    price_m  = now_cost / 10
  ) %>%
  arrange(desc(gw_score))


#####################################################################
# Visualizations
#####################################################################

# VIZ 1: Midfielders — P(elite xGI) vs P(elite CBITR)
dev.new()
ggplot(
  mids_xgi %>%
    select(id, web_name, xgi_prob_elite = prob_elite) %>%
    left_join(mids_cbitr %>% select(id, cbitr_prob_good = prob_good), by = "id"),
  aes(x = xgi_prob_elite, y = cbitr_prob_good)
) +
  geom_point(colour = "steelblue", alpha = 0.7) +
  geom_text_repel(aes(label = web_name), size = 3) +
  labs(
    title = "Midfielders: attacking vs defensive Bayesian probability",
    x     = "P(elite xGI)",
    y     = "P(elite CBITR)"
  ) +
  theme_minimal()


# VIZ 2: Top 20 midfielders by composite score with credible intervals
dev.new()
mid_composite %>%
  slice_head(n = 20) %>%
  mutate(web_name = fct_reorder(web_name, composite_score)) %>%
  ggplot(aes(x = composite_score, y = web_name)) +
  geom_point(colour = "steelblue") +
  geom_errorbarh(
    aes(xmin = ci_lower_xgi, xmax = ci_upper_xgi),
    height = 0.3, colour = "grey50"
  ) +
  labs(
    title    = "Top 20 midfielders — composite Bayesian score",
    subtitle = "Error bars = 90% credible interval (xGI posterior)",
    x = "Composite score", y = NULL
  ) +
  theme_minimal()


# VIZ 3: Rolling Bayesian xGI trend for top 5 midfielders
top5_mid_ids <- mid_composite %>% slice_head(n = 5) %>% pull(id)

dev.new()
mid_xgi_trend %>%
  filter(id %in% top5_mid_ids) %>%
  ggplot(aes(x = gameweek, y = post_mean,
             colour = web_name, group = web_name)) +
  geom_line() +
  geom_ribbon(
    aes(ymin = ci_lower, ymax = ci_upper, fill = web_name),
    alpha = 0.1, colour = NA
  ) +
  labs(
    title    = "Rolling Bayesian xGI probability — top 5 midfielders",
    subtitle = "Shaded band = 90% credible interval",
    x = "Gameweek", y = "Posterior P(elite xGI per 90)",
    colour = NULL, fill = NULL
  ) +
  theme_minimal()


# VIZ 4: Midfielder value — composite score vs price
dev.new()
mid_composite %>%
  filter(!is.na(now_cost)) %>%
  mutate(price_m = now_cost / 10) %>%
  ggplot(aes(x = price_m, y = composite_score)) +
  geom_point(colour = "steelblue", alpha = 0.7) +
  geom_text_repel(
    data = ~ filter(.x, value_score >= quantile(value_score, 0.85, na.rm = TRUE)),
    aes(label = web_name),
    size = 3
  ) +
  labs(
    title    = "Midfielder value: composite score vs price",
    subtitle = "Labelled = top 15% value picks",
    x = "Price (£M)", y = "Composite score"
  ) +
  theme_minimal()


# VIZ 5: GW target — form vs fixture, coloured by trend, sized by price
dev.new()
gw_targets_mid %>%
  filter(!is.na(fixture_favorability)) %>%
  ggplot(aes(x = composite_score, y = fixture_favorability, size = price_m)) +
  geom_point(aes(colour = trend_4gw), alpha = 0.75) +
  scale_colour_gradient2(
    low = "firebrick", mid = "grey70", high = "darkgreen", midpoint = 0,
    name = "4-GW trend"
  ) +
  scale_size_continuous(range = c(2, 9), name = "Price (£M)") +
  geom_text_repel(
    data = ~ filter(.x, gw_score >= quantile(gw_score, 0.80, na.rm = TRUE)),
    aes(label = web_name), size = 3
  ) +
  geom_hline(yintercept = 1,
             linetype = "dashed", colour = "grey50") +
  geom_vline(xintercept = median(gw_targets_mid$composite_score, na.rm = TRUE),
             linetype = "dashed", colour = "grey50") +
  annotate("text", x = Inf, y = Inf, label = "Buy targets",
           hjust = 1.1, vjust = 1.5, size = 3, colour = "grey40") +
  labs(
    title    = paste0("GW", target_gw, " midfielder targets"),
    subtitle = "Top-right = strong form + easy fixture | Green = rising form | Size = price",
    x        = "Composite Bayesian score (season form)",
    y        = paste0("GW", target_gw, " fixture favorability (higher = easier)")
  ) +
  theme_minimal()


#####################################################################
# Exports
#####################################################################

dir.create(here("data", "outputs"), showWarnings = FALSE, recursive = TRUE)

write_csv(mid_composite,  here("data", "outputs", "mid_composite.csv"))
write_csv(def_composite,  here("data", "outputs", "def_composite.csv"))
write_csv(fwd_composite,  here("data", "outputs", "fwd_composite.csv"))
write_csv(mids_xgi,       here("data", "outputs", "mids_xgi_bayes.csv"))
write_csv(mids_cbitr,     here("data", "outputs", "mids_cbitr_bayes.csv"))
write_csv(mids_xg,        here("data", "outputs", "mids_xg_bayes.csv"))
write_csv(def_cbit,       here("data", "outputs", "def_cbit_bayes.csv"))
write_csv(def_xgi,        here("data", "outputs", "def_xgi_bayes.csv"))
write_csv(fwd_xgi,        here("data", "outputs", "fwd_xgi_bayes.csv"))
write_csv(gw_targets_mid, here("data", "outputs", paste0("gw", target_gw, "_mid_targets.csv")))


#####################################################################
# Optional: interactive exploration in RStudio
# Uncomment View() calls as needed
#####################################################################

# View(mid_composite)
# View(def_composite)
# View(fwd_composite)
# View(mids_xgi)
# View(mids_cbitr)
# View(mids_xg)
# View(def_cbit)
# View(def_xgi)
# View(fwd_xgi)
