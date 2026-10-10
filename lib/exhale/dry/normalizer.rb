# frozen_string_literal: true

require_relative "normalizer/ruby"
require_relative "normalizer/erb"

module Exhale
  module Dry
    # Turns a unit's parser node into a normalized Shape tree.
    module Normalizer
      # Part of every cache key and the report header. Bump it whenever a
      # normalization rule changes, since old fingerprints stop meaning the
      # same thing.
      VERSION = 2

      module_function

      def normalize(unit)
        case unit.language
        when :ruby then Ruby.normalize(unit.node)
        when :erb then Erb.normalize(unit.node, unit.path)
        else raise ArgumentError, "no normalizer for #{unit.language.inspect}"
        end
      end
    end
  end
end
