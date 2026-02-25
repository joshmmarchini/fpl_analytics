{{ config(materialized='table') }}

with src as (
  select * from {{ ref('stg_players') }}
),

dedup as (
  select *
  from src
  qualify row_number() over (partition by player_id order by player_id) = 1
)

select
    cast(player_code as integer)                as player_code,
    cast(player_id as integer)                  as player_id,
    cast(trim(first_name) as varchar)           as first_name,
    cast(trim(second_name) as varchar)          as second_name,
    cast(trim(web_name) as varchar)             as web_name,
    cast(team_code as integer)                  as team_code,
    cast(trim(position) as varchar)             as position
from dedup

