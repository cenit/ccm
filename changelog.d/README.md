# changelog.d

One file per released `ModuleVersion`, named exactly after it: `1.38.0.md`.

**Every PR that changes `ModuleVersion` in `CCM.psd1` adds the matching file
here.** `Tests/CcmVersioning.Tests.ps1` fails the build otherwise, and fails it
the other way round too — an entry whose version is ahead of the manifest means
the bump was forgotten.

## Why this exists rather than a single CHANGELOG.md

To make a version collision **impossible**, not merely visible.

Three PRs once each branched from 1.35.0 and each bumped `ModuleVersion` to
`1.36.0`. All three merged with no conflict and no warning, and master ended up
calling three different trees 1.36.0. That is not a lapse anyone could have
caught by being more careful: **git reports a conflict only when the two sides
of a merge differ**, and all three sides had changed the same line to the same
string. Each merge resolved it silently, and correctly, by its own rules. The
one check everybody trusts to catch a collision is structurally blind to this
one.

A single `CHANGELOG.md` does not fix it either. Two PRs appending different
prose at the top of the same file usually conflict — but *usually* is the
problem, and a rebase that resolves "keep both" produces a file with two
entries for one version and a green build.

A file per version cannot do that. Two PRs bumping to the same number both
create `changelog.d/1.39.0.md` with different content, which is an **add/add
conflict**: git cannot merge it, no rebase silently resolves it, and whoever
hits it has to pick a different version. The collision stops being something to
detect and becomes something that cannot be committed.

The cost is one file per release, and it is deliberately a low bar — a heading
and a few lines. It is not release notes; it is a token that two PRs cannot
both hold.

## Format

```markdown
# 1.39.0

One line on what changed and, where it is not obvious, why.
```

## History

Entries begin at 2.0.0, the first release of the `CCM` module in this
repository. Earlier releases (`utils.psm1` up to 1.5.0) are in the git log, and
backfilling them would be inventing a record rather than keeping one.
