#####################################################################
# GW32 Midfielder Shortlist — budget 9.4m
# Criteria:
#   1. Attack threat: xGI per 90 >= threshold over last 5 GWs
#   2. Reliable minutes: avg minutes >= 60
#   3. Favourable GW32 fixture (opponent ELO below median)
#####################################################################

library(DBI)
library(duckdb)
library(here)
library(tidyverse)
library(slider)
options(scipen = 999)


#####################################################################
# Parameters
#####################################################################

target_gw      <- 32
budget         <- 9.4   # maximum price in millions
window         <- 5     # rolling game window (last N matches)
min_games      <- 3     # minimum appearances in window
min_minutes    <- 60    # minutes threshold for reliable starter
xgi_threshold  <- 0.20  # xGI per 90 threshold for attack flag
recency_gws    <- 4     # player must have played within this many GWs of last_completed_gw


#####################################################################
# DB Connection & Data Load
#####################################################################

con <- dbConnect(
  duckdb(),
  dbdir     = here("duckdb", "fpl-insights.duckdb"),
  read_only = TRUE
)

mid_match <- dbGetQuery(con, "
  SELECT
    f.player_id,
    p.web_name,
    t.short_name AS team,
    f.gameweek,
    f.minutes_played,
    f.goals,
    f.assists,
    f.xg,
    f.xa,
    f.xgi,
    f.shots_on_target,
    f.total_shots,
    f.chances_created,
    f.touches_opposition_box,
    f.penalties_scored,
    f.penalties_missed,
    f.team_goals_conceded,
    CASE WHEN f.team_goals_conceded = 0
          AND f.minutes_played >= 60 THEN 1 ELSE 0 END AS clean_sheet
  FROM analytics.fact_playermatchstats f
  JOIN analytics.dim_players p ON f.player_id  = p.player_id
  JOIN analytics.dim_teams   t ON p.team_code  = t.code
  WHERE p.position = 'Midfielder'
")

affordable <- dbGetQuery(con, "
  SELECT player_id, now_cost
  FROM analytics.vw_player_cost_current
  WHERE position = 'Midfielder'
    AND now_cost <= 9.4
")

gw32_fix <- dbGetQuery(con, "
  SELECT team, opponent_elo
  FROM analytics.vw_team_gw_opponent_elo
  WHERE gameweek = 32
")

dbDisconnect(con, shutdown = TRUE)


#####################################################################
# Rolling last-N-game stats
#####################################################################

last_completed_gw <- target_gw - 1
mid_match <- mid_match %>% filter(gameweek <= last_completed_gw)

rolling <- mid_match %>%
  arrange(player_id, gameweek) %>%
  group_by(player_id, web_name, team) %>%
  mutate(
    games_window   = slide_dbl(minutes_played, ~ sum(!is.na(.x)), .before = window - 1, .complete = FALSE),
    minutes_window = slide_dbl(minutes_played, sum,               .before = window - 1, .complete = FALSE),
    xgi_window     = slide_dbl(xgi,            sum,               .before = window - 1, .complete = FALSE),
    xg_window      = slide_dbl(xg,             sum,               .before = window - 1, .complete = FALSE),
    xa_window      = slide_dbl(xa,             sum,               .before = window - 1, .complete = FALSE),
    goals_window   = slide_dbl(goals,          sum,               .before = window - 1, .complete = FALSE),
    assists_window = slide_dbl(assists,        sum,               .before = window - 1, .complete = FALSE),
    shots_window   = slide_dbl(shots_on_target,sum,               .before = window - 1, .complete = FALSE),
    chances_window = slide_dbl(chances_created,sum,               .before = window - 1, .complete = FALSE),
    cs_window      = slide_dbl(clean_sheet,    sum,               .before = window - 1, .complete = FALSE)
  ) %>%
  slice_max(gameweek, n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  filter(
    games_window >= min_games,
    gameweek     >= last_completed_gw - recency_gws   # must have played recently
  ) %>%
  mutate(
    avg_minutes    = minutes_window / games_window,
    xgi_per_90     = if_else(minutes_window > 0, (xgi_window / minutes_window) * 90, NA_real_),
    xg_per_90      = if_else(minutes_window > 0, (xg_window  / minutes_window) * 90, NA_real_),
    xa_per_90      = if_else(minutes_window > 0, (xa_window  / minutes_window) * 90, NA_real_),
    cs_rate        = cs_window / games_window,
    goal_inv_total = goals_window + assists_window
  )


#####################################################################
# Apply budget filter, join fixture difficulty, flag criteria
#####################################################################

median_elo <- median(gw32_fix$opponent_elo, na.rm = TRUE)

results <- rolling %>%
  inner_join(affordable, by = "player_id") %>%
  left_join(gw32_fix,   by = "team") %>%
  mutate(
    cost_m        = now_cost,
    fixture_label = case_when(
      opponent_elo < median_elo - 50 ~ "Easy",
      opponent_elo < median_elo      ~ "Favourable",
      opponent_elo < median_elo + 50 ~ "Tough",
      TRUE                           ~ "Very Tough"
    ),
    flag_attack   = xgi_per_90  >= xgi_threshold,
    flag_minutes  = avg_minutes >= min_minutes,
    flag_fixture  = opponent_elo < median_elo
  ) %>%
  filter(flag_attack | (flag_minutes & flag_fixture))


#####################################################################
# Output
#####################################################################

output <- results %>%
  mutate(criteria_met = flag_attack + flag_minutes + flag_fixture) %>%
  arrange(desc(criteria_met), desc(xgi_per_90), desc(goal_inv_total)) %>%
  select(
    web_name, team, cost_m,
    games   = games_window,
    avg_min = avg_minutes,
    xgi_p90 = xgi_per_90,
    xg_p90  = xg_per_90,
    xa_p90  = xa_per_90,
    g       = goals_window,
    a       = assists_window,
    cs_rate,
    opp_elo = opponent_elo,
    fixture = fixture_label,
    criteria_met,
    flag_attack, flag_minutes, flag_fixture
  ) %>%
  mutate(across(where(is.double), ~ round(.x, 2)))

cat("\n=== GW32 Midfielder Shortlist (budget <= 9.4m) ===\n\n")
print(output, n = Inf, width = Inf)

cat("\n--- Criteria flags ---\n")
cat("flag_attack   : xGI per 90 >=", xgi_threshold, "\n")
cat("flag_minutes  : avg minutes per game >=", min_minutes, "\n")
cat("flag_fixture  : opponent ELO below median\n")
cat("Median GW32 opponent ELO:", round(median_elo, 1), "\n")
cat("Recency filter: must have played in GW >=", last_completed_gw - recency_gws, "\n")
