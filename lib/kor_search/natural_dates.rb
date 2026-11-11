# frozen_string_literal: true

# Opt-in: natural-language date params ("last month", "mtd", "since jan").
# Requires the chronic gem in your Gemfile.
require "kor_search"
require_relative "dates/natural"

KorSearch.date_parser = KorSearch::Dates::Natural
