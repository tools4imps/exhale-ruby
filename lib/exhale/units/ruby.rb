# frozen_string_literal: true

require "prism"
require_relative "../errors"
require_relative "depth"
require_relative "../unit"

module Exhale
  module Units
    # Finds the units in one Ruby file: methods, and the bodies of Rails DSL
    # calls (scopes, callbacks, validations, rescue_from, job hooks).
    module Ruby
      DSL = %i[
        scope default_scope validate validates_each
        before_validation after_validation
        before_save around_save after_save before_create around_create after_create
        before_update around_update after_update before_destroy around_destroy after_destroy
        after_commit after_create_commit after_update_commit after_destroy_commit after_save_commit after_rollback
        after_initialize after_find after_touch
        before_action after_action around_action prepend_before_action append_before_action
        prepend_after_action append_after_action rescue_from
        before_perform after_perform around_perform before_enqueue after_enqueue around_enqueue
      ].freeze

      # Concern blocks whose contents read as the class body itself.
      CLASS_BODIES = %i[included prepended concerning].freeze

      # Blocks that reopen their constant receiver as a class body.
      CLASS_EVALS = %i[class_eval class_exec module_eval module_exec].freeze

      # Block-defined methods, and whether each defines a singleton method.
      DEFINE_METHODS = { define_method: false, define_singleton_method: true }.freeze

      # A string naming a constant, as `rescue_from "Billing::Declined"` takes.
      CONSTANT_PATH = /\A(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*\z/

      module_function

      def extract(source, path)
        result = Prism.parse(source)
        # Counted before the syntax errors, so a deep file reads as too deep
        # whether or not it also has one.
        Depth.check!(result.value, path)
        if result.failure?
          error = result.errors.first
          raise ParseError.new(path, error.location.start_line, error.message)
        end

        Walker.new(path).walk(result.value)
      end

      # Walks a file keeping the namespace a statement sits in, and whether
      # it sits in a singleton body (`class << self`, `class_methods do`).
      class Walker
        def initialize(path)
          @path = path
          @units = []
          @ordinals = Hash.new(0)
        end

        def walk(program)
          visit(program, "Object", false)
          number_repeats
          @units
        end

        private

        def visit(node, namespace, singleton)
          case node
          when Prism::ModuleNode, Prism::ClassNode
            visit_body(node.body, nest(namespace, node.constant_path), false)
          when Prism::SingletonClassNode then singleton_class(node, namespace)
          when Prism::DefNode then add_method(node, namespace, singleton)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode then constant_write(node, namespace, singleton)
          when Prism::CallNode then call(node, namespace, singleton)
          else visit_children(node, namespace, singleton)
          end
        end

        def visit_body(body, namespace, singleton)
          visit(body, namespace, singleton) if body
        end

        def visit_children(node, namespace, singleton)
          node.compact_child_nodes.each { |child| visit(child, namespace, singleton) }
        end

        # `class << self` opens this namespace's singleton class, `class <<
        # Other` opens Other's. Any other object's isn't a namespace.
        def singleton_class(node, namespace)
          owner = owner_of(node.expression, namespace)
          visit_body(node.body, owner, true) if owner
        end

        # A def nested inside this one belongs to it, so the walk stops here.
        # `def obj.x` on a non-constant object belongs to no namespace.
        def add_method(node, namespace, singleton)
          return add(:method, node, namespace, node.name.to_s, singleton ? "." : "#") unless node.receiver

          owner = owner_of(node.receiver, namespace)
          add(:method, node, owner, node.name.to_s, ".") if owner
        end

        # `Point = Struct.new(:x) do ... end` and `Class.new do ... end`
        # define their methods on the constant.
        def constant_write(node, namespace, singleton)
          value = node.value
          if value.is_a?(Prism::CallNode) && value.block.is_a?(Prism::BlockNode)
            name = node.is_a?(Prism::ConstantWriteNode) ? join(namespace, node.name.to_s) : nest(namespace, node.target)
            visit_body(value.block.body, name, false)
          else
            visit_children(node, namespace, singleton)
          end
        end

        def call(node, namespace, singleton)
          block = node.block if node.block.is_a?(Prism::BlockNode)
          if block && DEFINE_METHODS.key?(node.name) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
            return define_method(node, block, namespace, singleton || DEFINE_METHODS[node.name])
          end
          return receiver_call(node, block, namespace, singleton) if node.receiver

          if CLASS_BODIES.include?(node.name) && block then visit_body(block.body, namespace, false)
          elsif node.name == :class_methods && block then visit_body(block.body, namespace, true)
          elsif DSL.include?(node.name) && (body = block || lambda_argument(node)) then add_dsl(node, body, namespace)
          else visit_children(node, namespace, singleton)
          end
        end

        # `Order.class_eval do ... end` reads as Order's class body.
        def receiver_call(node, block, namespace, singleton)
          if block && CLASS_EVALS.include?(node.name) && constant?(node.receiver)
            visit_body(block.body, resolve(namespace, node.receiver), false)
          else
            visit_children(node, namespace, singleton)
          end
        end

        def define_method(node, block, namespace, singleton)
          separator = singleton ? "." : "#"
          name = literal_name(node) || "#{node.name}[#{next_ordinal(namespace, node.name)}]"
          add(:method, block, namespace, name, separator)
        end

        def add_dsl(node, body, namespace)
          add(:dsl, body, namespace, dsl_name(node, namespace), ".")
        end

        # A body named by its first argument, a symbol or string (`scope
        # :settled`, `scope "settled"`) or constants (`rescue_from
        # Billing::Declined`), keeps its identity as the bodies around it
        # change. An unnamed body gets an ordinal, and ordinals drift: a new
        # `before_save do` above it renumbers it.
        def dsl_name(node, namespace)
          constants = Array(node.arguments&.arguments).take_while { |argument| constant_reference?(argument) }
          return "#{node.name}(#{constants.map { |c| constant_text(c) }.join(", ")})" if constants.any?

          name = literal_name(node)
          return "#{node.name}(:#{name})" if name

          "#{node.name}[#{next_ordinal(namespace, node.name)}]"
        end

        def constant_reference?(node)
          constant?(node) || (node.is_a?(Prism::StringNode) && node.unescaped.match?(CONSTANT_PATH))
        end

        def constant_text(node)
          node.is_a?(Prism::StringNode) ? node.unescaped.delete_prefix("::") : constant_name(node).last
        end

        # `scope :x, -> { ... }`, or the older `scope :x, lambda { ... }`.
        def lambda_argument(node)
          Array(node.arguments&.arguments).each do |argument|
            return argument if argument.is_a?(Prism::LambdaNode)
            return argument.block if lambda_call?(argument)
          end
          nil
        end

        def lambda_call?(node)
          node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[lambda proc].include?(node.name) &&
            node.block.is_a?(Prism::BlockNode)
        end

        def literal_name(node)
          first = node.arguments&.arguments&.first
          first.unescaped if first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
        end

        def next_ordinal(namespace, macro)
          @ordinals[[namespace, macro]] += 1
        end

        def add(kind, node, namespace, name, separator)
          @units << Unit.new(kind: kind, identity: "#{namespace}#{separator}#{name}", namespace: namespace,
                             name: name, path: @path, start_line: node.location.start_line,
                             end_line: last_line(node), language: :ruby, node: node)
        end

        # A name defined twice in one file (in both branches of an `if`, or in
        # a class reopened further down) still gets one identity per unit, in
        # source order: `Cart#total`, then `Cart#total[2]`.
        def number_repeats
          seen = Hash.new(0)
          @units.each do |unit|
            count = seen[unit.identity] += 1
            next if count == 1

            unit.identity = "#{unit.identity}[#{count}]"
            unit.name = "#{unit.name}[#{count}]"
          end
        end

        # A heredoc's body and terminator sit below the line its node ends on.
        def last_line(node)
          last = node.location.end_line
          stack = [node]
          until stack.empty?
            current = stack.pop
            last = [last, current.closing_loc.start_line].max if heredoc?(current)
            stack.concat(current.compact_child_nodes)
          end
          last
        end

        def heredoc?(node)
          node.respond_to?(:heredoc?) && node.heredoc? && node.closing_loc
        end

        # The namespace a `self` or constant receiver names; nil for any
        # other object.
        def owner_of(node, namespace)
          case node
          when Prism::SelfNode then namespace
          when Prism::ConstantReadNode, Prism::ConstantPathNode then resolve(namespace, node)
          end
        end

        def constant?(node)
          node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
        end

        # A definition (`class Foo`) nests inside the enclosing namespace.
        def nest(namespace, constant_path)
          anchor, name = constant_name(constant_path)
          anchor == :root ? name : join(namespace, name)
        end

        # A reference (`def Foo.x`, `class << Foo`, `Foo.class_eval`) names
        # an existing constant. Short of full constant lookup, it resolves to
        # an enclosing namespace when its first segment names one, so `def
        # Billing.x` inside `module Billing` is `Billing.x`, and otherwise
        # reads as written.
        def resolve(namespace, node)
          anchor, name = constant_name(node)
          return name if anchor == :root
          return join(namespace, name) if anchor == :self

          segments = namespace.split("::")
          index = segments.rindex(name.split("::").first)
          index ? (segments[0...index] + [name]).join("::") : name
        end

        def join(namespace, name)
          namespace == "Object" ? name : "#{namespace}::#{name}"
        end

        # [anchor, "Foo::Bar"]. anchor is :root for a leading `::`, :self for
        # a leading `self::` (the current namespace), and nil otherwise.
        def constant_name(node)
          case node
          when Prism::ConstantReadNode then [nil, node.name.to_s]
          when Prism::ConstantPathNode
            return [:root, node.name.to_s] if node.parent.nil?
            return [:self, node.name.to_s] if node.parent.is_a?(Prism::SelfNode)

            anchor, parent = constant_name(node.parent)
            [anchor, "#{parent}::#{node.name}"]
          else [nil, node.slice]
          end
        end
      end
    end
  end
end
