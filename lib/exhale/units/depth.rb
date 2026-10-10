# frozen_string_literal: true

require_relative "../errors"

module Exhale
  module Units
    # Every walk over a parse tree recurses, so a tree nested past the stack
    # would stop the run, and how deep that is depends on the process's stack.
    # A fixed limit makes it a property of the source: real code nests far
    # less, and the walks handle at least twice the limit.
    #
    # Prism and Herb recurse in C before anything can be counted. They run on
    # the caller's stack, so a file too deep for them stops the run as it
    # always did: rescuing an overflow in C left the process to die later with
    # a signal.
    module Depth
      LIMIT = 200

      module_function

      # Raises unless root's tree stays within LIMIT levels, a level being one
      # node on the path from root to its deepest leaf, root included. A tree
      # parsed out of another one starts at the level below where it sits.
      def check!(root, path, from: 1)
        stack = [[root, from]]
        until stack.empty?
          node, depth = stack.pop
          raise too_deep(path) if depth > LIMIT

          node.compact_child_nodes.each { |child| stack << [child, depth + 1] }
        end
      end

      # Herb parses a tag's Ruby with Prism and passes Prism's own nesting
      # limit on as the diagnostic id of a Ruby error, before any tree exists
      # to count. A Ruby file at that limit comes back deeper than LIMIT.
      def parser_limit!(errors, path)
        hit = errors.any? { |e| e.respond_to?(:diagnostic_id) && e.diagnostic_id == "nesting_too_deep" }
        raise too_deep(path) if hit
      end

      # Line 1 whatever node went past the limit, so the error is the same
      # whether the count or a parser's own limit caught the file.
      def too_deep(path)
        ParseError.new(path, 1, "nests deeper than #{LIMIT} levels")
      end
    end
  end
end
