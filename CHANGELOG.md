# Changelog

## 0.1.0 (unreleased)

Initial release, extracted from Korrelate's searcher.

- `KorSearch::Searcher` with `search_fields`, `search_associations`, `boolean_search`, `simple_search`, `text_search`, `text_source` and `date_filters`.
- `Model.kor_search(params)` on every ActiveRecord model and relation.
- Ransack allowlists answered per searcher at query time instead of written onto the model.
- Date coercion for date and datetime columns, with an opt-in natural-language parser (`require "kor_search/natural_dates"`).
- `search_params_reference` and `ignored_params` for documenting and validating the param language.
