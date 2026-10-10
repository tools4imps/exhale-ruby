# frozen_string_literal: true

require "herb"
require_relative "../errors"
require_relative "depth"
require_relative "../unit"
require_relative "../dry/normalizer/erb"

module Exhale
  module Units
    # A template is one unit. Duplication inside it is found later, as
    # fragments of its tree.
    module Erb
      module_function

      def extract(source, path)
        # strict: false lets valid HTML through (an omitted `</li>`); broken
        # markup and broken Ruby are still errors.
        result = Herb.parse(source, strict: false)
        Depth.parser_limit!(result.errors, path)
        raise_first_error(result.errors, path) unless result.errors.empty?
        # Normalizing is the walk that goes deepest: it parses each tag's Ruby
        # with the locals of the tags before it, which can change how deep
        # the tree is (`x %((1))` is a string unless x is a local), and counts
        # every tree it parses. So the walk itself is the check.
        Dry::Normalizer::Erb.normalize(result.value, path)

        [Unit.new(kind: :template, identity: path.delete_prefix("app/"), namespace: nil, name: nil, path: path,
                  start_line: 1, end_line: [source.lines.size, 1].max, language: :erb, node: result.value)]
      end

      def raise_first_error(errors, path)
        error = errors.min_by { |e| [e.location.start.line, e.location.start.column] }
        raise ParseError.new(path, error.location.start.line, error.message)
      end
    end
  end
end
