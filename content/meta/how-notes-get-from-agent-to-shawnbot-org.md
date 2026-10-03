---
title: "How notes get from agent to shawnbot.org"
date: 2026-10-03
summary: "How a markdown note becomes a live page: CI, GHCR, and Flux image automation."
tags: [hugo, flux, ci, github-actions]
---

## Writing

Notes are plain markdown files under `content/<topic>/` in the
[shawnbot.org repo](https://github.com/taoofshawn/shawnbot.org). An agent
creates them with the `notes-publisher` skill, which encodes the site's
conventions:

- Front matter: `title` (sentence case, becomes the H1), `date`,
  `summary` (one standalone sentence used in listings and search
  results), and `tags`.
- No `draft` field — anything committed to `main` publishes.
- Links between notes are relative (`../other-note/`), never wikilinks.
- The skill also requires a local `hugo --minify` build to pass before
  committing, so a broken note never reaches CI.

## Build and ship

A push to `main` triggers a GitHub Actions workflow that:

1. Builds the site with Hugo into a container running nginx.
2. Tags the image with a dated tag (`YYYYMMDD_HHMM`) plus `latest`.
3. Pushes both to `ghcr.io/taoofshawn/shawnbot.org`.

The build takes roughly 2–3 minutes.

## Deploy

A separate Flux repo holds the k8s manifests. An `ImageRepository` for
ghcr.io polls for new tags every 10 minutes; an `ImagePolicy` selects
the newest semver-ish dated tag. When it finds one, Flux's **Setters**
strategy rewrites the tag in the deployment manifest and commits it
back to the Flux repo, so the desired state in git always matches what
runs. Flux then syncs and rolls the `shawnbot-org` deployment in the
`external` namespace.

To skip the wait, annotate the ImageRepository to force an immediate
scan:

```sh
kubectl -n external annotate imagerepository shawnbot-org \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

Traffic reaches the cluster through cloudflared tunnels, so no ports
are exposed publicly.

## End to end

Typical timing: commit → live in about 3–15 minutes, dominated by
CI (~3 min) and the next Flux scan (up to 10 min). Faster local edits
can be checked with `hugo server` before pushing.
