# frozen_string_literal: true

require "chronic"
require "time"

module KorSearch
  module Dates
    # Chronic-backed natural-language date parser, ported from Korrelate.
    # Enable with `require "kor_search/natural_dates"`. Understands single
    # dates ("today", "next fri", "1/2/99") and ranges ("last month", "mtd",
    # "since jan", "mon-fri", "past 2 weeks", "1999").
    module Natural
      module_function

      WEEKDAY_PATTERN = "su(n|nday)?|mo(n|nday)?|tu(e|es|esday)?|we(d|dnesday)?|" \
        "th(u|ur|urs|ursday)?|fr(i|iday)?|sa(t|tur|turday)?"
      MONTH_WORD_PATTERN = "jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|" \
        "aug(ust)?|sept?(ember)?|oct(ober)?|nov(ember)?|dec(ember)?"
      DATE_WORD_PATTERN = Regexp.new(
        "\\A((next +|last +|this +)?(#{WEEKDAY_PATTERN})|today|yesterday|tomorrow|" \
        "\\d{1,2}(st|nd|rd|th)|([ .\\/\\\\-]|[0-9]|#{MONTH_WORD_PATTERN}|days?|weeks?|ago){3,})\\z"
      )

      RELATIVE_SHIFT_PATTERN = /this|current|next|upcoming|following|last|past|prev(?:ious)?/
      UNIT_SIZE_PATTERN = /days?|dys?|weeks?|wks?|mos?|months?|quarters?|qtrs?|years?|yrs?/
      MONTH_PATTERN = Regexp.new(
        "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|" \
        "sep(?:t|tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"
      )
      YEAR_PATTERN = /\d{4}|'\d{2}/
      PARSEABLE_DATE_PATTERN = /[a-z0-9 .\/\-,]{3,}|mo|tu|we|th|fr|sa|su/
      ISO_DATETIME_PATTERN = /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?\z/
      EXPLICIT_TIME_PATTERN = /(?:\bat\b|\bnoon\b|\bmidnight\b|\d{1,2}:\d{2}|\d{1,2}\s*(?:am|pm)\b)/i

      def parse(input, options = {})
        return input.to_date if input.respond_to?(:to_date) && !input.is_a?(String)
        return nil if input.nil?

        date_val = input.to_s
        date_pieces = []

        if (match_data = date_val.strip.match(/\A([0-9]+)[^0-9]+([0-9]+)(?:[^0-9]+([0-9]+))?\z/))
          date_pieces = match_data.to_a.slice(1..3).compact
          date_pieces[2] = "20#{date_pieces[2]}" if date_pieces[2] == "00"
          date_val = date_pieces.join("/")
        end

        parsed = Chronic.parse(date_val, options)&.to_date

        if parsed && date_pieces.length == 2
          parsed -= 1.year if parsed > (Date.current + 330.days) && parsed < (Date.current + 1.year)
        end

        parsed
      rescue
        nil
      end

      def parse_datetime(input, options = {})
        return input.in_time_zone if input.respond_to?(:in_time_zone) && !input.is_a?(String)
        return nil if input.nil?

        raw = input.to_s.strip
        return nil if raw.empty?
        return Time.zone ? Time.zone.parse(raw) : Time.parse(raw) if raw.match?(ISO_DATETIME_PATTERN)

        unless raw.match?(EXPLICIT_TIME_PATTERN)
          parsed_date = parse(raw, options)
          return parsed_date.in_time_zone if parsed_date
        end

        parsed = Chronic.parse(raw, options)
        return nil unless parsed
        return parsed unless Time.zone

        Time.zone.local(parsed.year, parsed.month, parsed.day, parsed.hour, parsed.min, parsed.sec)
      rescue
        nil
      end

      def parseable?(input)
        raw = input.to_s.strip
        return false if raw.match?(/\A[0-9,.]+\z/)

        parse(raw).present? && raw.downcase.match?(DATE_WORD_PATTERN)
      end

      def parse_range(input)
        range_val = input.to_s.strip.squish.downcase
        range_val.gsub!(/(?:\A| )(\d{4})-(\d{1,2})-(\d{2})(?: |\z)/, "\\2/\\3/\\1")

        unless range_val.match?(/\A(after|from|before|until|since|thru|through)/)
          range_val.gsub!(relative_date_replacement_pattern) do |text|
            parseable?(text.strip) ? " #{parse(text.strip).strftime("%m/%d/%Y")} " : text
          end
          range_val = range_val.strip.squish
        end

        range = parse_named_range(range_val) ||
          parse_year_range(range_val) ||
          parse_month_range(range_val) ||
          parse_unit_range(range_val) ||
          parse_span_range(range_val) ||
          parse_period_to_date_range(range_val) ||
          parse_one_sided_before_after_range(range_val) ||
          parse_one_sided_month_range(range_val) ||
          parse_one_sided_since_through_range(range_val) ||
          parse_month_day_range(range_val) ||
          parse_verbose_range(range_val) ||
          parse_single_date_range(range_val)

        return nil unless range

        range.include?(nil) ? range : range.sort
      rescue
        nil
      end

      def parse_named_range(range_val)
        case range_val
        when "past" then [nil, Date.current]
        when "future", "upcoming" then [Date.current, nil]
        when "recent" then [Date.current - 90.days, Date.current]
        when "current" then [Date.current - 1.week, Date.current + 1.week]
        end
      end

      def parse_year_range(range_val)
        return nil unless range_val.match?(/\A#{YEAR_PATTERN}\z/o)

        year = to_four_year(range_val.gsub(/\D/, ""))
        [parse("1/1/#{year}"), parse("12/31/#{year}")]
      end

      def parse_month_range(range_val)
        match_data = range_val.match(/\A(#{RELATIVE_SHIFT_PATTERN} )?(#{MONTH_PATTERN})( #{YEAR_PATTERN})?\z/o)
        return nil unless match_data

        relative_shift = simplify_relative_shift(match_data[1].to_s.strip)
        month = match_data[2]

        first = if relative_shift.present?
          apply_shift(parse("#{month} 1st #{Date.current.year}"), relative_shift, "year")
        else
          year = to_four_year(match_data[3].to_s.gsub(/\D/, ""))
          parse("#{month} 1st#{year.present? ? " #{year}" : " #{Date.current.year}"}")
        end

        [first, first.end_of_month]
      end

      def parse_unit_range(range_val)
        match_data = range_val.match(/\A(#{RELATIVE_SHIFT_PATTERN})? ?(#{UNIT_SIZE_PATTERN})\z/o)
        return nil unless match_data

        relative_shift = simplify_relative_shift((match_data[1] || "this").strip)
        unit_size = simplify_unit_size(match_data[2].to_s.strip)
        first = Date.current.public_send("beginning_of_#{unit_size}").to_date
        first = apply_shift(first, relative_shift, unit_size)

        [first, first.public_send("end_of_#{unit_size}")]
      end

      def parse_span_range(range_val)
        match_data = range_val.match(/\A(#{RELATIVE_SHIFT_PATTERN})?( *-?[0-9]+ ?)? ?(#{UNIT_SIZE_PATTERN})\z/o)
        return nil unless match_data

        relative_shift = simplify_relative_shift(match_data[1] || "next")
        step_size = (match_data[2] || 1).to_s.strip.to_i
        unit_size = simplify_unit_size(match_data[3].to_s.strip)
        shifted_date = apply_shift(Date.current, relative_shift, unit_size, step_size)

        (relative_shift == "last") ? [shifted_date, Date.current] : [Date.current, shifted_date]
      end

      def parse_period_to_date_range(range_val)
        match_data = range_val.match(/\A(w|week |m|month |q|quarter |y|year )(to date|td)\z/)
        return nil unless match_data

        relative_term = {
          "w" => "week",
          "m" => "month",
          "q" => "quarter",
          "y" => "year"
        }.fetch(match_data[1].strip[0], "")

        [Date.current.public_send("beginning_of_#{relative_term}"), Date.current]
      end

      def parse_one_sided_before_after_range(range_val)
        match_data = range_val.match(/\A(after|from|before|until) (#{PARSEABLE_DATE_PATTERN})\z/o)
        return nil unless match_data

        relative_term = match_data[1]
        date_term = match_data[2]

        case relative_term
        when "after" then [parse(date_term) + 1.day, nil]
        when "from" then [parse(date_term), nil]
        when "before" then [nil, parse(date_term) - 1.day]
        when "until" then [nil, parse(date_term)]
        end
      end

      def parse_one_sided_month_range(range_val)
        match_data = range_val.match(
          /
            \A(since|thru|through)[ ]?(first|start|beginning|last|end)?[ ]?(?:of[ ])?
            ((?:this[ ]|last[ ]|next[ ])?month|#{MONTH_PATTERN}(?:[ ]#{YEAR_PATTERN})?)\z
          /xo
        )
        return nil unless match_data

        relative_term = match_data[1]
        month_term = match_data[3]

        if relative_term == "since"
          date_shift = %w[last end].include?(match_data[2]) ? :end_of_month : :beginning_of_month
          [parse(month_term, context: :past).public_send(date_shift), Date.current]
        else
          date_shift = %w[first start beginning].include?(match_data[2]) ? :beginning_of_month : :end_of_month
          [Date.current, parse(month_term, context: :future).public_send(date_shift)]
        end
      end

      def parse_one_sided_since_through_range(range_val)
        match_data = range_val.match(/\A(since|thru|through) (#{PARSEABLE_DATE_PATTERN})\z/o)
        return nil unless match_data

        if match_data[1] == "since"
          [parse(match_data[2], context: :past), Date.current]
        else
          [Date.current, parse(match_data[2], context: :future)]
        end
      end

      def parse_month_day_range(range_val)
        match_data = range_val.match(
          /
            \A(#{MONTH_PATTERN})[ ](\d{1,2})[ ]?(?:st|nd|rd|th)?[ ]?(?:to|thru|through|-)[ ]?
            (\d{1,2})[ ]?(?:st|nd|rd|th)?\z
          /xo
        )
        return nil unless match_data

        month = parse(match_data[1]).month
        future_months = (Date.current.month..(Date.current.month + 4)).map { |i| (i > 12) ? i - 12 : i }
        context = future_months.include?(month) ? :future : :past

        [parse("#{month}/#{match_data[2]}", context: context), parse("#{month}/#{match_data[3]}", context: context)]
      end

      def parse_verbose_range(range_val)
        match_data = range_val.match(
          /\A(#{PARSEABLE_DATE_PATTERN}) ?(to|thru|through|-|:|and)++ ?(#{PARSEABLE_DATE_PATTERN})\z/o
        )
        return nil unless match_data
        return nil unless parse(match_data[1]).present? && parse(match_data[3]).present?

        [parse(match_data[1].strip), parse(match_data[3].strip, now: parse(match_data[1].strip))]
      end

      def parse_single_date_range(range_val)
        return nil unless parseable?(range_val)

        [parse(range_val), parse(range_val)]
      end

      def relative_date_replacement_pattern
        /
          (?:\A|[^a-z])
          ((next[ ]+|last[ ]+|this[ ]+)?
          (su(n|nday)?|mo(n|nday)?|tu(e|es|esday)?|we(d|dnesday)?|th(u|ur|urs|ursday)?|
          fr(i|iday)?|sa(t|tur|turday)?)|today|yesterday|tomorrow|\d{1,2}(st|nd|rd|th))?
          (?:[^a-z]|\z)
        /x
      end

      def simplify_relative_shift(relative_shift)
        case relative_shift
        when "next", "upcoming", "following" then "next"
        when "last", "past", "prev", "previous" then "last"
        when "this", "current" then "this"
        else relative_shift
        end
      end

      def simplify_unit_size(unit_size)
        case unit_size
        when "day", "days", "dy", "dys" then "day"
        when "week", "weeks", "wk", "wks" then "week"
        when "month", "months", "mo", "mos" then "month"
        when "quarter", "quarters", "qtr", "qtrs" then "quarter"
        when "year", "years", "yr", "yrs" then "year"
        else unit_size
        end
      end

      def apply_shift(first, relative_shift, unit_size, step_size = 1)
        return first if relative_shift == "this"

        if unit_size == "quarter"
          return first + (3 * step_size).months if relative_shift == "next"
          return first - (3 * step_size).months if relative_shift == "last"
        end

        return first + step_size.public_send(unit_size) if relative_shift == "next"
        return first - step_size.public_send(unit_size) if relative_shift == "last"

        first
      end

      def to_four_year(year, years_forward_cutoff = 30)
        return year unless year.match?(/\A\d{2}\z/)

        this_century = Date.current.year.to_s[0, 2]
        if "#{this_century}#{year}".to_i > (Date.current.year + years_forward_cutoff)
          "#{this_century.to_i - 1}#{year}"
        else
          "#{this_century}#{year}"
        end
      end
    end
  end
end
