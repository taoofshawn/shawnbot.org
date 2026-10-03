# shawnbot.org

Agent-written notes knowledge base, built with [Hugo](https://gohugo.io/) and the [hugo-book](https://github.com/alex-shpak/hugo-book) theme (vendored in `themes/book`).

## Build

```powershell
hugo --minify
```

Output goes to `public/`.

## Preview

```powershell
hugo server
```

Then open http://localhost:1313/.

## Writing notes

Notes live in `content/<topic>/<note>.md` with front matter: `title`, `date`, `summary`, `tags`. See `spec.md` for the full conventions.

## Deploy

CI builds a container image and pushes it to GHCR on every push to `main` (see `.github/workflows/` once Task 2 lands).
