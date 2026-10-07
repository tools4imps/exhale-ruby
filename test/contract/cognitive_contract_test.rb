# frozen_string_literal: true

require "test_helper"
require "exhale/units"
require "exhale/complexity/cognitive"

# The Cognitive score's obligations, contract/cognitive/README.md. Every
# expected score was worked out by hand from the rules; the comment beside a
# snippet shows the arithmetic.
class CognitiveContractTest < Minitest::Test
  def units(source)
    Exhale::Units::Ruby.extract(source, "app/models/x.rb")
  end

  def points_of(source, identity)
    unit = units(source).find { |u| u.identity == identity } or flunk "no unit #{identity} in:\n#{source}"
    Exhale::Complexity::Cognitive.points(unit)
  end

  def score_of(source, identity)
    points_of(source, identity).sum(&:increment)
  end

  # body becomes the body of `def m(a, b, c, d, xs)`.
  def method_score(body)
    score_of("def m(a, b, c, d, xs)\n#{body}\nend\n", "Object#m")
  end

  def assert_table(table)
    table.each do |body, expected|
      assert_equal expected, method_score(body), "expected #{expected} for:\n#{body}"
    end
  end

  # Contract: cognitive/K1
  def test_branches_and_loops_add_one_plus_nesting
    assert_table [
      ["if a\n  b\nend", 1],
      ["b if a", 1],
      ["unless a\n  b\nend", 1],
      ["b unless a", 1],
      ["a ? b : c", 1],
      ["while a\n  b\nend", 1],
      ["b while a", 1],
      ["until a\n  b\nend", 1],
      ["b until a", 1],
      ["begin\n  b\nend while a", 1],
      ["for x in xs\n  b\nend", 1],
      ["x rescue nil", 1],
      # 1 for the if, 2 for the if inside it
      ["if a\n  if b\n    c\n  end\nend", 3],
      # 1 for the while, 2 for the until, 3 for the ternary
      ["while a\n  until b\n    c ? d : a\n  end\nend", 6]
    ]
  end

  # Contract: cognitive/K1
  def test_a_whole_case_adds_one_however_many_branches
    assert_table [
      ["case a\nwhen 1 then b\nwhen 2 then c\nwhen 3 then d\nelse xs\nend", 1],
      ["case a\nin [x] then b\nin {y:} then c\nin Integer | Float then d\nelse xs\nend", 1],
      ["case\nwhen a then b\nend", 1],
      # 1 for the if, 2 for the case inside it; the case's else adds nothing
      ["if a\n  case b\n  when 1 then c\n  else d\n  end\nend", 3]
    ]
  end

  # Contract: cognitive/K1
  def test_each_rescue_clause_adds_one_plus_nesting
    assert_table [
      ["begin\n  b\nrescue ArgumentError\n  c\nend", 1],
      ["begin\n  b\nrescue ArgumentError\n  c\nrescue TypeError, KeyError => e\n  d\nend", 2],
      # the else of a begin/rescue and its ensure add nothing
      ["begin\n  b\nrescue ArgumentError\n  c\nelse\n  d\nensure\n  xs\nend", 1],
      # 1 for the each block, 2 for the rescue inside it
      ["xs.each do |x|\n  x.call\nrescue StandardError\n  nil\nend", 3],
      # 1 for the if, 2 for the inline rescue inside it
      ["if a\n  b.call rescue nil\nend", 3]
    ]
    assert_equal 2, score_of("def m\n  a\nrescue A\n  b\nrescue B\n  c\nend\n", "Object#m")
  end

  # Contract: cognitive/K1
  def test_elsif_and_else_add_one_with_no_nesting_cost
    assert_table [
      ["if a\n  b\nelse\n  c\nend", 2],
      ["if a\n  b\nelsif c\n  d\nend", 2],
      ["if a\n  b\nelsif c\n  d\nelsif xs\n  a\nelse\n  b\nend", 4],
      ["unless a\n  b\nelse\n  c\nend", 2],
      # 1 for the each block, then 2 for the if inside it, and 1 each for
      # its elsif and else however deep they sit
      ["xs.each do |x|\n  if a\n    1\n  elsif b\n    2\n  else\n    3\n  end\nend", 5],
      # a ternary's else is part of the ternary
      ["a ? b : c", 1]
    ]
  end

  # Contract: cognitive/K2
  def test_nesting_rises_inside_charged_bodies_and_blocks
    assert_table [
      # a block that doesn't iterate adds nothing but nests: 2 for the if
      ["transaction do\n  b if a\nend", 2],
      # a lambda nests the same way: 2 for the ternary
      ["handler = -> { a ? b : c }", 2],
      ["handler = lambda { |x| x ? b : c }", 2],
      # 1 for the while, 2 for the if in its body
      ["while a\n  b if c\nend", 3],
      # 1 for the case, 2 for the ternary inside a branch
      ["case a\nwhen 1 then b ? c : d\nend", 3],
      # 1 for the rescue, 2 for the if inside it
      ["begin\n  b\nrescue StandardError\n  c if d\nend", 3],
      # the rescue's else and ensure aren't charged, so they don't nest
      ["begin\n  b\nrescue StandardError\n  c\nelse\n  d if a\nend", 2],
      ["begin\n  b\nensure\n  d if a\nend", 1],
      # a condition sits at its construct's level, not inside it
      ["if a ? b : c\n  d\nend", 2],
      ["while a ? b : c\n  d\nend", 2],
      ["case a ? b : c\nwhen 1 then d\nend", 2],
      # when and in branches sit inside their case: 1 for the case, 2 each
      # for the ternaries in a when's condition and in an in's body
      ["case a\nwhen (b ? 1 : 2) then c\nend", 3],
      ["case a\nin Integer then b ? c : d\nend", 3],
      # 1 for the if, 2 for the each inside it, 3 for the unless in the block
      ["if a\n  xs.each do |x|\n    next unless x\n  end\nend", 6]
    ]
  end

  # Contract: cognitive/K2
  def test_a_unit_starts_at_nesting_zero_and_a_dsl_block_is_its_body
    source = <<~RUBY
      class Order < ApplicationRecord
        scope :open, -> { status ? where(open: true) : all }
        before_save do
          self.total = 0 if lines.empty?
        end
        validate do
          errors.add(:base, "empty") unless lines.any?
        end
        define_method(:label) { name ? name.upcase : "?" }
      end
    RUBY
    assert_equal 1, score_of(source, "Order.scope(:open)")
    assert_equal 1, score_of(source, "Order.before_save[1]")
    assert_equal 1, score_of(source, "Order.validate[1]")
    assert_equal 1, score_of(source, "Order#label")
    assert(points_of(source, "Order.scope(:open)").all? { |p| p.nesting.zero? })
  end

  # Contract: cognitive/K3
  def test_each_run_of_like_boolean_operators_adds_one
    assert_table [
      ["a && b && c", 1],
      ["a && b || c", 2],
      ["a || b || c", 1],
      ["a and b and c", 1],
      ["a && b and c", 1],
      ["a || b or c", 1],
      ["a || b && c || d", 3],
      ["a && !b && c", 1],
      ["a && !(b && c)", 1],
      ["a && (b && c)", 1],
      ["a && (b || c)", 2],
      ["a && not(b && c)", 1],
      # two expressions are two runs
      ["x = a && b\ny = c && d", 2],
      # an argument is an expression of its own
      ["a && foo(b && c)", 2],
      # 1 for the if, 1 for its condition's run
      ["if a && b && c\n  d\nend", 2]
    ]
  end

  # Contract: cognitive/K3
  def test_safe_navigation_assignment_operators_and_jumps_add_nothing
    assert_table [
      ["a&.b&.c", 0],
      ["@total ||= compute(a)", 0],
      ["@total &&= @total.round", 0],
      ["a ||= b\nc &&= d", 0],
      ["@cache ||= {}\n@cache[a] ||= xs.sum", 0],
      ["return a", 0],
      ["xs.each do |x|\n  next\nend", 1],
      ["loop do\n  break\nend", 1],
      # a guard clause is an if
      ["return if a.nil?\nreturn unless b\nraise ArgumentError if c\nd", 3],
      # memoizing a branch still pays for the branch
      ["@x ||= begin\n  a ? b : c\nend", 1]
    ]
  end

  # Contract: cognitive/K4
  def test_recursion_adds_one_once_per_unit
    assert_equal 2, score_of("def fact(n)\n  n <= 1 ? 1 : n * fact(n - 1)\nend\n", "Object#fact")
    assert_equal 1, score_of("def fib(n)\n  fib(n - 1) + fib(n - 2)\nend\n", "Object#fib")
    assert_equal 1, score_of("def walk(n)\n  self.walk(n.next)\nend\n", "Object#walk")
    assert_equal 0, score_of("def walk(n)\n  other.walk(n)\nend\n", "Object#walk")
    assert_equal 0, score_of("def walk(n)\n  walker(n)\nend\n", "Object#walk")
    assert_equal 1, score_of("class Tree\n  def self.depth(n)\n    depth(n.left)\n  end\nend\n", "Tree.depth")
    assert_equal 1, score_of("class Tree\n  define_method(:size) { |n| size(n.left) }\nend\n", "Tree#size")
    # A repeat of an identity in the file still recurses on its own name.
    assert_equal 1, score_of("def x = 1\ndef x(n)\n  x(n)\nend\n", "Object#x[2]")
    points = points_of("def fib(n)\n  if n < 2\n    n\n  else\n    fib(n - 1)\n  end\nend\n", "Object#fib")
    recursion = points.find { |p| p.construct == "recursion" }
    assert_equal [5, 1, 1], [recursion.line, recursion.increment, recursion.nesting]
  end

  # Contract: cognitive/K5
  def test_listed_iterators_make_a_block_iterate
    names = %w[each each_with_object each_with_index each_slice each_pair map flat_map collect filter_map select
               filter reject find detect find_index find_all any? all? none? one? count sum inject reduce group_by
               partition sort_by min_by max_by minmax_by uniq zip take_while drop_while chunk_while slice_when
               times upto downto step loop cycle with_index with_object map! collect! select! filter! reject!
               sort_by!]
    names.each do |name|
      assert_equal 1, method_score("xs.#{name} { |x| x }"), "#{name} iterates"
      assert_equal 1, method_score("xs.#{name} do |x|\n  x\nend"), "#{name} do-block iterates"
    end
  end

  # Contract: cognitive/K5
  def test_other_blocks_and_block_arguments_dont_iterate
    assert_table [
      ["xs.tap { |x| x }", 0],
      ["xs.then { |x| x }", 0],
      ["xs.sort { |a, b| a <=> b }", 0],
      ["xs.sort! { |a, b| a <=> b }", 0],
      ["Struct.new(:a) { def b = 1 }", 0],
      ["xs.map(&:to_s)", 0],
      ["xs.each(&method(:puts))", 0],
      ["xs.select(&block)", 0],
      # the block goes to with_index, which iterates; each alone has none
      ["xs.each.with_index { |x, i| x }", 1],
      ["xs.map.with_object([]) { |x, memo| memo << x }", 1],
      # 1 for the outer each, 2 for the map inside it
      ["xs.each { |x| x.map { |y| y } }", 3],
      ["5.times { a }\nloop { break }", 2]
    ]
  end

  # Contract: cognitive/K6
  def test_metaprogramming_calls_add_one_and_are_reported_apart
    names = %w[eval instance_eval class_eval module_eval instance_exec class_exec module_exec define_method
               define_singleton_method send __send__ public_send instance_variable_get instance_variable_set const_get]
    names.each do |name|
      points = points_of("def m(obj)\n  obj.#{name}(:x)\nend\n", "Object#m")
      assert_equal [[name, 1, true]], points.map { |p| [p.construct, p.increment, p.meta] }, name
    end
    # no nesting cost: 1 for the each, 2 for the if, 1 for send at nesting 2
    points = points_of("def m(xs)\n  xs.each do |x|\n    x.send(:y) if x\n  end\nend\n", "Object#m")
    assert_equal 4, points.sum(&:increment)
    assert_equal 1, points.count(&:meta)
    send = points.find(&:meta)
    assert_equal [1, 2], [send.increment, send.nesting]
  end

  # Contract: cognitive/K6
  def test_defining_method_missing_adds_a_metaprogramming_point
    source = <<~RUBY
      class Proxy
        def method_missing(name, *args)
          target.respond_to?(name) ? target.public_send(name, *args) : super
        end
      end
    RUBY
    points = points_of(source, "Proxy#method_missing")
    # 1 for defining method_missing, 1 for the ternary, 1 for public_send
    assert_equal 3, points.sum(&:increment)
    assert_equal %w[method_missing public_send], points.select(&:meta).map(&:construct)
  end

  # Contract: cognitive/K7
  def test_points_carry_line_construct_and_nesting_and_sum_to_the_score
    source = <<~RUBY
      def m(xs)
        xs.each do |x|
          if x.ok? && x.ready?
            x.go
          end
        end
      end
    RUBY
    points = points_of(source, "Object#m")
    assert_equal [[2, "each block", 0, 1], [3, "if", 1, 2], [3, "&&", 1, 1]],
                 points.map { |p| [p.line, p.construct, p.nesting, p.increment] }
    assert_equal 4, score_of(source, "Object#m")
  end

  # Contract: cognitive/K7
  def test_the_score_depends_only_on_the_units_source
    method = "  def m(a)\n    a ? 1 : 2\n  end\n"
    here = Exhale::Units::Ruby.extract("class A\n#{method}end\n", "app/a.rb").first
    there = Exhale::Units::Ruby.extract("# moved\n\nmodule B\n  class C\n#{method}  end\nend\n", "lib/b.rb").first
    first = Exhale::Complexity::Cognitive.points(here)
    assert_equal first, Exhale::Complexity::Cognitive.points(here)
    assert_equal(first.map { |p| [p.construct, p.increment, p.nesting] },
                 Exhale::Complexity::Cognitive.points(there).map { |p| [p.construct, p.increment, p.nesting] })
  end

  # Contract: cognitive/K8
  def test_nested_defs_and_units_score_on_their_own
    source = <<~RUBY
      class Builder
        def build(a)
          def helper(b)
            b ? 1 : 2
          end
          define_method(:dyn) { |c| c ? 1 : 2 }
          class << self
            def other(d) = d ? 1 : 2
          end
          a ? 1 : 2
        end
      end
    RUBY
    # 1 for its own ternary and 1 for calling define_method; the nested
    # def, define_method block and singleton class's def are left out.
    assert_equal 2, score_of(source, "Builder#build")
  end

  # Contract: cognitive/K8
  def test_methods_and_dsl_units_are_scored_and_templates_arent
    template = Exhale::Unit.new(kind: :template, identity: "views/a.html.erb", path: "app/views/a.html.erb",
                                start_line: 1, end_line: 1, language: :erb)
    assert_raises(ArgumentError) { Exhale::Complexity::Cognitive.points(template) }
    source = "class A\n  scope :x, -> { a ? 1 : 2 }\n  def y = b ? 1 : 2\nend\n"
    assert_equal({ "A.scope(:x)" => 1, "A#y" => 1 },
                 units(source).to_h { |u| [u.identity, Exhale::Complexity::Cognitive.points(u).sum(&:increment)] })
  end
end
