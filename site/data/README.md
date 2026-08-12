# `site/data/` — the site's source of truth

The site never hand-writes a capability claim. Everything the matrix renders
comes from here, and CI checks it against the repo:

| File | Holds | Checked by |
|---|---|---|
| `matrix.json` | every capability × platform cell, its evidence tag and footnote | `tools/site/check-matrix.mjs` vs the README table |
| `evidence.json` | the tag vocabulary (`E2E` … `dev`) and per-tag counts | derived from `matrix.json` |

Both land in **P3**. Until then the pages carry no capability claims at all,
which is why this directory is empty of data and not of intent.

Rule: if the README table and `matrix.json` disagree, the phase fails. The site
can never quietly out-claim the repo.
