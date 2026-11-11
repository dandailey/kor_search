# frozen_string_literal: true

module KorSearch
  module Bool
    module_function

    TRUTHY = %w[true 1 t on yes y].freeze

    # A pragmatic truthiness parser for params.
    #
    #   truthy?(true)   # => true
    #   truthy?("Yes")  # => true
    #   truthy?("0")    # => false
    #   truthy?(nil)    # => false
    def truthy?(value)
      return true if value == true
      return false if value.nil?

      TRUTHY.include?(value.to_s.strip.downcase)
    end
  end
end
