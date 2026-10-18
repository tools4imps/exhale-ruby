# frozen_string_literal: true

require_relative "lib/exhale/version"

Gem::Specification.new do |spec|
  spec.name = "exhale"
  spec.version = Exhale::VERSION
  spec.authors = ["Obie Fernandez"]
  spec.email = ["obiefernandez@gmail.com"]

  spec.summary = "The contraction toolkit for Rails. Its first check, exhale dry, fails a PR while the codebase holds duplication the Contract doesn't keep"
  spec.description = <<~DESC.strip.gsub(/\n/, " ")
    exhale is the contraction toolkit for the exhale of every pull request in a Rails app. Its
    first check, exhale dry, sweeps the whole codebase for duplicated Ruby and ERB, scores near-copies by rarity-weighted
    structural similarity, and fails the build while any copy is undeclared. Deliberate
    duplication is declared in the Contract, next to the reason for it. Built on Prism and Herb.
  DESC
  spec.homepage = "https://github.com/tools4imps/exhale-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ contract/ assets/ .git .github .mutineer appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = ["exhale"]
  spec.require_paths = ["lib"]

  spec.add_dependency "bigdecimal", ">= 3.1", "< 5"
  spec.add_dependency "herb", "~> 0.11"
  spec.add_dependency "prism", "~> 1.9"

  spec.add_development_dependency "minitest", "~> 6.0"
  spec.add_development_dependency "rake", "~> 13.0"

  spec.metadata["rubygems_mfa_required"] = "true"
end
