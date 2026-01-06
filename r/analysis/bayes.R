#####################################################################
# Load libraries
#####################################################################
library(DBI)
library(duckdb)
library(skimr)
library(tidyverse)
library(zoo) # for rolling (last 3 game or avg) calculations
options(scipen = 999) # turn off scientific notation
library(ggrepel)
library(slider)


#####################################################################
# Connect to duckdb. Load vw_gw_player_data
#####################################################################

# fpl_insights db connection
con <- dbConnect(
  duckdb(),
  dbdir = "C:/dev/fpl_analytics/duckdb/fpl-insights.duckdb",
  read_only = FALSE
)


dbListTables(con)



gw_player <- dbGetQuery(con,
"
SELECT*
FROM analytics.vw_gw_player_data gw                       
")

cost <- dbGetQuery(con,
"
SELECT player_id As id, now_cost
FROM analytics.vw_player_cost_current                   
")


dbDisconnect(con, shutdown = TRUE)

#####################################################################
# Create reusable aggregation window
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

      # defensive contributions
      defcon_def     = sum(cbit, na.rm = TRUE),
      defcon_mid_fwd = sum(cbitr, na.rm = TRUE),

      # volume
      matches        = n(),
      minutes_played = sum(minutes_played, na.rm = TRUE),

      # attacking volume
      xgi_total      = sum(xgi, na.rm = TRUE),

      .groups = "drop"
    ) %>%
    mutate(
      # per-90 metrics
      xgi_per_90 = if_else(
        minutes_played > 0,
        (xgi_total / minutes_played) * 90,
        NA_real_
      ),

      avg_min_per_game = minutes_played / matches,
      min_share_90     = avg_min_per_game / 90,

      defcon = case_when(
        position == "Defender" ~ defcon_def,
        position %in% c("Midfielder", "Forward") ~ defcon_mid_fwd,
        TRUE ~ 0
      ),

      defcon_per_90 = if_else(
        minutes_played > 0,
        (defcon / minutes_played) * 90,
        NA_real_
      )


    ) %>%
    select(-defcon_def, -defcon_mid_fwd)
}



max_gw <- max(gw_player$gameweek)
min_gw <- min(gw_player$gameweek)

season <- gw_player %>%
  aggregate_window() %>%
  mutate(window = "season")

last_8 <- gw_player %>%
  filter(gameweek > max_gw - 8) %>%
  aggregate_window() %>%
  mutate(window = "last_8")

last_4 <- gw_player %>%
  filter(gameweek > max_gw - 4) %>%
  aggregate_window() %>%
  mutate(window = "last_4")

last_1 <- gw_player %>%
  filter(gameweek == max_gw) %>%
  aggregate_window() %>%
  mutate(window = "last_1")

first_13 <- gw_player %>%
  filter(gameweek >= 1 & gameweek <= 13) %>%
  aggregate_window() %>%
  mutate(window = "first_13")

last_6 <- gw_player %>%
  filter(gameweek > 13) %>%
  aggregate_window() %>%
  mutate(window = "last_6")

top_performers <- bind_rows(first_13, last_6) %>%
  #arrange(desc(fantasy_points)) %>%
  left_join(cost, by = c("id" = "id")) %>%
  arrange(web_name, window)

# Bucket players by id, web_name, price, position

# xgi per 90 percentiles
season_mids <- season %>%
  filter(position == "Midfielder" & minutes_played >= 906)

skim(season_mids)
summary(season_mids$xgi_per_90)
summary(season_mids$defcon_per_90)

# For midfielders who played at least 780 minutes during the first 13 gw,
# who was in the top 25% of xgi per 90?
midfielders_prior <- top_performers %>%
  filter(window == "first_13") %>%
  filter(position == "Midfielder") %>%
  filter(xgi_per_90 > 0 & minutes_played >= 780) %>%
  # Good Player criteria
  mutate(good_buy = if_else(xgi_per_90 >= 0.389, 1, 0))

# Total "good players"
sum(midfielders_prior$good_buy)

skim(midfielders_prior)

# Distribution of now_cost?
summary(midfielders_prior$now_cost)

windows()
ggplot(midfielders_prior, aes(x = now_cost)) +
  geom_histogram(bins = 10, fill = "steelblue", color = "white") +
  geom_text(
    stat = "bin",
    bins = 10,
    aes(
      label = paste0(
        round(after_stat(xmin), 1), "–",
        round(after_stat(xmax), 1), "\n(n=",
        after_stat(count), ")"
      )
    ),
    vjust = -0.2,
    size = 3
  ) +
  labs(
    title = "Distribution of Cost",
    x = "Cost",
    y = "Count"
  )


