# Report

The report is written for the agent doing the exhale, and for tools.

## Obligations

- **R1** Text names both sides of every finding with path, lines and identity, marks which side is the copy, and gives one hint.
- **R2** The header counts every label and every Contract error, and says clean only when the run exits 0.
- **R3** JSON carries the exhale and normalizer versions and the same findings as data. EDN uses dryer's candidate shape.
- **R4** The same result renders byte for byte the same.

- **R5** The complexity report names each failing unit with its path, lines and identity, its base and head scores, and the lines that earned the most points, worst first. It ends with a count of contracted units.
- **R6** Complexity JSON carries every scored unit with its score, its metaprogramming points and its label. Complexity EDN writes crapper's entry shape, `{:entries [{:name :namespace :complexity}]}`, so uml-viewer can read it.

```covers
Exhale::Report
```
