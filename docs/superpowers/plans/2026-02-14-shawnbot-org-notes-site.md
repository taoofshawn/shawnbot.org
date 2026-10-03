# shawnbot.org Notes Site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the agent-notes knowledge base site per `spec.md`: Hugo + vendored hugo-book + Pagefind, CI-built container, Flux image automation to the `external` namespace, and a `notes-publisher` agent skill.

**Architecture:** Content repo (this repo) builds a static site with Hugo, indexes it with Pagefind, and packages it into an `nginx:1.27-alpine` container via GitHub Actions on every push to `main`. A separate FluxCD repo (`fluxcd-shawnkube`, on gitea) holds the Deployment/Service and Flux image-automation objects that poll GHCR every 10 minutes, commit the new tag back to the Flux repo, and roll the pods. cloudflared routes shawnbot.org to the service.

**Tech Stack:** Hugo Extended (≥0.158; local v0.167.0 via winget), hugo-book theme (vendored in `themes/book`), Pagefind (via npx/node 24), Docker multi-stage (alpine + nginx:alpine), GitHub Actions, Flux image-reflector/image-automation controllers.

**Spec:** `spec.md` (same repo) — decisions in §11 are locked; this plan implements §3–§10.

## Global Constraints

- All notes are **public**; no auth, no RSS.
- Theme is **hugo-book**, vendored (copied into `themes/book`), same vendoring style as shawndo.com's `themes/shawndo_2025`. No git submodules, no Hugo modules (keeps Docker build COPY-only).
- CI mirrors shawndo.com: push to `main` → docker build → push `ghcr.io/taoofshawn/shawnbot.org:YYYYMMDD_HHMM` + `:latest`.
- Runner image is `nginx:1.27-alpine`; target idle footprint: single-digit MB RAM, image well under 100 MB.
- K8s pod name/labels: deployment `shawnbot-org`, labels `app: shawnbot-org`, `role: standalone-web`, namespace `external`.
- Flux `ImageRepository` scan interval: **10m** (spec §7).
- Front matter template (spec §4): `title`, `date`, `summary`, `tags` — **no `draft` field**.
- Body line length < 80 chars, no web-font waterfalls (spec §8).
- Local Hugo binary in this session: `C:\Users\sdrew\AppData\Local\Microsoft\WinGet\Packages\Hugo.Hugo.Extended_Microsoft.Winget.Source_8wekyb3d8bbwe\hugo.exe` (referenced as `$hugo` below; in fresh shells plain `hugo` works).
- Docker daemon is not reachable from this machine (DOCKER_HOST=tcp://127.0.0.1:2375, nothing listening) — container verification happens via the GitHub Actions build, not locally.
- Flux repo: `C:\Users\sdrew\code\gitea\fluxcd-shawnkube` (gitea remote `git@gitea.shawndo.intra:sdrew/fluxcd-shawnkube.git`).

---

### Task 1: Scaffold Hugo site with vendored hugo-book and sample content

**Files:**
- Create: `.gitignore`
- Create: `hugo.toml`
- Create: `README.md`
- Create: `content/_index.md`
- Create: `content/homelab/_index.md`, `content/homelab/setting-up-ups-monitoring-with-nut.md`
- Create: `content/llm-tools/_index.md`, `content/llm-tools/agent-skills-for-recurring-work.md`, `content/llm-tools/picking-a-static-site-generator.md`
- Create (vendored): `themes/book/**` (from hugo-book latest release)

**Interfaces:**
- Produces: site builds with `hugo --minify`; content layout (`content/<topic>/<note>.md`) and front-matter template that Tasks 3 and 5 consume.

- [ ] **Step 1: Init git and create .gitignore**

```powershell
git init
```

`.gitignore`:

```
public/
resources/
.hugo_build.lock
```

- [ ] **Step 2: Vendor hugo-book theme**

Download the latest hugo-book release archive and extract it as `themes/book` (no `.git`, no `.github` inside):

```powershell
$resp = Invoke-RestMethod -Uri "https://api.github.com/repos/alex-shpak/hugo-book/releases/latest"
$tag = $resp.tag_name
"Latest hugo-book: $tag"
Invoke-WebRequest -Uri "https://github.com/alex-shpak/hugo-book/archive/refs/tags/$tag.tar.gz" -OutFile "$env:TEMP\hugo-book.tar.gz"
New-Item -ItemType Directory -Force -Path themes | Out-Null
tar -xzf "$env:TEMP\hugo-book.tar.gz" -C "$env:TEMP"
Move-Item "$env:TEMP\hugo-book-$($tag.TrimStart('v'))" themes\book
Remove-Item -Recurse -Force themes\book\.github -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\hugo-book.tar.gz"
```

Verify: `themes/book/theme.toml` and `themes/book/layouts/` exist.

- [ ] **Step 3: Create hugo.toml**

```toml
baseURL = 'https://shawnbot.org/'
languageCode = 'en-us'
title = 'shawnbot.org'
theme = 'book'

[params]
  # Pagefind (Task 3) replaces the theme's built-in fuse search
  BookSearch = false
  BookToC = true
  BookSection = '*'
```

- [ ] **Step 4: Create content files**

`content/_index.md`:

```markdown
---
title: Home
---

Notes on homelab, tooling, and whatever else is worth writing down. Use the
search in the sidebar or browse by topic.
```

`content/homelab/_index.md`:

```markdown
---
title: Homelab
summary: Servers, networking, Kubernetes, and everything running on them.
---
```

`content/homelab/setting-up-ups-monitoring-with-nut.md`:

```markdown
---
title: "Setting up UPS monitoring with NUT"
date: 2026-02-14
summary: "How Network UPS Tools are wired into the cluster so power events drain nodes cleanly."
tags: [nut, ups, kubernetes]
---

## Why NUT

The UPS is attached to the main host; everything else needs to know when the
power drops so VMs and nodes shut down in order.

## Setup

1. Install `nut` on the host with the USB driver.
2. Run `nut-webapi` so remote clients can poll battery status.
3. Point node shutdown scripts at the NUT server status.

## Gotchas

- The USB driver claims the device exclusively — only one server can talk to it.
- Test with `upsc ups@localhost` before wiring anything into shutdown hooks.
```

`content/llm-tools/_index.md`:

```markdown
---
title: LLM Tools
summary: Working with LLM agents, skills, and the workflows built around them.
---
```

`content/llm-tools/agent-skills-for-recurring-work.md`:

```markdown
---
title: "Agent skills for recurring work"
date: 2026-02-14
summary: "Encoding repeatable workflows as agent skills so agents stop rediscovering them."
tags: [llm, agents, skills]
---

## The idea

Anything done more than twice by an agent is a skill: a short markdown file
that tells the agent the workflow, the conventions, and the verification
steps.

## What belongs in a skill

- When to use it (trigger conditions)
- Exact commands and file paths
- What "done" looks like, in verifiable terms

## What does not

- Anything speculative — skills accrue complexity the same way code does.
```

`content/llm-tools/picking-a-static-site-generator.md`:

```markdown
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
```

- [ ] **Step 5: Verify the build**

```powershell
& "$hugo" --minify
```

Expected: build succeeds, `public/index.html`, `public/homelab/`, `public/llm-tools/` exist, no `ERROR` lines.

- [ ] **Step 6: Commit**

```powershell
git add -A
git commit -m "scaffold: hugo + vendored hugo-book + sample topics"
```

---

### Task 2: Dockerfile, nginx.conf, CI workflow, GitHub repo, first image

**Files:**
- Create: `Dockerfile`
- Create: `nginx.conf`
- Create: `.dockerignore`
- Create: `.github/workflows/docker-image.yml`

**Interfaces:**
- Consumes: Task 1's buildable site.
- Produces: `ghcr.io/taoofshawn/shawnbot.org:latest` + dated tags in GHCR — consumed by Task 6 (Flux image automation) and the existing `shawnbot-org` Deployment.

- [ ] **Step 1: Create Dockerfile**

```dockerfile
FROM alpine:3.22 AS builder

WORKDIR /src

# hugo from edge/community; node/npm for pagefind
RUN apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
    hugo \
    nodejs npm

COPY . .

RUN hugo --minify

# Pagefind indexes the built HTML into public/pagefind/
RUN npx --yes pagefind --site public

# Pre-compress text assets for nginx gzip_static
RUN find public -type f \( -name '*.html' -o -name '*.css' -o -name '*.js' \) -exec gzip -kf {} +

FROM nginx:1.27-alpine AS runner
COPY --from=builder /src/public /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf
```

- [ ] **Step 2: Create nginx.conf** (copy of shawndo.com's, identical pattern)

```nginx
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Compression
    gzip on;
    gzip_static on;  # serve pre-compressed .gz files
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_min_length 256;
    gzip_types
        text/html
        text/plain
        text/css
        text/javascript
        application/javascript
        application/json
        application/xml
        image/svg+xml
        font/ttf
        font/otf;

    # Security
    server_tokens off;

    server {
        listen 80;
        root /usr/share/nginx/html;
        index index.html;

        # Cache fingerprinted assets for 1 year
        location ~* \.(css|js)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }

        # Cache images for 30 days
        location ~* \.(jpg|jpeg|png|gif|ico|webp|avif|svg)$ {
            expires 30d;
            add_header Cache-Control "public, immutable";
        }

        # HTML: no-cache (content may change)
        location / {
            expires -1;
            add_header Cache-Control "no-cache, must-revalidate";
            try_files $uri $uri/ =404;
        }
    }
}
```

- [ ] **Step 3: Create .dockerignore**

```
.git
.github
public
resources
*.md
!README.md
```

- [ ] **Step 4: Create .github/workflows/docker-image.yml** (identical shape to shawndo.com's)

```yaml
name: build and push docker image
on:
  push:
    branches:
      - 'main'

jobs:

  build:

    runs-on: ubuntu-latest

    steps:
    - uses: actions/checkout@v4

    - name: login
      uses: docker/login-action@v3
      with:
        registry: ghcr.io
        username: ${{ github.actor }}
        password: ${{ secrets.GHCR_TOKEN }}

    - name: build and push
      run: |
        GHREPO=ghcr.io/${{ github.repository }}
        TAG=$(date +%Y%m%d_%H%M)
        docker build . --no-cache --file Dockerfile --tag $GHREPO:$TAG
        docker tag $GHREPO:$TAG $GHREPO:latest
        docker push $GHREPO:$TAG
        docker push $GHREPO:latest
```

- [ ] **Step 5: Wire the GitHub remote and set the token secret**

Repo already created by user: `git@github.com:taoofshawn/shawnbot.org.git`.

```powershell
git remote add origin git@github.com:taoofshawn/shawnbot.org.git
gh secret set GHCR_TOKEN --repo taoofshawn/shawnbot.org
# paste the same PAT shawndo.com uses (write:packages scope) when prompted
```

If `gh` is not authenticated (`gh auth status` fails), the user sets the secret via the GitHub web UI (Settings → Secrets and variables → Actions → New repository secret).

- [ ] **Step 6: Push and watch the first build**

```powershell
git push -u origin main
gh run watch --repo taoofshawn/shawnbot.org
```

Expected: run succeeds, `ghcr.io/taoofshawn/shawnbot.org:latest` and a dated tag exist (check the run log or `gh api /user/packages/container/shawnbot.org/versions`). If GHCR rejects the push, the PAT lacks `write:packages` — fix the secret.

---

### Task 3: Pagefind search page

**Files:**
- Create: `layouts/search.html`
- Create: `content/search.md`

**Interfaces:**
- Consumes: Task 1's site; `public/pagefind/` produced at Docker build (Task 2) and locally via `npx pagefind`.
- Produces: `/search/` page with Pagefind UI, linked from the book menu.

- [ ] **Step 1: Create layouts/search.html**

Inspect `themes/book/layouts/_default/baseof.html` first and reuse its partials so the page keeps the theme chrome:

```html
{{ define "main" }}
  <div class="markdown">
    <h1>{{ .Title }}</h1>
    <div id="search"></div>
  </div>
{{ end }}
```

Adjust the wrapper to match what baseof.html expects (read the theme source; if baseof requires a `<main>`-level structure, mirror `themes/book/layouts/_default/single.html` minus the TOC/menu).

- [ ] **Step 2: Create content/search.md**

```markdown
---
title: Search
layout: search
---
```

- [ ] **Step 3: Load the Pagefind UI only on the search page**

Append to `layouts/search.html` (inside the define block):

```html
{{ define "scripts" }}
  <link rel="stylesheet" href="/pagefind/pagefind-ui.css">
  <script src="/pagefind/pagefind-ui.js"></script>
  <script>
    window.addEventListener('DOMContentLoaded', () => {
      new PagefindUI({ element: "#search", showSubResults: true });
    });
  </script>
{{ end }}
```

If the theme's baseof does not define a `scripts` block, add the tags directly in the `main` block instead — PagefindUI init must run after the `<div id="search">`.

- [ ] **Step 4: Add a Search link to the menu**

Create `layouts/partials/docs/menu.html` only if the theme supports hook overrides; otherwise add to `hugo.toml`:

```toml
[menu]
[[menu.after]]
  name = "Search"
  url = "/search/"
  weight = 100
```

(Verify hugo-book renders `menu.after` in its sidebar; if not, check the theme's `docs/menu.html` partial for the supported bundle mechanism and use that instead.)

- [ ] **Step 5: Verify locally**

```powershell
& "$hugo" --minify
npx --yes pagefind --site public
# serve and check
npx --yes serve public
```

Open http://localhost:3000/search/ and confirm: Pagefind box renders, typing "UPS" returns the NUT note with its summary, clicking it navigates.

- [ ] **Step 6: Commit and push**

```powershell
git add -A
git commit -m "feat: pagefind search page"
git push
gh run watch --repo taoofshawn/shawnbot.org   # image rebuilds with search
```

---

### Task 4: Design pass with the frontend-design skill

**Files:**
- Create: `assets/_custom.scss` (hugo-book auto-concats this file if present)
- Modify: `hugo.toml` (only if the design plan requires params)

**Interfaces:**
- Consumes: Task 1/3's built site.
- Produces: custom typography/palette layered on hugo-book without forking the theme.

- [ ] **Step 1: Load the frontend-design skill and produce a design plan**

Invoke the `frontend-design` skill (installed at `.agents/skills/frontend-design/`). Produce its compact token plan for this brief — a personal engineering-notes site: color (4–6 named hex), type (typefaces + roles; self-hosted or system stack, no CDN waterfalls), layout (sidebar + content, line length < 80ch), principles (quiet, readable, nothing templated).

- [ ] **Step 2: Review the plan against the frontend-design anti-defaults checklist**

Explicitly check the plan against the skill's "AI-generated tells" list (warm-cream + terracotta, acid-green-on-near-black, all-caps eyebrows, middle-dot meta strings, etc.) and revise anything that reads as a default. Record what changed and why.

- [ ] **Step 3: Implement via assets/_custom.scss**

```scss
// Design tokens from the reviewed plan (final values from Step 1-2)
// Variables documented in themes/book/assets/_variables.scss
// e.g.:
// $body-font: ...;
// $color-link: ...;
```

Fill with the plan's actual tokens — font family/size/line-height for body and headings, palette overrides for links/accents, and the Pagefind UI styling (`:root { --pagefind-ui-*: ... }`) so the search box matches the site.

- [ ] **Step 4: Verify**

```powershell
& "$hugo" server
```

Check in a browser: readable at mobile width (375px) and desktop, body line length < 80ch, dark mode legible (emulate `prefers-color-scheme: dark`), search page styled consistently. Note anything hugo-book's SCSS variables can't express — if a structural change is genuinely needed, override the minimal template file into `layouts/` rather than forking the theme.

- [ ] **Step 5: Commit and push**

```powershell
git add -A
git commit -m "design: typography and palette pass"
git push
```

---

### Task 5: notes-publisher agent skill

**Files:**
- Create: `.agents/skills/notes-publisher/SKILL.md`

**Interfaces:**
- Consumes: content conventions (spec §4), build commands (Task 1), publish flow (spec §5–§7).
- Produces: the skill agents invoke for every note; Task 6's end-to-end test uses it.

- [ ] **Step 1: Write SKILL.md**

```markdown
---
name: notes-publisher
description: Create, edit, organize, and publish notes to shawnbot.org. Use when the user asks to research a topic and write it up as a note, or to update an existing note on the site.
---

# Publishing notes to shawnbot.org

This repo is a Hugo site. Notes are plain markdown under `content/`.
Anything committed to `main` is published: CI builds a container and Flux
rolls it out to https://shawnbot.org within ~15 minutes. There are no
drafts — do not add a `draft` field.

## 1. Deciding placement

1. List existing topics: `content/*/` (each is a top-level folder with an
   `_index.md` carrying a one-line `summary`).
2. Pick the best-fit existing topic. Create a new topic only if the note
   genuinely fits none. Prefer few, broad topics over many narrow ones.
3. Naming: topics are lowercase-hyphenated (`llm-tools`, `homelab`);
   note files are lowercase-hyphenated descriptive slugs
   (`picking-a-static-site-generator.md`).

## 2. Creating a note

Create `content/<topic>/<note-slug>.md`:

```markdown
---
title: "<Sentence-style descriptive title>"
date: <YYYY-MM-DD>
summary: "<One sentence shown in listings and search results.>"
tags: [lowercase, tags]
---

## <Section>

Body markdown. Links between notes use standard relative links
(`../other-note/`), never wikilinks.
```

Quality bar:
- **title** becomes the H1, the listing entry, and the search result
  title. Sentence case, descriptive ("How X works", "Fixing Y"), not
  "Notes on X".
- **summary** is what search results and listings display. Write it as a
  standalone sentence a reader can act on.
- One idea per note. If a note is drifting into two topics, split it.
- Update `date` semantics when editing an existing note: add
  `lastmod: <YYYY-MM-DD>` rather than changing the original `date`.

## 3. Verifying locally

```powershell
hugo --minify
```

Then spot-check `public/<topic>/<note-slug>/index.html` renders, links
resolve, and the topic `_index.md` listing looks right. If Hugo errors,
fix before committing — CI failures block publishing for every note.

## 4. Publishing

1. `git add` the note, commit with a message like
   `note: <note title>`, and `git push` to `main`.
2. Publishing is automatic: GH Actions builds the image (~2–3 min), Flux
   image automation picks up the new tag within 10 minutes and rolls the
   site. Optionally run `gh run watch --repo taoofshawn/shawnbot.org` to
   confirm the build succeeded.
3. Never commit secrets, credentials, or anything the user would not
   want public — the site is public.

## 5. Search hygiene

Pagefind indexes the built HTML. Titles, headings, and the first
paragraph dominate results — write them with the reader's search terms
in mind. The `summary` front matter matters most; do not leave it
template-shaped.
```

- [ ] **Step 2: Verify the skill is loadable**

Confirm the session/agent catalog picks up `notes-publisher` (same mechanism as `.agents/skills/frontend-design/`, which appeared after install). If it doesn't, compare directory layout with the frontend-design skill and fix.

- [ ] **Step 3: Commit and push**

```powershell
git add .agents/skills/notes-publisher
git commit -m "skill: notes-publisher"
git push
```

---

### Task 6: Flux image automation (fluxcd-shawnkube repo)

**Files:**
- Modify: `C:\Users\sdrew\code\gitea\fluxcd-shawnkube\clusters\shawnkube\external\shawnbot-org.yaml` (image line)
- Create: `C:\Users\sdrew\code\gitea\fluxcd-shawnkube\clusters\shawnkube\external\image-automation.yaml`
- Possibly modify: `gotk-components.yaml` / flux bootstrap args (Step 1)

**Interfaces:**
- Consumes: `ghcr.io/taoofshawn/shawnbot.org` from Task 2.
- Produces: automatic rollout of new `:latest` images; the last manual step in the publish flow disappears.

- [ ] **Step 1: Enable the image controllers**

Check what's running:

```powershell
kubectl -n flux-system get deploy
kubectl get crd -o name | Select-String image
```

The CRDs (`imagerepositories`, `imagepolicies`, `imageupdateautomations`) are absent. Re-run bootstrap with the extra components (idempotent — it reuses the existing repo/config):

```powershell
flux bootstrap git --url=ssh://git@gitea.shawndo.intra/sdrew/fluxcd-shawnkube.git --branch=main --path=clusters/shawnkube --components-extra=image-reflector-controller,image-automation-controller
```

First inspect how the current install was bootstrapped (`flux get all -n flux-system`, and check the GitRepository secret) and match its arguments; if the bootstrap re-run conflicts with the existing setup, instead apply the two controller manifests from the flux install manifest matching the installed Flux version, extracted with `flux install --components-extra=...` output.

Verify: `kubectl -n flux-system get deploy` shows `image-reflector-controller` and `image-automation-controller` Running.

- [ ] **Step 2: Inspect the GitRepository source and its credentials**

```powershell
kubectl -n flux-system get gitrepository -o yaml
```

Note the name and any `spec.secretRef`. The `ImageUpdateAutomation` in Step 4 needs **write** access to the gitea repo. If the existing deploy key is read-only, generate a new keypair, add the public key as a read/write deploy key in gitea, and create the secret in Step 4.

- [ ] **Step 3: Create image-automation.yaml** (in the `external` folder of the flux repo)

```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: shawnbot-org
  namespace: external
spec:
  image: ghcr.io/taoofshawn/shawnbot.org
  interval: 10m0s

---

apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: shawnbot-org
  namespace: external
spec:
  imageRepositoryRef:
    name: shawnbot-org
  filterTags:
    pattern: '^(?P<ts>\d{8}_\d{4})$'
    extract: '$ts'
  policy:
    alphabetical:
      order: asc

---

apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageUpdateAutomation
metadata:
  name: shawnkube-images
  namespace: flux-system
spec:
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: fluxbot
        email: flux@shawnbot.org
      messageTemplate: 'chore(images): update shawnbot.org to {{ range .Updated.Images }}{{ . }}{{ end }}'
    push:
      branch: main
  update:
    path: ./clusters/shawnkube/external
    strategy: Setters
```

Adjust `sourceRef.name` to the actual GitRepository name found in Step 2, and `git.secretRef` (add under `git:`) if write creds are needed. The dated tags `YYYYMMDD_HHMM` sort alphabetically = chronologically, so the alphabetical policy is correct.

- [ ] **Step 4: Point the Deployment at the policy**

In `clusters/shawnkube/external/shawnbot-org.yaml`, change the image line:

```yaml
          image: ghcr.io/taoofshawn/shawnbot.org:latest # {"$imagepolicy": "external:shawnbot-org"}
```

Keep the existing comment about the placeholder removed (the real image now exists).

- [ ] **Step 5: Register, commit, push, verify**

Add `image-automation.yaml` to `clusters/shawnkube/external/kustomization.yaml` resources (alphabetical position, matching the existing list style). Then:

```powershell
git -C C:\Users\sdrew\code\gitea\fluxcd-shawnkube add -A
git -C C:\Users\sdrew\code\gitea\fluxcd-shawnkube commit -m "flux: image automation for shawnbot.org (10m GHCR scan)"
git -C C:\Users\sdrew\code\gitea\fluxcd-shawnkube push
flux reconcile kustomization flux-system --with-source
```

Verify in order:
1. `kubectl -n external get imagerepository shawnbot-org` — `STATUS` shows a last-scan timestamp (proves GHCR is reachable; if it errors on auth, the GHCR package is private — make it public in GitHub package settings, matching the other sites).
2. `kubectl -n external get imagepolicy shawnbot-org` — shows `Latest image: ghcr.io/taoofshawn/shawnbot.org:<dated tag>`.
3. `kubectl -n flux-system get imageupdateautomation shawnkube-images` — last commit time advances; `git -C fluxcd-shawnkube pull` shows the automation's commit rewriting the deployment's tag.
4. `kubectl -n external rollout status deploy/shawnbot-org` — pods roll to the real image; `kubectl -n external get pods -l app=shawnbot-org` shows the new image ID.

---

### Task 7: End-to-end verification

**Files:**
- Create: one real note via the skill (content chosen at execution time from actual agent work)

- [ ] **Step 1: Run the skill end-to-end**

Using the `notes-publisher` skill, create a genuine note (not sample content) documenting something from this project — e.g. "How notes get from agent to shawnbot.org" in a `meta` topic — following §1–§4 of the skill exactly, including local `hugo --minify` verification.

- [ ] **Step 2: Publish and watch the full pipeline**

```powershell
git add -A; git commit -m "note: how notes get from agent to shawnbot.org"; git push
gh run watch --repo taoofshawn/shawnbot.org
# then wait for the 10m scan + rollout:
kubectl -n external rollout status deploy/shawnbot-org
```

- [ ] **Step 3: Confirm live**

`curl https://shawnbot.org/<topic>/<note-slug>/` returns 200 with the note content; search on https://shawnbot.org/search/ finds it; the new note appears in the sidebar under its topic.

- [ ] **Step 4: Clean up sample content (optional)**

If the real notes make the Task 1 samples redundant, delete them; keep the taxonomy honest. Commit `content: replace sample notes` if so.
