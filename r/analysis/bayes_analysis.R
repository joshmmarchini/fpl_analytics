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
SELECT*
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

# Variables for all positions
max_gw <- max(gw_player$gameweek) # 21
min_gw <- min(gw_player$gameweek) # 1

prior_sample <- ceiling(.70 * max_gw) # 15
post_sample <- prior_sample + 1 # 16

min_threshold_prior <- ceiling(0.5 * (prior_sample * 90))
min_threshold_post  <- ceiling(0.5 * ((max_gw - post_sample) * 90))

# Variables for midfielders only
prior_data_mid <- gw_player %>%
  filter(gameweek <= prior_sample & position == "Midfielder") %>%
  aggregate_window() %>%
  filter(minutes_played >= min_threshold_prior) %>%
  mutate(window = "prior")

post_data_mid <- gw_player %>%
  filter(gameweek >= post_sample & position == "Midfielder") %>%
  aggregate_window() %>%
  filter(minutes_played >= min_threshold_post) %>%
  mutate(window = "post")

xgi_q3_mid_prior <- quantile(
  prior_data_mid$xgi_per_90,
  probs = 0.75,
  na.rm = TRUE
)

xgi_q3_mid_post <- quantile(
  post_data_mid$xgi_per_90,
  probs = 0.75,
  na.rm = TRUE
)

cbitr_q3_mid_prior <- quantile(
  prior_data_mid$defcon_per_90,
  probs = 0.75,
  na.rm = TRUE
)

cbitr_q3_mid_post <- quantile(
  post_data_mid$defcon_per_90,
  probs = 0.75,
  na.rm = TRUE
)

# Variables for defenders only
prior_data_def <- gw_player %>%
  filter(gameweek <= prior_sample & position == "Defender") %>%
  aggregate_window() %>%
  filter(minutes_played >= min_threshold_prior) %>%
  mutate(window = "prior")

post_data_def <- gw_player %>%
  filter(gameweek >= post_sample & position == "Defender") %>%
  aggregate_window() %>%
  filter(minutes_played >= min_threshold_post) %>%
  mutate(window = "post")

xgi_q3_def_prior <- quantile(
  prior_data_def$xgi_per_90,
  probs = 0.75,
  na.rm = TRUE
)

xgi_q3_def_post <- quantile(
  post_data_def$xgi_per_90,
  probs = 0.75,
  na.rm = TRUE
)

cbit_q3_def_prior <- quantile(
  prior_data_def$defcon_per_90,
  probs = 0.75,
  na.rm = TRUE
)

cbit_q3_def_post <- quantile(
  post_data_def$defcon_per_90,
  probs = 0.75,
  na.rm = TRUE
)


###############################################################3
# Variables defined for Bayesian Analysis

# Variables needed for midfielder xgi Bayesian analysis
xgi_q3_mid_prior
xgi_q3_mid_post

# Variables needed for defender xgi Bayesian analysis
xgi_q3_def_prior
xgi_q3_def_post

# Variables needed for midfielder defcon Bayesian analysis
cbitr_q3_mid_prior
cbitr_q3_mid_post

# Variables needed for defender defcon Bayesian analysis
cbit_q3_def_prior
cbit_q3_def_post

# Variables needed for all Bayesian analysis
min_threshold_prior
min_threshold_post
prior_sample
post_sample



#############################################################
# 1) Bayesian Score for Midfielders based on xgi
##############################################################

#---------------------------------------------------------------------
# Step 1: Define success at the GW level
#---------------------------------------------------------------------

# One row per player per match (gw_player)
mids_xgi <- gw_player %>%
  filter(position == "Midfielder" & minutes_played >= 30) %>%
  select(id, web_name, gameweek, minutes_played, xgi) %>%
  mutate(
    xgi_per_90 = if_else(minutes_played > 0,(xgi / minutes_played) * 90,NA_real_)
    ) %>%
  select(-xgi)

# Define success at GW level
mids_xgi <- mids_xgi %>%
  mutate(
    window = case_when(
      gameweek <= prior_sample ~ "prior",
      gameweek >= post_sample ~ "recent",
      TRUE ~ NA_character_
    ),
    good_xgi = case_when(
      window == "prior" & xgi_per_90 >= xgi_q3_mid_prior ~ 1,
      window == "recent" & xgi_per_90 >= xgi_q3_mid_post ~ 1,
      TRUE ~ 0
    )
  )

# Each gw is now a Bernoulli trial with success defined above

#---------------------------------------------------------------------
# Step 2: Aggregate to player x window
#---------------------------------------------------------------------

