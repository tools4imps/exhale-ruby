# frozen_string_literal: true

require_relative "cognitive"
require_relative "../dry/normalizer"
require_relative "../dry/fingerprints"
require_relative "../dry/index"

module Exhale
  module Complexity
    # A unit and the points it scored, at the head or at the base.
    Scored = Struct.new(:unit, :points) do
      def self.of(unit)
        new(unit, Cognitive.points(unit))
      end

      def score
        points.sum(&:increment)
      end

      def meta
        points.count(&:meta)
      end
    end

    # One unit's verdict.
    #
    # label      - :raised and :introduced fail. :kept rose past the floor
    #              within a ceiling. :rose, :new, :unchanged, :contracted and
    #              :gone pass. With no base, :warning is over the floor and
    #              :scored isn't.
    # head, base - Scored, or nil on the side the unit is missing from.
    # match      - :identity or :shape when both sides are there.
    # similarity - The shape score of a :shape match.
    # floor      - The floor the unit was judged against.
    # ceiling    - The Contract clause that keeps it, or nil.
    Row = Struct.new(:label, :head, :base, :match, :similarity, :floor, :ceiling, keyword_init: true) do
      def failing?
        Ratchet::FAILING.include?(label)
      end

      def unit
        (head || base).unit
      end
    end

    # Judges each head unit against its base unit. Only a rise can fail, so
    # code is never punished for what it already was.
    class Ratchet
      FAILING = %i[raised introduced].freeze
      SIMILARITY = Rational(80, 100)
      # A unit that rose, a new unit, and a unit with no base to compare
      # against: its label over its limit, and at or under it.
      OUTCOMES = { rose: %i[raised rose], new: %i[introduced new], alone: %i[warning scored] }.freeze

      # head and base are Scored lists in path and line order; base is nil
      # when there's nothing to compare against. floor_for and ceiling_for
      # take a unit.
      def initialize(head:, base:, floor_for:, ceiling_for:)
        @head = head
        @base = base
        @floor_for = floor_for
        @ceiling_for = ceiling_for
      end

      def rows
        return @head.map { |scored| judge(scored) } unless @base

        pairs = match
        taken = taken(pairs)
        @head.map { |scored| judge(scored, *pairs[scored]) } +
          @base.reject { |base| taken[base] }.map { |base| Row.new(label: :gone, base: base) }
      end

      private

      def judge(head, base = nil, match = nil, similarity = nil)
        floor = @floor_for.call(head.unit)
        ceiling = @ceiling_for.call(head.unit)
        Row.new(label: label(head.score, base&.score, floor, ceiling), head: head, base: base, match: match,
                similarity: similarity, floor: floor, ceiling: ceiling)
      end

      # A ceiling stands in for the floor as the line a rise can't cross.
      def label(score, base_score, floor, ceiling)
        return :contracted if base_score && score < base_score
        return :unchanged if score == base_score

        over, under = OUTCOMES.fetch(situation(base_score))
        return over if score > (ceiling ? ceiling.max : floor)

        ceiling && score > floor ? :kept : under
      end

      def situation(base_score)
        return :alone unless @base

        base_score ? :rose : :new
      end

      # {head => [base, how, similarity]}: identity first, then shape.
      def match
        pairs = identity_pairs
        taken = taken(pairs)
        shape_matches(@head.reject { |h| pairs.key?(h) }, @base.reject { |b| taken[b] }).each do |head, base, score|
          pairs[head] = [base, :shape, score]
        end
        pairs
      end

      def taken(pairs)
        pairs.each_value.with_object({}.compare_by_identity) { |(base, *), taken| taken[base] = true }
      end

      def identity_pairs
        pairs = {}.compare_by_identity
        bases = @base.group_by { |scored| scored.unit.identity }
        @head.group_by { |scored| scored.unit.identity }.each do |identity, heads|
          pair_up(heads, bases.fetch(identity, [])).each { |head, base| pairs[head] = [base, :identity, nil] }
        end
        pairs
      end

      # An identity is unique within a file, so a unit pairs with the one in
      # its own file first; the rest pair in path and line order.
      def pair_up(heads, bases)
        same = heads.filter_map { |head| (base = bases.find { |b| b.unit.path == head.unit.path }) && [head, base] }
        rest = (heads - same.map(&:first)).zip(bases - same.map(&:last))
        same + rest.select(&:last)
      end

      # Every pair at or over the threshold, best first; ties go to the base
      # unit first in path and line order. Each side matches at most once.
      def shape_matches(heads, bases)
        return [] if heads.empty? || bases.empty?

        entries = entries(heads + bases)
        index = Dry::Index.new(entries)
        greedy(candidates(index, entries.first(heads.size), entries.drop(heads.size)), heads, bases)
      end

      def entries(scored)
        scored.each_with_index.map do |each, id|
          tree = Dry::Fingerprints.build(Dry::Normalizer.normalize(each.unit))
          Dry::Entry.new(id: id, unit: each.unit, tree: tree, set: tree.digests)
        end
      end

      # [[score, base index, head index]] for every pair at the threshold.
      def candidates(index, heads, bases)
        heads.each_with_index.flat_map do |h, hi|
          bases.each_with_index.filter_map { |b, bi| (score = similarity(index, h, b)) && [score, bi, hi] }
        end
      end

      def similarity(index, a, b)
        return unless close?(a.total, b.total)

        score = index.score(a.set, a.total, b.set, b.total)
        score if score >= SIMILARITY
      end

      def greedy(candidates, heads, bases)
        used_heads = {}
        used_bases = {}
        candidates.sort_by { |score, bi, hi| [-score, bi, hi] }.filter_map do |score, bi, hi|
          next if used_heads[hi] || used_bases[bi]

          used_heads[hi] = used_bases[bi] = true
          [heads[hi], bases[bi], score]
        end
      end

      # Jaccard can't reach the threshold when one side outweighs the other
      # by more than its inverse, so those pairs aren't scored.
      def close?(a, b)
        small, large = [a, b].minmax
        small * SIMILARITY.denominator >= large * SIMILARITY.numerator
      end
    end
  end
end
