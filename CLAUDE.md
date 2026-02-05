# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Fantasy Premier League analytics platform. Ingests FPL player/match data from CSV files, transforms it through a dbt/DuckDB pipeline, and performs statistical analysis (Bayesian modeling, fixture difficulty, rolling form metrics) in R.

## Tech Stack

- **DuckDB** - Embedded analytical database (`duckdb/fpl-insights.duckdb`)
- **dbt** - SQL transformation layer (profile: `fpl_insights`, project in `dbt/fpl_insights/`)
- **R** - Data ingestion and statistical analysis (tidyverse, DBI, duckdb, slider, zoo, ggrepel)

## Data Pipeline Architecture

```
External CSVs (data/external/FPL-Core-Insights/data/2025-2026/By Gameweek/)
    │
    ▼
R Ingest Scripts (r/ingest/) → CSV files (data/processed/)
    │
    ▼
dbt Staging Models (stg_*) → read_csv_auto() from processed CSVs
    │
    ▼
dbt Fact/Dimension Models (fact_*, dim_*) → business logic, LAG windows, calculated fields
    │
    ▼
dbt Analytical Views (vw_*) → joined, analysis-ready datasets
    │
    ▼
R Analysis Scripts (r/analysis/) → query views via DBI, produce plots and exports
```

## Common Commands

### dbt (run from `dbt/fpl_insights/`)
```bash
dbt run              # Build all models
dbt run -s model_name  # Build a single model
dbt test             # Run dbt tests
dbt clean            # Remove target/ and dbt_packages/
```

### R Scripts
Run interactively in RStudio or via `Rscript <path>`. No formal build system. Scripts connect to DuckDB at `C:/dev/fpl_analytics/duckdb/fpl-insights.duckdb`.

**Ingestion order:** Run ingest scripts first to populate `data/processed/` CSVs, then `dbt run` to load into DuckDB, then analysis scripts.

## Key dbt Models

| Layer | Models | Purpose |
|-------|--------|---------|
| Staging | `stg_players`, `stg_teams`, `stg_matches`, `stg_playerstats`, `stg_playermatchstats`, `stg_player_gameweek_stats` | Read raw CSVs into DuckDB |
| Dimension | `dim_players`, `dim_teams`, `dim_matches` | Deduplicated reference entities |
| Fact | `fact_playerstats`, `fact_playermatchstats` | Calculated metrics: `xgi` (xg+xa), `cbit` (clearances+blocks+interceptions+tackles), GW deltas via LAG |
| View | `vw_gw_player_data`, `vw_player_cost_current`, `vw_team_gw_opponent_elo` | Joined analytical views used by R scripts |

## Key R Scripts

- **`r/ingest/`** - Four scripts that loop GW1-GW38, reading CSVs from the external dataset and combining them into single processed files
- **`r/analysis/bayes_analysis.R`** - Bayesian probability modeling for player metrics (xgi, defensive contributions). Uses `aggregate_window()` helper for flexible windowed aggregation
- **`r/analysis/fixture_analysis.R`** - ELO-based fixture difficulty ratings
- **`r/analysis/gw_18.R`** - Rolling 4-game window metrics and per-90 normalization
- **`r/exports/current_player_cost.r`** - Exports current player pricing from DuckDB to CSV

## Important Conventions

- R scripts use hardcoded absolute paths to `C:/dev/fpl_analytics/` for DuckDB connections and file I/O
- dbt models use `read_csv_auto()` (DuckDB function) in staging models to import from `data/processed/`
- DuckDB schema: `analytics` (used in R queries, e.g., `analytics.vw_gw_player_data`)
- External data source is the FPL-Core-Insights dataset (updated 2x daily), stored in `data/external/`
- All data files, DuckDB databases, and logs are git-ignored
