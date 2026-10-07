# Ratchet

The ratchet is the gate behind `exhale complexity`. It fails a pull request that leaves a method harder to follow than it found it. Studies of complexity metrics find that absolute scores mostly track size and vary a lot from team to team. The direction of a change is the signal that holds up, so the gate judges change and never punishes code for what it already was.

## Obligations

- **T1** Every Ruby unit is scored at the head and at the merge base. The base is `--base`, or the merge base with the default branch. With no git or no merge base, nothing is compared: the run exits 0, says so, and lists units over the floor as warnings.
- **T2** A head unit matches the base unit with the same identity. An unmatched head unit then matches an unmatched base unit whose normalized shape scores at or above 0.80 against it, so a rename or move keeps its history. Ties go to the highest score, then to the base unit first in path and line order, and each base unit matches at most once.
- **T3** A matched unit whose score rose and ends above the floor is raised. A new unit above the floor is introduced. Both fail the gate. A unit that didn't rise passes, however high it is.
- **T4** A matched unit whose score fell is reported as contracted. A base unit with no head match is gone. Splitting a method passes when the method keeps its score or lowers it and every new piece ends at or under the floor. The total never counts.
- **T5** The floor defaults to 8. A primitive's `complexity.md` can set its own with a `settings` block holding `floor: N`, and `--floor` overrides every primitive for a local run only and never changes the verdict CI sees.
- **T6** A `ceiling` block in `contract/<primitive>/complexity.md` keeps the units it names, each up to the `max: N` it gives. The section the block sits in is its reason. A kept unit fails only above its max. A ceiling is stale when every unit it names scores at or under the floor, and it's an error when it names no unit. Stale clauses and errors fail the gate.
- **T7** Exit code 0 means nothing raised or introduced and every clause valid. 1 means at least one of either. 2 means exhale couldn't run, which includes a file that doesn't parse at the head and a `--base` that names no commit.

```covers
Exhale::Complexity::Ratchet
Exhale::Complexity::Check
```
