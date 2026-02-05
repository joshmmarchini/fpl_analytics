
#####################################################################
# Load libraries
#####################################################################
library(DBI)
library(duckdb)
library(here)
library(readr)

#####################################################################
# Connect to duckdb
#####################################################################

# fpl_insights db connection
con <- dbConnect(
  duckdb(),
  dbdir = "C:/dev/fpl_analytics/duckdb/fpl-insights.duckdb",
  read_only = FALSE
)


dbListTables(con)


cost <- dbGetQuery(con,
"
SELECT*
FROM analytics.vw_player_cost_current                   
")


dbDisconnect(con, shutdown = TRUE)

# Export data
write_csv(
  cost,
  here("data", "exports", "current_player_cost.csv")
)

