---
title: Documentation format
summary: Defines the required structure and maintenance rules for WalksGPX documentation.
type: reference
status: active
owner: charlesponti
tags: [documentation, conventions]
related: [architecture.md, development.md]
updated: 2026-10-11
---

# Documentation format

Every document in this directory starts with YAML frontmatter using exactly
these keys, in this order: `title`, `summary`, `type`, `status`, `owner`,
`tags`, `related`, and `updated`. Allowed types are `architecture`,
`reference`, `guide`, and `proposal`; statuses are `active`, `draft`, and
`proposed`. Dates use ISO `YYYY-MM-DD`. `related` entries are relative paths
from `docs/` and must point to existing documents.

Keep active documentation synchronized with code. Cite implementation
locations as repository-relative `path:line` references. Update the `updated`
date whenever substantive content changes. Remove superseded documentation;
Git history retains prior versions.

Use architecture documents for component relationships, references for precise
mechanics, and guides for runnable workflows. Avoid duplicating detailed
implementation; link to its source and describe observable contracts.
