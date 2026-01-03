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

# For midfielders who played at least 780 minutes during the first 13 gw, who was in the top 25% of xgi per 90?
midfielders_prior <- top_performers %>%
  filter(window == "first_13") %>%
  filter(position == "Midfielder") %>%
  filter(xgi_per_90 > 0 & minutes_played >= 780) %>%
  mutate(good_buy = if_else(xgi_per_90 >= 0.389, 1, 0)) %>%
  filter(good_buy == 1)

dim(midfielders_prior)

midfielders_later <- top_performers %>%
  filter(window == "last_6") %>%
  filter(position == "Midfielder") %>%
  filter(xgi_per_90 > 0 & minutes_played >= 270) %>%
  mutate(good_buy = if_else(xgi_per_90 >= 0.389, 1, 0)) %>% 
  filter(good_buy == 1)

skim(midfielders_prior)

print(midfielders_prior)
print(midfielders_later, n = 30)

View(midfielders_later)
View(midfielders_prior)



