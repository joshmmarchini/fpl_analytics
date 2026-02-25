{{ config(materialized = 'view') }}

WITH stg_data AS (
    SELECT 
        CAST(m.gameweek AS INT) AS gameweek,
        home.short_name AS home_short_name,
        away.short_name AS away_short_name,
        home.elo AS home_elo,
        away.elo AS away_elo
    FROM {{ ref('dim_matches') }} AS m
    LEFT JOIN {{ ref('dim_teams') }} AS home ON home.code = m.home_team
    LEFT JOIN {{ ref('dim_teams') }} AS away ON away.code = m.away_team
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
),

pivoted AS (
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
)

SELECT 
    team,
    CAST(REPLACE(column_name, 'GW', '') AS INT) AS gameweek,
    value AS opponent_elo
FROM pivoted
UNPIVOT (value FOR column_name IN (
    GW1, GW2, GW3, GW4, GW5, GW6, GW7, GW8, GW9, GW10,
    GW11, GW12, GW13, GW14, GW15, GW16, GW17, GW18, GW19, GW20,
    GW21, GW22, GW23, GW24, GW25, GW26, GW27, GW28, GW29, GW30,
    GW31, GW32, GW33, GW34, GW35, GW36, GW37, GW38
))
ORDER BY team, gameweek
