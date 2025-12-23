{{ config(materialized='table') }}

SELECT
    CAST(player_id AS TEXT) || '_' || match_id AS player_match_id,
    *,
    -- defensive contributions
    (clearances + blocks + interceptions + tackles) AS cbit,
    (clearances + blocks + interceptions + tackles + recoveries) AS cbitr,
    (xg + xa) AS xgi
FROM {{ ref('stg_playermatchstats') }}
