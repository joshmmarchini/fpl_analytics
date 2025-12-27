
{{ config(materialized='table') }}

SELECT *
FROM read_csv_auto('C:/dev/fpl_analytics/data/processed/stg_playermatchstats.csv')