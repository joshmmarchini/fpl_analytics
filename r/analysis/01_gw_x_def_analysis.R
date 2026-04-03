#####################################################################
# GW32 Defender Shortlist — budget 6.3m
# Criteria:
#   1. CBIT >= 10 cumulative over last 5 GWs
#   2. Clean sheet candidate: avg minutes >= 60, CS rate >= 40%,
#      and favourable GW32 fixture (opponent ELO below median)
#   3. Goal / assist threat: xGI per 90 >= 0.10 or
#      at least one G/A in the last 5 GWs
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

target_gw     <- 32    # upcoming gameweek to plan for
budget        <- 6.3   # maximum price in millions
window        <- 5     # rolling game window (last N matches)
min_games     <- 3     # minimum appearances in window to be included
min_minutes   <- 60    # minutes threshold for clean sheet eligibility
cbit_target   <- 5     # avg CBIT per game threshold
cs_rate_min   <- 0.40  # minimum clean sheet rate (2-in-5)
xgi_per90_min <- 0.10  # minimum xGI per 90 for goal/assist flag


#####################################################################
# DB Connection & Data Load
#####################################################################

con <- dbConnect(
  duckdb(),
  dbdir     = here("duckdb", "fpl-insights.duckdb"),
  read_only = TRUE
)

# Per-match defender stats across all GWs
def_match <- dbGetQuery(con, "
  SELECT
    f.player_id,
    p.web_name,
    t.short_name                                                     AS team,
    f.gameweek,
    f.minutes_played,
    f.cbit,
    f.cbitr,
    f.xg,
    f.xa,
    f.xgi,
    f.goals,
    f.assists,
    f.team_goals_conceded,
    CASE WHEN f.team_goals_conceded = 0
          AND f.minutes_played >= 60 THEN 1 ELSE 0 END              AS clean_sheet
  FROM analytics.fact_playermatchstats f
  JOIN analytics.dim_players p ON f.player_id  = p.player_id
  JOIN analytics.dim_teams   t ON p.team_code  = t.code
  WHERE p.position = 'Defender'
")

# Affordable defenders (price <= 6.3m)
affordable <- dbGetQuery(con, "
  SELECT player_id, now_cost
  FROM analytics.vw_player_cost_current
  WHERE position = 'Defender'
    AND now_cost <= 6.3
")

# GW32 fixture difficulty
gw32_fix <- dbGetQuery(con, "
  SELECT team, opponent_elo
  FROM analytics.vw_team_gw_opponent_elo
  WHERE gameweek = 32
")

dbDisconnect(con, shutdown = TRUE)


#####################################################################
# Rolling last-N-game stats (evaluated at each player's latest GW)
#####################################################################

# Cap to completed GWs — data/external updates 2x daily so future GW
# files may already exist before matches are played
last_completed_gw <- target_gw - 1
def_match <- def_match %>% filter(gameweek <= last_completed_gw)

rolling <- def_match %>%
  arrange(player_id, gameweek) %>%
  group_by(player_id, web_name, team) %>%
  mutate(
    games_window   = slide_dbl(minutes_played, ~ sum(!is.na(.x)), .before = window - 1, .complete = FALSE),
    minutes_window = slide_dbl(minutes_played, sum,               .before = window - 1, .complete = FALSE),
    cbit_window    = slide_dbl(cbit,           sum,               .before = window - 1, .complete = FALSE),
    xgi_window     = slide_dbl(xgi,            sum,               .before = window - 1, .complete = FALSE),
    xa_window      = slide_dbl(xa,             sum,               .before = window - 1, .complete = FALSE),
    goals_window   = slide_dbl(goals,          sum,               .before = window - 1, .complete = FALSE),
    assists_window = slide_dbl(assists,        sum,               .before = window - 1, .complete = FALSE),
    cs_window      = slide_dbl(clean_sheet,    sum,               .before = window - 1, .complete = FALSE)
  ) %>%
  # Evaluate at each player's own most recent GW — handles teams with a
  # game in hand (e.g. Man City, Crystal Palace at GW30 vs rest at GW31).
  # with_ties = FALSE prevents duplicates for DGW players (2 matches same GW)
  slice_max(gameweek, n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  filter(games_window >= min_games) %>%
  mutate(
    avg_minutes   = minutes_window / games_window,
    cbit_per_game = cbit_window    / games_window,
    xgi_per_90    = if_else(minutes_window > 0, (xgi_window / minutes_window) * 90, NA_real_),
    xa_per_90     = if_else(minutes_window > 0, (xa_window  / minutes_window) * 90, NA_real_),
    cs_rate       = cs_window      / games_window,
    goal_inv_total = goals_window  + assists_window
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
    flag_cbit     = cbit_per_game   >= cbit_target,
    flag_cs       = avg_minutes    >= min_minutes &
                    cs_rate        >= cs_rate_min  &
                    opponent_elo   <  median_elo,
    flag_goal_inv = xgi_per_90     >= xgi_per90_min | goal_inv_total >= 1
  ) %>%
  filter(flag_cbit | flag_cs | flag_goal_inv)


#####################################################################
# Output — sorted by number of criteria met, then CS rate
#####################################################################

output <- results %>%
  mutate(
    criteria_met = flag_cbit + flag_cs + flag_goal_inv
  ) %>%
  arrange(desc(criteria_met), desc(cs_rate), desc(cbit_per_game)) %>%
  select(
    web_name, team, cost_m,
    games  = games_window,
    avg_min = avg_minutes,
    cbit_pg = cbit_per_game,
    cs_rate,
    cs_n    = cs_window,
    xgi_p90 = xgi_per_90,
    g       = goals_window,
    a       = assists_window,
    opp_elo = opponent_elo,
    fixture = fixture_label,
    criteria_met,
    flag_cbit, flag_cs, flag_goal_inv
  ) %>%
  mutate(across(where(is.double), ~ round(.x, 2)))

cat("\n=== GW32 Defender Shortlist (budget <= 6.3m) ===\n\n")
print(output, n = Inf, width = Inf)

cat("\n--- Criteria flags ---\n")
cat("flag_cbit     : avg CBIT per game >=", cbit_target, "\n")
cat("flag_cs       : avg mins >= 60, CS rate >=", cs_rate_min, ", opponent ELO below median\n")
cat("flag_goal_inv : xGI/90 >=", xgi_per90_min, "or at least 1 G/A in last", window, "games\n")
cat("Median GW32 opponent ELO:", round(median_elo, 1), "\n")
