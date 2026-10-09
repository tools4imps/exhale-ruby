# Source

Source decides which files a sweep reads. Everything after it trusts the list.

## Obligations

- **S1** Ruby files (`*.rb`) and HTML ERB templates (`*.html.erb`, `*.html+variant.erb`, `*.turbo_stream.erb`) are compared. No other file is.
- **S2** Nothing under `db/` or `config/` is compared, at the root or one level under `engines/`, `packs/`, `components/` or `gems/`. Neither is anything under `vendor/`, `node_modules/`, `tmp/`, `log/`, `coverage/`, `public/`, `storage/`, `bin/`, `app/assets/builds/`, or a directory whose name starts with a dot.
- **S3** Tests are left out unless the run asks for them: any `spec/` or `test/` segment, and files ending `_spec.rb` or `_test.rb`. Tests should be DAMP, not DRY.
- **S4** A file is skipped as generated only when one of its first five lines is a comment that starts with a generated-code header. A comment that merely mentions generation doesn't count.
- **S5** Symlinks are never followed, in source or in the Contract.
- **S6** The list is sorted. At the head it's the files git tracks plus the untracked files git doesn't ignore. A tracked file the working tree has deleted is left out, as the change the author is making. A sparse checkout, which hides files the commit holds, is an error instead (gate/G2).
- **S7** `.exhale.yml` may declare an `ignore` list of glob patterns. Matching source files are left out at the head and merge base; malformed settings and symlinks are errors.

```covers
Exhale::SourceFiles
```
