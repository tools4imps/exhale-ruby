# frozen_string_literal: true

require "test_helper"
require "herb"
require "exhale/dry/normalizer/erb"

class NormalizerErbTest < Minitest::Test
  # Contract: shape/N2
  def test_markup_differing_only_in_values_and_names_is_equal
    edit = normalize(%(<div class="p-4 text-sm"><%= link_to "Edit", edit_order_path(@order) %></div>))
    show = normalize(%(<div class="mt-2 font-bold"><%= link_to "Show", order_path(@invoice) %></div>))

    assert_equal project(edit), project(show)
  end

  # Contract: shape/N1
  def test_stimulus_controller_names_survive
    dropdown = normalize(%(<div data-controller="dropdown"><span></span></div>))
    modal = normalize(%(<div data-controller="modal"><span></span></div>))

    refute_equal project(dropdown), project(modal)
    assert_equal ["html_attribute_value", "dropdown"], project(dropdown.children.first.children.first.children.first)
  end

  # Contract: shape/N1
  def test_stimulus_actions_survive
    refute_equal project(normalize(%(<button data-action="click->menu#open"></button>))),
                 project(normalize(%(<button data-action="click->menu#close"></button>)))
  end

  # Contract: shape/N1
  # Contract: shape/N2
  def test_element_shape
    shape = normalize(%(<DIV class="a"><%= link_to "Edit", edit_order_path(@order) %></DIV>))

    assert_equal ["document_node", nil,
                  ["html_element_node", "div",
                   ["html_attribute_node", "class", [":literal", nil]],
                   ["html_body", nil,
                    ["erb_output", nil,
                     ["call_node", "link_to", ["arguments_node", nil, [":literal", nil], ["call_node", ":route", ["arguments_node", nil, [":ivar", nil]]]]]]]]],
                 project(shape)
    assert shape.sequence
    assert shape.children.first.children.last.sequence
  end

  # Contract: shape/N4
  def test_block_body_is_a_sequence_holding_the_markup
    shape = normalize(%(<% @items.each do |i| %><span><%= i.name %></span><% end %>))
    block = shape.children.first

    assert_equal "erb_block_node", block.kind
    head, body = block.children
    assert_equal ["erb_logic", nil,
                  ["call_node", "each", [":ivar", nil],
                   ["block_node", nil, ["block_parameters_node", nil, ["parameters_node", nil, [":local", nil]]]]]],
                 project(head)
    assert_equal "erb_body", body.kind
    assert body.sequence
    assert_equal ["html_element_node", "span", ["html_body", nil, ["erb_output", nil, ["call_node", "name", [":local", nil]]]]],
                 project(body.children.first)
  end

  # Contract: shape/N4
  def test_text_and_comments_drop_out
    shape = normalize(<<~ERB)
      <%# a comment %>
      <!-- markup comment -->
      Some words
      <p>more words</p>
    ERB

    assert_equal ["document_node", nil, ["html_element_node", "p"]], project(shape)
  end

  # Contract: shape/N4
  def test_if_keeps_conditions_of_every_branch
    shape = normalize(%(<% if admin? %><b></b><% elsif editor? %><i></i><% else %><u></u><% end %>))

    assert_equal ["erb_if_node", nil,
                  ["erb_logic", nil, ["if_node", nil, ["call_node", "admin?"]]],
                  ["erb_body", nil, ["html_element_node", "b"]],
                  ["erb_if_node", nil,
                   ["erb_logic", nil, ["if_node", nil, ["call_node", "editor?"]]],
                   ["erb_body", nil, ["html_element_node", "i"]],
                   ["erb_else_node", nil, ["erb_logic", nil], ["erb_body", nil, ["html_element_node", "u"]]]]],
                 project(shape.children.first)
  end

  # Contract: shape/N4
  def test_case_keeps_its_when_conditions
    shape = normalize(%(<% case state %><% when :draft %><i></i><% end %>))

    assert_equal ["erb_case_node", nil,
                  ["erb_logic", nil, [":local", nil]],
                  ["erb_when_node", nil,
                   ["erb_logic", nil, ["when_node", nil, [":literal", nil]]],
                   ["erb_body", nil, ["html_element_node", "i"]]]],
                 project(shape.children.first)
  end

  # Value: protects=an element whose opening tag is chosen in a conditional keeps the condition, each branch's attribute names and its body; fails_when=the walk reads children the conditional open tag doesn't have and raises NoMethodError (issue #17), or drops the branches' attributes; why_new=no template chose its opening tag in a conditional; seam=none
  # Contract: shape/N1
  # Contract: shape/N4
  def test_a_conditional_open_tag_keeps_its_condition_and_each_branch_attributes
    shape = normalize(%(<% if open? %><div class="a"><% else %><div id="b"><% end %><span></span></div>))

    assert_equal ["html_element_node", "div",
                  ["erb_if_node", nil,
                   ["erb_logic", nil, ["if_node", nil, ["call_node", "open?"]]],
                   ["erb_body", nil, ["html_open_tag_node", nil, ["html_attribute_node", "class", [":literal", nil]]]],
                   ["erb_else_node", nil,
                    ["erb_logic", nil],
                    ["erb_body", nil, ["html_open_tag_node", nil, ["html_attribute_node", "id", [":literal", nil]]]]]],
                  ["html_body", nil, ["html_element_node", "span"]]],
                 project(shape.children.first)
  end

  # Value: protects=Stimulus values in a conditional opening tag survive, so templates that wire different controllers aren't copies; fails_when=the conditional open tag's attributes are skipped instead of normalized (issue #17); why_new=no template chose its opening tag in a conditional; seam=none
  # Contract: shape/N1
  def test_conditional_open_tags_differing_in_a_stimulus_value_differ
    template = ->(controller) { %(<% if open? %><div data-controller="#{controller}"><% else %><div><% end %><span></span></div>) }

    refute_equal project(normalize(template.call("dropdown"))), project(normalize(template.call("modal")))
  end

  def test_yield_keeps_its_arguments
    shape = normalize(%(<%= yield :sidebar %>))

    assert_equal ["erb_yield_node", nil, ["erb_output", nil, ["yield_node", nil, ["arguments_node", nil, [":literal", nil]]]]],
                 project(shape.children.first)
  end

  # Contract: shape/N1
  # Contract: shape/N2
  def test_attribute_values_with_erb_keep_the_erb
    shape = normalize(%(<a class="btn <%= size %>" disabled></a>))

    assert_equal ["html_element_node", "a",
                  ["html_attribute_node", "class",
                   ["html_attribute_value_node", nil, [":literal", nil], ["erb_output", nil, [":local", nil]]]],
                  ["html_attribute_node", "disabled"]],
                 project(shape.children.first)
  end

  # `row [0]` indexes a local but calls a method named row, so the parse
  # shows whether `row` is in scope.
  def test_template_locals_carry_into_later_tags_until_their_block_ends
    shape = normalize(<<~ERB)
      <% total = 0 %>
      <% rows.each do |row| %><%= row [0] %><%= total [0] %><% end %>
      <%= row [0] %>
    ERB
    block = shape.children[1]
    after = shape.children[2]
    index = ["call_node", "[]", [":local", nil], ["arguments_node", nil, [":literal", nil]]]

    assert_equal [["erb_output", nil, index], ["erb_output", nil, index]],
                 block.children[1].children.map { |child| project(child) }
    assert_equal ["erb_output", nil, ["call_node", "row", ["arguments_node", nil, ["array_node", nil, [":literal", nil]]]]],
                 project(after)
  end

  def test_lines_come_from_the_template
    shape = normalize(<<~ERB)
      <ul>
        <% @items.each do |item| %>
          <li><%= item.name %></li>
        <% end %>
      </ul>
    ERB
    list = shape.children.first
    block = list.children.first.children.first
    head, body = block.children

    assert_equal [1, 5], [list.start_line, list.end_line]
    assert_equal [2, 4], [block.start_line, block.end_line]
    assert_equal [2, 2], [head.start_line, head.end_line]
    assert_equal [3, 3], [body.children.first.start_line, body.children.first.end_line]
    assert_equal 3, body.children.first.children.first.children.first.children.first.start_line
  end

  # Contract: shape/N3
  def test_partials_differing_only_in_their_local_are_equal
    partial = lambda do |name, path|
      <<~ERB
        <div id="<%= dom_id #{name} %>">
          <h2><%= #{name}.title %></h2>
          <%= link_to "Edit", #{path}(#{name}) %>
        </div>
      ERB
    end

    assert_equal project(normalize(partial.call("order", "edit_order_path"))),
                 project(normalize(partial.call("invoice", "edit_invoice_path")))
  end

  # Contract: shape/N3
  def test_strict_locals_comment_puts_its_locals_in_scope
    shape = normalize(<<~ERB)
      <%# locals: (order:, invoice: nil) -%>
      <%= order [0] %>
      <%= invoice [0] %>
    ERB
    index = ["erb_output", nil, ["call_node", "[]", [":local", nil], ["arguments_node", nil, [":literal", nil]]]]

    assert_equal [index, index], shape.children.map { |child| project(child) }
  end

  # Value: protects=the strict locals comment is found after an ordinary ERB comment; fails_when=the first comment of any kind ends the search and the partial's locals parse as method calls; why_new=every strict-locals test put the magic comment first; seam=none
  # Contract: shape/N3
  def test_strict_locals_comment_after_another_comment_still_counts
    shape = normalize(<<~ERB)
      <%# the order form %>
      <%# locals: (order:) -%>
      <%= order [0] %>
    ERB
    index = ["erb_output", nil, ["call_node", "[]", [":local", nil], ["arguments_node", nil, [":literal", nil]]]]

    assert_equal index, project(shape.children.last)
  end

  # Contract: shape/N3
  def test_strict_locals_partials_differing_only_in_their_local_are_equal
    assert_equal project(normalize("<%# locals: (order:) %>\n<p><%= order.title %></p>\n")),
                 project(normalize("<%# locals: (invoice:) %>\n<p><%= invoice.title %></p>\n"))
  end

  def test_bodies_span_their_shapes_and_heads_stay_on_their_tag
    shape = normalize("<% if x %>\n  <p>a</p>\n  <p>b</p>\n  <% end %>\n")
    head, body = shape.children.first.children

    assert_equal [2, 3], [body.start_line, body.end_line]
    assert_equal [1, 1], [head.start_line, head.end_line]
    assert_equal [1, 1], [head.children.first.start_line, head.children.first.end_line]
  end

  # Value: protects=ERB comments and escaped `<%%` tags drop out of the shape; fails_when=a comment or an escape is read as Ruby and leaves a tag behind; why_new=comments were only tested as the strict-locals magic comment; seam=none
  # Contract: shape/N4
  def test_erb_comments_and_escaped_tags_drop_out
    assert_equal project(normalize("<p>a</p>\n")), project(normalize("<p>a</p>\n<%# note %>\n<%% x %>\n"))
  end

  # Value: protects=an empty tag is a tag with no statements; fails_when=a tag with no Ruby in it crashes the normalizer; why_new=every tag held Ruby; seam=none
  def test_an_empty_tag_is_a_tag_with_no_statements
    assert_equal [%w[erb_logic], %w[erb_output]], ["<% %>\n", "<%= %>\n"].map { |source| normalize(source).children.map(&:kind) }
    assert_empty normalize("<%= %>\n").children.first.children
  end

  # Value: protects=a block that opens and closes inside one tag puts nothing in scope for the tags after it; fails_when=the block's parameters leak into the body below, so a call there reads as an index on a local; why_new=only blocks left open by their tag were tested; seam=none
  # Contract: shape/N3
  def test_a_block_closed_inside_its_tag_scopes_nothing_after_it
    # The block closes exactly where the tag's Ruby ends.
    shape = normalize("<% if x; items.each { |item| item }%>\n<%= item [0] %>\n<% end %>\n")
    output = shape.children.first.children.last.children.first

    assert_equal ["erb_output", nil, ["call_node", "item", ["arguments_node", nil, ["array_node", nil, [":literal", nil]]]]],
                 project(output)
  end

  # Value: protects=an empty template is one line long; fails_when=a node that ends at column 0 of its own first line is pulled back to the line before it; why_new=no test normalized an empty template; seam=none
  def test_an_empty_template_spans_its_first_line
    shape = normalize("")

    assert_equal [1, 1], [shape.start_line, shape.end_line]
  end

  # Value: protects=an empty body takes its node's lines; fails_when=an empty body crashes reading the lines of its first child; why_new=every control tag had a body; seam=none
  def test_an_empty_body_takes_its_nodes_lines
    body = normalize("<% if x %><% end %>\n").children.first.children.last

    assert_equal ["erb_body", 1, 1, []], [body.kind, body.start_line, body.end_line, body.children]
  end

  # Value: protects=a tag spans from its opening to its closing, and each statement in it keeps its own lines; fails_when=a tag ends with its Ruby though `%>` sits on a later line, or a short statement is stretched to the tag's last line; why_new=multi-line tags were only tested with the end a head borrows; seam=none
  def test_a_tag_spans_to_its_closing_and_its_statements_keep_their_lines
    output = normalize("<%= x\n%>\n").children.first
    assert_equal [1, 2], [output.start_line, output.end_line]

    first, second = normalize("<% x = 1\n   y = 2 %>\n").children.first.children
    assert_equal [[1, 1], [2, 2]], [[first.start_line, first.end_line], [second.start_line, second.end_line]]
  end

  private

  def normalize(source)
    Exhale::Dry::Normalizer::Erb.normalize(Herb.parse(source, strict: false).value)
  end

  # Shapes compare with their line numbers; this view compares structure.
  def project(shape)
    [shape.kind, shape.label, *shape.children.map { |child| project(child) }]
  end
end
