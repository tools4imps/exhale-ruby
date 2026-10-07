# Clause

Clauses are how a team declares deliberate duplication, the code each primitive owns, and its settings. This primitive reads them from a Contract like this one.

## Obligations

- **C1** Only `contract/<primitive>/README.md` (for `covers`) `contract/<primitive>/duplication.md` or `duplication/**/*.md` (for `parallel` and `settings`), and `contract/<primitive>/complexity.md` (for `ceiling` and `settings`) are read. Each check reads only its own files, and a block type in the other check's file is an error. A block in the wrong file (another Markdown file in a primitive, or a file at the Contract's root) is an error, and so is a symlink anywhere in the Contract.
- **C2** A clause keeps a pair only when the two units take different references. Each unit takes its most specific matching reference, and for a glob, its longest matching prefix.
- **C3** An empty `parallel` block is an error, and so is a reference that names no unit. A clause that keeps nothing is stale, and stale is an error. A clause added since the base is flagged in the report.
- **C4** A unit belongs to the primitive whose `covers` reference matches it most specifically.
- **C5** A pair takes the lower threshold and the lower size floors of its two primitives' settings, the settings that flag more. A malformed or repeated setting is an error.
- **C6** A fence inside an HTML comment isn't live. Matching a reference against a namespace takes time linear in their lengths, however many `**` segments the reference has.

```covers
Exhale::Contract
```
