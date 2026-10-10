# frozen_string_literal: true

require "test_helper"
require "exhale/units/erb"

class UnitsErbTest < Minitest::Test
  SOURCE = <<~ERB
    <%= form_with model: @order do |f| %>
      <%= f.text_field :total %>
    <% end %>
  ERB

  # Contract: unit/U8
  def test_a_template_is_one_unit
    units = Exhale::Units::Erb.extract(SOURCE, "app/views/orders/_form.html.erb")

    assert_equal 1, units.size
    unit = units.first
    assert_equal :template, unit.kind
    assert_equal "views/orders/_form.html.erb", unit.identity
    assert_nil unit.namespace
    assert_nil unit.name
    assert_equal "app/views/orders/_form.html.erb", unit.path
    assert_equal :erb, unit.language
    assert_equal [1, 3], [unit.start_line, unit.end_line]
    assert_instance_of Herb::AST::DocumentNode, unit.node
  end

  # Contract: unit/U8
  def test_identity_keeps_paths_outside_app
    unit = Exhale::Units::Erb.extract("<p></p>\n", "engines/shop/views/a.html.erb").first

    assert_equal "engines/shop/views/a.html.erb", unit.identity
  end

  def test_omitted_close_tags_are_valid_html
    assert_equal 1, Exhale::Units::Erb.extract("<ul><li>a<li>b</ul>\n", "app/views/a.html.erb").size
  end

  # Contract: unit/U9
  def test_unclosed_tag_raises
    error = assert_raises(Exhale::ParseError) do
      Exhale::Units::Erb.extract("<p>fine</p>\n<div>\n  <span>x</span>\n", "app/views/orders/show.html.erb")
    end

    assert_equal "app/views/orders/show.html.erb", error.path
    assert_equal 2, error.line
  end

  # Contract: unit/U9
  def test_unclosed_erb_block_raises
    assert_raises(Exhale::ParseError) do
      Exhale::Units::Erb.extract("<% items.each do |i| %>\n  <%= i %>\n", "app/views/a.html.erb")
    end
  end

  # Value: protects=a template up to the depth limit is read and one level deeper is a parse error naming it, the same on every machine; fails_when=a deep template reaches the recursive walks and overflows the stack, or the limit is off by one (issue #19); why_new=no template tree was ever measured; seam=none
  # Contract: unit/U9
  def test_a_template_deeper_than_the_limit_is_a_parse_error
    nested = ->(levels) { "#{'<div>' * levels}x#{'</div>' * levels}\n" } # the document and the text add 2
    limit = Exhale::Units::Depth::LIMIT
    path = "app/views/a/show.html.erb"

    assert_equal 1, Exhale::Units::Erb.extract(nested.call(limit - 2), path).size
    error = assert_raises(Exhale::ParseError) { Exhale::Units::Erb.extract(nested.call(limit - 1), path) }
    assert_equal "#{path}:1: nests deeper than #{limit} levels", error.message
  end

  # Value: protects=the Ruby in an ERB tag counts on top of the tag's own depth, since normalizing walks into it; fails_when=only the HTML is counted, so a long chain in one tag overflows the stack while the template reads as shallow (issue #19); why_new=no tag held deep Ruby; seam=none
  # Contract: unit/U9
  def test_ruby_in_a_tag_counts_toward_the_templates_depth
    nested = ->(terms) { "#{'<div>' * 10}<%= #{(['a'] * terms).join(' + ')} %>#{'</div>' * 10}\n" } # 185 terms reach 200
    path = "app/views/a/show.html.erb"

    assert_equal 1, Exhale::Units::Erb.extract(nested.call(185), path).size
    error = assert_raises(Exhale::ParseError) { Exhale::Units::Erb.extract(nested.call(186), path) }
    assert_equal "#{path}:1: nests deeper than #{Exhale::Units::Depth::LIMIT} levels", error.message
  end

  # Value: protects=the signature in a partial's strict locals comment counts toward the template's depth, since normalizing parses it too; fails_when=only code tags are counted, so a deep signature overflows Prism in the normalizer and exits 1 (issue #19); why_new=no locals comment was ever deep; seam=none
  # Contract: unit/U9
  def test_a_strict_locals_signature_counts_toward_the_templates_depth
    partial = ->(levels) { "<%# locals: (x: #{'[' * levels}1#{']' * levels}) %>\n<p><%= x %></p>\n" } # 193 levels reach 200
    path = "app/views/a/_p.html.erb"

    assert_equal 1, Exhale::Units::Erb.extract(partial.call(193), path).size
    error = assert_raises(Exhale::ParseError) { Exhale::Units::Erb.extract(partial.call(194), path) }
    assert_equal "#{path}:1: nests deeper than #{Exhale::Units::Depth::LIMIT} levels", error.message
  end

  # Value: protects=a tag's Ruby is counted as the normalizer parses it, with the template's locals in scope; fails_when=the count parses the tag on its own, where `x %((` reads as a string, while the normalizer, knowing x is a local, builds the nesting and overflows the stack (issue #19); why_new=no counted tag depended on an earlier tag's locals; seam=none
  # Contract: unit/U9
  def test_a_tag_is_counted_with_the_locals_before_it
    deep = ->(n) { "#{'(' * n}1#{')' * n}" } # each pair of parentheses is two levels
    forms = {
      "modulo" => [96, ->(n) { "<% x = 1 %>\n<%= x %#{deep.call(n)} %>\n" }],
      "division" => [96, ->(n) { "<% x = 1 %>\n<%= x /#{deep.call(n)}/ 1 %>\n" }],
      "shift" => [97, ->(n) { "<% x = 1 %>\n<% x <<A\n#{deep.call(n)}\nA\n%>\n" }],
      "block parameter" => [96, ->(n) { "<% [1].each do |x| %>\n<%= x %#{deep.call(n)} %>\n<% end %>\n" }]
    }
    path = "app/views/a/show.html.erb"
    forms.each do |name, (reach, template)|
      assert_equal 1, Exhale::Units::Erb.extract(template.call(reach), path).size, name
      error = assert_raises(Exhale::ParseError, name) { Exhale::Units::Erb.extract(template.call(reach + 1), path) }
      assert_equal "#{path}:1: nests deeper than #{Exhale::Units::Depth::LIMIT} levels", error.message, name
    end
  end

  # Value: protects=a tag past Herb's own nesting limit for Ruby reads as the depth limit, the same message a Ruby file gets; fails_when=Herb's nesting_too_deep diagnostic is passed on as it is (issue #19); why_new=no tag reached Herb's limit; seam=none
  # Contract: unit/U9
  def test_herbs_own_nesting_limit_reads_as_the_depth_limit
    tag = "<%= #{'[' * 20_000}1#{']' * 20_000} %>\n"

    error = assert_raises(Exhale::ParseError) { Exhale::Units::Erb.extract(tag, "app/views/a/show.html.erb") }
    assert_equal "app/views/a/show.html.erb:1: nests deeper than #{Exhale::Units::Depth::LIMIT} levels", error.message
  end

  # Value: protects=a template is counted on the caller's stack, so a tree within the limit reads the same whatever the thread stack size; fails_when=the count runs on a thread, where a stack set smaller than the default made templates within the limit read as too deep (issue #19); why_new=the count ran on a thread before; seam=the normalizer wrapped to record its thread
  # Contract: unit/U9
  def test_a_template_is_counted_on_the_callers_stack
    normalize = Exhale::Dry::Normalizer::Erb.method(:normalize)
    threads = []
    Exhale::Dry::Normalizer::Erb.define_singleton_method(:normalize) { |*args| threads << Thread.current and normalize.call(*args) }

    Exhale::Units::Erb.extract("<p><%= x %></p>\n", "app/views/a/show.html.erb")

    assert_equal [Thread.current], threads
  ensure
    Exhale::Dry::Normalizer::Erb.define_singleton_method(:normalize, normalize)
  end

  # Contract: unit/U9
  def test_broken_ruby_raises
    error = assert_raises(Exhale::ParseError) { Exhale::Units::Erb.extract("<%= link_to( %>\n", "app/views/a.html.erb") }
    assert_equal "app/views/a.html.erb:1: argument_term_paren: unexpected end-of-input; expected a `)` to close the arguments",
                 error.message
  end
end
