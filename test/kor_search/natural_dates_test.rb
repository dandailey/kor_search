# frozen_string_literal: true

require "test_helper"
require "kor_search/dates/natural"

class NaturalDatesTest < KorSearchTest
  Natural = KorSearch::Dates::Natural

  def test_parse
    assert_equal Date.new(1999, 1, 2), Natural.parse("1/2/99")
    assert_equal Date.new(2000, 1, 2), Natural.parse("1/2/00")
    refute Natural.parseable?("1999")
    assert Natural.parseable?("today")
    assert Natural.parseable?("next fri")
  end

  def test_period_ranges
    assert_range "1999", Date.new(1999, 1, 1), Date.new(1999, 12, 31)
    assert_range "january '99", Date.new(1999, 1, 1), Date.new(1999, 1, 31)
    assert_range "next jan", Date.new(Date.current.year + 1, 1, 1), Date.new(Date.current.year + 1, 1, 31)
    assert_range "this month", Date.current.beginning_of_month, Date.current.end_of_month
    assert_range "qtr", Date.current.beginning_of_quarter, Date.current.end_of_quarter
    assert_range "past month", Date.current.beginning_of_month - 1.month, (Date.current.beginning_of_month - 1.month).end_of_month
  end

  def test_span_and_one_sided_ranges
    assert_range "7 days", Date.current, Date.current + 7.days
    assert_range "past 2 weeks", Date.current - 2.weeks, Date.current
    assert_range "mtd", Date.current.beginning_of_month, Date.current
    assert_range "after fri", Natural.parse("fri").tomorrow, nil
    assert_range "until fri", nil, Natural.parse("fri")
    assert_range "future", Date.current, nil
  end

  # Day words used to be rewritten as ISO dates, whose dashes were then read
  # as a range separator ("yesterday" became yesterday..today).
  def test_day_words_are_single_days
    assert_range "today", Date.current, Date.current
    assert_range "yesterday", Date.yesterday, Date.yesterday
    assert_range "tomorrow", Date.tomorrow, Date.tomorrow
    assert_range "fri", Natural.parse("fri"), Natural.parse("fri")
  end

  # The /x replacement pattern ignored the space in "next +", so relative
  # weekdays never matched as a unit.
  def test_relative_weekdays_are_single_days
    assert_range "next fri", Natural.parse("next fri"), Natural.parse("next fri")
    assert_range "last mon", Natural.parse("last mon"), Natural.parse("last mon")
    assert_range "after next fri", Natural.parse("next fri").tomorrow, nil
  end

  def test_verbose_ranges
    assert_range "1/2 to 3/4", Natural.parse("1/2"), Natural.parse("3/4")
    assert_range "2019-10-14", Date.new(2019, 10, 14), Date.new(2019, 10, 14)
  end

  def test_drives_searches
    KorSearch.date_parser = Natural
    Product.create!(name: "Now", released_on: Date.current)
    Product.create!(name: "Old", released_on: Date.current - 2.years)

    assert_equal %w[Now], names(Product.kor_search(released_on: "this year"))
    assert_equal %w[Old], names(Product.kor_search(released_on: (Date.current.year - 2).to_s))
    assert_equal %w[Now], names(Product.kor_search(released_on_gteq: "last month"))
    assert_equal %w[Old], names(Product.kor_search(released_on_lteq: "last month"))
    assert_equal({released_on_lteq: Date.current.beginning_of_month - 1.day},
      ProductSearcher.new.effective_search_params(released_on_lteq: "last month"))
  end

  private

  def assert_range(input, from, to)
    assert_equal [from, to], Natural.parse_range(input), input
  end
end
