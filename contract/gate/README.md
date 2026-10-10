# Gate

The gate turns a sweep's matches into findings, labels them, and decides the verdict.

## Obligations

- **G1** The verdict reads only the commit: its tree, its Contract and the gem versions it pins. The merge base, the cache, the machine and the user's git config never change it. The `--introduced-only` on-ramp is the one exception, because it reads the base by design. The machine's limits are outside this: README's Determinism section lists the stack sizes and Herb's parse timeout that can still change it.
- **G2** Exit code 0 means no unkept finding and every clause valid. 1 means at least one of either. 2 means exhale couldn't run, which includes a root that doesn't exist and a sparse checkout that hides part of the commit.
- **G3** A touched location with no base pair to another location in its finding is introduced, whatever else in that finding was there before.
- **G4** A finding with no touched location is already there when its locations sat in one finding at the base, by identity or by structure. Otherwise it's shifted. A location's identity includes its file, so a unit defined under the same name in two files is two locations.
- **G5** A pair that matched at the base and doesn't match at the head is contracted, counted per occurrence, so deleting one of three identical copies is a contraction.
- **G6** Flag overrides report but never gate, and they apply to the base sweep too, so labels stay true under them. A run narrowed to paths gates on the findings inside those paths.
- **G7** `--introduced-only` fails only on introduced and shifted findings, and lists the rest as warnings.
- **G8** Matches that share a location form one finding. A clause keeps a group of identical units only when it keeps every pair among them, the pairs the star leaves out included.
- **G9** The copy is a touched location when there is one. Otherwise it's the location whose lines were committed last, and with no git, the last by path.
- **G10** Payoff is the normalized nodes in every location but the original, weighted by score. Findings are ordered by label, then payoff, then location.
- **G11** Hints come from fixed rules over unit kinds and paths. No model is asked.
- **G12** A whole check, sweep and gate together, stays close to linear in the number of copies in a finding.

```covers
Exhale::Dry::Gate
```
