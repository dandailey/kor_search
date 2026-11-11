# KorSearch

One search language for ActiveRecord, in code and over HTTP.

KorSearch turns a flat hash of params into a narrowed ActiveRecord relation. You declare, once per model, what it can be searched by. From then on the same params work everywhere:

```ruby
Product.kor_search(status_in: %w[open pending], q: "anvil", released_on: "2026-01-01..2026-03-31")
```

```
GET /products?search[status_in][]=open&search[status_in][]=pending&search[q]=anvil&search[released_on]=2026-01-01..2026-03-31
```

Both lines run exactly the same query. Controllers, background jobs, API clients, admin screens, reports and tests all speak one vocabulary, and each model's searcher is the single place that vocabulary is defined.

## Contents

- [Why](#why)
- [Installation](#installation)
- [Quick start](#quick-start)
- [The param language](#the-param-language)
- [Searching over HTTP](#searching-over-http)
- [Defining searchers](#defining-searchers)
- [Text search](#text-search)
- [Dates](#dates)
- [Introspection](#introspection)
- [Configuration](#configuration)
- [Best practices](#best-practices)
- [How it works](#how-it-works)
- [Errors](#errors)
- [Development](#development)

## Why

Most Rails apps grow search the same way. A controller picks a few keys out of `params`, calls some scopes, and adds a `where` here and there. Then the API needs the same filters with slightly different names, an export job needs a third copy, and nobody can say which params a screen actually accepts.

KorSearch puts that mapping in one declarative class per model:

- **Scopes stay the source of truth.** Searchers don't replace your scopes; they decide which ones are exposed and under what param names.
- **One language.** Field predicates (`name_cont`, `price_gteq`, `status_not_in`), boolean flags (`active=1`), value filters (`category=5`), free text (`q=anvil`) and dates (`created_at=last month`) all live in one flat hash.
- **Allowlisted by construction.** Only what a searcher declares is searchable. Anything else is ignored, or rejected if you ask.
- **Self-describing.** A searcher can list every param it accepts, for API docs, form builders or validation.

## Installation

```ruby
# Gemfile
gem "kor_search", github: "dandailey/kor_search"

gem "ransack"  # optional: enables field predicates (search_fields)
gem "chronic"  # optional: enables natural-language dates
```

KorSearch requires Ruby 3.1+ and ActiveRecord 7.0+. Ransack and Chronic are optional. Without Ransack, `search_fields` declarations are inert and everything else works.

## Quick start

Write scopes as usual:

```ruby
class Product < ApplicationRecord
  belongs_to :manufacturer

  scope :active, -> { where(active: true) }
  scope :in_category, ->(id) { where(category_id: id) }
end
```

Create `app/searchers/product_searcher.rb`. The class name maps it to the model.

```ruby
class ProductSearcher < KorSearch::Searcher
  search_fields :name, :sku, :status, :price, :released_on
  search_associations :manufacturer

  text_search :q, columns: %i[name sku description]

  boolean_search :active
  simple_search :category, method: :in_category
end
```

Search:

```ruby
Product.kor_search(active: "1", category: 5, q: "anvil")
current_account.products.kor_search(params[:search])   # respects the existing scope
ProductSearcher.new(Product.all).search(price_lt: 100) # the explicit form
```

`kor_search` is available on every model and relation. It finds `#{Model}Searcher`, runs it against the current scope, and returns a relation you can keep chaining (`.order`, `.page`, `.includes`, and so on).

## The param language

A search is a flat hash. Every key is one of the kinds below, and all present keys are combined with AND. Keys may be strings or symbols, and `ActionController::Parameters` works as is.

| Kind | Declared with | Example params | Effect |
|---|---|---|---|
| Field | `search_fields :status` | `status=open`, `status_not_in[]=closed` | Ransack predicate on the column |
| Association field | `search_associations :manufacturer` | `manufacturer_name_cont=acme` | Predicate on the associated model |
| Boolean | `boolean_search :active` | `active=1` | Calls `.active` when the value is truthy |
| Value | `simple_search :category` | `category=5` | Calls `.category("5")` |
| Text | `text_search :q, columns: [...]` | `q=anvil` | Free text across one or more sources |

### Fields and predicates

`search_fields` allows these predicates on each listed attribute:

| Predicate | Meaning | Example |
|---|---|---|
| *(none)* | equals | `status=open` |
| `eq`, `not_eq` | equals / not equal | `status_not_eq=closed` |
| `in`, `not_in` | in list / not in list | `status_in[]=open&status_in[]=pending` |
| `lt`, `lteq`, `gt`, `gteq` | comparisons | `price_lt=100` |
| `cont`, `not_cont` | contains | `name_cont=anv` |
| `start`, `not_start`, `end`, `not_end` | prefix / suffix | `sku_start=AN-` |
| `matches`, `does_not_match` | SQL LIKE pattern | `name_matches=A%l` |
| `null`, `not_null`, `present`, `blank` | presence (value `1`) | `description_blank=1` |
| `true`, `false` | boolean column (value `1`) | `featured_true=1` |

A bare field name means `eq`, so `status=open` and `status_eq=open` are identical. Compound predicates always win the split: `status_not_eq` is `status` + `not_eq`, never `status_not` + `eq`.

Association fields work the same way. `manufacturer_name_cont=acme` is allowed when the searcher lists `search_associations :manufacturer` *and* `ManufacturerSearcher` lists `name` in its own `search_fields`. Each model controls what it exposes, including when it's reached through another model.

### Boolean and value searches

A boolean search fires only for truthy values: `1`, `true`, `t`, `yes`, `y`, `on`, in any case. `active=0` does nothing; it does **not** mean "inactive". If you need the opposite, declare it: `boolean_search :inactive`.

A value search passes the raw value to its scope. Blank values do nothing.

### Text searches

A text search takes whatever a user typed and matches it against one or more sources: columns, custom SQL, or related models. See [Text search](#text-search).

### Rules that apply to everything

- **Unknown keys are ignored.** The hash can carry pagination, sorting or anything else. Use `ignored_params` to detect or reject them.
- **Blank values are ignored,** so an empty form submits cleanly.
- **Order:** field predicates apply first, then registered searches in the order they were declared. Since everything is AND, order only matters for custom blocks that join or group.
- **Searching only narrows.** A search never widens the relation you pass in, so scoping for authorization first (`current_user.orders.kor_search(...)`) is always safe.
- **Input is never modified.**

## Searching over HTTP

Because the language is a flat hash, it maps directly onto query strings, form fields and JSON.

### Namespace your params

Put search params under one key, conventionally `search`:

```
/products?search[q]=anvil&search[active]=1&page=2&sort=name
```

```ruby
def index
  @products = current_account.products.kor_search(params[:search]).order(:name).page(params[:page])
end
```

Pagination, sorting and other UI state stay outside the search hash, so they never collide with a search name.

### Arrays

`in` and `not_in` take arrays. Use Rails' bracket syntax:

```
/orders?search[status_in][]=open&search[status_in][]=pending
```

### The `q` convention

`q` has no special meaning to KorSearch; it's an ordinary text search name. It is, however, a strong convention. If every searcher declares `text_search :q`, any search box, global search or API client can rely on `q` meaning "free text across the obvious columns". Add other text searches with descriptive names (`text_search :notes, columns: [:notes]`) where you need them.

### Forms

A GET form scoped to `search` produces exactly the language:

```erb
<%= form_with url: products_path, scope: :search, method: :get do |f| %>
  <%= f.search_field :q, value: params.dig(:search, :q), placeholder: "Search products" %>
  <%= f.select :status_in, %w[open pending closed], {}, multiple: true %>
  <%= f.date_field :released_on_gteq %>
  <%= f.check_box :active, {}, "1", nil %>
  <%= f.submit "Search" %>
<% end %>
```

Because search state lives in the URL, results are bookmarkable and shareable, and the back button works.

### JSON APIs

The same hash works as a JSON body or query string. To reject bad requests instead of silently ignoring unknown keys:

```ruby
def index
  searcher = OrderSearcher.new(current_account.orders)
  unknown = searcher.ignored_params(params[:search])
  return render(json: {error: "unknown search params", params: unknown}, status: :bad_request) if unknown.any?

  render json: searcher.search(params[:search]).limit(100)
end
```

Publish what each endpoint accepts with `OrderSearcher.search_params_reference` (see [Introspection](#introspection)).

### Echoing active filters

`effective_search_params` returns the params as the search actually ran them, after normalization and date coercion. Use it for "filter pills", or to show that `released_on=last month` meant October 1 to October 31.

## Defining searchers

### Naming and model inference

`ProductSearcher` searches `Product`. Namespaced searchers try the full name first, then the bare model: `Stageline::StageSearcher` finds `Stageline::Stage`, and `Admin::ProductSearcher` falls back to `Product`. Override with `searches`:

```ruby
class InventorySearcher < KorSearch::Searcher
  searches Product
end
```

A subclass whose name doesn't match a model keeps its parent's model, so `class ArchivedProductSearcher < ProductSearcher` still searches `Product`.

`Model.kor_search` always uses `#{Model}Searcher`. For other searchers, instantiate them directly: `InventorySearcher.new(Product.all).search(...)`. With no relation, a searcher starts from `Model.all`: `InventorySearcher.new.search(...)`.

### An application base class

As with `ApplicationRecord`, give your app a base class for shared conventions:

```ruby
# app/searchers/application_searcher.rb
class ApplicationSearcher < KorSearch::Searcher
end
```

Subclasses inherit everything declared on their parents. Siblings never see each other's declarations.

### Single-table inheritance

A model without its own searcher uses its STI base class's searcher. `Gadget < Product` with no `GadgetSearcher` uses `ProductSearcher`.

### DSL reference

```ruby
class ProductSearcher < ApplicationSearcher
  # Ransack predicates on columns (see "Fields and predicates")
  search_fields :name, :sku, :status, :price, :released_on

  # Predicates through associations, onto the associated searcher's fields
  search_associations :manufacturer, :category

  # Truthy param calls a no-argument scope
  boolean_search :active                          # active=1 → .active
  boolean_search :archived, :starred              # several at once
  boolean_search unpaid: :with_unpaid_invoices    # param name → scope name
  boolean_search :featured do |query|             # inline logic
    query.where(featured: true)
  end

  # Value param calls a one-argument scope
  simple_search :category, method: :in_category   # category=5 → .in_category("5")
  simple_search :brand, :color                    # .brand(v), .color(v)
  simple_search entity_type: :by_entity_type
  simple_search :price_range do |value, query|
    min, max = value.split("-").map(&:to_d)
    query.where(price: min..max)
  end

  # Value param parsed as a date before it reaches its scope (see "Dates")
  date_filters :shipped_since
  simple_search :shipped_since, method: :shipped_on_or_after

  # Free text (see "Text search")
  text_search :q, columns: %i[name sku description], extended: %i[manufacturer]
end
```

Blocks must return a relation. A registered search whose scope doesn't exist raises `KorSearch::MissingScope` when it's used, so typos surface immediately instead of silently returning unfiltered results.

## Text search

A text search matches a record when **any** of its sources matches:

```ruby
text_search :q,
  columns: [:name, :email],   # case-insensitive substring match
  through: %i[company],       # the company's own :q search
  extended: %i[account]       # only when run with extended: true
```

| Source | What it does |
|---|---|
| `columns:` | Case-insensitive substring match on each column. `%` and `_` in the input match literally. `"table.column"` reaches a table the relation already joins. Uses `ILIKE` on PostgreSQL and `LIKE` elsewhere. |
| block | Your own logic. Return a narrowed relation, or `nil` to contribute nothing. |
| `through:` | For each `belongs_to` association, runs the associated model's text search of the same name and matches records whose parent matched. Map to a different name with `through: {company: :keywords}`. |
| `extended:` | Like `through:`, but only applied when the search runs with `extended: true`. Use it for wider, costlier matching behind an "include related records" toggle. |

Sources are combined as id subqueries, so a block can join, group or use a full-text index without interfering with the other sources:

```ruby
text_search :q, columns: %i[name] do |value, query|
  query.where("search_vector @@ plainto_tsquery('english', ?)", value)
end
```

```ruby
Product.kor_search(q: "acme")                  # name, sku, description
Product.kor_search(q: "acme", extended: true)  # ...or the manufacturer's own :q
```

`through:` and `extended:` pull at most 1,000 matching parent ids (`KorSearch::Searcher::ASSOCIATED_ID_LIMIT`). They're meant for "also match on the parent's name", not for huge fan-outs.

If none of a text search's sources match, the search returns no records: a text query that matches nothing finds nothing.

### Adding sources from a base class

`text_source` adds a source to a text search, creating the search if needed. Sources added this way survive a later `text_search` declaration, so a base class can give every searcher an extra source:

```ruby
class ApplicationSearcher < KorSearch::Searcher
  def self.inherited(subclass)
    super
    subclass.text_source(:q) { |value, query| SearchIndex.narrow(query, value) }
  end
end
```

## Dates

Date and datetime columns listed in `search_fields` get date coercion, so dates in params behave the way people expect:

| Param | On a `date` column | On a `datetime` column |
|---|---|---|
| `released_on=2026-01-15` | that day | 00:00:00 to 23:59:59 that day |
| `released_on=2026-01-01..2026-01-31` | Jan 1 to Jan 31 inclusive | start of Jan 1 to end of Jan 31 |
| `released_on=2026-01-01..` | on or after Jan 1 | from 00:00 on Jan 1 |
| `released_on=..2026-01-31` | on or before Jan 31 | through 23:59:59 on Jan 31 |
| `released_on_gteq=2026-01-15` | on or after | from the start of the day |
| `released_on_lteq=2026-01-15` | on or before | through the end of the day |
| `released_on_gt=2026-01-15` | after | after the end of the day |
| `released_on_lt=2026-01-15` | before | before the start of the day |

Ranges may be written `a..b`, `a to b`, `a thru b` or `a through b`. Values that include a time of day (`2026-01-15 09:30`) pass through untouched, as do values the parser doesn't understand.

With a range, the comparison predicates use the sensible edge: `released_on_gteq=last month` means on or after the first of last month, and `released_on_lteq=last month` means on or before the last day of it.

`date_filters` marks value searches whose param should reach the scope as a `Date`.

### Natural-language dates

The default parser understands ISO 8601 only. For people-friendly input, add `chronic` to your Gemfile and opt in:

```ruby
# config/initializers/kor_search.rb
require "kor_search/natural_dates"
```

Then every date param also understands:

| Input | Meaning |
|---|---|
| `today`, `yesterday`, `tomorrow`, `fri`, `next fri`, `last mon` | a single day |
| `1/2/99`, `jan 5`, `2019-10-14` | a single day |
| `this month`, `last week`, `last quarter`, `next year`, `2025`, `march '24` | a whole period |
| `past 2 weeks`, `7 days`, `-3 days` | a span ending or starting today |
| `mtd`, `qtd`, `ytd`, `quarter to date` | period to date |
| `since jan`, `since yesterday`, `after fri`, `until 3/1`, `from 2/1` | open-ended |
| `mon-fri`, `1/2 to 3/4`, `march 3-10` | explicit ranges |
| `recent` (last 90 days), `past`, `future` | named ranges |

So `created_at=last month` or `due_on=next week` work the same from code and from a URL.

Dates written without a year resolve forward, following Chronic: in November, `jan 5` means the coming January. Include the year when it matters.

### A custom parser

Any object with `parse(value)` (returning a `Date` or `nil`) and `parse_range(value)` (returning `[from, to]` with either end possibly `nil`, or `nil` when it can't parse) can be the parser:

```ruby
KorSearch.date_parser = FiscalCalendarDates
```

## Introspection

Every searcher can describe its own language:

```ruby
ProductSearcher.search_params_reference
# => [
#   {param: "status", kind: :field, column_type: :string, predicates: ["blank", "cont", ...]},
#   {param: "released_on", kind: :field, column_type: :date, predicates: [...]},
#   {param: "manufacturer_name", kind: :association_field, association: :manufacturer, predicates: [...]},
#   {param: "q", kind: :text, sources: [:columns, :association]},
#   {param: "active", kind: :boolean},
#   {param: "category", kind: :simple}
# ]

ProductSearcher.registered_searches       # => [:q, :active, :category]
searcher.ignored_params(params[:search])  # => [:bogus]
searcher.effective_search_params(params)  # params after date coercion
```

Use these to generate API documentation, build search UIs from metadata, or write a test asserting that a searcher's public surface doesn't change by accident.

## Configuration

```ruby
# config/initializers/kor_search.rb
KorSearch.configure do |config|
  # Parser for date params (default: ISO 8601 only)
  config.date_parser = KorSearch::Dates::Natural

  # Raise when a registered search's scope is missing (default: true)
  config.strict_scopes = true

  # Extra ways to find a model's searcher, tried after the naming convention.
  # Each takes a model class and returns a searcher class or nil.
  config.searcher_resolvers << ->(model) { GeneratedSearchers.for(model) }
end
```

`KorSearch::Dates::Natural` needs `require "kor_search/natural_dates"` (or `"kor_search/dates/natural"`) first.

## Best practices

**Name params for the client, not the scope.** Params are a public API: they end up in bookmarks, API clients and other people's code. `simple_search :category, method: :in_category` keeps the URL clean while the scope keeps its descriptive name. Renaming a scope shouldn't break a URL.

**Keep logic in scopes; keep searchers declarative.** A scope can be tested, reused and composed. Inline blocks are fine for one-liners, but once a block grows, move it into a scope and point the searcher at it.

**Expose deliberately.** `search_fields` makes every predicate available on those columns, including `cont` and `matches`. List the fields a user should be able to filter on, not every column. Sensitive columns (tokens, internal notes, costs) don't belong in a searcher a client can reach.

**Scope for authorization before searching.** Use `current_user.orders.kor_search(params[:search])`. Searching only narrows, so it can never escape the scope you start from. Never authorize through search params.

**Prefer explicit booleans to falsy values.** `active=0` does nothing by design. Declare `boolean_search :inactive` if clients need it. Absent and false mean the same thing, which keeps forms and URLs predictable.

**Use `q` for the search box.** One free-text param name across every searcher means global search, command palettes and API clients never have to ask.

**Put the expensive work behind `extended:`.** Matching through associations or a large full-text index can be slow. Keep the default `q` fast and let users opt into wider searches.

**Keep sorting and pagination out of the search hash.** KorSearch narrows; it doesn't order or page. Keep those as sibling params (`page`, `sort`) so they never collide with a search name.

**Test the language, not just the scopes.** A searcher test that runs a few param hashes against fixtures documents the public API and catches accidental renames. `search_params_reference` makes a good snapshot test.

**One searcher per audience when needed.** An admin screen and a public API may need different vocabularies for the same model. Define `Admin::ProductSearcher` (or any class with `searches Product`) and call it explicitly. Allowlists are per searcher, so they don't leak into each other.

## How it works

- `Model.kor_search(params)` calls `KorSearch.searcher_for(Model)`, which looks for `#{Model}Searcher`, then any configured resolvers, then the same for the STI base class. It then runs `searcher.new(all).search(params)`; `all` is the current scope when called on a relation.
- `search` normalizes the params (symbol keys, `ActionController::Parameters` unwrapped), applies date coercion, runs the allowlisted field predicates through Ransack, then applies registered searches in declaration order.
- Ransack's allowlist methods (`ransackable_attributes` and friends) are answered by the running searcher, through a module prepended to each searched model, rather than written onto the model. Two searchers for the same model can expose different fields, and a model's own `ransackable_*` methods still govern Ransack calls made outside KorSearch.
- Each subclass gets its own copy of every declaration, so sibling searchers are fully independent.

## Errors

| Error | When |
|---|---|
| `KorSearch::SearcherNotFound` | `Model.kor_search` is called and no searcher exists for the model |
| `KorSearch::MissingScope` | a registered search points at a scope the model doesn't have (with `strict_scopes`, the default) |
| `ArgumentError` | misconfiguration: `method:` with several names, `through:` on an unsupported association, or a missing related text search |

## Development

```sh
bundle install
bundle exec rake test
```

The suite runs against an in-memory SQLite database with Ransack and Chronic installed. It's currently exercised on Ruby 4.0 and ActiveRecord 8.1; other versions in the supported range are expected to work but aren't yet covered by CI.

## Origins

KorSearch was extracted from the searcher layer of Korrelate, which grew out of an earlier library built on the same idea. The scope-backed DSL (`boolean_search`, `simple_search`) has been in production use in various forms since 2024.

## License

Released under the [MIT License](LICENSE).
