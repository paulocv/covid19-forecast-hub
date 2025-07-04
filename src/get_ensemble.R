# R script to create ensemble forecats using models submitted to the CovidHub

parser <- argparser::arg_parser(
  "Create a hub ensemble model for covid-19 hospital admissions"
)
parser <- argparser::add_argument(
  parser,
  "--reference-date",
  help = "reference date in YYYY-MM-DD format"
)
parser <- argparser::add_argument(
  parser,
  "--base-hub-path",
  type = "character",
  help = "Path to the Covid19 forecast hub directory."
)

args <- argparser::parse_args(parser)
reference_date <- as.Date(args$reference_date)
base_hub_path <- args$base_hub_path

dow_supplied <- lubridate::wday(reference_date, week_start = 7, label = FALSE)
if (dow_supplied != 7) {
  cli::cli_abort(
    message = paste0(
      "Expected `reference_date` to be a Saturday, day number 7 ",
      "of the week, given the `week_start` value of Sunday. ",
      "Got {reference_date}, which is day number ",
      "{dow_supplied} of the week."
    )
  )
}

task_id_cols <- c(
  "reference_date",
  "location",
  "horizon",
  "target",
  "target_end_date"
)
output_dirpath <- fs::path(base_hub_path, "model-output", "CovidHub-ensemble")
if (!fs::dir_exists(output_dirpath)) {
  fs::dir_create(output_dirpath, recursive = TRUE)
}

# Get current forecasts from the hub, excluding baseline and ensembles
hub_content <- hubData::connect_hub(base_hub_path)
current_forecasts <- hub_content |>
  dplyr::filter(
    reference_date == !!reference_date,
    !str_detect(model_id, "CovidHub")
  ) |>
  hubData::collect_hub()

list_model_id_current <- unique(current_forecasts$model_id)
weekly_models <- hubData::load_model_metadata(
  base_hub_path,
  model_ids = list_model_id_current
) |>
  dplyr::distinct(.data$model_id, .data$designated_model) |>
  dplyr::select(Model = "model_id", Designated_Model = "designated_model")

write.csv(
  weekly_models,
  file.path(
    "auxiliary-data",
    "weekly-model-submissions",
    paste0(
      as.character(reference_date),
      "-",
      "models-submitted-to-hub.csv"
    )
  ),
  row.names = FALSE
)

eligible_models <- weekly_models |> dplyr::filter(.data$Designated_Model)
models <- eligible_models$Model
current_forecasts <- current_forecasts |>
  dplyr::filter(model_id %in% models)

# QUANTILE ENSEMBLE
quantile_forecasts <- current_forecasts |>
  dplyr::filter(
    output_type == "quantile",
    target == "wk inc covid hosp"
  ) |>
  # ensure quantiles are handled accurately even with leading/trailing zeros
  dplyr::mutate(output_type_id = as.factor(as.numeric(output_type_id)))

median_ensemble_outputs <- quantile_forecasts |>
  hubEnsembles::simple_ensemble(
    agg_fun = "median",
    model_id = "CovidHub-quantile-median-ensemble",
    task_id_cols = task_id_cols
  ) |>
  dplyr::mutate(value = pmax(value, 0)) |>
  dplyr::select(-model_id)

write.csv(
  median_ensemble_outputs,
  file.path(
    output_dirpath,
    paste0(as.character(reference_date), "-", "CovidHub-ensemble.csv")
  ),
  row.names = FALSE
)