mids_xgi_window <- mids_xgi %>%
  filter(!is.na(window)) %>%
  group_by(id, web_name, window) %>%
  summarise(
    n = n(), # Number of gws
    k = sum(good_xgi, na.rm = TRUE), # Number of good gws
    .groups = "drop"
  )

# Now we have ingredients for k_prior, n_prior, k_recent, n_recent

#---------------------------------------------------------------------
# Step 3: Reshape to wide format
#---------------------------------------------------------------------

mids_xgi_window <- mids_xgi_window %>%
  pivot_wider(
    id_cols = c(id, web_name),
    names_from = window,
    values_from = c(n, k),
    values_fill = 0
  )

#---------------------------------------------------------------------
# Step 4: Define the Bayesian model
#---------------------------------------------------------------------

# Theta i = P(elite xGI GW for player i)
# Prior ~ Beta(alpha0, beta0)

# Start weak
alpha0 <- 1
beta0  <- 1

#---------------------------------------------------------------------
# Step 5: Update with prior-window evidence
#---------------------------------------------------------------------

mids_xgi_window <- mids_xgi_window %>%
  mutate(
    alpha_prior = alpha0 + k_prior,
    beta_prior  = beta0 + (n_prior - k_prior)
  )

# This is the INFORMED PRIOR going into the recent window

#---------------------------------------------------------------------
# Step 6: Update with recent-window evidence (posterior)
#---------------------------------------------------------------------

mids_xgi_window <- mids_xgi_window %>%
  mutate(
    alpha_post = alpha_prior + k_recent,
    beta_post  = beta_prior + (n_recent - k_recent)
  )

#---------------------------------------------------------------------
# Step 7: Compute posteriror quantities you actually use
#---------------------------------------------------------------------

mids_xgi_window <- mids_xgi_window %>%
  mutate(
    posterior_mean = alpha_post / (alpha_post + beta_post), # Expected rate of elite GWs

    # Probability player is genuinely good going forward
    prob_good = 1 - pbeta(0.5, alpha_post, beta_post), # confidence signal

    # More aggressive "elite" probability
    prob_elite = 1 - pbeta(0.6, alpha_post, beta_post) # buy now signal
  )

mids_xgi_window <- mids_xgi_window %>%
  arrange(desc(prob_elite), desc(posterior_mean)) %>%
    left_join(cost %>% select(id = player_id, now_cost, team_name), by = "id")


#############################################################
# 2) Bayesian Score for Midfielders based on defcon
##############################################################

#---------------------------------------------------------------------
# Step 1: Define success at the GW level
#---------------------------------------------------------------------

# One row per player per match (gw_player)
mids_cbitr <- gw_player %>%
  filter(position == "Midfielder" & minutes_played >= 30) %>%
  select(id, web_name, gameweek, minutes_played, cbitr) %>%
  mutate(
    cbitr_per_90 = if_else(minutes_played > 0,(cbitr / minutes_played) * 90,NA_real_)
    ) %>%
  select(-cbitr)

# Define success at GW level
mids_cbitr <- mids_cbitr %>%
  mutate(
    window = case_when(
      gameweek <= prior_sample ~ "prior",
      gameweek >= post_sample ~ "recent",
      TRUE ~ NA_character_
    ),
    good_cbitr = case_when(
      window == "prior" & cbitr_per_90 >= cbitr_q3_mid_prior ~ 1,
      window == "recent" & cbitr_per_90 >= cbitr_q3_mid_post ~ 1,
      TRUE ~ 0
    )
  )

# Each gw is now a Bernoulli trial with success defined above


# Each gw is now a Bernoulli trial with success defined above

#---------------------------------------------------------------------
# Step 2: Aggregate to player x window
#---------------------------------------------------------------------

mids_cbitr_window <- mids_cbitr %>%
  filter(!is.na(window)) %>%
  group_by(id, web_name, window) %>%
  summarise(
    n = n(), # Number of gws
    k = sum(good_cbitr, na.rm = TRUE), # Number of good gws
    .groups = "drop"
  )

# Now we have ingredients for k_prior, n_prior, k_recent, n_recent

#---------------------------------------------------------------------
# Step 3: Reshape to wide format
#---------------------------------------------------------------------

mids_cbitr_window <- mids_cbitr_window %>%
  pivot_wider(
    id_cols = c(id, web_name),
    names_from = window,
    values_from = c(n, k),
    values_fill = 0
  )

#---------------------------------------------------------------------
# Step 4: Define the Bayesian model
#---------------------------------------------------------------------

# Theta i = P(elite xGI GW for player i)
# Prior ~ Beta(alpha0, beta0)

# Start weak
alpha0 <- 1
beta0  <- 1

#---------------------------------------------------------------------
# Step 5: Update with prior-window evidence
#---------------------------------------------------------------------

