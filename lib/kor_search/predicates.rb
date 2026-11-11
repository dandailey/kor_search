# frozen_string_literal: true

module KorSearch
  # The Ransack predicates KorSearch honors, longest first so compound
  # predicates win the split: "status_not_eq" must parse as "status" + "not_eq",
  # never "status_not" + "eq".
  PREDICATES = %w[
    eq not_eq matches does_not_match lt lteq gt gteq
    present blank null not_null in not_in
    cont not_cont start not_start end not_end
    true false
  ].sort_by { |p| -p.length }.freeze

  # Split a search param key into [attribute, predicate], using the allowlist
  # to decide the split. A bare allowlisted key returns [key, "eq"]. Returns
  # nil when no allowlisted split exists.
  #
  #   split_predicate("status_not_eq", [:status])  # => ["status", "not_eq"]
  #   split_predicate("status", [:status])         # => ["status", "eq"]
  #   split_predicate("secret_eq", [:status])      # => nil
  def self.split_predicate(key, allowlist)
    key = key.to_s
    allowlist = allowlist.map(&:to_s)

    PREDICATES.each do |predicate|
      next unless key.end_with?("_#{predicate}")

      attr_name = key.delete_suffix("_#{predicate}")
      return [attr_name, predicate] if allowlist.include?(attr_name)
    end

    return [key, "eq"] if allowlist.include?(key)

    nil
  end
end
