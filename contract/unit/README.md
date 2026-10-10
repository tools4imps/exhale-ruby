# Unit

A unit is anything that can appear in a finding: a method, the body of a Rails DSL call, or an HTML template. Its identity has to survive a file move.

## Obligations

- **U1** An instance method is `Namespace#name`. A singleton method is `Namespace.name`, whether it's written `def self.name`, inside `class << self`, inside `class << Const`, or as `def Const.name`. A `def` on any other receiver, or a `class << obj` on one, isn't a unit. `define_method` gives an instance method and `define_singleton_method` a singleton method, with or without `self.` in front.
- **U2** Namespaces follow module and class nesting, compact paths like `class Foo::Bar`, any block-taking call assigned to a constant (`Struct.new`, `Class.new`, `Data.define`, `Module.new`, including `Foo::Bar = ...`), and `class_eval`, `class_exec`, `module_eval` and `module_exec` blocks on a constant. A constant named on a receiver resolves inside the enclosing namespace when its first segment names one, and as written otherwise. The top level is `Object`.
- **U3** A concern's `included`, `prepended` and `concerning` blocks read as class bodies, and `class_methods` reads as a singleton body.
- **U4** The block or lambda passed to a listed Rails macro is a DSL unit, named `Namespace.macro(:name)` from a symbol or string name, `Namespace.rescue_from(A, B::C)` from its leading constants (a string naming a constant path counts), or `Namespace.macro[n]` by ordinal when it has no name. Ordinals drift when a block is inserted above, so a Contract reference should prefer named macros.
- **U5** A class-body macro call with no block or lambda is never a unit.
- **U6** Identities are unique within a file. A repeat gets `[2]`, `[3]` and so on, in source order.
- **U7** A unit's lines cover its whole source, heredoc bodies included.
- **U8** A template is one unit, named by its path with the leading `app/` removed.
- **U9** A file that doesn't parse cleanly, can't be read, isn't valid UTF-8, or whose parse tree nests deeper than 200 levels raises a parse error naming the file, so the gate exits 2 rather than passing code it never read. A level is one node of the parse tree, so each link of an operator or method chain is a level, and a template counts as the ERB normalizer walks it: a tag's Ruby, parsed with the locals of the tags before it in scope, counts from the tag's level, and the signature in a partial's strict locals comment from the template's top. Prism stopping at its own nesting limit gives the same error, and so does Herb's nesting limit for the Ruby in a tag. A file too deep for Prism or Herb to parse without overflowing the stack stops the run instead, as README's Determinism section says.

```covers
Exhale::Units
```
