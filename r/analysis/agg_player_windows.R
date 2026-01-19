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

# max_gw * .70 and round up


train_sample <- ceiling(.70 * max_gw)
test_sample <- train_sample + 1


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

train_data <- gw_player %>%
  filter(gameweek <= train_sample) %>%
  aggregate_window() %>%
  mutate(window = "first_70%")

test_data <- gw_player %>%
  filter(gameweek >= test_sample) %>%
  aggregate_window() %>%
  mutate(window = "last_30%")

top_performers <- bind_rows(train_data, test_data) %>%
  #arrange(desc(fantasy_points)) %>%
  left_join(cost, by = c("id" = "id")) %>%
  arrange(web_name, window)

# Bucket players by id, web_name, price, position

# Include midfielders who have played at least 70% of total minutes this year
min_threshold <- ceiling(0.5 * (max_gw * 90))

# xgi per 90 percentiles
season_mids <- season %>%
  filter(position == "Midfielder" & minutes_played >= min_threshold) %>%
  arrange(team, web_name, desc(xgi_per_90))

# season_mids %>%
#   group_by(team) %>%
#   summarise(n = n()) %>%
#   arrange(desc(n))

skim(season_mids)
summary(season_mids$xgi_per_90)
summary(season_mids$defcon_per_90)

# Variable for Q3 of xgi per 90 for midfielders this season
xgi_per_90_q3 <- quantile(
  season_mids$xgi_per_90,
  probs = 0.75,
  na.rm = TRUE
)

# Variable for Q3 of defcon per 90 for midfielders this season
defcon_per_90_q3 <- quantile(
  season_mids$defcon_per_90,
  probs = 0.75,
  na.rm = TRUE
)

# Number of players in season_mids above q3 xgi_per_90?
sum(season_mids$xgi_per_90 >= xgi_per_90_q3)

# Number of players in season_mids above q3 defcon_per_90?
sum(season_mids$defcon_per_90 >= defcon_per_90_q3)

View(
  season_mids %>%
    filter(xgi_per_90 >= xgi_per_90_q3) %>%
    arrange(desc(xgi_per_90))
)

View(
  season_mids %>%
    filter(defcon_per_90 >= defcon_per_90_q3) %>%
    arrange(desc(defcon_per_90))
  )

# Number of players in season_mids above 

# For midfielders who played at least 50% of the minutes in the training data (first ROUNDUP(70% of games))

# Minute threshold given sample
min_threshold_train <- ceiling(0.5 * (train_sample * 90))


# who was in the top 25% of xgi per 90?
midfielders_prior <- top_performers %>%
  filter(window == "first_70%") %>%
  filter(position == "Midfielder") %>%
  filter(minutes_played >= min_threshold_train) %>%
  # Good Player criteria
  #mutate(good_xgi = if_else(xgi_per_90 >= xgi_per_90_q3, 1, 0))

# Determine q3 for xgi_per_90 in prior data
xgi_per_90_q3_prior <- quantile(
  midfielders_prior$xgi_per_90,
  probs = 0.75,
  na.rm = TRUE
)

# Add good_xgi based on prior q3
midfielders_prior <- midfielders_prior %>%
  mutate(good_xgi = if_else(xgi_per_90 >= xgi_per_90_q3_prior, 1, 0))

sum(midfielders_prior$good_xgi)

# For midfielders who played at least 50% of the minutes in the testing data (first ROUNDUP(30% of games))

# Minute threshold given sample
min_threshold_test <- ceiling(0.5 * ((max_gw - train_sample) * 90))


# who was in the top 25% of xgi per 90?
midfielders_post <- top_performers %>%
  filter(window == "last_30%") %>%
  filter(position == "Midfielder") %>%
  filter(minutes_played >= min_threshold_test) %>%
  # Good Player criteria
  #mutate(good_xgi = if_else(xgi_per_90 >= xgi_per_90_q3, 1, 0))

# Determine q3 for xgi_per_90 in prior data
xgi_per_90_q3_post <- quantile(
  midfielders_post$xgi_per_90,
  probs = 0.75,
  na.rm = TRUE
)

# Add good_xgi based on prior q3
midfielders_post <- midfielders_post %>%
  mutate(good_xgi = if_else(xgi_per_90 >= xgi_per_90_q3_post, 1, 0))

sum(midfielders_post$good_xgi)

View(
  midfielders_prior %>%
    filter(good_xgi == 1) %>%
    arrange(desc(xgi_per_90))
  )




