# Cognitive

Cognitive scores how hard a Ruby unit is to follow. It's G. Ann Campbell's Cognitive Complexity (SonarSource, 2017), read off the Prism tree with the Ruby decisions below written down, so a score never depends on taste. A method that reads straight down scores low however long it is. Each break in that reading costs a point, and costs more the deeper it sits.

## Obligations

- **K1** Each of these adds 1 plus the current nesting level: `if`, `unless`, a ternary, and their modifier forms; `while`, `until` and `for`, modifier forms included; a whole `case` or `case`/`in`, however many branches it has; each `rescue` clause, inline `rescue` included; and a block that iterates (K5). Each `elsif` and each `else` of an `if` or `unless` adds 1 with no nesting cost. The `else` of a `case` and of a `begin`/`rescue` adds nothing.
- **K2** Nesting rises by one inside the body of everything K1 charges with nesting, and inside any block or lambda, which add nothing themselves. A unit starts at nesting 0. A DSL unit's own block is the unit's body and doesn't raise nesting.
- **K3** Each run of like boolean operators in one expression adds 1: `a && b && c` adds 1, and `a && b || c` adds 2. `and` counts as `&&` and `or` as `||`. A `!` or parentheses don't break a run on their own. `&.`, `||=`, `&&=`, `return`, `next` and `break` add nothing.
- **K4** A call to the unit's own name with no receiver or with `self` adds 1 for recursion, once per unit.
- **K5** A block iterates when the call it's passed to is one of a fixed list: `each` and every `each_*`, `map`, `flat_map`, `collect`, `filter_map`, `select`, `filter`, `reject`, `find`, `detect`, `find_index`, `find_all`, `any?`, `all?`, `none?`, `one?`, `count`, `sum`, `inject`, `reduce`, `group_by`, `partition`, `sort_by`, `min_by`, `max_by`, `minmax_by`, `uniq`, `zip`, `take_while`, `drop_while`, `chunk_while`, `slice_when`, `times`, `upto`, `downto`, `step`, `loop` and `cycle`. A block passed as `&:sym` or `&method(:x)` isn't a block and adds nothing.
- **K6** Each call to `eval`, `instance_eval`, `class_eval`, `module_eval`, `instance_exec`, `class_exec`, `module_exec`, `define_method`, `define_singleton_method`, `send`, `__send__`, `public_send`, `instance_variable_get`, `instance_variable_set` or `const_get` adds 1 with no nesting cost, and so does defining `method_missing`. These are reported apart as the unit's metaprogramming points.
- **K7** Every point carries its line, the construct that earned it, and its nesting, and the points sum to the score. The score depends only on the unit's source.
- **K8** Methods and DSL units are scored. Templates aren't, and a unit that holds a nested `def` or a nested unit scores without it, since that unit is scored on its own.

```covers
Exhale::Complexity::Cognitive
```
