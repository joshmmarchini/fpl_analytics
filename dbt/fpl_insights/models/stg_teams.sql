
{{ config(materialized='table') }}

SELECT *
FROM read_csv_auto('C:/dev/fpl_analytics/data/external/FPL-Core-Insights/data/2025-2026/teams.csv')