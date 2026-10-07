# frozen_string_literal: true

require "prism"
require_relative "../units/ruby"

module Exhale
  module Complexity
    # One increment of a unit's score.
    #
    # line      - Where the construct that earned it sits.
    # construct - What earned it: "if", "elsif", "&&", "each block", "send".
    # nesting   - The nesting level at the construct.
    # increment - 1, plus the nesting level for the constructs that pay it.
    # meta      - true for a metaprogramming point.
    Point = Struct.new(:line, :construct, :nesting, :increment, :meta, keyword_init: true)

    # G. Ann Campbell's Cognitive Complexity read off the Prism tree, with the
    # Ruby decisions in contract/cognitive/README.md.
    class Cognitive
      ITERATORS = %i[
        each map flat_map collect filter_map select filter reject find detect find_index find_all
        any? all? none? one? count sum inject reduce group_by partition sort_by min_by max_by minmax_by
        uniq zip take_while drop_while chunk_while slice_when times upto downto step loop cycle
        with_index with_object map! collect! select! filter! reject! sort_by!
      ].freeze

      METAPROGRAMMING = %i[
        eval instance_eval class_eval module_eval instance_exec class_exec module_exec
        define_method define_singleton_method send __send__ public_send
        instance_variable_get instance_variable_set const_get
      ].freeze

      def self.points(unit)
        raise ArgumentError, "#{unit.identity} isn't Ruby; templates aren't scored" unless unit.language == :ruby

        new(unit.node, method_name(unit)).points
      end

      # The name a recursive call would use. A DSL body has none, and neither
      # does a define_method named only by its ordinal.
      def self.method_name(unit)
        return unless unit.kind == :method

        name = unit.name.sub(/\[\d+\]\z/, "")
        name unless !unit.node.is_a?(Prism::DefNode) && Units::Ruby::DEFINE_METHODS.key?(name.to_sym)
      end

      def initialize(node, name)
        @node = node
        @name = name&.to_sym
      end

      # Sorted by line, then in the order the walk met them.
      def points
        @points = []
        @recursed = false
        root
        @points.each_with_index.sort_by { |point, index| [point.line, index] }.map(&:first)
      end

      private

      # The unit's own def, block or lambda is its body, at nesting 0.
      def root
        flat("method_missing", @node.location.start_line, 0, meta: true) if @name == :method_missing
        visit(@node.parameters, 0)
        visit(@node.body, 0)
      end

      def visit(node, nesting)
        return if node.nil? || node.is_a?(Prism::DefNode)

        case node
        when Prism::IfNode then if_node(node, nesting)
        when Prism::UnlessNode then unless_node(node, nesting)
        when Prism::WhileNode, Prism::UntilNode then loop_node(node, nesting)
        when Prism::ForNode then for_node(node, nesting)
        when Prism::CaseNode, Prism::CaseMatchNode then case_node(node, nesting)
        when Prism::BeginNode then begin_node(node, nesting)
        when Prism::RescueModifierNode then rescue_modifier(node, nesting)
        when Prism::AndNode, Prism::OrNode then boolean(node, nesting)
        when Prism::CallNode then call(node, nesting)
        when Prism::BlockNode, Prism::LambdaNode then nested_body(node, nesting)
        else children(node, nesting)
        end
      end

      def children(node, nesting)
        node.compact_child_nodes.each { |child| visit(child, nesting) }
      end

      def nested(construct, line, nesting)
        @points << Point.new(line: line, construct: construct, nesting: nesting, increment: 1 + nesting, meta: false)
      end

      def flat(construct, line, nesting, meta: false)
        @points << Point.new(line: line, construct: construct, nesting: nesting, increment: 1, meta: meta)
      end

      # A ternary has no if keyword, and its else costs nothing.
      def if_node(node, nesting)
        ternary = node.if_keyword_loc.nil?
        nested(ternary ? "ternary" : "if", line(node.if_keyword_loc || node.location), nesting)
        visit(node.predicate, nesting)
        visit(node.statements, nesting + 1)
        ternary ? visit(node.subsequent&.statements, nesting + 1) : branches(node.subsequent, nesting)
      end

      def branches(branch, nesting)
        case branch
        when Prism::IfNode
          flat("elsif", line(branch.if_keyword_loc), nesting)
          visit(branch.predicate, nesting)
          visit(branch.statements, nesting + 1)
          branches(branch.subsequent, nesting)
        when Prism::ElseNode
          flat("else", line(branch.else_keyword_loc), nesting)
          visit(branch.statements, nesting + 1)
        end
      end

      def unless_node(node, nesting)
        nested("unless", line(node.keyword_loc), nesting)
        visit(node.predicate, nesting)
        visit(node.statements, nesting + 1)
        branches(node.else_clause, nesting)
      end

      def loop_node(node, nesting)
        nested(node.keyword_loc.slice, line(node.keyword_loc), nesting)
        visit(node.predicate, nesting)
        visit(node.statements, nesting + 1)
      end

      def for_node(node, nesting)
        nested("for", line(node.for_keyword_loc), nesting)
        visit(node.index, nesting)
        visit(node.collection, nesting)
        visit(node.statements, nesting + 1)
      end

      # One charge for the whole case; its branches and else sit inside it.
      def case_node(node, nesting)
        nested(node.is_a?(Prism::CaseMatchNode) ? "case/in" : "case", line(node.case_keyword_loc), nesting)
        visit(node.predicate, nesting)
        node.conditions.each { |condition| case_branch(condition, nesting + 1) }
        visit(node.else_clause&.statements, nesting + 1)
      end

      # A guard on an `in` branch is an if or unless around the pattern in
      # Prism, but it costs 1 flat.
      def case_branch(condition, nesting)
        guard = condition.pattern if condition.is_a?(Prism::InNode)
        return visit(condition, nesting) unless guard.is_a?(Prism::IfNode) || guard.is_a?(Prism::UnlessNode)

        keyword = guard.is_a?(Prism::IfNode) ? guard.if_keyword_loc : guard.keyword_loc
        flat("#{keyword.slice} guard", line(keyword), nesting)
        visit(guard.statements, nesting)
        visit(guard.predicate, nesting)
        visit(condition.statements, nesting)
      end

      # The else of a begin/rescue and its ensure cost nothing and don't nest.
      def begin_node(node, nesting)
        visit(node.statements, nesting)
        clause = node.rescue_clause
        while clause
          nested("rescue", line(clause.keyword_loc), nesting)
          clause.exceptions.each { |exception| visit(exception, nesting) }
          visit(clause.reference, nesting)
          visit(clause.statements, nesting + 1)
          clause = clause.subsequent
        end
        visit(node.else_clause&.statements, nesting)
        visit(node.ensure_clause&.statements, nesting)
      end

      def rescue_modifier(node, nesting)
        nested("rescue", line(node.keyword_loc), nesting)
        visit(node.expression, nesting)
        visit(node.rescue_expression, nesting + 1)
      end

      # One point per run of like operators, in source order. `!` and
      # parentheses are see-through, so `a && !(b && c)` is one run.
      def boolean(node, nesting)
        operators = []
        operands = []
        flatten(node, operators, operands)
        operators.each_with_index do |(kind, at), index|
          flat(kind, at, nesting) if index.zero? || operators[index - 1].first != kind
        end
        operands.each { |operand| visit(operand, nesting) }
      end

      def flatten(node, operators, operands)
        if node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode)
          flatten(node.left, operators, operands)
          operators << [node.is_a?(Prism::AndNode) ? "&&" : "||", line(node.operator_loc)]
          flatten(node.right, operators, operands)
        elsif (inner = see_through(node))
          flatten(inner, operators, operands)
        else
          operands << node
        end
      end

      def see_through(node)
        case node
        when Prism::ParenthesesNode
          body = node.body
          body.is_a?(Prism::StatementsNode) && body.body.size == 1 ? body.body.first : nil
        when Prism::CallNode
          node.receiver if node.name == :! && node.arguments.nil? && node.block.nil?
        end
      end

      def call(node, nesting)
        at = line(node.message_loc || node.location)
        recursion(node, at, nesting)
        flat(node.name.to_s, at, nesting, meta: true) if METAPROGRAMMING.include?(node.name)
        visit(node.receiver, nesting)
        visit(node.arguments, nesting)
        block(node, nesting)
      end

      def recursion(node, at, nesting)
        return if @recursed || @name.nil? || node.name != @name
        return unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

        @recursed = true
        flat("recursion", at, nesting)
      end

      # `&:sym` and `&method(:x)` aren't blocks. A define_method block inside
      # a unit is no unit of its own (Units::Ruby stops at a unit), so it
      # scores here like any block.
      def block(node, nesting)
        block = node.block
        return visit(block, nesting) unless block.is_a?(Prism::BlockNode)

        nested("#{node.name} block", line(block.opening_loc), nesting) if iterates?(node.name)
        nested_body(block, nesting)
      end

      def nested_body(node, nesting)
        visit(node.parameters, nesting + 1)
        visit(node.body, nesting + 1)
      end

      def iterates?(name)
        ITERATORS.include?(name) || name.start_with?("each_")
      end

      def line(location)
        location.start_line
      end
    end
  end
end
