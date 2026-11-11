# frozen_string_literal: true

require_relative "lib/kor_search/version"

Gem::Specification.new do |spec|
  spec.name = "kor_search"
  spec.version = KorSearch::VERSION
  spec.authors = ["Daniel Dailey"]
  spec.email = ["daniel@danieldailey.com"]

  spec.summary = "One search language for ActiveRecord, in code and over HTTP"
  spec.description = "KorSearch maps a flat params hash onto your models' scopes and columns through small, " \
                     "declarative searcher classes: Ransack-style field predicates, boolean and value scopes, " \
                     "multi-source free-text search, and date coercion. The same params work from Ruby and from a URL."
  spec.homepage = "https://github.com/dandailey/kor_search"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.0"
  spec.add_dependency "activesupport", ">= 7.0"
end
