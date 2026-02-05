
{{ config(materialized='table') }}

SELECT
    * EXCLUDE (filename),
    CAST(regexp_extract(filename, 'GW(\d+)', 1) AS INTEGER) AS gameweek
FROM read_csv_auto(
    '{{ var("project_root") }}/data/external/FPL-Core-Insights/data/2025-2026/By Gameweek/GW*/playerstats.csv',
    filename=true,
    union_by_name=true
)
