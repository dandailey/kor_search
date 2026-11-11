# frozen_string_literal: true

require_relative "ransackable"

module KorSearch
  # Base class for searchers. A searcher declares which params a model can be
  # searched by, and turns a params hash into a narrowed relation.
  #
  #   class ProductSearcher < KorSearch::Searcher
  #     search_fields :name, :sku, :price, :released_on   # Ransack predicates
  #     search_associations :manufacturer                  # manufacturer_name_cont, ...
  #
  #     text_search :q, columns: %i[name sku description]  # free-text box
  #
  #     boolean_search :active, :in_stock                  # ?active=1 calls .active
  #     simple_search :category, method: :in_category      # ?category=5 calls .in_category(5)
  #   end
  #
  #   ProductSearcher.new(Product.all).search(name_cont: "widget", active: "1")
  #   Product.kor_search(params[:search])
  #
  # See README.md for the full param language.
  class Searcher
    # Limit on ids pulled from an associated model by a `through:`/`extended:`
    # text search before they're used in an IN clause.
    ASSOCIATED_ID_LIMIT = 1_000

    # Predicates that date coercion understands.
    DATE_PREDICATES = %w[eq gteq gt lteq lt].freeze

    # A value that carries a time of day is passed through untouched.
    TIME_OF_DAY = /\d{1,2}:\d{2}|\d\s*(?:am|pm)\b/i

    class_attribute :search_registry, default: {}
    class_attribute :searchable_attributes_list, default: []
    class_attribute :searchable_associations_list, default: []
    class_attribute :date_filter_names, default: []
    class_attribute :target_model, default: nil

    class << self
      # Each subclass gets its own copies, so siblings never see each other's
      # searches.
      def inherited(subclass)
        super
        subclass.search_registry = search_registry.transform_values(&:deep_dup)
        subclass.searchable_attributes_list = searchable_attributes_list.dup
        subclass.searchable_associations_list = searchable_associations_list.dup
        subclass.date_filter_names = date_filter_names.dup
        subclass.target_model = nil
      end

      # ═════════════════════════════════════════════════════════════════════
      # MODEL
      # ═════════════════════════════════════════════════════════════════════

      # Name the model explicitly when it can't be inferred from the class
      # name (InventorySearcher searching Product, for example).
      def searches(model_class)
        self.target_model = model_class
      end

      # The model this searcher manages: explicit, or inferred from the class
      # name. Stageline::StageSearcher tries Stageline::Stage, then Stage.
      # A subclass whose name doesn't match a model (SpecialProductSearcher <
      # ProductSearcher) keeps its parent's model.
      def model_class
        target_model || inferred_model || (superclass.model_class if superclass < KorSearch::Searcher)
      end

      def inferred_model
        return nil if name.nil? || self == KorSearch::Searcher

        full = name.delete_suffix("Searcher")
        [full, full.demodulize].uniq.each do |candidate|
          klass = candidate.safe_constantize
          return klass if klass.is_a?(Class) && klass < ActiveRecord::Base
        end

        nil
      end

      # ═════════════════════════════════════════════════════════════════════
      # DSL
      # ═════════════════════════════════════════════════════════════════════

      # Allow Ransack predicates on these model attributes. A bare attribute
      # name means equality, so `price=100` is `price_eq=100`. Date and
      # datetime columns get date coercion (see README).
      #
      #   search_fields :name, :sku, :price
      def search_fields(*attributes)
        self.searchable_attributes_list = (searchable_attributes_list + attributes.flatten.map(&:to_sym)).uniq
      end

      # Allow Ransack predicates through these associations, onto the fields
      # the associated model's own searcher declares.
      #
      #   search_associations :manufacturer   # manufacturer_name_cont=acme
      def search_associations(*associations)
        self.searchable_associations_list = (searchable_associations_list + associations.flatten.map(&:to_sym)).uniq
      end

      # Mark simple searches whose value should be parsed as a date before it
      # reaches the scope.
      #
      #   date_filters :shipped_on
      #   simple_search :shipped_on, method: :shipped_on_date
      def date_filters(*names)
        self.date_filter_names = (date_filter_names + names.flatten.map(&:to_sym)).uniq
      end

      # A param whose truthy value ("1", "true", "yes", "on") calls a scope
      # that takes no arguments. Falsy values do nothing.
      #
      #   boolean_search :active                       # calls .active
      #   boolean_search :archived, :starred           # several at once
      #   boolean_search unpaid: :with_unpaid_invoices # param => scope
      #   boolean_search :featured do |query|
      #     query.where(featured: true)
      #   end
      def boolean_search(*names, method: nil, **mapping, &block)
        each_search_name(names, mapping, method) do |name, scope|
          register_search(name, type: :boolean, method: scope, block: block)
        end
      end

      # A param whose value is passed to a scope. Blank values do nothing.
      #
      #   simple_search :category                     # calls .category(value)
      #   simple_search :category, method: :in_category
      #   simple_search entity_type: :by_entity_type
      #   simple_search :price_range do |value, query|
      #     min, max = value.split("-").map(&:to_f)
      #     query.where(price: min..max)
      #   end
      def simple_search(*names, method: nil, **mapping, &block)
        each_search_name(names, mapping, method) do |name, scope|
          register_search(name, type: :simple, method: scope, block: block)
        end
      end

      # A free-text param. A record matches when ANY source matches:
      #
      # - columns:  case-insensitive substring match on these columns
      #             ("table.column" reaches a joined table)
      # - block:    custom logic; return a narrowed relation
      # - through:  belongs_to associations whose searcher has a text search
      #             of the same name; a record matches when its parent does.
      #             Map to a differently named search with a hash:
      #             through: {company: :q}
      # - extended: like through:, but only applied when the search is run
      #             with `extended: true` (for wider, costlier searches)
      #
      # Other sources can be added later with `text_source`.
      #
      #   text_search :q, columns: %i[name email]
      #   text_search :q, columns: %i[name], through: %i[company]
      #   text_search :q do |value, query|
      #     query.where("search_vector @@ plainto_tsquery(?)", value)
      #   end
      def text_search(name, columns: nil, through: nil, extended: nil, &block)
        sources = []
        sources << {kind: :columns, columns: Array(columns)} if columns.present?
        sources << {kind: :block, block: block} if block
        association_sources(name, through).each { |source| sources << source }
        association_sources(name, extended).each { |source| sources << source.merge(extended: true) }

        # Keep sources added with text_source (by a base class, say), so a
        # subclass declaring its own text search doesn't drop them.
        existing = search_registry[name.to_sym]
        sources.concat(existing[:sources].select { |s| s[:added] }) if existing&.dig(:type) == :text

        register_search(name, type: :text, sources: sources)
      end

      # Add a source to an existing text search. The block returns a narrowed
      # relation, or nil when it has nothing to contribute. Useful in a base
      # searcher that adds a source to every subclass:
      #
      #   class ApplicationSearcher < KorSearch::Searcher
      #     def self.inherited(subclass)
      #       super
      #       subclass.text_source(:q) { |value, query| FullTextIndex.narrow(query, value) }
      #     end
      #   end
      def text_source(name, &block)
        raise ArgumentError, "text_source needs a block" unless block

        config = search_registry[name.to_sym]
        unless config&.dig(:type) == :text
          text_search(name)
          config = search_registry[name.to_sym]
        end

        config[:sources] << {kind: :block, block: block, added: true}
      end

      # Names of all registered (non-Ransack) searches.
      def registered_searches
        search_registry.keys
      end

      # Every param this searcher understands, for building docs, API
      # references, or a search UI.
      #
      #   ProductSearcher.search_params_reference
      #   # => [{param: "name", kind: :field, column_type: :string, predicates: [...]},
      #   #     {param: "q", kind: :text, sources: [:columns]},
      #   #     {param: "active", kind: :boolean}, ...]
      def search_params_reference
        fields = searchable_attributes_list.map do |attr|
          column = model_class&.columns_hash&.dig(attr.to_s)
          {param: attr.to_s, kind: :field, column_type: column&.type, predicates: KorSearch::PREDICATES.sort}
        end

        associated = searchable_associations_list.flat_map do |assoc|
          associated_fields_for(assoc).map do |attr|
            {param: "#{assoc}_#{attr}", kind: :association_field, association: assoc, predicates: KorSearch::PREDICATES.sort}
          end
        end

        registered = search_registry.map do |name, config|
          entry = {param: name.to_s, kind: config[:type]}
          entry[:sources] = config[:sources].map { |s| s[:kind] }.uniq if config[:type] == :text
          entry[:date] = true if date_filter_names.include?(name)
          entry
        end

        fields + associated + registered
      end

      # Fields reachable through an allowed association: the fields declared
      # by the associated model's searcher.
      def associated_fields_for(association)
        reflection = model_class&.reflect_on_association(association)
        return [] if reflection.nil? || reflection.polymorphic?

        KorSearch.searcher_for(reflection.klass)&.searchable_attributes_list || []
      end

      private

      def association_sources(name, associations)
        Array.wrap(associations).flat_map do |entry|
          pairs = entry.is_a?(Hash) ? entry.to_a : [[entry, name]]
          pairs.map { |assoc, target| {kind: :association, association: assoc.to_sym, target: target.to_sym} }
        end
      end

      def each_search_name(names, mapping, method)
        names = names.flatten
        names << mapping if mapping.any?
        raise ArgumentError, "method: can only be used with a single search name" if method && names.length > 1

        names.each do |entry|
          if entry.is_a?(Hash)
            entry.each { |name, scope| yield name.to_sym, scope.to_sym }
          else
            yield entry.to_sym, (method || entry).to_sym
          end
        end
      end

      def register_search(name, **config)
        search_registry[name.to_sym] = config
      end
    end

    # ═══════════════════════════════════════════════════════════════════════
    # INSTANCE
    # ═══════════════════════════════════════════════════════════════════════

    attr_reader :relation

    def initialize(relation = nil)
      relation ||= self.class.model_class&.all
      raise ArgumentError, "#{self.class.name} needs a relation (no model could be inferred)" unless relation

      @relation = relation.dup
    end

    # Narrow the relation by the given params. Accepts a Hash,
    # ActionController::Parameters, or keyword arguments. Unknown params are
    # ignored (see #ignored_params). The input is never modified.
    #
    # Ransack field predicates apply first, then registered searches in the
    # order they were declared.
    #
    #   searcher.search(params[:search])
    #   searcher.search(status_in: %w[open pending], q: "acme", extended: true)
    def search(params = {}, extended: false, **keyword_params)
      params = effective_search_params(normalize_params(params).merge(keyword_params))

      query = apply_ransack(params, relation)
      apply_registered_searches(params, query, extended: extended)
    end

    # The params after normalization and date coercion: what the search
    # actually runs on. Handy for echoing back active filters.
    def effective_search_params(params = {})
      coerce_date_params(normalize_params(params))
    end

    # Params this searcher would ignore. Useful in development, or to reject
    # bad API requests:
    #
    #   bad = searcher.ignored_params(params[:search])
    #   return render(json: {unknown_params: bad}, status: 400) if bad.any?
    def ignored_params(params)
      normalize_params(params).keys.reject do |key|
        self.class.search_registry.key?(key) ||
          KorSearch.split_predicate(key, ransack_allowlist)
      end
    end

    # Override to turn off Ransack for a searcher.
    def ransack_enabled?
      true
    end

    def ransack_available?
      relation.respond_to?(:ransack)
    end

    # Called by KorSearch::Ransackable to answer Ransack's allowlist checks
    # while this searcher is running.
    def ransackable_attributes_for(klass)
      if same_model?(klass)
        self.class.searchable_attributes_list.map(&:to_s)
      else
        (KorSearch.searcher_for(klass)&.searchable_attributes_list || []).map(&:to_s)
      end
    end

    def ransackable_associations_for(klass)
      same_model?(klass) ? self.class.searchable_associations_list.map(&:to_s) : []
    end

    private

    def model
      relation.klass
    end

    def same_model?(klass)
      klass <= model || model <= klass
    end

    def normalize_params(params)
      return {} if params.blank?

      params = params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
      params.to_h.deep_symbolize_keys
    end

    # ─── Ransack ─────────────────────────────────────────────────────────────

    def ransack_allowlist
      own = self.class.searchable_attributes_list
      associated = self.class.searchable_associations_list.flat_map do |assoc|
        self.class.associated_fields_for(assoc).map { |attr| :"#{assoc}_#{attr}" }
      end

      own + associated
    end

    def apply_ransack(params, query)
      return query unless ransack_enabled? && ransack_available?

      ransack_params = extract_ransack_params(params)
      return query if ransack_params.empty?

      KorSearch::Ransackable.install(model)
      self.class.searchable_associations_list.each do |assoc|
        reflection = model.reflect_on_association(assoc)
        KorSearch::Ransackable.install(reflection.klass) if reflection && !reflection.polymorphic?
      end

      query.ransack(ransack_params, auth_object: self).result
    end

    def extract_ransack_params(params)
      allowlist = ransack_allowlist
      return {} if allowlist.empty?

      params.each_with_object({}) do |(key, value), ransack_params|
        next if value.blank? && value != false

        attr_name, predicate = KorSearch.split_predicate(key, allowlist)
        next unless attr_name

        ransack_params[:"#{attr_name}_#{predicate}"] = value
      end
    end

    # ─── Dates ───────────────────────────────────────────────────────────────

    def coerce_date_params(params)
      params.each_with_object({}) do |(key, value), coerced|
        if self.class.date_filter_names.include?(key) && date_like?(value)
          coerced[key] = KorSearch.date_parser.parse(value) || value
        elsif !coerce_date_predicate(key, value, coerced)
          coerced[key] = value
        end
      end
    end

    # Writes the coerced predicate(s) into `coerced` and returns true, or
    # returns false when the param isn't a date predicate it can parse.
    def coerce_date_predicate(key, value, coerced)
      return false unless date_like?(value)

      attr_name, predicate = KorSearch.split_predicate(key, self.class.searchable_attributes_list)
      return false unless attr_name && DATE_PREDICATES.include?(predicate)

      column = model.columns_hash[attr_name]
      return false unless column && %i[date datetime].include?(column.type)

      from, to = KorSearch.date_parser.parse_range(value)
      return false if from.nil? && to.nil?

      bounds = case predicate
      when "eq" then {gteq: from, lteq: to}
      when "gteq" then {gteq: from || to}
      when "lt" then {lt: from || to}
      when "lteq" then {lteq: to || from}
      when "gt" then {gt: to || from}
      end

      bounds.each do |op, date|
        next unless date

        edge = %i[lteq gt].include?(op) ? :ending : :beginning
        coerced[:"#{attr_name}_#{op}"] = date_boundary(column, date, edge)
      end

      true
    end

    def date_like?(value)
      (value.is_a?(String) && value.present? && !value.match?(TIME_OF_DAY)) || value.instance_of?(Date)
    end

    def date_boundary(column, date, edge)
      return date unless column.type == :datetime

      (edge == :ending) ? date.end_of_day : date.beginning_of_day
    end

    # ─── Registered searches ─────────────────────────────────────────────────

    def apply_registered_searches(params, query, extended:)
      self.class.search_registry.each do |name, config|
        next unless params.key?(name)

        value = params[name]
        query = case config[:type]
        when :boolean then apply_boolean_search(config, value, query)
        when :simple then apply_simple_search(config, value, query)
        when :text then apply_text_search(name, config, value, query, extended: extended)
        else query
        end
      end

      query
    end

    def apply_boolean_search(config, value, query)
      return query unless KorSearch::Bool.truthy?(value)
      return config[:block].call(query) if config[:block]

      call_scope(query, config[:method])
    end

    def apply_simple_search(config, value, query)
      return query if value.blank? && value != false
      return config[:block].call(value, query) if config[:block]

      call_scope(query, config[:method], value)
    end

    def call_scope(query, scope, *args)
      return query.public_send(scope, *args) if query.respond_to?(scope)
      raise KorSearch::MissingScope, "#{model.name} has no scope or class method named #{scope.inspect} (#{self.class.name})" if KorSearch.strict_scopes

      query
    end

    # ─── Text ────────────────────────────────────────────────────────────────

    def apply_text_search(name, config, value, query, extended:)
      value = value.to_s.strip
      return query if value.empty?

      sources = config[:sources].reject { |source| source[:extended] && !extended }
      matches = sources.filter_map { |source| text_source_relation(name, source, value, query) }
      return query.none if matches.empty?
      return matches.first if matches.one?

      # Combine sources as id subqueries so each may join or group freely.
      primary_key = model.primary_key
      matches.map { |match| query.where(primary_key => match.select(primary_key)) }.reduce(:or)
    end

    def text_source_relation(name, source, value, query)
      case source[:kind]
      when :columns then column_text_match(source[:columns], value, query)
      when :block then source[:block].call(value, query)
      when :association then associated_text_match(source[:association], source[:target], value, query)
      end
    end

    def column_text_match(columns, value, query)
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(value)}%"
      conditions = columns.map do |column|
        table_name, column_name = column.to_s.include?(".") ? column.to_s.split(".", 2) : [model.table_name, column.to_s]
        Arel::Table.new(table_name)[column_name].matches(pattern, "\\", false)
      end

      query.where(conditions.reduce(:or))
    end

    def associated_text_match(association, target, value, query)
      reflection = model.reflect_on_association(association)
      unless reflection&.belongs_to? && !reflection.polymorphic?
        raise ArgumentError, "#{self.class.name}: text searches can only go through non-polymorphic belongs_to associations (#{association.inspect})"
      end

      related_searcher = KorSearch.searcher_for(reflection.klass)
      unless related_searcher&.search_registry&.dig(target, :type) == :text
        raise ArgumentError, "#{self.class.name}: #{reflection.klass.name} has no searcher with a text search named #{target.inspect}"
      end

      related_ids = related_searcher.new(reflection.klass.all)
        .search(target => value)
        .limit(ASSOCIATED_ID_LIMIT)
        .pluck(reflection.klass.primary_key)
      return nil if related_ids.empty?

      query.where(reflection.foreign_key => related_ids)
    end
  end
end
