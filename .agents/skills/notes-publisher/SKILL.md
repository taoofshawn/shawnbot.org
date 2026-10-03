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
