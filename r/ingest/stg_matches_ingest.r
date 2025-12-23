# #############################################################################
# Script Name: stg_matches_ingestion.R
# Date: 9/30/2024 # nolint
# Goal: Loop through matches table create df of all matches
# ############################################################################
library(here)

root<- here(
"data",
"external",
"FPL-Core-Insights",
"data",
"2025-2026",
"By Gameweek"
)


# Run here::here() --> should show your project root
# Run print(root) to see full project path
dir.exists(root) # should be true



read_gw_base <- function(n) {
  csv_path <- file.path(root, paste0("GW", n), "matches.csv")
  # Skip missing files
  if (!file.exists(csv_path)) {
    warning(sprintf("Missing file for GW%d: %s", n, csv_path))
    return(NULL)
  }
d <- read.csv(csv_path, stringsAsFactors = FALSE, check.names = FALSE)
  
  # Skip empty files
  if (nrow(d) == 0) {
    warning(sprintf("Empty file for GW%d: %s", n, csv_path))
    return(NULL)
  }
  
  d$gameweek <- n
  d
}

# Read all gameweeks
lst <- lapply(1:38, read_gw_base)

# Drop NULLs and bind
df <- do.call(rbind, Filter(Negate(is.null), lst))

# Quick sanity check
cat("Rows:", nrow(df), "  Cols:", ncol(df), "\n")
head(df, 3)

# Export to CSV
write.csv(
  df,
  "C:/dev/fpl_analytics/data/processed/stg_matches.csv",
  row.names = FALSE
)
