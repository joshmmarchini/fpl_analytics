{{ config(materialized = 'view') }}

SELECT
    p.player_id,
    p.web_name,
    p.position,
    p.team_code,
    t.short_name AS team_name,
    s.now_cost
FROM {{ ref('fact_playerstats') }} s
LEFT JOIN {{ ref('dim_players') }} p ON s.id = p.player_id
LEFT JOIN {{ ref('dim_teams') }} t ON p.team_code = t.code
WHERE 
    s.gameweek = (SELECT MAX(gameweek) FROM {{ ref('stg_playerstats') }})
