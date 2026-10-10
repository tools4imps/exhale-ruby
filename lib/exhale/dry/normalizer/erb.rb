# frozen_string_literal: true

require "herb"
require "prism"
require_relative "../../shape"
require_relative "ruby"

module Exhale
  module Dry
    module Normalizer
      # Turns a Herb node into a Shape. Markup keeps its tag and attribute
      # names; attribute values and text drop out, except the Stimulus
      # attributes whose values name behavior. Embedded Ruby goes through the
      # Ruby normalizer, so `link_to "Edit", edit_order_path(@order)` and
      # `link_to "Show", order_path(@invoice)` read the same.
      module Erb
        DROPPED = %w[
          HTMLTextNode WhitespaceNode HTMLCommentNode ERBCommentNode ERBEndNode
          HTMLCloseTagNode HTMLOmittedCloseTagNode HTMLVirtualCloseTagNode
        ].freeze

        # Herb classes for ERB tags that open (or continue) a Ruby construct
        # spanning several tags.
        CONTROL = %w[
          ERBBlockNode ERBIfNode ERBUnlessNode ERBElseNode ERBCaseNode ERBCaseMatchNode ERBWhenNode ERBInNode
          ERBForNode ERBWhileNode ERBUntilNode ERBBeginNode ERBRescueNode ERBEnsureNode ERBYieldNode
        ].freeze

        BRANCH_FIELDS = %i[conditions subsequent rescue_clause else_clause ensure_clause].freeze

        # Values that name behavior, so they stay in the tree.
        KEPT_VALUES = %w[data-controller data-action].freeze

        STRICT_LOCALS = /\A\s*locals:\s*(\(.*\))\s*\z/m

        # A head that can't parse alone, even with an `end`, gets wrapped in
        # the construct it belongs to, and the part it wrote is picked back
        # out. So the condition of `<% elsif admin? %>` or `<% when :draft %>`
        # survives. Wrappers stay on the code's line so Prism's line numbers
        # are the template's.
        BRANCHES = {
          "case" => [->(code) { "#{code}\nwhen nil\nend" }, ->(statement) { statement.predicate }],
          "elsif" => [->(code) { "#{code.sub("elsif", "if")}\nend" }, ->(statement) { statement }],
          "when" => [->(code) { "case;#{code}\nend" }, ->(statement) { statement.conditions.first }],
          "in" => [->(code) { "case nil;#{code}\nend" }, ->(statement) { statement.conditions.first }],
          "rescue" => [->(code) { "begin;#{code}\nend" }, ->(statement) { statement.rescue_clause }]
        }.freeze

        module_function

        def normalize(node)
          Walker.new.normalize(node)
        end

        # Each ERB tag parses on its own, so the walk carries the locals the
        # template has defined so far (block parameters, `<% total = 0 %>`)
        # into every later tag. Without them `item.name` inside
        # `<% items.each do |item| %>` would read as a call to `item`.
        class Walker
          def initialize
            @scopes = [[]]
          end

          def normalize(node)
            name = class_name(node)
            return if DROPPED.include?(name)

            case name
            when "DocumentNode" then document(node)
            when "HTMLElementNode" then element(node)
            when "HTMLAttributeNode" then attribute(node)
            when "LiteralNode" then leaf(":literal", node.location)
            when "ERBContentNode" then tag(node)&.first
            when *CONTROL then control(node)
            else build(node)
            end
          end

          private

          def normalize_all(nodes)
            Array(nodes).compact.filter_map { |child| normalize(child) }
          end

          def document(node)
            @scopes.first.concat(strict_locals(node.children))
            build(node, children: normalize_all(node.children), sequence: true)
          end

          # A partial's `<%# locals: (order:, compact: false) %>` magic comment
          # names the locals `render` passes in.
          def strict_locals(children)
            Array(children).each do |child|
              next unless class_name(child) == "ERBCommentNode"

              signature = child.content&.value.to_s[STRICT_LOCALS, 1]
              next unless signature

              result = Prism.parse("def _#{signature}; end")
              return result.value.statements.body.first.locals if result.success?
            end
            []
          end

          # An opening tag chosen in a conditional has no attributes of its own:
          # each branch's tag sits in the conditional, walked like any `<% if %>`.
          def element(node)
            open_tag = node.open_tag
            parts = class_name(open_tag) == "HTMLConditionalOpenTagNode" ? [open_tag.conditional] : open_tag&.children
            attributes = normalize_all(parts)
            body = normalize_all(node.body)
            children = body.empty? ? attributes : attributes + [run("html_body", body, node)]
            build(node, label: node.tag_name&.value&.downcase, children: children)
          end

          def attribute(node)
            name = literal_text(node.name&.children)
            build(node, label: name, children: [attribute_value(name, node.value)].compact)
          end

          # A value that is plain text becomes ":literal"; a value with ERB in
          # it keeps the ERB, normalized, beside ":literal" for each text part.
          def attribute_value(name, value)
            return unless value

            parts = Array(value.children)
            if KEPT_VALUES.include?(name.to_s.downcase)
              erb_parts = normalize_all(parts.reject { |part| literal?(part) })
              return build(value, kind: "html_attribute_value", label: literal_text(parts), children: erb_parts)
            end
            return leaf(":literal", value.location) if parts.all? { |part| literal?(part) }

            build(value, children: normalize_all(parts))
          end

          # `<%= ... %>` or `<% ... %>` on its own. Returns the shape and the
          # locals of any block the tag opens, or nil for an escaped `<%%`.
          def tag(node)
            opening = node.tag_opening&.value.to_s
            return if opening.start_with?("<%#", "<%%")

            kind = opening.start_with?("<%=") ? "erb_output" : "erb_logic"
            statements, block_locals = node.content ? ruby(node.content.value, node.content.location.start.line) : nil
            lines = tag_lines(node)
            children = Array(statements).map { |statement| clamp(Ruby.normalize(statement, template: true), lines[:end_line]) }
            [Shape.new(kind: kind, label: nil, children: children, sequence: false, **lines), block_locals]
          end

          # A tag that opens a Ruby construct over several tags: its head (the
          # tag itself), its body, then each later branch (else, elsif, when,
          # rescue, ensure), normalized the same way. The end tag drops out.
          def control(node)
            head, block_locals = tag(node)
            @scopes.push(block_locals) if block_locals
            children = [head].compact
            body_nodes = body_of(node)
            children << run("erb_body", normalize_all(body_nodes), node) if body_nodes
            children.concat(branches(node))
            build(node, children: children)
          ensure
            @scopes.pop if block_locals
          end

          # A case's own children are the gap before its first `when`, which
          # ERB never renders.
          def body_of(node)
            if node.respond_to?(:body) then node.body
            elsif node.respond_to?(:statements) then node.statements
            end
          end

          def branches(node)
            BRANCH_FIELDS.select { |field| node.respond_to?(field) }
                         .flat_map { |field| Array(node.public_send(field)) }
                         .filter_map { |branch| normalize(branch) }
          end

          # The Prism statements for one tag's Ruby, plus the locals of a
          # block it opens (nil when it opens none). Nil statements when it
          # won't parse even with a closing `end`.
          def ruby(code, line)
            statements = parse(code, line)
            return [statements, nil] if statements

            closed = "#{code}\nend"
            statements = parse(closed, line)
            return [statements, opened_block_locals(statements, code.bytesize)] if statements

            [branch(code, line) || in_method(code, line), nil]
          end

          def branch(code, line)
            wrap, pick = BRANCHES[code.strip[/\A\w+/]]
            statements = wrap && parse(wrap.call(code), line)
            picked = statements && pick.call(statements.first)
            [picked] if picked
          end

          # `yield` is only valid Ruby inside a method.
          def in_method(code, line)
            statements = parse("def _;#{code}\nend", line)
            body = statements&.first&.body
            body.body if body.is_a?(Prism::StatementsNode)
          end

          # Parses with the template's locals in scope, and keeps any locals
          # the code assigns for the tags after it.
          def parse(code, line)
            result = Prism.parse(code, line: line, scopes: @scopes)
            return unless result.success?

            @scopes.last.concat(result.value.locals - @scopes.last)
            result.value.statements.body
          end

          # A block whose `end` is the one appended to the head is the block
          # the ERB body runs inside.
          def opened_block_locals(statements, code_size)
            blocks = []
            stack = statements.dup
            until stack.empty?
              node = stack.pop
              blocks << node if node.is_a?(Prism::BlockNode) && node.location.end_offset > code_size
              stack.concat(node.compact_child_nodes)
            end
            blocks.empty? ? nil : blocks.flat_map(&:locals).uniq
          end

          # A run spans the shapes it holds; the text and whitespace around
          # them dropped out, so they don't stretch it. An empty run takes
          # the lines of the node it belongs to.
          def run(kind, children, fallback)
            return build(fallback, kind: kind, children: children, sequence: true) if children.empty?

            Shape.new(kind: kind, label: nil, children: children, sequence: true,
                      start_line: children.first.start_line, end_line: children.map(&:end_line).max)
          end

          def build(node, kind: snake_case(class_name(node)), label: nil,
                    children: normalize_all(node.compact_child_nodes), sequence: false)
            location = node.location
            Shape.new(kind: kind, label: label, children: children, sequence: sequence,
                      start_line: location.start.line, end_line: end_line(location))
          end

          def leaf(kind, location)
            Shape.new(kind: kind, label: nil, children: [], sequence: false,
                      start_line: location.start.line, end_line: end_line(location))
          end

          def tag_lines(node)
            first = node.tag_opening || node
            last = node.tag_closing || node.content || node
            { start_line: first.location.start.line, end_line: end_line(last.location) }
          end

          # The `end` a head borrowed to parse sits on the line after the tag.
          def clamp(shape, last)
            return shape if shape.end_line <= last

            shape.dup.tap do |copy|
              copy.end_line = [last, shape.start_line].max
              copy.children = shape.children.map { |child| clamp(child, last) }
            end
          end

          # Herb ends a node that runs to a newline at column 0 of the next
          # line; that line holds none of the node.
          def end_line(location)
            finish = location.end
            finish.column.zero? && finish.line > location.start.line ? finish.line - 1 : finish.line
          end

          def literal?(node)
            class_name(node) == "LiteralNode"
          end

          def literal_text(nodes)
            Array(nodes).select { |part| literal?(part) }.map(&:content).join
          end

          def class_name(node)
            node.class.name.split("::").last
          end

          def snake_case(name)
            name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
          end
        end
      end
    end
  end
end
