# Changelog

## Unreleased

- An HTML ERB element whose opening tag is chosen in a conditional (`<% if x %><div class="a"><% else %><div><% end %>…</div>`) no longer stops `exhale dry` with a `NoMethodError`. Its shape keeps the condition and each branch's tag and attributes, as shape/N1 and N4 say.
- A file whose parse tree nests deeper than 200 levels is a parse error, `path:1: nests deeper than 200 levels`, so the run exits 2 naming it, as unit/U9 now says. Before, such a file stopped `exhale dry` and `exhale complexity` with `SystemStackError` and exit 1, and how deep it had to be depended on the Ruby VM stack. A Ruby file's tree is counted without recursing right after parsing, and a template by the ERB normalizer's own walk, which stops at the limit, so no walk recurses past it. A level is one parse-tree node, so each link of an operator or method chain is a level, and a template counts as the ERB normalizer walks it: a tag's Ruby, parsed with the locals of the tags before it in scope, counts from the tag's level, and the signature in a partial's strict locals comment from the template's top. The locals matter: `x %((1))` is a string unless `x` is a local, and then it's nested parentheses. Prism's and Herb's own nesting limits give the same error. Prism and Herb parse on the caller's stack, so a file too deep for them to parse at all still stops the run with `SystemStackError` and exit 1, as on 0.2.0: on macOS arm64 with the default 8 MB stack, Prism parsed 9,000 nested arrays and overflowed on 10,001, and stopped at its own limit on 5,000 nested blocks; with `ulimit -s 1024` Herb overflowed on 2,500 nested `<div>`s. A Ruby file is counted before its syntax errors, so one too deep reads as too deep whether or not it has one. The base cache key now includes the depth limit, so a base swept by 0.2.0 isn't reused. README's Determinism section lists what can still change a verdict: a stack smaller than Ruby's defaults and Herb's 1,000 ms parse timeout.

## 0.2.0

- `exhale complexity` is the second check. It scores every Ruby method and Rails DSL body with Cognitive Complexity at the head and at the merge base, and fails a pull request that raises a unit past the floor (8 by default) or adds one over it. Renamed and moved methods keep their history by identity, then by shape. `complexity.md` in a primitive sets its floor and keeps units up to a ceiling's max. `exhale complexity explain UNIT` prints every point. JSON lists every unit; EDN writes crapper's entries.
- The Contract loads per check: dry reads `duplication.md`, complexity reads `complexity.md`, and a block that belongs to the other check is an error.
- The mutation gate moves to Mutineer 1.5. `timeout: 120` in `.mutineer.yml` replaces the `test/support/mutineer_timeout.rb` patch, and 8 ignore entries for continuation lines are gone, because Mutineer now selects tests for the later lines of a multi-line call or hash. The 13 on the right side of a multi-line `&&` stay, because Mutineer still selects no tests for an operand that may never run.
- `bin/mutate --matrix` reports blind and redundant tests with Mutineer 1.5's kill matrix. It is a separate run, not part of the gate.

## 0.1.0

First release. `exhale dry` sweeps the whole codebase for duplicated Ruby and HTML ERB and fails while any copy isn't kept by the Contract.

- Units from Prism (methods, Rails DSL bodies, concerns) and Herb (HTML ERB templates), normalized so the names of operations survive and the names of things become markers.
- Rarity-weighted Jaccard over subtree fingerprints, with exact prefix filtering for whole units, exact subtree digests for copied fragments, and statement-run seeds for code lifted out of the middle of a method.
- The verdict depends only on the commit. The merge base labels each finding introduced, shifted, already there, kept or contracted, and `--introduced-only` is the on-ramp for codebases that don't sweep clean yet.
- The Contract under `contract/<primitive>/` keeps deliberate duplication (`parallel`), maps primitives to code (`covers`) and holds settings (`settings`). Stale clauses and unknown references fail the gate.
- Text, JSON and EDN reports. EDN uses the shape Uncle Bob's dryer writes.
- exhale ships with its own Contract (64 obligations, all executable), a clean run on itself, and a mutation gate where every Mutineer mutant is killed or listed with a reason.
