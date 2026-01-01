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
FROM analytics.vw_gw_player_data                             
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

      defcon_def     = sum(cbit, na.rm = TRUE),
      defcon_mid_fwd = sum(cbitr, na.rm = TRUE),

      matches        = n(),
      minutes_played = sum(minutes_played, na.rm = TRUE),

      avg_min_per_game = minutes_played / matches,
      .groups = "drop"
    ) %>%
    mutate(
      defcon = case_when(
        position == "Defender" ~ defcon_def,
        position %in% c("Midfielder", "Forward") ~ defcon_mid_fwd,
        TRUE ~ 0
      )
    ) %>%
    select(-defcon_def, -defcon_mid_fwd)
}


max_gw <- max(gw_player$gameweek)

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

top_performers <- bind_rows(season, last_8, last_4, last_1) %>%
  arrange(desc(fantasy_points))
