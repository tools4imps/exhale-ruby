# frozen_string_literal: true

require "test_helper"
require "clauses/clauses_helper"

# complexity.md: ceilings and the floor, read only by the complexity check.
class ComplexityClausesTest < ContractTestCase
  def complexity_contract
    Exhale::Contract.load(@root, check: :complexity)
  end

  def where(errors)
    errors.map { |e| "#{e.path}:#{e.line}" }
  end

  # Contract: clause/C1
  def test_complexity_md_holds_ceilings_and_the_floor
    write "contract/p/complexity.md", <<~MD
      # P

      ```settings
      floor: 10
      ```

      ## The parser stays one method

      Splitting the state machine scatters its transitions.

      ```ceiling
      max: 14  # measured 12
      Parser#step
      Parser::Lexer  # the whole lexer
      ```
    MD
    c = complexity_contract
    assert_empty c.errors
    assert_equal({ "p" => { floor: 10 } }, c.settings)
    clause = c.clauses.first
    assert_equal [:ceiling, 14, 11], [clause.kind, clause.max, clause.line]
    assert_equal ["Parser#step", "Parser::Lexer"], clause.references.map(&:text)
    assert_equal "The parser stays one method Splitting the state machine scatters its transitions.", clause.reason
  end

  # Contract: clause/C1
  def test_each_check_reads_only_its_own_file
    write "contract/p/duplication.md", "```settings\nthreshold: 0.9\n```\n```parallel\nA\nB\n```\n"
    write "contract/p/complexity.md", "```settings\nfloor: 3\n```\n```ceiling\nmax: 9\nA#x\n```\n"
    dry = load_contract
    assert_empty dry.errors
    assert_equal({ "p" => { threshold: 0.9 } }, dry.settings)
    assert_equal [:parallel], dry.clauses.map(&:kind)

    complexity = complexity_contract
    assert_empty complexity.errors
    assert_equal({ "p" => { floor: 3 } }, complexity.settings)
    assert_equal [:ceiling], complexity.clauses.map(&:kind)
  end

  # Contract: clause/C1
  def test_a_block_type_in_the_other_checks_file_is_an_error
    write "contract/p/duplication.md", "```ceiling\nmax: 9\nA#x\n```\n```settings\nfloor: 3\n```\n"
    write "contract/p/complexity.md", "```parallel\nA\nB\n```\n```settings\nthreshold: 0.5\n```\n"
    dry = load_contract
    assert_equal ["contract/p/duplication.md:1", "contract/p/duplication.md:6"], where(dry.errors)
    assert_match(/belongs in complexity.md/, dry.errors[0].message)
    assert_match(/unknown setting: floor/, dry.errors[1].message)

    complexity = complexity_contract
    assert_equal ["contract/p/complexity.md:1", "contract/p/complexity.md:6"], where(complexity.errors)
    assert_match(/belongs in duplication.md/, complexity.errors[0].message)
    assert_match(/unknown setting: threshold/, complexity.errors[1].message)
    assert_empty complexity.clauses
  end

  # Contract: clause/C1
  def test_ceilings_in_the_wrong_file_are_errors
    write "contract/p/README.md", "```ceiling\nmax: 9\nA#x\n```\n"
    write "contract/p/notes.md", "```ceiling\nmax: 9\nA#x\n```\n"
    write "contract/notes.md", "```ceiling\nmax: 9\nA#x\n```\n"
    write "contract/p/complexity.md", "```covers\nA\n```\n"
    errors = complexity_contract.errors
    assert_equal ["contract/notes.md:1", "contract/p/README.md:1", "contract/p/complexity.md:1",
                  "contract/p/notes.md:1"], where(errors).sort
    assert_match(/belongs in complexity.md/, errors.find { |e| e.path.end_with?("README.md") }.message)
    assert_match(/belongs in README.md/, errors.find { |e| e.path.end_with?("complexity.md") }.message)
    assert_equal 3, load_contract.errors.size
  end

  # Contract: clause/C1
  def test_a_ceiling_needs_one_valid_max_and_a_unit
    write "contract/a/complexity.md", "```ceiling\nA#x\n```\n"
    write "contract/b/complexity.md", "```ceiling\nmax: 3\nmax: 4\nA#x\n```\n"
    write "contract/c/complexity.md", "```ceiling\nmax: lots\nA#x\n```\n"
    write "contract/d/complexity.md", "```ceiling\nmax: 3\n# nothing\n```\n"
    write "contract/e/complexity.md", "```ceiling\nmax: -1\nA#x\n```\n"
    c = complexity_contract
    assert_empty c.clauses
    assert_equal ["contract/a/complexity.md:1", "contract/b/complexity.md:3", "contract/c/complexity.md:2",
                  "contract/d/complexity.md:1", "contract/e/complexity.md:2"], where(c.errors)
    assert_equal ["ceiling block needs max: N", "repeated max in a ceiling block", 'bad value for max: "lots"',
                  "ceiling block names no unit", 'bad value for max: "-1"'],
                 c.errors.map { |e| e.message.split(": ", 2).last }
  end

  # Contract: clause/C1
  def test_other_fenced_blocks_in_complexity_md_are_prose
    write "contract/p/complexity.md", "```ruby\ndef x = 1\n```\n```ceiling\nmax: 0\nA#x\n```\n"
    c = complexity_contract
    assert_empty c.errors
    assert_equal [0], c.clauses.map(&:max)
  end

  # Contract: clause/C5
  def test_the_floor_is_a_whole_number_set_once
    write "contract/a/complexity.md", "```settings\nfloor: 0\n```\n"
    write "contract/b/complexity.md", "```settings\nfloor: -1\n```\n"
    write "contract/c/complexity.md", "```settings\nfloor: 2\nfloor: 3\n```\n"
    write "contract/d/complexity.md", "```settings\nfloor: 2\n```\n```settings\nfloor: 3\n```\n"
    c = complexity_contract
    assert_equal({ floor: 0 }, c.settings["a"])
    assert_equal ["contract/b/complexity.md:2", "contract/c/complexity.md:3", "contract/d/complexity.md:4"],
                 where(c.errors)
  end

  def test_an_unknown_check_is_refused
    assert_raises(ArgumentError) { Exhale::Contract.load(@root, check: :crap) }
  end
end
