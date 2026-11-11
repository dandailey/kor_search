# frozen_string_literal: true

require "test_helper"

class DatesTest < KorSearchTest
  def setup
    super
    Product.create!(name: "Jan", released_on: Date.new(2026, 1, 15), published_at: Time.utc(2026, 1, 15, 23, 30))
    Product.create!(name: "Feb", released_on: Date.new(2026, 2, 1), published_at: Time.utc(2026, 2, 1, 0, 0))
    Product.create!(name: "Mar", released_on: Date.new(2026, 3, 31), published_at: Time.utc(2026, 3, 31, 12, 0))
  end

  def test_eq_on_a_datetime_column_covers_the_whole_day
    assert_equal %w[Jan], names(Product.kor_search(published_at: "2026-01-15"))
  end

  def test_eq_with_a_range_expands_to_both_bounds
    assert_equal %w[Feb Jan], names(Product.kor_search(released_on: "2026-01-01..2026-02-28"))
    assert_equal %w[Feb Jan], names(Product.kor_search(published_at: "2026-01-15 to 2026-02-01"))
  end

  def test_open_ended_ranges
    assert_equal %w[Feb Mar], names(Product.kor_search(released_on: "2026-02-01.."))
    assert_equal %w[Jan], names(Product.kor_search(released_on: "..2026-01-31"))
  end

  def test_comparison_predicates_pick_the_right_edge
    assert_equal %w[Feb Mar], names(Product.kor_search(released_on_gteq: "2026-02-01"))
    assert_equal %w[Feb Jan], names(Product.kor_search(published_at_lteq: "2026-02-01"))
    assert_equal %w[Mar], names(Product.kor_search(published_at_gt: "2026-02-01"))
    assert_equal %w[Jan], names(Product.kor_search(published_at_lt: "2026-02-01"))
  end

  def test_values_with_a_time_of_day_pass_through
    assert_equal %w[Feb Mar], names(Product.kor_search(published_at_gteq: "2026-02-01 00:00"))
  end

  def test_unparseable_values_pass_through_to_ransack
    params = ProductSearcher.new.effective_search_params(released_on: "someday")

    assert_equal({released_on: "someday"}, params)
  end

  def test_declared_date_filters_reach_the_scope_as_dates
    assert_equal({since: Date.new(2026, 2, 1)}, ProductSearcher.new.effective_search_params(since: "2026-02-01"))
    assert_equal %w[Feb Mar], names(Product.kor_search(since: "2026-02-01"))
  end

  def test_custom_date_parser
    parser = Module.new do
      def self.parse(value) = (value == "launch") ? Date.new(2026, 2, 1) : nil
      def self.parse_range(value) = (d = parse(value)) && [d, d]
    end
    KorSearch.date_parser = parser

    assert_equal %w[Feb], names(Product.kor_search(released_on: "launch"))
  end

  def test_basic_parser
    basic = KorSearch::Dates::Basic

    assert_equal Date.new(2026, 1, 2), basic.parse("2026-01-02")
    assert_nil basic.parse("01/02/2026")
    assert_nil basic.parse("2026-13-01")
    assert_equal [Date.new(2026, 1, 1), Date.new(2026, 1, 31)], basic.parse_range("2026-01-31..2026-01-01")
    assert_equal [Date.new(2026, 1, 1), nil], basic.parse_range("2026-01-01 to ")
    assert_nil basic.parse_range("2026-01-01..soon")
  end
end
