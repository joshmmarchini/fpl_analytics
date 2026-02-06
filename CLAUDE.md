# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Fantasy Premier League analytics platform. Ingests FPL player/match data from CSV files, transforms it through a dbt/DuckDB pipeline, and performs statistical analysis (Bayesian modeling, fixture difficulty, rolling form metrics) in R.

## Tech Stack

- **DuckDB** - Embedded analytical database (`duckdb/fpl-insights.duckdb`)
- **dbt** - SQL transformation layer (profile: `fpl_insights`, project in `dbt/fpl_insights/`)
- **R** - Statistical analysis (tidyverse, DBI, duckdb, slider, zoo, ggrepel)

## Data Pipeline Architecture

```
External CSVs (data/external/FPL-Core-Insights/data/2025-2026/)
    │
    ▼
dbt Staging Models (stg_*) → read_csv_auto() with glob patterns directly from external CSVs
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
Run interactively in RStudio or via `Rscript <path>`. No formal build system. Scripts connect to DuckDB via `here("duckdb", "fpl-insights.duckdb")`.

**Pipeline order:** Run `dbt run` to load external CSVs into DuckDB, then run R analysis scripts.

## Key dbt Models

| Layer | Models | Purpose |
|-------|--------|---------|
| Staging | `stg_players`, `stg_teams`, `stg_matches`, `stg_playerstats`, `stg_playermatchstats`, `stg_player_gameweek_stats` | Glob-read external CSVs into DuckDB, extract gameweek from file path |
| Dimension | `dim_players`, `dim_teams`, `dim_matches` | Deduplicated reference entities |
| Fact | `fact_playerstats`, `fact_playermatchstats` | Calculated metrics: `xgi` (xg+xa), `cbit` (clearances+blocks+interceptions+tackles), GW deltas via LAG |
| View | `vw_gw_player_data`, `vw_player_cost_current`, `vw_team_gw_opponent_elo` | Joined analytical views used by R scripts |

## Key R Scripts

- **`r/analysis/bayes_analysis.R`** - Bayesian probability modeling for player metrics (xgi, defensive contributions). Uses `aggregate_window()` helper for flexible windowed aggregation
- **`r/analysis/fixture_analysis.R`** - ELO-based fixture difficulty ratings
- **`r/analysis/gw_18.R`** - Rolling 4-game window metrics and per-90 normalization
- **`r/exports/current_player_cost.r`** - Exports current player pricing from DuckDB to CSV

## Important Conventions

- R scripts use the `here` package for all file paths (DuckDB connections, CSV I/O). Never use hardcoded absolute paths; always use `here()` to build paths relative to the project root
- dbt staging models use `read_csv_auto()` with glob patterns to read directly from `data/external/`. The `get_project_root()` macro resolves the base path from the `FPL_PROJECT_ROOT` environment variable
- DuckDB schema: `analytics` (used in R queries, e.g., `analytics.vw_gw_player_data`)
- External data source is the FPL-Core-Insights dataset (updated 2x daily), stored in `data/external/`
- All data files, DuckDB databases, and logs are git-ignored
