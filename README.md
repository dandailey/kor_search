# KorSearch

> Work in progress. The API is settling; full documentation is coming.

One search language for ActiveRecord, in code and over HTTP. A small searcher class declares what a model can be searched by, and a flat params hash narrows a relation:

```ruby
class ProductSearcher < KorSearch::Searcher
  search_fields :name, :sku, :price, :released_on   # Ransack-style predicates
  search_associations :manufacturer                  # manufacturer_name_cont=acme
  text_search :q, columns: %i[name sku]              # free-text box
  boolean_search :active                             # active=1 calls .active
  simple_search :category, method: :in_category      # category=5 calls .in_category(5)
end

Product.kor_search(name_cont: "widget", active: "1", released_on: "2026-01-01..2026-03-31")
```

The same params work from a URL:

```
/products?search[name_cont]=widget&search[active]=1&search[released_on]=2026-01-01..2026-03-31
```

## License

MIT
