---
title: "Picking a static site generator for agent-written notes"
date: 2026-02-14
summary: "Hugo won for build speed and footprint; MkDocs Material and Quartz were close."
tags: [hugo, mkdocs, quartz]
---

## The contenders

Hugo (Go, single binary), Material for MkDocs (Python), Quartz (Node).
All three are actively maintained.

## Why Hugo won

- Same stack as the existing blogs, so operational knowledge transfers.
- Smallest build and serving footprint of the three.
- Pagefind adds build-time client-side search with no server component.
