# frozen_string_literal: true

require "test_helper"
require "exhale/units/ruby"

class UnitsRubyTest < Minitest::Test
  # Contract: unit/U1
  # Contract: unit/U2
  def test_nested_modules_and_compact_class_paths
    units = extract(<<~RUBY)
      module Billing
        class Invoice
          def total; end
        end

        class Line::Item
          def amount; end
        end

        class ::Ledger
          def post; end
        end
      end

      def helper; end
    RUBY

    assert_equal ["Billing::Invoice#total", "Billing::Line::Item#amount", "Ledger#post", "Object#helper"],
                 units.map(&:identity)
    assert_equal ["Billing::Invoice", "Billing::Line::Item", "Ledger", "Object"], units.map(&:namespace)
    assert_equal %w[total amount post helper], units.map(&:name)
  end

  # Contract: unit/U1
  def test_singleton_methods
    units = extract(<<~RUBY)
      class Invoice
        def self.build; end

        class << self
          def find_due; end
        end

        def total; end
      end
    RUBY

    assert_equal ["Invoice.build", "Invoice.find_due", "Invoice#total"], units.map(&:identity)
  end

  # Contract: unit/U7
  def test_unit_fields
    unit = extract(<<~RUBY, "app/models/invoice.rb").first
      class Invoice
        def total
          lines.sum(&:amount)
        end
      end
    RUBY

    assert_equal :method, unit.kind
    assert_equal "app/models/invoice.rb", unit.path
    assert_equal :ruby, unit.language
    assert_equal [2, 4], [unit.start_line, unit.end_line]
    assert_instance_of Prism::DefNode, unit.node
  end

  def test_a_def_inside_a_def_belongs_to_the_outer_method
    units = extract(<<~RUBY)
      class Invoice
        def setup
          def helper; end
        end
      end
    RUBY

    assert_equal ["Invoice#setup"], units.map(&:identity)
  end

  # Contract: unit/U1
  def test_define_method_is_a_method_unit
    units = extract(<<~RUBY)
      class Invoice
        define_method(:paid?) { state == "paid" }
        define_method :due? do
          state == "due"
        end
      end
    RUBY

    assert_equal ["Invoice#paid?", "Invoice#due?"], units.map(&:identity)
    assert_equal [:method, :method], units.map(&:kind)
    assert units.all? { |unit| unit.node.is_a?(Prism::BlockNode) }
    assert_equal [3, 5], [units.last.start_line, units.last.end_line]
  end

  # Contract: unit/U4
  def test_scope_with_a_lambda
    unit = extract(<<~RUBY).first
      class Order < ApplicationRecord
        scope :settled, -> { where(state: :settled) }
      end
    RUBY

    assert_equal ["Order.scope(:settled)", "scope(:settled)", "Order", :dsl],
                 [unit.identity, unit.name, unit.namespace, unit.kind]
    assert_instance_of Prism::LambdaNode, unit.node
  end

  # Contract: unit/U4
  def test_callback_blocks_named_and_numbered
    units = extract(<<~RUBY)
      class OrdersController < ApplicationController
        before_action do
          authenticate!
        end
        before_action :load_order do
          @order = Order.find(params[:id])
        end
        before_action { track! }
        after_action { log! }
      end
    RUBY

    assert_equal ["OrdersController.before_action[1]", "OrdersController.before_action(:load_order)",
                  "OrdersController.before_action[2]", "OrdersController.after_action[1]"],
                 units.map(&:identity)
    assert units.all? { |unit| unit.node.is_a?(Prism::BlockNode) }
  end

  # Contract: unit/U4
  def test_serializer_attributes_inside_traits_are_units
    units = extract(<<~RUBY)
      class InvoiceSerializer
        attributes :id
        trait :billing do
          attribute :total do |invoice|
            invoice.total
          end
        end
      end
    RUBY

    assert_equal ["InvoiceSerializer.attribute(:total)"], units.map(&:identity)
  end

  # Contract: unit/U4
  def test_policy_relation_scopes_are_units
    units = extract(<<~RUBY)
      class InvoicePolicy
        relation_scope do |relation|
          relation.where(user: user)
        end
      end
    RUBY

    assert_equal ["InvoicePolicy.relation_scope[1]"], units.map(&:identity)
  end

  # Contract: unit/U4
  def test_state_machine_callbacks_are_units
    units = extract(<<~RUBY)
      class Invoice
        state_machine :status do
          event(:pay) { transition pending: :paid }
          before_transition { |invoice| invoice.prepare }
          after_transition { |invoice| invoice.notify }
          around_transition { |invoice, transition, block| block.call }
        end
      end
    RUBY

    assert_equal ["Invoice.before_transition[1]", "Invoice.after_transition[1]", "Invoice.around_transition[1]"],
                 units.map(&:identity)
  end

  # Contract: unit/U4
  def test_token_generation_blocks_are_units
    units = extract(<<~RUBY)
      class Invitation
        generates_token_for :acceptance do
          token_version
        end
      end
    RUBY

    assert_equal ["Invitation.generates_token_for(:acceptance)"], units.map(&:identity)
  end

  # Contract: unit/U3
  def test_concern_blocks_read_as_the_class_body
    units = extract(<<~RUBY)
      module Billable
        extend ActiveSupport::Concern

        included do
          before_save { normalize_amount }
          def bill; end
        end

        class_methods do
          def billable; end
        end

        concerning :Refunds do
          def refund; end
        end
      end
    RUBY

    assert_equal ["Billable.before_save[1]", "Billable#bill", "Billable.billable", "Billable#refund"],
                 units.map(&:identity)
  end

  # Contract: unit/U5
  def test_class_body_macros_without_a_body_are_not_units
    units = extract(<<~RUBY)
      class Order < ApplicationRecord
        has_many :lines, -> { order(:position) }
        belongs_to :customer
        validates :total, presence: true
        before_save :normalize
        before_save :recalculate, if: -> { lines_changed? }
        scope :recent, :ordered
        attribute :name, :string
        relation_scope :visible
        before_transition :prepare
        after_transition :notify
        around_transition :wrap
        generates_token_for :access
      end
    RUBY

    assert_empty units
  end

  def test_units_come_in_source_order
    units = extract(<<~RUBY)
      class Order
        def a; end
        validate { check }
        def b; end
      end
    RUBY

    assert_equal ["Order#a", "Order.validate[1]", "Order#b"], units.map(&:identity)
  end

  # Contract: unit/U9
  def test_parse_errors_raise_with_the_line
    error = assert_raises(Exhale::ParseError) { extract("class Order\n  def total(\nend\n", "app/models/order.rb") }

    assert_equal "app/models/order.rb", error.path
    assert_kind_of Integer, error.line
    assert_match(/\Aapp\/models\/order\.rb:\d+: /, error.message)
  end

  # Contract: unit/U6
  def test_repeated_identities_in_one_file_are_numbered_in_source_order
    units = extract(<<~RUBY)
      class Cart
        if ENV["FAST"]
          def total = 1
        else
          def total = 2
        end
      end

      class Cart
        def total = 3
      end
    RUBY

    assert_equal ["Cart#total", "Cart#total[2]", "Cart#total[3]"], units.map(&:identity)
    assert_equal ["total", "total[2]", "total[3]"], units.map(&:name)
  end

  # Contract: unit/U2
  def test_constant_path_write_with_a_block_is_a_namespace
    units = extract(<<~RUBY)
      module A
        Foo::Point = Struct.new(:x) do
          def len; end
        end
      end
    RUBY

    assert_equal ["A::Foo::Point#len"], units.map(&:identity)
  end

  # Value: protects=only a block-taking call assigned to a constant opens a namespace; a literal or a call without a block is a plain constant; fails_when=a constant holding a literal or a blockless call crashes extraction or opens a namespace; why_new=every constant-write test assigned a call with a block; seam=none
  # Contract: unit/U2
  def test_constants_holding_a_literal_or_a_blockless_call_are_plain_constants
    units = extract(<<~RUBY)
      LIMIT = 10
      Point = Struct.new(:x)
      Billing::KEYS = %i[a b].freeze
      class Order
        def total; end
      end
    RUBY

    assert_equal ["Order#total"], units.map(&:identity)
  end

  # Value: protects=a rooted constant (`::Billing`) on a receiver reads as written, never inside the enclosing namespace; fails_when=a leading `::` is ignored and `class << ::Billing` inside `Admin::Billing` lands on Admin::Billing; why_new=no test named a rooted receiver; seam=none
  # Contract: unit/U2
  def test_a_rooted_receiver_reads_as_written
    units = extract(<<~RUBY)
      module Admin
        module Billing
          class << ::Billing
            def charge; end
          end

          ::Billing.class_eval do
            def refund; end
          end
        end
      end
    RUBY

    assert_equal ["Billing.charge", "Billing#refund"], units.map(&:identity)
  end

  # Contract: unit/U2
  def test_class_eval_reads_as_the_receivers_class_body
    units = extract(<<~RUBY)
      Order.class_eval do
        def paid?; end
      end
      Billing::Invoice.module_eval do
        scope :due, -> { where(due: true) }
      end
      order.class_eval do
        def ignored?; end
      end
    RUBY

    assert_equal ["Order#paid?", "Billing::Invoice.scope(:due)", "Object#ignored?"], units.map(&:identity)
  end

  # Contract: unit/U1
  def test_singleton_receivers_name_their_owner
    units = extract(<<~RUBY)
      module Billing
        def Billing.configure; end
        def Ledger.post; end

        class Invoice
          class << Ledger
            def reset; end
          end

          class << some_object
            def skipped; end
          end

          def other.skipped; end
        end
      end
    RUBY

    assert_equal ["Billing.configure", "Ledger.post", "Ledger.reset"], units.map(&:identity)
  end

  # Contract: unit/U4
  def test_rescue_from_is_named_by_its_constants
    units = extract(<<~RUBY)
      class ApplicationController
        rescue_from ActiveRecord::RecordNotFound do |error|
          render_not_found(error)
        end
        rescue_from Pundit::NotAuthorizedError, ::Billing::Declined do
          head :forbidden
        end
        rescue_from "Timeout::Error" do
          head :gateway_timeout
        end
      end
    RUBY

    assert_equal ["ApplicationController.rescue_from(ActiveRecord::RecordNotFound)",
                  "ApplicationController.rescue_from(Pundit::NotAuthorizedError, Billing::Declined)",
                  "ApplicationController.rescue_from(Timeout::Error)"],
                 units.map(&:identity)
  end

  # Contract: unit/U7
  def test_units_end_at_their_last_heredoc_terminator
    units = extract(<<~RUBY)
      class Order
        scope :stale, -> { where(<<~SQL) }
          created_at < now() - interval '30 days'
          AND status = 'open'
          AND archived_at IS NULL
        SQL

        def report
          execute(<<~SQL, <<~CSV)
            SELECT 1
          SQL
            a,b
          CSV
        end
      end
    RUBY

    assert_equal [["Order.scope(:stale)", 2, 6], ["Order#report", 8, 14]],
                 units.map { |unit| [unit.identity, unit.start_line, unit.end_line] }
  end

  # Contract: unit/U1
  def test_block_defined_methods_on_self_and_singletons
    units = extract(<<~RUBY)
      class Invoice
        self.define_method(:paid?) { state == "paid" }
        define_singleton_method(:build) { new }
        self.define_singleton_method(:find_due) { where(due: true) }
        other.define_method(:skipped) { }
      end
    RUBY

    assert_equal ["Invoice#paid?", "Invoice.build", "Invoice.find_due"], units.map(&:identity)
  end

  # Contract: unit/U4
  def test_a_string_name_on_a_macro_reads_like_a_symbol
    units = extract(<<~RUBY)
      class Account
        scope "active", -> { where(active: true) }
        scope :closed, -> { where(active: false) }
      end
    RUBY

    assert_equal ["Account.scope(:active)", "Account.scope(:closed)"], units.map(&:identity)
  end

  # Contract: unit/U2
  def test_self_prefixed_constant_paths_nest_in_the_current_namespace
    units = extract(<<~RUBY)
      module Outer
        class self::Bar
          def x; end
        end

        class self::Baz::Qux
          def y; end
        end

        self::Bar.class_eval do
          def z; end
        end
      end
    RUBY

    assert_equal ["Outer::Bar#x", "Outer::Baz::Qux#y", "Outer::Bar#z"], units.map(&:identity)
  end

  private

  def extract(source, path = "app/models/example.rb")
    Exhale::Units::Ruby.extract(source, path)
  end
end
