# frozen_string_literal: true

require "test_helper"
require "exhale/units"
require "exhale/complexity/cognitive"

# Whole methods scored by hand: the examples from Campbell's white paper
# translated to Ruby, and the shapes a Rails app is full of.
class CognitiveTest < Minitest::Test
  def score(source, identity)
    unit = Exhale::Units::Ruby.extract(source, "app/x.rb").find { |u| u.identity == identity }
    Exhale::Complexity::Cognitive.points(unit).sum(&:increment)
  end

  # Campbell's getWords: a switch is one decision however many cases it has.
  def test_get_words
    source = <<~RUBY
      def get_words(number)
        case number          # +1
        when 1 then "one"
        when 2 then "a couple"
        when 3 then "a few"
        else "lots"
        end
      end
    RUBY
    assert_equal 1, score(source, "Object#get_words")
  end

  # Campbell's sumOfPrimes scores 7 in Java: two loops, an if, and a
  # labeled continue. Ruby has no labeled continue, so the inner loop
  # becomes an any? block and the continue a guard clause.
  def test_sum_of_primes
    source = <<~RUBY
      def sum_of_primes(max)
        total = 0
        (1..max).each do |i|                         # +1
          next if (2...i).any? { |j| (i % j).zero? } # +2 for the if, +2 for any?
          total += i
        end
        total
      end
    RUBY
    assert_equal 5, score(source, "Object#sum_of_primes")
  end

  # The same method as nested for loops with a flag.
  def test_sum_of_primes_with_loops
    source = <<~RUBY
      def sum_of_primes(max)
        total = 0
        for i in 1..max          # +1
          prime = true
          for j in 2...i         # +2
            if (i % j).zero?     # +3
              prime = false
              break
            end
          end
          total += i if prime    # +2
        end
        total
      end
    RUBY
    assert_equal 8, score(source, "Object#sum_of_primes")
  end

  # Campbell's overriddenSymbolFrom, the white paper's worked example: 19.
  def test_overridden_symbol_from
    source = <<~RUBY
      def overridden_symbol_from(class_type)
        if class_type.unknown?                                        # +1
          return Symbols.unknown_method_symbol
        end
        unknown_found = false
        symbols = class_type.symbol.members.lookup(name)
        symbols.each do |override_symbol|                             # +1
          if override_symbol.kind?(JavaSymbol::MTH) && !override_symbol.static? # +2, +1
            method_symbol = override_symbol
            if can_override?(method_symbol)                           # +3
              overriding = check_overriding_parameters(method_symbol, class_type)
              if overriding.nil?                                      # +4
                unless unknown_found                                  # +5
                  unknown_found = true
                end
              elsif overriding                                        # +1
                return method_symbol
              end
            end
          end
        end
        if unknown_found                                              # +1
          return Symbols.unknown_method_symbol
        end
        nil
      end
    RUBY
    assert_equal 19, score(source, "Object#overridden_symbol_from")
  end

  def test_rails_controller_and_model_units
    source = <<~RUBY
      class OrdersController < ApplicationController
        before_action :authenticate!
        before_action(only: :show) { redirect_to root_path unless current_user.admin? } # +1
        rescue_from ActiveRecord::RecordNotFound do |error|
          case error.model         # +1
          when "Order" then head :not_found
          else raise error
          end
        end

        def index
          @orders = Order.where(user: current_user)
          @orders = @orders.where(status: params[:status]) if params[:status].present? # +1
          respond_to do |format|
            format.html
            format.json { render json: @orders }
          end
        end
      end

      class Order < ApplicationRecord
        scope :recent, ->(days = 7) { where(created_at: days.days.ago..) }
        scope :visible, -> { admin? ? all : where(hidden: false) }                  # +1
        validate do
          errors.add(:total, "negative") if total&.negative? && !refunded?          # +1, +1
        end

        def total
          @total ||= lines.sum { |line| line.price * line.quantity }               # +1
        end
      end
    RUBY
    expected = {
      "OrdersController.before_action[1]" => 1, "OrdersController.rescue_from(ActiveRecord::RecordNotFound)" => 1,
      "OrdersController#index" => 1, "Order.scope(:recent)" => 0, "Order.scope(:visible)" => 1,
      "Order.validate[1]" => 2, "Order#total" => 1
    }
    expected.each { |identity, value| assert_equal value, score(source, identity), identity }
  end

  def test_pattern_matching
    source = <<~RUBY
      def handle(event)
        case event                                # +1
        in { type: "paid", amount: Integer => amount } then credit(amount)
        in { type: "refund", amount: } if amount.positive? then debit(amount) # +2: a guard is a modifier if
        in [first, *rest] then batch(first, rest)
        else ignore(event)
        end
        event => { id: }
        id in String
      end
    RUBY
    assert_equal 3, score(source, "Object#handle")
  end

  def test_guard_clauses_read_straight_down
    source = <<~RUBY
      def publish(post)
        return if post.nil?                 # +1
        return unless post.draft?           # +1
        raise Forbidden unless can_publish? # +1

        post.update!(published_at: Time.current)
        notify(post.author&.followers)
      end
    RUBY
    assert_equal 3, score(source, "Object#publish")
  end
end