mids_cbitr_window <- mids_cbitr_window %>%
  mutate(
    alpha_prior = alpha0 + k_prior,
    beta_prior  = beta0 + (n_prior - k_prior)
  )

# This is the INFORMED PRIOR going into the recent window

#---------------------------------------------------------------------
# Step 6: Update with recent-window evidence (posterior)
#---------------------------------------------------------------------

mids_cbitr_window <- mids_cbitr_window %>%
  mutate(
    alpha_post = alpha_prior + k_recent,
    beta_post  = beta_prior + (n_recent - k_recent)
  )

#---------------------------------------------------------------------
# Step 7: Compute posteriror quantities you actually use
#---------------------------------------------------------------------

mids_cbitr_window <- mids_cbitr_window %>%
  mutate(
    posterior_mean = alpha_post / (alpha_post + beta_post), # Expected rate of elite GWs

    # Probability player is genuinely good going forward
    prob_good = 1 - pbeta(0.5, alpha_post, beta_post), # confidence signal

    # More aggressive "elite" probability
    prob_elite = 1 - pbeta(0.6, alpha_post, beta_post) # buy now signal
  )

mids_cbitr_window <- mids_cbitr_window %>%
  arrange(desc(prob_elite), desc(posterior_mean)) %>%
  left_join(cost %>% select(id = player_id, now_cost, team_name), by = "id")


#############################################################
# 3) VIZ_1: Midfielders who rank high on both
##############################################################

mids_viz_1 <- mids_xgi_window %>%
  select(id, web_name, xgi_prob_elite = prob_elite) %>%
  left_join(
    mids_cbitr_window %>%
      select(id, cbitr_prob_good = prob_good),
    by = "id"
  )

library(ggrepel)

windows()
ggplot(mids_viz_1,
       aes(x = xgi_prob_elite, y = cbitr_prob_good)) +
  geom_point() +
  geom_text_repel(
    aes(label = web_name),
    size = 3
  ) +
  labs(
    x = "P(elite xGI)",
    y = "P(elite CBITR)"
  ) +
  theme_minimal()




#############################################################
# 4) Bayesian Score for Defenders based on cbit
##############################################################

#---------------------------------------------------------------------
# Step 1: Define success at the GW level
#---------------------------------------------------------------------

# One row per player per match (gw_player)
def_cbit <- gw_player %>%
  filter(position == "Defender" & minutes_played >= 30) %>%
  select(id, web_name, gameweek, minutes_played, cbit) %>%
  mutate(
    cbit_per_90 = if_else(minutes_played > 0,(cbit / minutes_played) * 90,NA_real_)
    ) %>%
  select(-cbit)

# Define success at GW level
def_cbit <- def_cbit %>%
  mutate(
    window = case_when(
      gameweek <= prior_sample ~ "prior",
      gameweek >= post_sample ~ "recent",
      TRUE ~ NA_character_
    ),
    good_cbit = case_when(
      window == "prior" & cbit_per_90 >= cbit_q3_def_prior ~ 1,
      window == "recent" & cbit_per_90 >= cbit_q3_def_post ~ 1,
      TRUE ~ 0
    )
  )

# Each gw is now a Bernoulli trial with success defined above


# Each gw is now a Bernoulli trial with success defined above

#---------------------------------------------------------------------
# Step 2: Aggregate to player x window
#---------------------------------------------------------------------

def_cbit_window <- def_cbit %>%
  filter(!is.na(window)) %>%
  group_by(id, web_name, window) %>%
  summarise(
    n = n(), # Number of gws
    k = sum(good_cbit, na.rm = TRUE), # Number of good gws
    .groups = "drop"
  )

# Now we have ingredients for k_prior, n_prior, k_recent, n_recent

#---------------------------------------------------------------------
# Step 3: Reshape to wide format
#---------------------------------------------------------------------

def_cbit_window <- def_cbit_window %>%
  pivot_wider(
    id_cols = c(id, web_name),
    names_from = window,
    values_from = c(n, k),
    values_fill = 0
  )

#---------------------------------------------------------------------
# Step 4: Define the Bayesian model
#---------------------------------------------------------------------

# Theta i = P(elite xGI GW for player i)
# Prior ~ Beta(alpha0, beta0)

# Start weak
alpha0 <- 1
beta0  <- 1

#---------------------------------------------------------------------
# Step 5: Update with prior-window evidence
#---------------------------------------------------------------------

def_cbit_window <- def_cbit_window %>%
  mutate(
    alpha_prior = alpha0 + k_prior,
    beta_prior  = beta0 + (n_prior - k_prior)
  )

# This is the INFORMED PRIOR going into the recent window

