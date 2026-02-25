{{ config(materialized='table') }}


SELECT
    CAST(id AS TEXT) || '_' || CAST(gw AS TEXT) AS id_gw,
    total_points - LAG(total_points, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS total_points_gw,
    bonus - LAG(bonus, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS bonus_points_gw,
    bps - LAG(bps, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS bps_gw,
    expected_goal_involvements - LAG(expected_goal_involvements, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS expected_goal_involvements_gw,
    influence - LAG(influence, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS influence_gw,
    creativity - LAG(creativity, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS creativity_gw,
    threat - LAG(threat, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS threat_gw,
    ict_index - LAG(ict_index, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS ict_index_gw,
    minutes - LAG(minutes, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS minutes_played_gw,
    defensive_contribution - LAG(defensive_contribution, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS defensive_contribution_gw,
    tackles - LAG(tackles, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS tackles_gw,
    clearances_blocks_interceptions - LAG(clearances_blocks_interceptions, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS clearances_blocks_interceptions_gw,
    recoveries - LAG(recoveries, 1, 0) OVER (PARTITION BY id ORDER BY gameweek) AS recoveries_gw,
    *
FROM {{ ref('stg_playerstats') }}

