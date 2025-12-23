
{{ config(materialized='table') }}

SELECT *
FROM read_csv_auto('C:/Users/joshm/OneDrive/Desktop/Projects/FPL-Elo-Insights/data/2025-2026/players.csv')