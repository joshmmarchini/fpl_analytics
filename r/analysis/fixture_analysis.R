

library(DBI)
library(duckdb)
library(skimr)
library(tidyverse)
library(zoo) # for rolling (last 3 game or avg) calculations
options(scipen = 999) # turn off scientific notation
library(ggrepel)

# specify gw range
start_gw <- 20
end_gw <- 30




# fpl_insights db connection
con <- dbConnect(duckdb::duckdb(),
                 dbdir = "C:/dev/fpl_analytics/duckdb/fpl-insights.duckdb",
                 read_only = FALSE)

#dbListTables(con)

fixture_diff <- dbGetQuery(con, "

WITH stg_data AS (
    SELECT 
        CAST(m.gameweek AS INT) AS gameweek,
        home.short_name AS home_short_name,
        away.short_name AS away_short_name,
        home.elo AS home_elo,
        away.elo AS away_elo
    FROM analytics.dim_matches AS m
    LEFT JOIN analytics.dim_teams AS home ON home.code = m.home_team
    LEFT JOIN analytics.dim_teams AS away ON away.code = m.away_team
    WHERE m.tournament = 'prem'
),
team_opponent_elo AS (
    SELECT 
        gameweek,
        home_short_name AS team,
        away_short_name AS opponent,
        away_elo AS opponent_elo
    FROM stg_data
    UNION ALL
    SELECT 
        gameweek,
        away_short_name AS team,
        home_short_name AS opponent,
        home_elo AS opponent_elo
    FROM stg_data
)
SELECT 
    team,
    MAX(CASE WHEN gameweek = 1  THEN opponent_elo END)  AS GW1,
    MAX(CASE WHEN gameweek = 2  THEN opponent_elo END)  AS GW2,
    MAX(CASE WHEN gameweek = 3  THEN opponent_elo END)  AS GW3,
    MAX(CASE WHEN gameweek = 4  THEN opponent_elo END)  AS GW4,
    MAX(CASE WHEN gameweek = 5  THEN opponent_elo END)  AS GW5,
    MAX(CASE WHEN gameweek = 6  THEN opponent_elo END)  AS GW6,
    MAX(CASE WHEN gameweek = 7  THEN opponent_elo END)  AS GW7,
    MAX(CASE WHEN gameweek = 8  THEN opponent_elo END)  AS GW8,
    MAX(CASE WHEN gameweek = 9  THEN opponent_elo END)  AS GW9,
    MAX(CASE WHEN gameweek = 10 THEN opponent_elo END)  AS GW10,
    MAX(CASE WHEN gameweek = 11 THEN opponent_elo END)  AS GW11,
    MAX(CASE WHEN gameweek = 12 THEN opponent_elo END)  AS GW12,
    MAX(CASE WHEN gameweek = 13 THEN opponent_elo END)  AS GW13,
    MAX(CASE WHEN gameweek = 14 THEN opponent_elo END)  AS GW14,
    MAX(CASE WHEN gameweek = 15 THEN opponent_elo END)  AS GW15,
    MAX(CASE WHEN gameweek = 16 THEN opponent_elo END)  AS GW16,
    MAX(CASE WHEN gameweek = 17 THEN opponent_elo END)  AS GW17,
    MAX(CASE WHEN gameweek = 18 THEN opponent_elo END)  AS GW18,
    MAX(CASE WHEN gameweek = 19 THEN opponent_elo END)  AS GW19,
    MAX(CASE WHEN gameweek = 20 THEN opponent_elo END)  AS GW20,
    MAX(CASE WHEN gameweek = 21 THEN opponent_elo END)  AS GW21,
    MAX(CASE WHEN gameweek = 22 THEN opponent_elo END)  AS GW22,
    MAX(CASE WHEN gameweek = 23 THEN opponent_elo END)  AS GW23,
    MAX(CASE WHEN gameweek = 24 THEN opponent_elo END)  AS GW24,
    MAX(CASE WHEN gameweek = 25 THEN opponent_elo END)  AS GW25,
    MAX(CASE WHEN gameweek = 26 THEN opponent_elo END)  AS GW26,
    MAX(CASE WHEN gameweek = 27 THEN opponent_elo END)  AS GW27,
    MAX(CASE WHEN gameweek = 28 THEN opponent_elo END)  AS GW28,
    MAX(CASE WHEN gameweek = 29 THEN opponent_elo END)  AS GW29,
    MAX(CASE WHEN gameweek = 30 THEN opponent_elo END)  AS GW30,
    MAX(CASE WHEN gameweek = 31 THEN opponent_elo END)  AS GW31,
    MAX(CASE WHEN gameweek = 32 THEN opponent_elo END)  AS GW32,
    MAX(CASE WHEN gameweek = 33 THEN opponent_elo END)  AS GW33,
    MAX(CASE WHEN gameweek = 34 THEN opponent_elo END)  AS GW34,
    MAX(CASE WHEN gameweek = 35 THEN opponent_elo END)  AS GW35,
    MAX(CASE WHEN gameweek = 36 THEN opponent_elo END)  AS GW36,
    MAX(CASE WHEN gameweek = 37 THEN opponent_elo END)  AS GW37,
    MAX(CASE WHEN gameweek = 38 THEN opponent_elo END)  AS GW38
FROM team_opponent_elo
GROUP BY team
ORDER BY team;
                               
")


dbDisconnect(con, shutdown = TRUE)



fixture_diff_long <- fixture_diff %>%
  pivot_longer(
    cols = starts_with("GW"),
    names_to = "gameweek",
    values_to = "value"
  ) %>%
  # Remove GW prefix from gameweek
  mutate(gameweek = as.integer(str_replace(gameweek, "GW", "")))

fixture_diff_long <- fixture_diff_long %>%
  filter(gameweek >= start_gw & gameweek <= end_gw)  

fixture_diff_summary <- fixture_diff_long %>%
  group_by(team) %>%
  summarise(
    avg_opponent_elo = mean(value, na.rm = TRUE),
    total_opponent_elo = sum(value, na.rm = TRUE),
    min_elo = min(value),
    max_elo = max(value),
    sd_elo = sd(value),  # variability of difficulty
    .groups = "drop"
  ) %>%
  arrange(desc(avg_opponent_elo))

View(fixture_diff_summary)
