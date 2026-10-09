# Changelog

## Unreleased

- `.exhale.yml` supports an `ignore` list of repository-relative glob patterns.
  Exhale applies it consistently to the checked-out tree and the merge base.

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
