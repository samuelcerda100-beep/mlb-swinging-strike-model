library(tidyverse)

dir.create("data", showWarnings = FALSE)
dir.create("figures", showWarnings = FALSE)
dir.create("results", showWarnings = FALSE)


regular <- read_csv(
  "data/dodgers_2025_regular.csv",
  show_col_types = FALSE
)

postseason <- read_csv(
  "data/dodgers_2025_postseason.csv",
  show_col_types = FALSE
)

# Check the number of rows and columns
dim(regular)
dim(postseason)

# Confirm the game types
regular |> count(game_type)
postseason |> count(game_type)

# Check regular-season dates and number of games
regular |>
  summarise(
    first_date = min(game_date, na.rm = TRUE),
    last_date = max(game_date, na.rm = TRUE),
    games = n_distinct(game_pk)
  )

# Check postseason dates and number of games
postseason |>
  summarise(
    first_date = min(game_date, na.rm = TRUE),
    last_date = max(game_date, na.rm = TRUE),
    games = n_distinct(game_pk)
  )

# Check game types
regular |> count(game_type)
postseason |> count(game_type)

# Check dates, games, and pitching team
coverage <- bind_rows(
  regular |> mutate(dataset = "Regular season"),
  postseason |> mutate(dataset = "Postseason")
) |>
  mutate(
    pitching_team = if_else(
      inning_topbot == "Top",
      home_team,
      away_team
    )
  ) |>
  group_by(dataset, pitching_team) |>
  summarise(
    pitches = n(),
    games = n_distinct(game_pk),
    first_date = min(game_date, na.rm = TRUE),
    last_date = max(game_date, na.rm = TRUE),
    .groups = "drop"
  )

print(coverage)

# Combine the files and create the outcome
pitches <- bind_rows(
  regular |> mutate(dataset = "Regular season"),
  postseason |> mutate(dataset = "Postseason")
) |>
  distinct(game_pk, at_bat_number, pitch_number, .keep_all = TRUE) |>
  filter(
    !is.na(description),
    !str_detect(description, "bunt")
  ) |>
  mutate(
    swinging_strike = as.integer(
      description %in% c(
        "swinging_strike",
        "swinging_strike_blocked"
      )
    )
  )

# Check the number of each outcome
pitches |>
  count(dataset, swinging_strike)
pitches |> count(dataset, swinging_strike)

# Keep the columns needed for modeling
model_data <- pitches |>
  transmute(
    dataset,
    game_date = as.Date(game_date),
    game_pk,
    swinging_strike,
    release_speed,
    pfx_x,
    pfx_z,
    plate_x,
    plate_z,
    balls,
    strikes,
    same_hand = as.integer(stand == p_throws)
  )

# Count rows with missing information before removing them
model_data |>
  summarise(
    total_rows = n(),
    rows_with_missing_data = sum(!complete.cases(model_data))
  )

# Remove rows missing required information
model_data <- model_data |> drop_na()

# Check remaining rows
model_data |> count(dataset)

# Training: regular season through July

train <- model_data |>
  filter(
    dataset == "Regular season",
    game_date < as.Date("2025-08-01")
  )

# Validation: August, for comparing models
validation <- model_data |>
  filter(
    dataset == "Regular season",
    game_date >= as.Date("2025-08-01"),
    game_date < as.Date("2025-09-01")
  )

# Final regular-season test: September onward
test <- model_data |>
  filter(
    dataset == "Regular season",
    game_date >= as.Date("2025-09-01")
  )

# Separate postseason test
playoff_test <- model_data |>
  filter(dataset == "Postseason")

# Check the size of each group
tibble(
  group = c("Training", "Validation", "Test", "Postseason"),
  pitches = c(
    nrow(train),
    nrow(validation),
    nrow(test),
    nrow(playoff_test)
  )
)
# Fit a logistic regression using only training data
model_simple <- glm(
  swinging_strike ~
    release_speed +
    pfx_x + pfx_z +
    plate_x + plate_z +
    factor(balls) +
    factor(strikes) +
    factor(same_hand),
  data = train,
  family = binomial()
)

# Check whether fitting completed successfully
model_simple$converged

# Display the model results
summary(model_simple)

