# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "exhale/units"
require "exhale/complexity/check"

class RatchetTest < Minitest::Test
  def scored(source, path)
    Exhale::Units::Ruby.extract(source, path).map { |u| Exhale::Complexity::Scored.of(u) }
  end

  def method(name, score)
    "  def #{name}(a)\n#{(1..score).map { |k| "    s#{k}(a) if a.r#{k}?\n" }.join}  end\n"
  end

  def ratchet(head, base, floor: 8, ceiling: nil)
    Exhale::Complexity::Ratchet.new(head: head, base: base, floor_for: ->(_) { floor }, ceiling_for: ->(_) { ceiling })
  end

  # A class reopened in two files repeats an identity across them; each
  # head unit pairs with the base unit in its own file.
  # Contract: ratchet/T2
  def test_a_repeated_identity_pairs_within_its_file_first
    base = scored("class A\n#{method('x', 2)}end\n", "a.rb") + scored("class A\n#{method('x', 5)}end\n", "b.rb")
    head = scored("class A\n#{method('x', 9)}end\n", "b.rb") + scored("class A\n#{method('x', 2)}end\n", "c.rb")
    rows = ratchet(head, base).rows
    assert_equal [["b.rb", "b.rb", :raised], ["c.rb", "a.rb", :unchanged]],
                 rows.map { |r| [r.head.unit.path, r.base.unit.path, r.label] }
  end

  # Contract: ratchet/T2
  def test_once_a_base_unit_pairs_in_its_own_file_it_isnt_offered_again
    base = scored("class A\n#{method('x', 2)}end\n", "a.rb") + scored("class A\n#{method('x', 5)}end\n", "b.rb")
    head = scored("class A\n#{method('x', 2)}end\n", "a.rb") + scored("class A\n#{method('x', 5)}end\n", "c.rb")
    assert_equal [%w[a.rb a.rb], %w[c.rb b.rb]], ratchet(head, base).rows.map { |r| [r.head.unit.path, r.base.unit.path] }
  end

  # Contract: ratchet/T6
  def test_a_kept_unit_that_ends_at_the_floor_only_rose
    base = scored("class A\n#{method('f', 5)}end\n", "a.rb")
    ceiling = Exhale::Contract::Clause.new("p", :ceiling, "contract/p/complexity.md", 1, "", "", [], "k", 14)
    assert_equal [:rose], ratchet(scored("class A\n#{method('f', 8)}end\n", "a.rb"), base, ceiling: ceiling).rows.map(&:label)
    assert_equal [:kept], ratchet(scored("class A\n#{method('f', 9)}end\n", "a.rb"), base, ceiling: ceiling).rows.map(&:label)
  end

  # The size prefilter only skips pairs Jaccard can't bring to 0.80, and a
  # pair at exactly 0.80 matches.
  # Contract: ratchet/T2
  def test_the_threshold_is_inclusive_and_the_size_prefilter_exact
    r = ratchet([], [])
    assert r.send(:close?, 4, 5)
    assert r.send(:close?, 5, 4)
    refute r.send(:close?, 4, 6)
    entry = Struct.new(:set, :total)
    index = Object.new
    def index.score(*) = Rational(4, 5)
    assert_equal Rational(4, 5), r.send(:similarity, index, entry.new([], 5), entry.new([], 5))
    def index.score(*) = Rational(79, 100)
    assert_nil r.send(:similarity, index, entry.new([], 5), entry.new([], 5))
  end

  def test_with_no_base_units_warn_over_their_limit_and_a_ceiling_keeps_them
    head = scored("class A\n#{method('x', 9)}#{method('y', 3)}end\n", "a.rb")
    assert_equal %i[warning scored], ratchet(head, nil).rows.map(&:label)
    ceiling = Exhale::Contract::Clause.new("p", :ceiling, "contract/p/complexity.md", 1, "", "", [], "k", 10)
    assert_equal %i[kept scored], ratchet(head, nil, ceiling: ceiling).rows.map(&:label)
  end

  # Contract: ratchet/T6
  def test_a_ceiling_under_the_floor_never_tightens_it
    base = scored("class A\n#{method('f', 1)}end\n", "a.rb")
    head = scored("class A\n#{method('f', 3)}end\n", "a.rb")
    ceiling = Exhale::Contract::Clause.new("p", :ceiling, "contract/p/complexity.md", 1, "", "", [], "k", 2)
    assert_equal [:rose], ratchet(head, base, ceiling: ceiling).rows.map(&:label)
    head = scored("class A\n#{method('f', 9)}end\n", "a.rb")
    assert_equal [:raised], ratchet(head, base, ceiling: ceiling).rows.map(&:label)
  end

  # Contract: ratchet/T6
  def test_the_most_specific_ceiling_wins_and_a_tie_takes_the_lower_max
    Dir.mktmpdir("exhale-ceilings") do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "contract", "p"))
      File.write(File.join(dir, "app/models/a.rb"), "class A\n#{method('x', 12)}#{method('y', 12)}end\n")
      File.write(File.join(dir, "contract/p/complexity.md"), <<~MD)
        ```ceiling
        max: 20
        A
        ```

        ```ceiling
        max: 13
        A#x
        ```

        ```ceiling
        max: 11
        A#x
        ```
      MD
      result = Exhale::Complexity::Check.new(root: dir).run
      rows = result.rows.to_h { |r| [r.unit.identity, [r.label, r.ceiling.max]] }
      assert_equal({ "A#x" => [:warning, 11], "A#y" => [:kept, 20] }, rows)
    end
  end
end
