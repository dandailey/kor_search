# frozen_string_literal: true

require "test_helper"

class SearcherTest < KorSearchTest
  def setup
    super
    @acme = Manufacturer.create!(name: "Acme", country: "US")
    @zeta = Manufacturer.create!(name: "Zeta Works", country: "DE")
    Product.create!(name: "Anvil", sku: "AN-1", status: "open", price: 100, active: true, manufacturer: @acme)
    Product.create!(name: "Rocket", sku: "RK-50%", status: "closed", price: 900, active: false, manufacturer: @acme)
    Product.create!(name: "Spring", sku: "SP-1", status: "pending", price: 5, active: true, manufacturer: @zeta)
  end

  # ─── Fields (Ransack) ─────────────────────────────────────────────────────

  def test_bare_field_means_equality
    assert_equal %w[Anvil], names(Product.kor_search(status: "open"))
  end

  def test_field_predicates
    assert_equal %w[Anvil Spring], names(Product.kor_search(name_cont: "n"))
    assert_equal %w[Rocket Spring], names(Product.kor_search(status_not_eq: "open"))
    assert_equal %w[Anvil Spring], names(Product.kor_search(status_in: %w[open pending]))
    assert_equal %w[Anvil Rocket], names(Product.kor_search(price_gteq: 100))
  end

  def test_unlisted_fields_are_ignored
    assert_equal 3, Product.kor_search(description_eq: "x", active_eq: true).count
  end

  def test_association_fields_use_the_associated_searchers_fields
    assert_equal %w[Spring], names(Product.kor_search(manufacturer_country_eq: "DE"))
    assert_equal %w[Anvil Rocket], names(Product.kor_search(manufacturer_name_start: "ac"))
  end

  def test_two_searchers_for_one_model_keep_their_own_allowlists
    narrow = Class.new(KorSearch::Searcher) do
      searches Product
      search_fields :sku
    end

    assert_equal %w[Anvil], names(ProductSearcher.new.search(status_eq: "open"))
    assert_equal 3, narrow.new.search(status_eq: "open").count
    assert_equal %w[Spring], names(narrow.new.search(sku_start: "SP"))
    assert_equal %w[Anvil], names(ProductSearcher.new.search(status_eq: "open"))
  end

  # ─── Registered searches ──────────────────────────────────────────────────

  def test_boolean_search_on_truthy_values_only
    %w[1 true yes on Y].each do |value|
      assert_equal %w[Anvil Spring], names(Product.kor_search(active: value)), value
    end
    %w[0 false no].each do |value|
      assert_equal 3, Product.kor_search(active: value).count, value
    end
  end

  def test_simple_search_passes_the_value_to_the_scope
    assert_equal %w[Anvil Spring], names(Product.kor_search(under: 500))
  end

  def test_blank_values_are_ignored
    assert_equal 3, Product.kor_search(under: "", status: "", q: "  ").count
  end

  def test_searches_combine
    assert_equal %w[Anvil], names(Product.kor_search(active: "1", under: 500, manufacturer_name_eq: "Acme"))
  end

  def test_multiple_names_and_hash_forms
    searcher = Class.new(KorSearch::Searcher) do
      searches Product
      boolean_search :active, cheap: :active
      simple_search with_status: :with_status
    end

    assert_equal %i[active cheap with_status], searcher.registered_searches
    assert_equal %w[Rocket], names(searcher.new.search(with_status: "closed"))
  end

  def test_method_with_several_names_is_rejected
    assert_raises(ArgumentError) do
      Class.new(KorSearch::Searcher) { simple_search :a, :b, method: :c }
    end
  end

  def test_blocks
    searcher = Class.new(KorSearch::Searcher) do
      searches Product
      simple_search(:price_range) { |value, query| query.where(price: Range.new(*value.split("-").map(&:to_i))) }
      boolean_search(:pricey) { |query| query.where("price > 500") }
    end

    assert_equal %w[Anvil Spring], names(searcher.new.search(price_range: "1-100"))
    assert_equal %w[Rocket], names(searcher.new.search(pricey: "1"))
  end

  def test_missing_scope_raises_by_default
    searcher = Class.new(KorSearch::Searcher) do
      searches Product
      boolean_search :no_such_scope
    end

    assert_raises(KorSearch::MissingScope) { searcher.new.search(no_such_scope: "1") }

    KorSearch.strict_scopes = false
    assert_equal 3, searcher.new.search(no_such_scope: "1").count
  end

  # ─── Text search ──────────────────────────────────────────────────────────

  def test_text_search_is_case_insensitive_across_columns
    assert_equal %w[Anvil], names(Product.kor_search(q: "aNv"))
    assert_equal %w[Spring], names(Product.kor_search(q: "sp-"))
  end

  def test_text_search_escapes_like_wildcards
    assert_equal %w[Rocket], names(Product.kor_search(q: "50%"))
    assert_equal %w[Rocket], names(Product.kor_search(q: "%"))
    assert_empty names(Product.kor_search(q: "_"))
  end

  def test_text_search_name_is_not_special
    searcher = Class.new(KorSearch::Searcher) do
      searches Product
      text_search :keywords, columns: %i[name]
    end

    assert_equal %w[Rocket], names(searcher.new.search(keywords: "rock"))
    assert_equal 3, searcher.new.search(q: "rock").count
  end

  def test_through_matches_on_the_parent_text_search
    assert_equal %w[Spring], names(Product.kor_search(maker: "zeta"))
  end

  def test_extended_sources_only_apply_when_asked
    assert_empty names(Product.kor_search(q: "zeta"))
    assert_equal %w[Spring], names(Product.kor_search(q: "zeta", extended: true))
  end

  def test_text_sources_are_ored
    searcher = Class.new(ProductSearcher) do
      text_source(:q) { |value, query| query.where(status: value) }
    end

    assert_equal %w[Rocket], names(searcher.new.search(q: "rocket"))
    assert_equal %w[Spring], names(searcher.new.search(q: "pending"))
    assert_equal %w[Anvil Spring], names(searcher.new.search(q: "n").where(status: %w[open pending]))
  end

  def test_text_sources_added_by_a_base_class_survive_subclass_declarations
    base = Class.new(KorSearch::Searcher) do
      def self.inherited(subclass)
        super
        subclass.text_source(:q) { |value, query| query.where(status: value) }
      end
    end
    searcher = Class.new(base) do
      searches Product
      text_search :q, columns: %i[name]
    end

    assert_equal %w[Rocket], names(searcher.new.search(q: "closed"))
    assert_equal %w[Anvil], names(searcher.new.search(q: "anv"))
  end

  def test_text_search_with_no_matching_source_returns_nothing
    assert_empty names(Product.kor_search(maker: "nobody"))
  end

  # ─── Inheritance and lookup ───────────────────────────────────────────────

  def test_sibling_searchers_do_not_share_registries
    base = Class.new(KorSearch::Searcher)
    first = Class.new(base) { boolean_search :one }
    second = Class.new(base) { boolean_search :two }

    assert_equal %i[one], first.registered_searches
    assert_equal %i[two], second.registered_searches
    assert_empty base.registered_searches
  end

  def test_subclasses_inherit_without_leaking_back
    child = Class.new(ProductSearcher) { boolean_search :extra }

    assert_includes child.registered_searches, :active
    refute_includes ProductSearcher.registered_searches, :extra
  end

  def test_searcher_without_a_relation_starts_from_all
    assert_equal %w[Anvil], names(ProductSearcher.new.search(status: "open"))
    assert_raises(ArgumentError) { Class.new(KorSearch::Searcher).new }
  end

  def test_through_misconfiguration_raises
    no_assoc = Class.new(KorSearch::Searcher) do
      searches Product
      text_search :q, through: %i[nothing]
    end
    no_target = Class.new(KorSearch::Searcher) do
      searches Product
      text_search :q, through: {manufacturer: :missing}
    end

    assert_raises(ArgumentError) { no_assoc.new.search(q: "x").to_a }
    assert_raises(ArgumentError) { no_target.new.search(q: "x").to_a }
  end

  def test_model_inference
    assert_equal Product, ProductSearcher.model_class
    assert_equal Shop::Order, Shop::OrderSearcher.model_class
  end

  def test_sti_subclass_falls_back_to_base_searcher
    Gadget.create!(name: "Gizmo", status: "open")

    assert_equal ProductSearcher, KorSearch.searcher_for(Gadget)
    assert_equal %w[Gizmo], names(Gadget.kor_search(status: "open"))
  end

  def test_kor_search_respects_the_existing_scope
    assert_equal %w[Spring], names(Product.where(manufacturer: @zeta).kor_search(active: "1"))
  end

  def test_kor_search_without_a_searcher_raises
    orphan = Class.new(ActiveRecord::Base) do
      self.table_name = "products"
      def self.name = "Orphan"
    end

    assert_raises(KorSearch::SearcherNotFound) { orphan.kor_search(q: "x") }
  end

  def test_custom_resolver
    orphan = Class.new(ActiveRecord::Base) do
      self.table_name = "products"
      def self.name = "Orphan"
    end
    generated = Class.new(KorSearch::Searcher) do
      searches orphan
      search_fields :status
    end
    KorSearch.searcher_resolvers = [->(model) { generated if model == orphan }]

    assert_equal generated, KorSearch.searcher_for(orphan)
    assert_equal %w[Anvil], orphan.kor_search(status: "open").pluck(:name)
    # The naming convention still wins over resolvers.
    KorSearch.searcher_resolvers = [->(_model) { generated }]
    assert_equal ProductSearcher, KorSearch.searcher_for(Product)
  end

  # ─── Params handling ──────────────────────────────────────────────────────

  def test_string_keys_keywords_and_parameters_like_objects
    assert_equal %w[Anvil], names(Product.kor_search({"status" => "open"}))
    assert_equal %w[Anvil], names(Product.kor_search(status: "open"))

    params = Struct.new(:hash) { def to_unsafe_h = hash }.new({"status" => "open"})
    assert_equal %w[Anvil], names(Product.kor_search(params))
  end

  def test_input_is_not_mutated
    params = {"released_on" => "2026-01-01..2026-01-31", "status" => "open"}
    frozen = params.deep_dup
    Product.kor_search(params).to_a

    assert_equal frozen, params
  end

  def test_ignored_params
    searcher = ProductSearcher.new
    assert_equal %i[bogus description_eq], searcher.ignored_params(status_eq: "x", bogus: 1, description_eq: "y", q: "z", manufacturer_name_cont: "a")
  end

  def test_search_params_reference
    reference = ProductSearcher.search_params_reference.to_h { |entry| [entry[:param], entry] }

    assert_equal :field, reference["status"][:kind]
    assert_equal :date, reference["released_on"][:column_type]
    assert_equal :association_field, reference["manufacturer_country"][:kind]
    assert_equal %i[columns association], reference["q"][:sources]
    assert_equal :boolean, reference["active"][:kind]
    assert reference["since"][:date]
  end
end
