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
    xg = sum(xg, na.rm = TRUE),
    xa = sum(xa, na.rm = TRUE),
    cbit = sum(cbit, na.rm = TRUE),
    avg_minutes_per_game = minutes_played / matches,
    xg_per_90 = (xg / minutes_played) * 90,
    xa_per_90 = (xa / minutes_played) * 90,
    xgi_per_90 = (xgi / minutes_played) * 90,
    cbit_per_90 = (cbit / minutes_played) * 90,
    .groups = "drop"
  )
  filter(avg_minutes_per_game >= 40)



# max_gw <- max(gw_player$gameweek, na.rm = TRUE)
max_gw <- 17
pos <- "Defender" # Defender, Midfielder, Goalkeeper, Forward

gw_player_rolling_latest <- gw_player %>%
  arrange(id, gameweek) %>%
  group_by(id, web_name) %>%
  mutate(
    matches_4gw = slide_int(
      minutes_played,
      ~ sum(!is.na(.x)),
      .before = 3,
      .complete = TRUE
    ),
    minutes_4gw = slide_dbl(
      minutes_played,
      sum,
      .before = 3,
      .complete = TRUE
    ),
    xgi_4gw = slide_dbl(
      xgi,
      sum,
      .before = 3,
      .complete = TRUE
    ),

    xg_4gw = slide_dbl(
      xg,
      sum,
      .before = 3,
      .complete = TRUE
    ),

    xa_4gw = slide_dbl(
      xa,
      sum,
      .before = 3,
      .complete = TRUE
    ),

    cbit_4gw = slide_dbl(
      cbit,
      sum,
      .before = 3,
      .complete = TRUE
    ),

    cbitr_4gw = slide_dbl(
      cbitr,
      sum,
      .before = 3,
      .complete = TRUE
    ),


    avg_minutes_per_game_4gw = minutes_4gw / matches_4gw,
    xgi_per_90_4gw = (xgi_4gw / minutes_4gw) * 90,
    xg_per_90_4gw = (xg_4gw / minutes_4gw) * 90,
    xa_per_90_4gw = (xa_4gw / minutes_4gw) * 90,
    cbit_per_90_4gw = (cbit_4gw / minutes_4gw) * 90,
    cbitr_per_90_4gw = (cbitr_4gw / minutes_4gw) * 90
  ) %>%
  ungroup() %>%
  filter(
    matches_4gw == 4,
    avg_minutes_per_game_4gw >= 70
  ) %>%
  filter(gameweek == max_gw) %>%
  filter(position == pos)


# Which defenders defend and have good xgi and cbit?
  # 

ggplot(
  gw_player_rolling_latest,
  aes(x = cbit_per_90_4gw, y = xgi_per_90_4gw, label = web_name)
) +
  geom_point(alpha = 0.7, size = 2) +
  geom_text_repel(size = 3, max.overlaps = 15) +
  geom_smooth(method = "lm", se = FALSE) +
  labs(
    title = "CBIT vs xGI (Last 4 GWs)",
    x = "CBIT per 90 (Last 4 GWs)",
    y = "xGI per 90 (Last 4 GWs)"
  ) +
  theme_minimal()


# Idea: Player points scored by gw





