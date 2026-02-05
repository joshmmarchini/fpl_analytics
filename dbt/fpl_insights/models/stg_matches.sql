
{{ config(materialized='table') }}

SELECT * EXCLUDE (filename)
FROM read_csv_auto(
    '{{ var("project_root") }}/data/external/FPL-Core-Insights/data/2025-2026/By Gameweek/GW*/matches.csv',
    filename=true,
    union_by_name=true
)
