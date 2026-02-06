# Install R packages required for FPL Analytics
#
# Run this script once after cloning the repository:
#   Rscript install.R
#
# Or run interactively in RStudio/R console:
#   source("install.R")

packages <- c(
  "DBI",
  "duckdb",
  "here",
  "tidyverse",
  "readr",
  "ggrepel",
  "slider",
  "zoo",
  "skimr"
)

install.packages(packages, repos = "https://cloud.r-project.org")

message("All packages installed successfully.")
