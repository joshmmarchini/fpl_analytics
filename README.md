# FPL Analytics

Fantasy Premier League analytics platform. Ingests FPL player/match data, transforms it through a dbt/DuckDB pipeline, and performs statistical analysis (Bayesian modeling, fixture difficulty, rolling form metrics) in R.

## Architecture

```
External CSVs (FPL-Core-Insights dataset)
    │
    ▼
dbt Staging Models ──► DuckDB (analytics schema)
    │
    ▼
dbt Fact/Dimension Models ──► Calculated metrics, LAG windows
    │
    ▼
dbt Analytical Views ──► Joined, analysis-ready datasets
    │
    ▼
R Analysis Scripts ──► Bayesian inference, visualizations, exports
```

## Prerequisites

- Python 3.9+
- R 4.0+
- Git

## Setup

### 1. Clone the repository

```bash
git clone https://github.com/joshmmarchini/fpl_analytics.git
cd fpl_analytics
```

### 2. Get the data

This project uses the [FPL-Core-Insights](https://github.com/vaastav/FPL-Core-Insights) dataset. Clone it into the `data/external/` directory:

```bash
mkdir -p data/external
git clone https://github.com/vaastav/FPL-Core-Insights.git data/external/FPL-Core-Insights
```

### 3. Install Python dependencies

```bash
pip install -r requirements.txt
```

### 4. Install R dependencies

```bash
Rscript install.R
```

Or in R/RStudio:
```r
source("install.R")
```

### 5. Configure dbt profile

Copy the example profile to your dbt config directory:

**Mac/Linux:**
```bash
mkdir -p ~/.dbt
cp dbt/fpl_insights/profiles.yml.example ~/.dbt/profiles.yml
```

**Windows:**
```powershell
mkdir -Force $env:USERPROFILE\.dbt
copy dbt\fpl_insights\profiles.yml.example $env:USERPROFILE\.dbt\profiles.yml
```

Then edit `~/.dbt/profiles.yml` and update the `path` to point to your local DuckDB file:
```yaml
path: /your/path/to/fpl_analytics/duckdb/fpl-insights.duckdb
```

### 6. Set the project root environment variable

dbt needs to know where to find the external CSV files. Set the `FPL_PROJECT_ROOT` environment variable to your project directory.

**Mac/Linux (add to ~/.bashrc or ~/.zshrc):**
```bash
export FPL_PROJECT_ROOT="/path/to/fpl_analytics"
```

**Windows (PowerShell):**
```powershell
$env:FPL_PROJECT_ROOT = "C:\path\to\fpl_analytics"
```

**Windows (permanent):**
```powershell
[Environment]::SetEnvironmentVariable("FPL_PROJECT_ROOT", "C:\path\to\fpl_analytics", "User")
```

Alternatively, pass it directly to dbt:
```bash
dbt run --vars '{"project_root": "/path/to/fpl_analytics"}'
```

### 7. Create the DuckDB database directory

```bash
mkdir -p duckdb
```

### 8. Build the pipeline

```bash
cd dbt/fpl_insights
dbt run
dbt test
```

## Usage

### Update data

Pull the latest FPL-Core-Insights data:
```bash
cd data/external/FPL-Core-Insights
git pull
```

Then rebuild:
```bash
cd dbt/fpl_insights
dbt run
```

### Run analysis scripts

From the project root in R/RStudio:

```r
# Bayesian player analysis
source("r/analysis/bayes_analysis.R")

# Fixture difficulty ratings
source("r/analysis/fixture_analysis.R")

# Rolling form metrics
source("r/analysis/gw_18.R")

# Export current player costs
source("r/exports/current_player_cost.r")
```

## Project Structure

```
fpl_analytics/
├── dbt/fpl_insights/        # dbt project
│   ├── models/              # SQL models (staging, fact, dim, views)
│   ├── macros/              # dbt macros
│   └── profiles.yml.example # Example dbt profile
├── r/
│   ├── analysis/            # R analysis scripts
│   └── exports/             # Data export scripts
├── data/
│   └── external/            # FPL-Core-Insights dataset (git-ignored)
├── duckdb/                  # DuckDB database files (git-ignored)
├── requirements.txt         # Python dependencies
├── install.R                # R package installer
└── README.md
```

## Key Models

| Layer | Models | Purpose |
|-------|--------|---------|
| Staging | `stg_players`, `stg_teams`, `stg_matches`, `stg_playerstats`, `stg_playermatchstats` | Glob-read external CSVs into DuckDB |
| Dimension | `dim_players`, `dim_teams`, `dim_matches` | Deduplicated reference entities |
| Fact | `fact_playerstats`, `fact_playermatchstats` | Calculated metrics (xgi, cbit), GW deltas via LAG |
| View | `vw_gw_player_data`, `vw_player_cost_current`, `vw_team_gw_opponent_elo` | Analysis-ready joined datasets |

