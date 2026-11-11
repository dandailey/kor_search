# frozen_string_literal: true

require "minitest/autorun"
require "active_record"
require "ransack"
require "kor_search"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false
Time.zone_default = Time.find_zone!("UTC")

ActiveRecord::Schema.define do
  create_table :manufacturers do |t|
    t.string :name
    t.string :country
  end

  create_table :products do |t|
    t.string :type
    t.string :name
    t.string :sku
    t.string :description
    t.string :status
    t.decimal :price
    t.boolean :active, default: false
    t.date :released_on
    t.datetime :published_at
    t.references :manufacturer
  end

  create_table :shop_orders do |t|
    t.string :number
  end
end

class Manufacturer < ActiveRecord::Base
  has_many :products
end

class Product < ActiveRecord::Base
  belongs_to :manufacturer, optional: true

  scope :active, -> { where(active: true) }
  scope :priced_under, ->(amount) { where("price < ?", amount) }
  scope :with_status, ->(status) { where(status: status) }
  scope :released_since, ->(date) { where("released_on >= ?", date) }
end

class Gadget < Product
end

module Shop
  class Order < ActiveRecord::Base
    self.table_name = "shop_orders"
  end
end

class ManufacturerSearcher < KorSearch::Searcher
  search_fields :name, :country
  text_search :q, columns: %i[name country]
end

class ProductSearcher < KorSearch::Searcher
  search_fields :name, :sku, :status, :price, :released_on, :published_at
  search_associations :manufacturer

  text_search :q, columns: %i[name sku], extended: %i[manufacturer]
  text_search :maker, through: %i[manufacturer]

  boolean_search :active
  simple_search :under, method: :priced_under
  simple_search :since, method: :released_since
  date_filters :since
end

module Shop
  class OrderSearcher < KorSearch::Searcher
    search_fields :number
  end
end

class KorSearchTest < Minitest::Test
  def setup
    @saved_parser = KorSearch.date_parser
    @saved_strict = KorSearch.strict_scopes
    @saved_resolvers = KorSearch.searcher_resolvers.dup
    Product.delete_all
    Manufacturer.delete_all
    Shop::Order.delete_all
  end

  def teardown
    KorSearch.date_parser = @saved_parser
    KorSearch.strict_scopes = @saved_strict
    KorSearch.searcher_resolvers = @saved_resolvers
  end

  def names(relation)
    relation.order(:name).pluck(:name)
  end
end
