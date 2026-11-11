# frozen_string_literal: true

module KorSearch
  # Extended onto ActiveRecord::Base. Because Rails delegates class methods to
  # relations, this works on both models and scoped relations:
  #
  #   Company.kor_search(params[:search])
  #   current_user.companies.active.kor_search(params[:search])
  module Model
    def kor_search(params = {}, extended: false, **keyword_params)
      searcher_class = KorSearch.searcher_for(self)
      raise KorSearch::SearcherNotFound, "No searcher found for #{name} (expected #{name}Searcher)" unless searcher_class

      searcher_class.new(all).search(params, extended: extended, **keyword_params)
    end
  end
end
