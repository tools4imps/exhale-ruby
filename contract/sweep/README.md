# Sweep

A sweep reads one tree end to end: its units, its Contract and every match. The check runs one sweep at the head and one at the merge base.

## Obligations

- **W1** Every run sweeps the whole codebase at the head.
- **W2** The base sweep is cached under a key that covers everything that can change it: the base SHA, the exhale, normalizer, prism and herb versions, the parse-tree depth limit, whether tests are included, where the app sits in its repository, the Contract's directory, and any flag overrides. The cache is plain JSON, checked field by field on read; anything malformed, of the wrong shape, or reached through a symlink is rebuilt rather than trusted.
- **W3** Candidates are generated at the loosest settings any primitive asks for, so no primitive's pairs are missed.

```covers
Exhale::Dry::Sweep
Exhale::Dry::Check
```
