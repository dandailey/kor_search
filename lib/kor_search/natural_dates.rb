# frozen_string_literal: true

# Opt-in: natural-language date params ("last month", "mtd", "since jan"),
# powered by the kor_dates gem. Add `gem "kor_dates"` to your Gemfile.
require "kor_search"
require "kor_dates"

KorSearch.date_parser = KorDates