#---------------------------------------------------------------------
# Step 6: Update with recent-window evidence (posterior)
#---------------------------------------------------------------------

def_cbit_window <- def_cbit_window %>%
  mutate(
    alpha_post = alpha_prior + k_recent,
    beta_post  = beta_prior + (n_recent - k_recent)
  )

#---------------------------------------------------------------------
# Step 7: Compute posteriror quantities you actually use
#---------------------------------------------------------------------

def_cbit_window <- def_cbit_window %>%
  mutate(
    posterior_mean = alpha_post / (alpha_post + beta_post), # Expected rate of elite GWs

    # Probability player is genuinely good going forward
    prob_good = 1 - pbeta(0.5, alpha_post, beta_post), # confidence signal

    # More aggressive "elite" probability
    prob_elite = 1 - pbeta(0.6, alpha_post, beta_post) # buy now signal
  )

def_cbit_window <- def_cbit_window %>%
  arrange(desc(prob_elite), desc(posterior_mean)) %>%
  left_join(cost %>% select(id = player_id, now_cost, team_name), by = "id")


#############################################################
# 5) Bayesian Score for Defenders based on xgi
##############################################################

#---------------------------------------------------------------------
# Step 1: Define success at the GW level
#---------------------------------------------------------------------

# One row per player per match (gw_player)
def_xgi <- gw_player %>%
  filter(position == "Defender" & minutes_played >= 30) %>%
  select(id, web_name, gameweek, minutes_played, xgi) %>%
  mutate(
    xgi_per_90 = if_else(minutes_played > 0,(xgi / minutes_played) * 90,NA_real_)
    ) %>%
  select(-xgi)

# Define success at GW level
def_xgi <- def_xgi %>%
  mutate(
    window = case_when(
      gameweek <= prior_sample ~ "prior",
      gameweek >= post_sample ~ "recent",
      TRUE ~ NA_character_
    ),
    good_xgi = case_when(
      window == "prior" & xgi_per_90 >= xgi_q3_def_prior ~ 1,
      window == "recent" & xgi_per_90 >= xgi_q3_def_post ~ 1,
      TRUE ~ 0
    )
  )

# Each gw is now a Bernoulli trial with success defined above


# Each gw is now a Bernoulli trial with success defined above

#---------------------------------------------------------------------
# Step 2: Aggregate to player x window
#---------------------------------------------------------------------

def_xgi_window <- def_xgi %>%
  filter(!is.na(window)) %>%
  group_by(id, web_name, window) %>%
  summarise(
    n = n(), # Number of gws
    k = sum(good_xgi, na.rm = TRUE), # Number of good gws
    .groups = "drop"
  )

# Now we have ingredients for k_prior, n_prior, k_recent, n_recent

#---------------------------------------------------------------------
# Step 3: Reshape to wide format
#---------------------------------------------------------------------

def_xgi_window <- def_xgi_window %>%
  pivot_wider(
    id_cols = c(id, web_name),
    names_from = window,
    values_from = c(n, k),
    values_fill = 0
  )

#---------------------------------------------------------------------
# Step 4: Define the Bayesian model
#---------------------------------------------------------------------

# Theta i = P(elite xGI GW for player i)
# Prior ~ Beta(alpha0, beta0)

# Start weak
alpha0 <- 1
beta0  <- 1

#---------------------------------------------------------------------
# Step 5: Update with prior-window evidence
#---------------------------------------------------------------------

def_xgi_window <- def_xgi_window %>%
  mutate(
    alpha_prior = alpha0 + k_prior,
    beta_prior  = beta0 + (n_prior - k_prior)
  )

# This is the INFORMED PRIOR going into the recent window

#---------------------------------------------------------------------
# Step 6: Update with recent-window evidence (posterior)
#---------------------------------------------------------------------

def_xgi_window <- def_xgi_window %>%
  mutate(
    alpha_post = alpha_prior + k_recent,
    beta_post  = beta_prior + (n_recent - k_recent)
  )

#---------------------------------------------------------------------
# Step 7: Compute posteriror quantities you actually use
#---------------------------------------------------------------------

def_xgi_window <- def_xgi_window %>%
  mutate(
    posterior_mean = alpha_post / (alpha_post + beta_post), # Expected rate of elite GWs

    # Probability player is genuinely good going forward
    prob_good = 1 - pbeta(0.5, alpha_post, beta_post), # confidence signal

    # More aggressive "elite" probability
    prob_elite = 1 - pbeta(0.6, alpha_post, beta_post) # buy now signal
  )

def_xgi_window <- def_xgi_window %>%
  arrange(desc(prob_elite), desc(posterior_mean)) %>%
  left_join(cost %>% select(id = player_id, now_cost, team_name), by = "id")