{{ config(materialized='view') }}

with gw_epl as (

    -- Gameweek-level player stats
    select
        gw.id,
        gw.gameweek,
        p.web_name,
        t.short_name as team,
        gw.total_points_gw,
        gw.bonus_points_gw,
        gw.bps_gw,
        gw.expected_goal_involvements_gw,
        gw.influence_gw,
        gw.creativity_gw,
        gw.threat_gw,
        gw.form,
        gw.ict_index_gw,
        gw.minutes_played_gw,
        gw.defensive_contribution_gw,
        gw.tackles_gw,
        gw.clearances_blocks_interceptions_gw,
        gw.recoveries_gw
    from {{ ref('fact_playerstats') }} gw
    left join {{ ref('dim_players') }} p
        on gw.id = p.player_id
    left join {{ ref('dim_teams') }} t
        on p.team_code = t.code

),

match_epl as (

    -- Match-level player stats (Premier League only)
    select
        m.gameweek,
        m.player_id as id,
        m.match_id,
        m.minutes_played,
        m.goals,
        m.assists,
        m.total_shots,
        m.xg,
        m.xa,
        round(m.xgi, 2) as xgi,
        m.shots_on_target,
        m.big_chances_missed,
        m.touches_opposition_box,
        m.touches,
        m.accurate_passes,
        m.chances_created,
        m.final_third_passes,
        m.accurate_crosses,
        m.accurate_long_balls,
        m.dribbled_past,
        m.saves,
        m.xgot_faced,
        m.corners,
        m.xgot,
        coalesce(m.penalties_scored, 0)
            + coalesce(m.penalties_missed, 0) as penalties_attempted,
        m.cbit,
        m.cbitr
    from {{ ref('fact_playermatchstats') }} m
    left join {{ ref('dim_matches') }} dm
        on m.match_id = dm.match_id
    where dm.tournament = 'prem'

)

select
    gw.*,
    m.match_id,
    m.minutes_played,
    m.goals,
    m.assists,
    m.total_shots,
    m.xg,
    m.xa,
    m.xgi,
    m.shots_on_target,
    m.big_chances_missed,
    m.touches_opposition_box,
    m.touches,
    m.accurate_passes,
    m.chances_created,
    m.final_third_passes,
    m.accurate_crosses,
    m.accurate_long_balls,
    m.dribbled_past,
    m.saves,
    m.xgot_faced,
    m.corners,
    m.xgot,
    m.penalties_attempted,
    m.cbit,
    m.cbitr
from gw_epl gw
left join match_epl m
    on gw.id = m.id
   and gw.gameweek = m.gameweek