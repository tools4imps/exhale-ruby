# exhale

<p align="center"><img src="assets/huff-exhale.svg" alt="Huff, the Impatient Programming imp, lips pursed, blowing two duplicate cards away while he keeps one in his hand and his robot sits at his feet" width="320"></p>

Exhale aims to be the premier contraction toolkit for Ruby, the checks for the breathe-out phase of Impatient Programming. Its first check is `exhale dry`. It fails a pull request while the codebase it leaves behind holds duplicated code the Contract doesn't keep, and it tells the agent doing the cleanup which original each copy should fold into.

Agents duplicate by default. They read the codebase, find a shape that works, and copy it. When pull requests merge without a person reading every diff, the copy reaches main unless a machine stops it, and every session after that copies it again. exhale is that machine for the exhale half of the breath: expand to learn, then contract what you learned into what already exists, in the same PR.

`exhale dry` combines Robert Martin's [dryer](https://github.com/unclebob/dryer) and Ryan Davis's [flay](https://github.com/seattlerb/flay), rebuilt on [Prism](https://github.com/ruby/prism) and [Herb](https://herb-tools.dev) so it reads modern Ruby and ERB the way Rails writes them. The second check, `exhale complexity`, fails a pull request that leaves a method harder to follow than it found it. A leaked-guards check is planned.

## Install

```ruby
# Gemfile
group :development, :test do
  gem "exhale", require: false
end
```

```bash
bundle install
bundle binstubs exhale
bin/exhale dry
```

`exhale dry` exits 0 when the codebase is clean. It exits 1 when the gate fails: there's unkept duplication, or a Contract clause is stale or names code that doesn't exist. It exits 2 when it couldn't run, usually because a file doesn't parse.

## What it compares

Units are methods, the bodies of Rails DSL calls (`scope`, `validate`, callbacks, `before_action` blocks), and ERB templates. Inside each unit it also compares fragments: blocks, conditionals, HTML elements, and runs of three or more consecutive statements lifted out of the middle of a method.

Class-body declarations like `has_many` and `validates` never count, and neither does anything under `db/`, `config/`, `vendor/` or `tmp/`. Tests are left out unless you pass `--include-tests`, because tests should be DAMP, not DRY.

## Ignoring files

Use `.exhale.yml` to leave files outside the sweep. Patterns are relative to
the repository root and use Ruby glob syntax:

```yaml
ignore:
  - "lib/generators/**/*"
  - "db/migrate/*"
```

The same configuration applies to the pull request head and its merge base, so
an ignored file cannot create a parse failure on either side of the comparison.

Normalization keeps the names of operations and drops the names of things. Method names at call sites survive, so do operators, HTML tags and Stimulus `data-controller` values. Locals, instance variables, constants, symbols and literals become markers. These two methods are the same shape:

```ruby
def alpha(xs)
  ys = xs.select(&:odd?)
  ys.map(&:succ)
end

def beta(items)
  kept = items.select(&:even?)
  kept.map(&:pred)
end
```

## Scoring

Every subtree of a normalized unit is a fingerprint. Each fingerprint is weighted by how rare it is, `ln(1 + 1000 / count)`, and two units score by Jaccard similarity over those weights. A shape that shows up in every controller weighs close to nothing, so scaffolding doesn't drown out real copies. The default threshold is 0.80, with floors of 4 lines and 20 normalized nodes.

## The gate

Every run sweeps the whole codebase. Main passes the same gate, so anything a pull request trips over is its own doing. `exhale dry` compares against the merge base only to label findings:

| Label | Meaning |
| --- | --- |
| Introduced | The PR touched one side, and the pair didn't match at the base |
| Shifted | Neither side was touched, but the PR's changes moved the weights enough to push the pair over |
| Already there | The pair matched at the base too |

The report also lists what the PR contracted: pairs that matched at the base and don't anymore.

An existing app won't sweep clean on its first run. `exhale dry --introduced-only` gates on introduced and shifted findings and lists the rest as warnings. Once main is clean, drop the flag.

## The Contract

Deliberate duplication is a design decision, so it's declared in the Contract next to its reason. The Contract is organized by primitive, and each kind of analysis has its own file inside the primitive:

```text
contract/
  provider_adapter/
    README.md        the primitive's prose, plus a covers block
    duplication.md   duplication it keeps, why, and its settings
    complexity.md    complexity it keeps, why, and its floor
```

A `parallel` block declares units that stay parallel on purpose. Its reason is the section it sits in:

````markdown
## Adapters stay independent

Each provider adapter stays independent. Providers change on their own
schedules, and a shared base class would couple their releases.

```parallel
Payments::*::Adapter
```
````

A `covers` block in the primitive's `README.md` names the code that belongs to it, and a `settings` block in `duplication.md` overrides the defaults for that code:

````markdown
```covers
Payments::*::Adapter
views/payments/**
```

```settings
threshold: 0.75
min-lines: 6
min-nodes: 30
```
````

A clause that names code that no longer exists fails the gate, and so does a clause with nothing left to keep. The Contract stays true or the build stays red.

## In CI

```yaml
exhale:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0
    - uses: ruby/setup-ruby@v1
      with:
        bundler-cache: true
    - name: exhale
      shell: bash
      run: bin/exhale dry --base origin/${{ github.base_ref || 'main' }} | tee -a "$GITHUB_STEP_SUMMARY"
```

`fetch-depth: 0` gives `exhale dry` the history it needs to find the merge base and run `git blame`. `exhale dry --format json` prints the same findings as data, and `--format edn` prints them in the shape dryer writes to `.metrics/dry.edn`.

## exhale complexity

`exhale complexity` scores every Ruby method and Rails DSL body twice, at the head and at the merge base, and fails the pull request when a score rose past the floor. Absolute scores mostly track size and swing from team to team, so the gate judges the change. Code that was already complex passes until someone makes it worse.

The score is G. Ann Campbell's Cognitive Complexity (SonarSource, 2017). A method that reads straight down scores low however long it is. Each `if`, `unless`, ternary, loop, `case`, `rescue` and iterating block costs a point plus how deeply it's nested, so a branch inside a loop inside a block costs 3. An `elsif` or `else` costs 1, and so does each run of `&&` or `||` and a recursive call. Calls like `send`, `define_method` and `instance_eval` cost 1 each and are reported apart as metaprogramming. `contract/cognitive/README.md` writes down every rule, down to which blocks count as iterating.

| Label | Meaning | Gate |
| --- | --- | --- |
| Raised | The score rose and ends over the floor | fails |
| Introduced | A new unit scores over the floor | fails |
| Kept | The score rose past the floor and stays within a ceiling | passes |
| Contracted | The score fell | passes |
| Gone | The base unit has no match at the head | passes |

A method keeps its history when it moves to another file, and when it's renamed: an unmatched new unit is compared with an unmatched old one whose normalized shape scores 0.80 or more against it. Splitting a method passes as long as the method doesn't rise and every new piece ends at or under the floor.

The floor is 8. A primitive can set its own in `complexity.md`, and a `ceiling` block lets a unit go over the floor, up to its max, for the reason in the section it sits in:

````markdown
```settings
floor: 10
```

## The rate table stays one method

Splitting it scatters the regions across files.

```ceiling
max: 14
Billing::Rates#lookup
```
````

A ceiling that names no method or DSL body fails the gate, and so does one whose units all score at or under the floor again. A ceiling only loosens: a max under the floor changes nothing. `exhale complexity explain Billing::Rates#lookup` prints a unit's score with every point, its line and the construct that earned it. `--floor N` changes the report for a local run and leaves the exit code on the Contract's floors. `--format json` lists every unit with its score, metaprogramming points and label, and `--format edn` writes the entries crapper writes so uml-viewer can read them.

With no git repository or no merge base there's nothing to compare, so the run exits 0 and lists the units over the floor as warnings. In CI, run it beside `exhale dry`:

```yaml
    - name: exhale complexity
      shell: bash
      run: bin/exhale complexity --base origin/${{ github.base_ref || 'main' }} | tee -a "$GITHUB_STEP_SUMMARY"
```

## Determinism

The same commit gets the same verdict on any machine on any day. The verdict reads the commit's tree, its Contract, and the gem versions in its `Gemfile.lock`, and nothing else. Digests are unseeded, weights are fixed-point integers computed without the platform's floating-point log, and every tie breaks on a stable key.

## Narrowing a run

`exhale dry PATH...` reports only the findings with a location under those paths. A narrowed run still gates, on the findings inside its paths, and every path has to exist, so a typo like `exhale dyr` exits 2 instead of passing.

## How exhale holds itself to this

exhale has its own Contract in `contract/`: 82 numbered obligations across 13 primitives (source, unit, shape, fingerprint, matcher, sweep, gate, clause, report, revision, cli, cognitive and ratchet). Every obligation has at least one test that names it with a `# Contract: <primitive>/<id>` comment, and `rake contract` publishes contract coverage and fails while any obligation lacks an executable test. CI also runs `exhale dry` and `exhale complexity` on itself, reading that Contract.

The mutation gate runs every mutant [Mutineer](https://github.com/davidteren/mutineer) can make of `lib/` against the whole suite. Each one is either killed by a test or listed in `.mutineer.yml` with the reason no test can catch it: an equivalent mutant, an infinite loop, or a line Ruby's coverage can't see. `bin/mutate` runs it under Ruby 3.4. `bin/mutate --matrix` also names the tests that kill no mutant and the tests whose every kill another test also makes; it runs every covering test per mutant, so it is a separate, slower run and not part of the gate.

## Known limits in 0.1

- Duplication of intent, where the same idea is written with a different structure, is out of reach for structural matching.
- A whole method copied into another method as a nested `def` isn't reported when its body alone is under the size floors.
- Every run sweeps the head cold and caches only the merge base. The exact incremental sweep comes in 0.2.
- A run of statements copied more than 50 times is connected as a star from its widest copy, which can miss a near-copy that only matches another copy.

## License

MIT. Copyright Obie Fernandez.
