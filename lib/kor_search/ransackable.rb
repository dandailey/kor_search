# frozen_string_literal: true

module KorSearch
  # Answers Ransack's allowlist questions (ransackable_attributes and friends)
  # from the searcher that is running, rather than writing one global list
  # onto the model. Two searchers for the same model can therefore expose
  # different fields, and a model's own ransackable_* definitions still apply
  # to Ransack calls made outside KorSearch.
  #
  # Installed lazily on a model the first time a searcher runs Ransack on it.
  module Ransackable
    def self.install(klass)
      klass.singleton_class.prepend(self) unless klass.singleton_class.include?(self)
    end

    def ransackable_attributes(auth_object = nil)
      return auth_object.ransackable_attributes_for(self) if auth_object.is_a?(KorSearch::Searcher)

      super
    end

    def ransackable_associations(auth_object = nil)
      return auth_object.ransackable_associations_for(self) if auth_object.is_a?(KorSearch::Searcher)

      super
    end

    def ransackable_scopes(auth_object = nil)
      return [] if auth_object.is_a?(KorSearch::Searcher)

      super
    end
  end
end
