# frozen_string_literal: true

require "test_helper"
require "kor_search/natural_dates"

# The parser itself is tested in kor_dates; this covers the integration.
class NaturalDatesTest < KorSearchTest
  def setup
    super
    KorSearch.date_parser = KorDates
    Product.create!(name: "Now", released_on: Date.current, published_at: Time.current)
    Product.create!(name: "Old", released_on: Date.current - 2.years, published_at: 2.years.ago)
  end

  def test_requiring_natural_dates_selects_kor_dates
    assert_equal KorDates, KorSearch.date_parser
  end

  def test_periods_and_years
    assert_equal %w[Now], names(Product.kor_search(released_on: "this year"))
    assert_equal %w[Old], names(Product.kor_search(released_on: (Date.current.year - 2).to_s))
  end

  def test_comparisons_use_the_right_edge
    assert_equal %w[Now], names(Product.kor_search(released_on_gteq: "last month"))
    assert_equal %w[Old], names(Product.kor_search(released_on_lteq: "last month"))
  end

  def test_day_words_on_a_datetime_column
    assert_equal %w[Now], names(Product.kor_search(published_at: "today"))
    assert_empty names(Product.kor_search(published_at: "yesterday"))
  end
end
