# Changelog

## 0.1.0 (unreleased)

Initial release, extracted from Korrelate's searcher.

- `KorSearch::Searcher` with `search_fields`, `search_associations`, `boolean_search`, `simple_search`, `text_search`, `text_source` and `date_filters`.
- `Model.kor_search(params)` on every ActiveRecord model and relation.
- Ransack allowlists answered per searcher at query time instead of written onto the model.
- Date coercion for date and datetime columns, with an opt-in natural-language parser (`require "kor_search/natural_dates"`).
- `search_params_reference` and `ignored_params` for documenting and validating the param language.

Changes from Korrelate's searcher:

- Text search is no longer tied to the `q` param: any name works, and `through:`, `extended:` and `text_source` replace the hard-wired extended and Bloodhound layers.
- `columns:` text search escapes `%` and `_` and is case-insensitive on every database (Arel `matches` instead of raw `ILIKE`).
- `eq` on a date column covers the whole day or range; comparison predicates pick the correct edge of a range.
- Namespaced searchers resolve namespaced models (`Stageline::StageSearcher` → `Stageline::Stage`).
- A missing scope raises `KorSearch::MissingScope` instead of being skipped silently (configurable).
- `ActionController::Parameters` are accepted directly.
- Natural dates: day words ("yesterday", "fri") no longer turn into a range ending today, and "next fri" / "last mon" resolve as single days.