# Baseline: average swinging-strike rate in training data
baseline_rate <- mean(train$swinging_strike)

# Predict probabilities for August pitches
validation_predictions <- validation |>
  mutate(
    baseline_probability = baseline_rate,
    model_probability = predict(
      model_simple,
      newdata = validation,
      type = "response"
    )
  )

# Brier score: average squared probability error
validation_results <- validation_predictions |>
  summarise(
    baseline_brier = mean(
      (swinging_strike - baseline_probability)^2
    ),
    model_brier = mean(
      (swinging_strike - model_probability)^2
    )
  )

print(validation_results)

# Add curved relationships for horizontal and vertical location
model_curved <- glm(
  swinging_strike ~
    release_speed +
    pfx_x + pfx_z +
    plate_x + I(plate_x^2) +
    plate_z + I(plate_z^2) +
    factor(balls) +
    factor(strikes) +
    factor(same_hand),
  data = train,
  family = binomial()
)

model_curved$converged

# Predict on the same August pitches
validation_predictions <- validation_predictions |>
  mutate(
    curved_probability = predict(
      model_curved,
      newdata = validation,
      type = "response"
    )
  )

# Compare all three approaches
comparison <- validation_predictions |>
  summarise(
    baseline_brier = mean(
      (swinging_strike - baseline_probability)^2
    ),
    simple_brier = mean(
      (swinging_strike - model_probability)^2
    ),
    curved_brier = mean(
      (swinging_strike - curved_probability)^2
    )
  )

print(comparison, width = Inf)


# Show the scores to six decimal places
comparison |>
  mutate(across(everything(), ~ sprintf("%.6f", .x))) |>
  print(width = Inf)

# Refit the selected model using data through August
development <- bind_rows(train, validation)

final_model <- update(
  model_curved,
  data = development
)

# Baseline uses the same development period
final_baseline <- mean(development$swinging_strike)

# Predict on the two untouched test periods

# Combine the two test periods
final_predictions <- bind_rows(
  test |> mutate(period = "September"),
  playoff_test |> mutate(period = "Postseason")
)

# Add predicted probabilities
final_predictions$probability <- predict(
  final_model,
  newdata = final_predictions,
  type = "response"
)


final_results <- final_predictions |>
  group_by(period) |>
  summarise(
    pitches = n(),
    baseline_brier = mean(
      (swinging_strike - final_baseline)^2
    ),
    model_brier = mean(
      (swinging_strike - probability)^2
    ),
    .groups = "drop"
  )

print(final_results, width = Inf)

# Group similar predictions within each test period
calibration <- final_predictions |>
  group_by(period) |>
  mutate(bin = ntile(probability, 5)) |>
  group_by(period, bin) |>
  summarise(
    predicted = mean(probability),
    observed = mean(swinging_strike),
    pitches = n(),
    .groups = "drop"
  )

# Plot predicted probabilities against observed rates
calibration_plot <- ggplot(
  calibration,
  aes(x = predicted, y = observed)
) +
  geom_abline(
    intercept = 0,
    slope = 1,
    linetype = "dashed",
    color = "gray50"
  ) +
  geom_point(size = 3, color = "#005A9C") +
  facet_wrap(~ period) +
  scale_x_continuous(labels = scales::label_percent()) +
  scale_y_continuous(labels = scales::label_percent()) +
  coord_equal() +
  labs(
    title = "Do predicted swinging-strike probabilities match reality?",
    x = "Average predicted probability",
    y = "Actual swinging-strike rate"
  ) +
  theme_minimal()

print(calibration_plot)

# Save the chart and results
dir.create("figures", showWarnings = FALSE)
dir.create("results", showWarnings = FALSE)

ggsave(
  "figures/calibration.png",
  calibration_plot,
  width = 8,
  height = 4
)

write_csv(final_results, "results/final_results.csv")

final_results |>
  mutate(
    improvement_pct =
      100 * (baseline_brier - model_brier) / baseline_brier
  ) |>
  print(width = Inf)

final_results <- final_results |>
  mutate(
    improvement_pct =
      100 * (baseline_brier - model_brier) / baseline_brier
  )

write_csv(final_results, "results/final_results.csv")
write_csv(calibration, "results/calibration.csv")
