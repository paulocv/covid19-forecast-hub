library(epipredict)

check_data_latency <- function(
  epi_df,
  reference_date,
  desired_max_time_value,
  target_label
) {
  excess_latency_tbl <- epi_df |>
    tidyr::drop_na(observation) |>
    dplyr::group_by(geo_value) |>
    dplyr::summarize(max_time_value = max(time_value), .groups = "drop") |>
    dplyr::mutate(
      excess_latency = pmax(
        as.integer(desired_max_time_value - max_time_value) %/% 7L,
        0L
      ),
      has_excess_latency = excess_latency > 0L
    )

  overlatent_err_thresh <- 0.20
  prop_locs_overlatent <- mean(excess_latency_tbl$has_excess_latency)

  if (prop_locs_overlatent > overlatent_err_thresh) {
    cli::cli_abort(
      paste0(
        "{target_label} forecast: More than ",
        "{100 * overlatent_err_thresh}% of locations have excess latency. ",
        "The reference date is {reference_date}, so we desire observations ",
        "at least through {desired_max_time_value}. However, ",
        "{nrow(excess_latency_tbl |> dplyr::filter(has_excess_latency))} ",
        "location{?s} had excess latency."
      )
    )
  } else if (prop_locs_overlatent > 0) {
    cli::cli_warn(
      paste0(
        "{target_label} forecast: Some locations have excess latency. ",
        "The reference date is {reference_date}, so we desire observations ",
        "at least through {desired_max_time_value}. However, ",
        "{nrow(excess_latency_tbl |> dplyr::filter(has_excess_latency))} ",
        "location{?s} had excess latency."
      )
    )
  }
}

make_baseline_forecast <- function(
  target_timeseries_path,
  target_name,
  target_label,
  reference_date,
  desired_max_time_value
) {
  epi_df <- nanoparquet::read_parquet(target_timeseries_path) |>
    dplyr::filter(target == target_name) |>
    dplyr::filter(
      as_of == max(as_of)
    ) |>
    dplyr::rename(
      geo_value = state,
      time_value = date
    ) |>
    dplyr::select(-c("as_of", "location", "target")) |>
    epiprocess::as_epi_df()

  check_data_latency(
    epi_df,
    reference_date,
    desired_max_time_value,
    target_label
  )

  rng_seed <- as.integer((59460707 + as.numeric(reference_date)) %% 2e9)
  preds <- withr::with_rng_version(
    "4.0.0",
    withr::with_seed(rng_seed, {
      fcst <- epipredict::cdc_baseline_forecaster(
        epi_df |>
          dplyr::filter(
            time_value <= desired_max_time_value
          ),
        "observation",
        epipredict::cdc_baseline_args_list(aheads = 1:4, nsims = 1e5)
      )
      # advance forecast_date by a week due to data latency and
      # create forecast for horizon -1
      fcst$predictions |>
        dplyr::mutate(
          forecast_date = reference_date,
          ahead = as.integer(.data$target_date - reference_date) %/% 7L
        ) |>
        # prepare -1 horizon predictions
        dplyr::bind_rows(
          epi_df |>
            tidyr::drop_na(observation) |>
            dplyr::slice_max(time_value) |>
            dplyr::transmute(
              forecast_date = reference_date,
              target_date = reference_date - 7L,
              ahead = -1L,
              geo_value,
              .pred = observation,
              .pred_distn = hardhat::quantile_pred(
                values = matrix(
                  rep(
                    observation,
                    each = length(
                      epipredict::cdc_baseline_args_list()$quantile_levels
                    )
                  ),
                  nrow = length(observation),
                  ncol = length(
                    epipredict::cdc_baseline_args_list()$quantile_levels
                  ),
                  byrow = TRUE
                ),
                quantile_levels = epipredict::cdc_baseline_args_list()$quantile_levels # nolint
              )
            )
        )
    })
  )

  preds_formatted <- preds |>
    epipredict::flusight_hub_formatter(
      target = target_name,
      output_type = "quantile"
    ) |>
    tidyr::drop_na(output_type_id) |>
    dplyr::arrange(target, horizon, location) |>
    dplyr::select(
      reference_date,
      horizon,
      target,
      target_end_date,
      location,
      output_type,
      output_type_id,
      value
    )
  return(preds_formatted)
}

parser <- argparser::arg_parser(
  "Create a flat baseline model for covid-19 hospital admissions"
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

desired_max_time_value <- reference_date - 7L
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

target_timeseries_path <- fs::path(
  base_hub_path,
  "target-data",
  "time-series.parquet"
)

preds_hosp <- make_baseline_forecast(
  target_timeseries_path = target_timeseries_path,
  target_name = "wk inc covid hosp",
  target_label = "Hospital Admissions",
  reference_date = reference_date,
  desired_max_time_value = desired_max_time_value
)

preds_ed <- make_baseline_forecast(
  target_timeseries_path = target_timeseries_path,
  target_name = "wk inc covid prop ed visits",
  target_label = "Proportion ED Visits",
  reference_date = reference_date,
  desired_max_time_value = desired_max_time_value
)

output_dirpath <- fs::path(base_hub_path, "model-output", "CovidHub-baseline")
if (!fs::dir_exists(output_dirpath)) {
  fs::dir_create(output_dirpath, recursive = TRUE)
}

readr::write_csv(
  dplyr::bind_rows(preds_hosp, preds_ed),
  fs::path(
    output_dirpath,
    paste0(as.character(reference_date), "-CovidHub-baseline.csv")
  )
)
