---
name: publish-shawnbot
description: Create, edit, organize, and publish notes to shawnbot.org. Works from any project — locates or clones the site repo itself. Use when the user asks to research a topic and write it up as a note, or to update an existing note on the site.
---

# Publishing notes to shawnbot.org

shawnbot.org is a Hugo site. Notes are plain markdown under `content/`.
Anything committed to `main` is published: CI builds a container and Flux
rolls it out to https://shawnbot.org within ~15 minutes. There are no
drafts — do not add a `draft` field.

## 0. Finding the repo (do this first, from any project)

This skill is global; the current working directory may be some other
project. All note work happens inside the shawnbot.org repo, not here.

1. If the current directory is already inside the repo (it has `hugo.toml`
   and a `content/` folder alongside a `themes/book/` folder), use it.
2. Otherwise look for the canonical clone:
   `~/code/github.com/taoofshawn/shawnbot.org`. If it exists, `git pull`
   it to get the latest notes and skill updates, then work there.
3. If it doesn't exist, clone it:
   `git clone git@github.com:taoofshawn/shawnbot.org.git ~/code/github.com/taoofshawn/shawnbot.org`
   (requires the user's SSH keys; no other credentials are needed to
   publish).

Every path and command below is relative to that repo root.

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

```sh
hugo --minify
```

If `hugo` is not installed, install Hugo Extended first (Windows:
`winget install Hugo.Hugo.Extended`; macOS: `brew install hugo`) and use
the full path if it is not on PATH.

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

## 6. Keeping the global skill fresh

The copy of this skill inside the repo (`.agents/skills/publish-shawnbot/`)
is canonical. After cloning or pulling the repo, sync the installed
global copy so behavior stays identical everywhere:

```sh
cp .agents/skills/publish-shawnbot/SKILL.md \
   <global-skills-dir>/publish-shawnbot/SKILL.md
```

`<global-skills-dir>` is the skills directory the local agent harness
reads at startup (for example `~/.agents/skills/` — this project uses
`~/.agents/skills/publish-shawnbot/SKILL.md`).
