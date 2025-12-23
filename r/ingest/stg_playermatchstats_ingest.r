

###############################################################################
# Script Name: stg_playermatchstats_stats.R
# Date: 2024-10-07
# Goal: Loop through player_gameweek_stats.csv tables across GW1..GW38, combine into one df

# Good
###############################################################################

root <- "C:/dev/fpl_analytics/data/external/FPL-Core-Insights/data/2025-2026/By Gameweek"

read_gw_base <- function(n) {
  csv_path <- file.path(root, paste0("GW", n), "playermatchstats.csv")
  
  if (!file.exists(csv_path)) {
    warning(sprintf("Missing file for GW%d: %s", n, csv_path))
    return(NULL)
  }
  
  # Check if file has content before reading
  if (file.info(csv_path)$size == 0) {
    warning(sprintf("Blank file for GW%d: %s", n, csv_path))
    return(NULL)
  }
  
  d <- read.csv(csv_path, stringsAsFactors = FALSE, check.names = FALSE)
  
  # Also skip if header exists but no rows
  if (nrow(d) == 0) {
    warning(sprintf("Empty data in GW%d: %s", n, csv_path))
    return(NULL)
  }
  
  d$gameweek <- n
  return(d)
}

# Read all gameweeks into list
lst <- lapply(1:38, read_gw_base)

# Bind only non-null results
df <- do.call(rbind, lst[!vapply(lst, is.null, logical(1))])

# Quick checks
cat("Rows:", nrow(df), "  Cols:", ncol(df), "\n")
print(head(df, 3))

# Export to csv
write.csv(df,
          "C:/dev/fpl_analytics/data/processed/stg_playermatchstats.csv",
          row.names = FALSE)