midfielders_later <- top_performers %>%
  filter(window == "last_6") %>%
  filter(position == "Midfielder") %>%
  filter(xgi_per_90 > 0 & minutes_played >= 270) %>%
  mutate(good_buy = if_else(xgi_per_90 >= 0.389, 1, 0)) #%>% 
  #filter(good_buy == 1)

View(midfielders_later)
View(midfielders_prior)


#########################################
# Bayesian Score for Midfielders
#########################################

# Helper: xGI + DefCon per 90 in a window
xgi_def_per90_window <- function(df, gw_min, gw_max) {
  df %>%
    filter(gameweek >= gw_min, gameweek <= gw_max) %>%
    group_by(id, web_name, position) %>%
    summarise(
      mins = sum(minutes_played, na.rm = TRUE),

      xgi  = sum(xgi, na.rm = TRUE),
      defcon = sum(cbitr, na.rm = TRUE),

      xgi_per90    = ifelse(mins > 0, 90 * xgi / mins, NA_real_),
      defcon_per90 = ifelse(mins > 0, 90 * cbitr / mins, NA_real_),

      .groups = "drop"
    )
}


# 1) Build prior groups from GW 1-13
train <- xgi_def_per90_window(gw_player, 1, 13) %>%
  filter(position == "Midfielder", mins >= 780) %>%
  mutate(good = ifelse(xgi_per90 > 0.389, 1, 0))

prior <- mean(train$good)  # should be ~0.19
prior


# 2) Evidence from GW 14-19
test <- xgi_def_per90_window(gw_player, 14, 19) %>%
  filter(position == "Midfielder", mins >= 270) %>%
  select(
    id,
    xgi_per90_6    = xgi_per90,
    defcon_per90_6 = defcon_per90,
    mins_6         = mins
  )


# 3) Join labels onto last-6 window for likelihood fitting
likelihood_df <- train %>%
  select(web_name, id, good) %>%
  inner_join(test, by = "id") %>%
  filter(
    !is.na(xgi_per90_6),
    !is.na(defcon_per90_6)
  )

skim(likelihood_df)


params <- likelihood_df %>%
  group_by(good) %>%
  summarise(
    mu_xgi = mean(xgi_per90_6, na.rm = TRUE),
    sd_xgi = sd(xgi_per90_6,  na.rm = TRUE),

    mu_def = mean(defcon_per90_6, na.rm = TRUE),
    sd_def = sd(defcon_per90_6,  na.rm = TRUE),

    n = n(),
    .groups = "drop"
  )

params

mu_xgi_g  <- params %>% filter(good == 1) %>% pull(mu_xgi)
sd_xgi_g  <- params %>% filter(good == 1) %>% pull(sd_xgi)

mu_xgi_ng <- params %>% filter(good == 0) %>% pull(mu_xgi)
sd_xgi_ng <- params %>% filter(good == 0) %>% pull(sd_xgi)

mu_def_g  <- params %>% filter(good == 1) %>% pull(mu_def)
sd_def_g  <- params %>% filter(good == 1) %>% pull(sd_def)

mu_def_ng <- params %>% filter(good == 0) %>% pull(mu_def)
sd_def_ng <- params %>% filter(good == 0) %>% pull(sd_def)


score <- likelihood_df %>%
  mutate(
    # Attack likelihoods
    pxgi_g  = dnorm(xgi_per90_6, mean = mu_xgi_g,  sd = sd_xgi_g),
    pxgi_ng = dnorm(xgi_per90_6, mean = mu_xgi_ng, sd = sd_xgi_ng),

    # Defense likelihoods
    pdef_g  = dnorm(defcon_per90_6, mean = mu_def_g,  sd = sd_def_g),
    pdef_ng = dnorm(defcon_per90_6, mean = mu_def_ng, sd = sd_def_ng),

    # Combined likelihoods (Naive Bayes)
    lik_g  = pxgi_g  * pdef_g,
    lik_ng = pxgi_ng * pdef_ng,

    # Posterior
    post_good = (lik_g * prior) /
      (lik_g * prior + lik_ng * (1 - prior))
  ) %>%
  #arrange(desc(post_good))
  arrange(web_name)

