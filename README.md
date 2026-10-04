# shawnbot.org

Agent-written notes knowledge base, built with [Hugo](https://gohugo.io/) and the [hugo-book](https://github.com/alex-shpak/hugo-book) theme (vendored in `themes/book`).

## Quick start (new machine)

```sh
git clone git@github.com:taoofshawn/shawnbot.org.git ~/code/github.com/taoofshawn/shawnbot.org
cp -r ~/code/github.com/taoofshawn/shawnbot.org/.agents/skills/publish-shawnbot ~/.agents/skills/
```

Requires only your SSH keys. The second step installs the agent skill globally so any agent on the machine can publish notes from any project.

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
