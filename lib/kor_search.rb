# frozen_string_literal: true

require "active_support"
require "active_support/core_ext"
require "active_record"

require_relative "kor_search/version"
require_relative "kor_search/bool"
require_relative "kor_search/predicates"
require_relative "kor_search/dates/basic"
require_relative "kor_search/searcher"
require_relative "kor_search/model"

module KorSearch
  class Error < StandardError; end

  # Raised when a model has no searcher and `.kor_search` is called on it.
  class SearcherNotFound < Error; end

  # Raised when a registered search points at a scope the relation doesn't have.
  class MissingScope < Error; end

  # Date parser used to coerce date params. Must respond to `parse(value)`,
  # returning a Date or nil, and `parse_range(value)`, returning [from, to]
  # (either end may be nil) or nil. `require "kor_search/natural_dates"` swaps
  # in a Chronic-backed parser that understands "last month", "mtd", etc.
  mattr_accessor :date_parser, default: KorSearch::Dates::Basic

  # When true (the default), a registered search whose scope doesn't exist on
  # the relation raises KorSearch::MissingScope. When false it is skipped.
  mattr_accessor :strict_scopes, default: true

  # Extra lookups tried, in order, after the "#{Model}Searcher" convention.
  # Each is a callable taking the model class and returning a searcher class
  # or nil.
  mattr_accessor :searcher_resolvers, default: []

  def self.configure
    yield self
  end

  # Find the searcher class for a model: "#{Model}Searcher" first, then any
  # registered resolvers, then the same lookups for the STI base class.
  def self.searcher_for(model)
    model = model.klass if model.is_a?(ActiveRecord::Relation)

    candidates = [model]
    candidates << model.base_class if model.respond_to?(:base_class) && model.base_class != model

    candidates.each do |klass|
      explicit = "#{klass.name}Searcher".safe_constantize
      return explicit if explicit.is_a?(Class) && explicit <= KorSearch::Searcher

      searcher_resolvers.each do |resolver|
        found = resolver.call(klass)
        return found if found
      end
    end

    nil
  end
end

ActiveSupport.on_load(:active_record) do
  extend KorSearch::Model
end
