
{{ config(materialized='table') }}

SELECT *
FROM read_csv_auto('{{ get_project_root() }}/data/external/FPL-Core-Insights/data/2025-2026/players.csv')