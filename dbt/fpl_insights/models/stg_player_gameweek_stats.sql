
{{ config(materialized='table') }}

SELECT *
FROM read_csv_auto('C:/Scripts/fpl_insights_ingestion_scripts/stg_player_gameweek_stats.csv')