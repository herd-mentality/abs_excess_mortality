library(tidyverse)
library(MASS)
library(janitor)


## Read data ----
suppressWarnings(
  abs_deaths <- file.path(
    getwd(), 
    'input', 
    'Comparison of all cause baseline and COVID-19 period deaths against regression, January 2016 - February 2022 (a)(b)(c)(d)(e)(f).csv'
  ) %>% 
    read_csv(skip = 1, show_col_types = FALSE) %>% 
    separate_wider_delim(`95% bounds`, '|', names = c('95%_lower', '95%_higher')) %>% 
    mutate(
      across(starts_with('95%'), as.numeric),
      `Week starting date` = dmy(`Week starting date`),
      week_number = 1:n()
    ) %>% 
    filter(!is.na(`Week starting date`)) %>% 
    clean_names()
)

## Initial plot ----
abs_deaths %>%
  dplyr::select(week_starting_date, expected, observed) %>% 
  pivot_longer(expected:observed, names_to = 'series', values_to = 'value') %>%
  mutate(series = str_to_title(series)) %>% 
  ggplot(aes(x = week_starting_date, y = value, colour = series)) +
  geom_line() +
  scale_y_continuous(labels = scales::comma) +
  labs(x = 'Week', y = 'Observed / Expected Deaths', colour = 'Series') +
  theme(legend.position = 'bottom')

## Fit robust regression using SAS default values ----
rlm_fit <- MASS::rlm(
  observed ~ week_number, 
  data = abs_deaths %>% mutate(week_number = 1:n()),
  method = 'M',  
  scale.est = 'MAD',
  psi = 'psi.bisquare',
  c = 2
) 

# rlm_fit %>% str()

## Plot weights ----
abs_deaths %>% 
  mutate(bisquare_weighting = rlm_fit$w) %>% 
  ggplot(aes(x = week_starting_date, y = observed, alpha = bisquare_weighting)) +
  geom_point()



## Grid search over c ----
library(gganimate)
library(transformr)
grid_search_c <- seq(1.5, 5, 0.5) %>% 
  purrr::map_dfr(
    function(x) {
      
      abs_deaths %>% 
        bind_cols(
          tibble(
            c = x,
            weights = MASS::rlm(
              observed ~ week_number, 
              data = abs_deaths,
              method = 'M',  
              scale.est = 'MAD',
              psi = 'psi.bisquare',
              c = x
            )$w
          )
        )
      
    }
  )


anim <- grid_search_c %>% 
  ggplot(aes(x = week_starting_date, y = observed, alpha = weights)) +
  geom_point(colour = '#14B8A6') +
  # facet_grid(rows = vars(c)) +
  scale_y_continuous(labels = scales::comma) +
  theme_minimal() +
  theme(panel.grid.major = element_blank(),
        panel.grid.minor = element_blank(),
        axis.line = element_line()) +
  transition_states(
    states = c,
    transition_length = 2,
    state_length = 1
  ) +
  enter_fade() +
  exit_fade()

animation <- animate(anim, nframes = 200, end_pause = 50, height = 300, width = 400)
library(gifski)
anim_save(file.path(getwd(), "my_animation.gif"), animation)

## Find best RMSE/MAE/MAPE ----
seq(1.5, 5, 0.5) %>% 
  lapply(
    function(x) {
      
      model <- MASS::rlm(
        observed ~ week_number, 
        data = abs_deaths,
        method = 'M',  
        scale.est = 'MAD',
        psi = 'psi.bisquare',
        c = x
      )
      
      residuals <- abs_deaths$observed - predict(model, abs_deaths, type = 'response')

      sqrt(mean(residuals^2))
      
    }
  )

# AS c increases, RMSE over training set decreases. This is because a higher c means that the outlying points will be included when optimising the least squares loss - leads to a better RMSE (since RMSE is calculated over all points)
# TODO: 
#  - We want to look at forecasting over 2020, but also forecasting 2021 including 2020 in baseline period since that's topical
#  - Look at grid searching over all perms of c/scaleest/psi to find best RMSE using CV - then apply to 2021?

cutoff_date <- ymd('2021-01-01')
train_set <- abs_deaths %>% filter(week_starting_date >= cutoff_date %m-% years(5) & week_starting_date < cutoff_date)
test_set <- abs_deaths %>% filter(week_starting_date >= cutoff_date & week_starting_date < cutoff_date %m+% years(1))

model <- MASS::rlm(
  observed ~ week_number + 
    I(week_number^2) + # Experiment with removing this as well in grid search
    I(sin(2 * pi * week_number / 52.18)) + 
    I(cos(2 * pi * week_number / 52.18)), 
  data = train_set,
  method = 'M',  
  scale.est = 'MAD',
  psi = 'psi.bisquare',
  c = 4.685
)


# TODO: plot CIs/PIs as well

train_set %>% 
  mutate(expected = predict(model, train_set, type = 'response'), series = 'train') %>% 
  bind_rows(
    test_set %>% 
      mutate(expected = predict(model, test_set, type = 'response'), series = 'test')
  ) %>% 
  dplyr::select(week_starting_date, series, expected, observed) %>% 
  pivot_longer(expected:observed, names_to = 'type', values_to = 'value') %>% 
  ggplot(aes(x = week_starting_date, y = value, colour = type)) +
  geom_point() +
  geom_vline(xintercept = cutoff_date)



seq(1.5, 5, 0.1) %>% 
  purrr::map_dfr(
    function(x) {
      
      model <- MASS::rlm(
        observed ~ week_number, 
        data = train_set,
        method = 'M',  
        scale.est = 'MAD',
        psi = 'psi.bisquare',
        c = x
      )
      
      residuals <- test_set$observed - predict(model, test_set, type = 'response')
      
      tibble(c = x, rmse = sqrt(mean(residuals^2)), mae = mean(abs(residuals)))
      
    }
  ) %>% 
  pivot_longer(rmse:mae, names_to = 'measure', values_to = 'value') %>% 
  ggplot(aes(x = c, y = value, colour = measure)) +
  geom_point()

## Animation ----


## Plot forecast ----


## Compare different scale estimators and psi functions ----
c('psi.huber', 'psi.hampel', 'psi.bisquare') %>% 
  map_dfr(
    function(x) {
      
      abs_deaths %>% 
        bind_cols(
          tibble(
            psi = x,
            weights = MASS::rlm(
              observed ~ week_number, 
              data = abs_deaths,
              method = 'M',  
              scale.est = 'MAD',
              psi = x,
              c = 1.5
            )$w
          )
        )
      
    }
  ) %>% 
  ggplot(aes(x = week_starting_date, y = observed, alpha = weights)) +
  geom_point(colour = '#14B8A6') +
  facet_grid(rows = vars(psi)) +
  scale_y_continuous(labels = scales::comma)

## Compare different scale estimators and psi functions ----
c("MAD", "Huber", "proposal 2") %>% 
  map_dfr(
    function(x) {
      
      abs_deaths %>% 
        bind_cols(
          tibble(
            scaleest = x,
            weights = MASS::rlm(
              observed ~ week_number, 
              data = abs_deaths,
              method = 'M',  
              scale.est = x,
              psi = 'psi.bisquare',
              c = 1.5
            )$w
          )
        )
      
    }
  ) %>% 
  ggplot(aes(x = week_starting_date, y = observed, alpha = weights)) +
  geom_point(colour = '#14B8A6') +
  facet_grid(rows = vars(scaleest)) +
  scale_y_continuous(labels = scales::comma)

## Do grid search over all c, scaleest, psi - best forecast rmse is second model, plot against ABS' SAS defaults