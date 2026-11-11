# frozen_string_literal: true

module KorSearch
  module Dates
    # Default date parser. Understands ISO 8601 dates and ranges written as
    # "2026-01-01..2026-01-31" or "2026-01-01 to 2026-01-31". Anything else is
    # left alone. For natural language ("last month", "mtd", "since jan"),
    # `require "kor_search/natural_dates"` (uses the kor_dates gem).
    module Basic
      module_function

      ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/
      RANGE_SEPARATOR = /\s*(?:\.\.|\bto\b|\bthru\b|\bthrough\b)\s*/i

      def parse(input)
        return input.to_date if input.respond_to?(:to_date) && !input.is_a?(String)

        raw = input.to_s.strip
        return nil unless raw.match?(ISO_DATE)

        Date.iso8601(raw)
      rescue ArgumentError
        nil
      end

      def parse_range(input)
        parts = input.to_s.strip.split(RANGE_SEPARATOR, 2)

        if parts.length == 2
          from = parts[0].blank? ? nil : parse(parts[0])
          to = parts[1].blank? ? nil : parse(parts[1])
          return nil if (parts[0].present? && from.nil?) || (parts[1].present? && to.nil?)
          return nil if from.nil? && to.nil?

          return (from && to && from > to) ? [to, from] : [from, to]
        end

        date = parse(input)
        date ? [date, date] : nil
      end
    end
  end
end
