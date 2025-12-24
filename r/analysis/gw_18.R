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
# Connect to duckdb. Load playermatchstats df
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

gw_player_agg <- gw_player %>%
  group_by(id, web_name) %>%
  summarise(
    matches = n(),
    minutes_played = sum(minutes_played, na.rm = TRUE),
    xgi = sum(xgi, na.rm = TRUE),
    avg_minutes_per_game = minutes_played / matches,
    xgi_per_90 = if_else(
      minutes_played > 0,
      (xgi / minutes_played) * 90,
      NA_real_
    ),
    .groups = "drop"
  ) %>%
  filter(avg_minutes_per_game >= 70)








