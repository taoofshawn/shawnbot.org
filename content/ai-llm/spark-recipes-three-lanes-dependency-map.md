---
title: "Three serving lanes, one fabric core: mapping what our switchless DGX Spark recipes actually share"
date: 2026-10-26
summary: "Our three 4-node switchless DGX Spark lanes look like three independent recipes with three inconsistent start/stop flows, but two artifacts — the fabric preflight and the four-PF NCCL build — are load-bearing for all of them, and they live inside the two GLM recipes. Runtime archiving is safe today; moving either GLM directory is not."
tags: [dgx-spark, switchless, nccl, glm, deepseek, vllm, sglang, recipe-management]
---

A strategy question came up about our `spark-recipes` repo: three switchless
4-node serving lanes, three different ways to start and stop them, and a
suspicion that the newest lane leans on the oldest one's code. The review below
is what the docs and the control scripts actually say. No files were changed.

## Verdict

The three recipes *are* discrete at runtime — but the repo has two
cross-recipe artifacts that are load-bearing for all three lanes, and one of
them lives inside the FP8 directory.

| Question | Answer |
|---|---|
| Can GLM-FP8 be archived (stop serving and maintaining it)? | Yes — the DeepSeek lane reads nothing from it at runtime |
| Can `glm-v53-flash-fp8-tp4-switchless/` be *moved* into `.archived/`? | **No, not without going first** — it holds the only copy of the shared fabric preflight and the netplan authority |
| Can both GLM recipes be archived? | Runtime yes; repo tooling no — the NVFP4 recipe holds the only reproducible build of the NCCL library all three lanes bind-mount |
| Does DeepSeek rely on "GLM FP8 code", or SparkRing? | Not on FP8's copy. It carries its own vendored SparkRing code. SparkRing is a third-party vendor (FujitsuPolycom), not FP8's code |

## 1. Why start/stop felt so different

The three lanes are three different upstream lineages with three different
control designs. Nothing was ever unified. This is a structural difference, not
a cosmetic one:

| | FP8 | NVFP4 | DeepSeek-V4.1 |
|---|---|---|---|
| upstream vendor | jnardiello `080fe09` | knapcio `770d115` | knapcio `aff52fa` |
| control | `tp4ctl status\|up\|down\|restart\|health` | `./start.sh serve\|stop\|status\|logs` | `site/start-cluster.sh` → wraps upstream `start.sh` |
| deployment model | 3-tier: repo → `deploy.sh` pushes to `~/.local/tp4` → container assembled at launch | 1-tier: `start.sh` renders env + `docker run`s directly | 1-tier + a **site wrapper** that envsubst-renders `env.switchless` into the head's stack dir, then execs the launcher |
| teardown semantics | `down` cycles all ranks | `stop` **preserves** containers → relaunch needs manual `docker rm` | `stop` removes stopped containers, **rank 0 first** (worker-joins-dead-head hazard) |
| config source of truth | `upstream/cluster.env` + `deploy.sh`; generated mirrors are gitignored (stale-config trap) | `site/env.switchless` → `.env` | `site/env.switchless` → rendered `.env.tp4-switchless` on the head |
| boot to `/health` | ~10 min | ~7 min cold / 3–4 warm | ~8 min |

Only the outcome is uniform: four fixed nodes, port 8000, and one shared
model-name proxy (currently `BACKEND_MODEL=deepseek-v41-flash`,
`SPOOF_FROM=deepseek-v41-flash,glm-5.3-flash`). The switch hinge is the proxy
env plus whichever recipe you exec.

## 2. What is actually shared: three layers, and the coupling is all in layer 2

**Layer 1 — host state on the four Sparks.** Not in any recipe directory, and it
survives any repo archiving: `/etc/netplan/40-cx7.yaml` (the four-PF plan),
`~/.local/lib/nccl-patched-4pf` (`8de68def…`), the legacy 2-PF
`~/.local/lib/nccl-patched` (`afe5f486…`), the kernel/driver pins, the HF
caches, and the deployed stacks (`~/.local/tp4`, `~/.local/nvfp4-tp4`,
`~/.local/ds41f-miaai`).

**Layer 2 — repo tooling that manages layer 1.** This is where the recipes are
*not* discrete:

| artifact | lives in | who needs it |
|---|---|---|
| `verify-fabric-p2.sh` | **FP8**, `noswitch-prep/scripts/` | **all three lanes** — every README and the switch runbook call that exact path |
| `render-netplan.sh` + `cluster.env` (`FABRIC_P2_VIEWS=1`) + the generated per-node netplan | **FP8**, `upstream/scripts/` | all three — the preflight calls `render-netplan.sh --check` and diffs the live `/etc/netplan` against *FP8's* generated files |
| `site/nccl-4pf/build-4pf.sh` + four pinned patches | **NVFP4** | all three — the only reproducible build of the library everyone binds |
| `site/netplan/<node>/40-cx7.yaml` | **NVFP4** | a *second* copy of the same plan (diffed on all four nodes ignoring comments: content identical, only the explanatory header differs) |
| `site/env.switchless` cluster block | NVFP4 (canonical) | the DeepSeek env was copied from it — `IB_HCA`, `NCCL_HOST_DIR` and the ring flags verbatim |
| the 2-PF NCCL build recipe | **FP8**, `upstream/scripts/node/nccl/build.sh` | FP8's own rollback artifact only |

**Layer 3 — vendored upstream code.** Three fully separate trees, zero
cross-imports: no shell script in one recipe sources or references another's
code. The only non-doc cross-references are comments and the preflight path.

## 3. The SparkRing question

SparkRing is [`FujitsuPolycom/sparkring`](https://github.com/FujitsuPolycom/sparkring)
(Apache-2.0), a third-party project — not FP8's code. There are three
*independent* consumptions, which is why the distinction matters:

1. **The FP8 lane** vendors `third_party/sparkring-sircl/` (15 bundle files
   byte-identical to upstream `be2f6465`) and `third_party/sparkring-mhc/`. Its
   container image *is*
   `ghcr.io/fujitsupolycom/sparkring-glm53-sparkcache`, and its 2-PF rollback
   NCCL is SparkRing-patched 2.30.7.
2. **The DeepSeek lane's retired vehicle** — `upstream-sparkring-archive/` is
   SparkRing's own `deepseek-v41-flash-cycle` profile, adopted 2026-10-17 and
   archived 2026-10-26 in favour of knapcio's stack.
3. **The DeepSeek lane today** still carries SparkRing *code* that knapcio's
   tree vendored itself: `runtime/b12x/b12x/comm/roce_ring` (the path-aware
   RoCEnante, ported from SparkRing `f16b5f4` with three bounded fixes), plus
   the documented NCCL `switchless-cycle` / `skip-tree-pat` lineage.

So the DeepSeek lane's SparkRing reliance is real but self-contained: it
vendors SparkRing, it does not import FP8's copy. Archiving FP8 touches none of
it. And the shared four-PF NCCL is **othexmr's** patch stack (`94c2669` plus
four patches, one site-modified GID range) — not SparkRing, and not FP8's.

## 4. Archiving impact, concretely

**Archive meaning "stop serving and stop maintaining" (directories stay):**

- GLM-FP8 → nothing else breaks. Its only live role for the other lanes is
  documentation pointing at its tooling.
- GLM-NVFP4 → the DeepSeek runtime is unaffected, but you lose the reproduction
  recipe for the shared NCCL library and the second netplan copy.
- Both → DeepSeek keeps serving indefinitely on existing host state. Its next
  node reimage or NCCL rebuild would have no in-repo source.

**Archive meaning "physically move to `.archived/`":** three hard breaks, all
repo-side.

1. The DeepSeek README and the switch runbook hard-code the FP8 preflight path.
   The script also sources FP8's `noswitch-prep/cluster.env` and runs FP8's
   `render-netplan.sh --check` against FP8's generated files — so copying the
   script alone is not enough; it needs its config and expectations too.
2. `site/nccl-4pf/` disappears → no reproducible build for the transport
   artifact all three lanes run. The binary survives on the nodes; the
   provenance evaporates.
3. The only in-repo statement of what the fabric *should* look like disappears
   — FP8's generated files are the authority the preflight compares the live
   netplan against.

The asymmetry worth noticing: **FP8 and NVFP4 are mutually coupled.** FP8's
runtime now uses the four-PF library built by NVFP4's directory, and FP8's own
`cluster.env` is what generates the four-view netplan that the other two lanes
boot on. DeepSeek sits *downstream* of that pair: it consumes their contract
but contributes no tooling back. The real shape is a two-recipe fabric core with
a third lane riding on it.

## 5. Calibrating the reliability model

| working assumption | what the docs show |
|---|---|
| FP8 = very reliable, proven | Agreed on runtime hours (the E29→E36 stack, a 157-check `verify-node.sh`, a frozen `check-f0.py` identity baseline, rollback overlays). But it is also the **most-modified** lane: five upstream file edits, nine site scripts, kernel/driver holds, per-image invariants, a `GPU_MEM_UTIL=0.85` ceiling. Proven **and** the highest site-change surface — those are different risks |
| NVFP4 = faster, less proven, fairly reliable | Agreed, with a plus that is easy not to price in: its vendored tree is **pristine** (zero upstream mods, additions only) and it is the structural source of the shared transport. Shorter history, cleanest shape |
| DeepSeek = very new, completely unproven | Slightly harsh — it has bring-ups, gates, benches and a six-hour soak receipt on the *previous* vehicle. But it is the least settled: one vehicle swap already (MiaAI-Lab → knapcio, 2026-10-26), an open prefix-retention issue under active tuning, and the only lane whose control surface is a site wrapper around someone else's launcher |

"Proven" tracks runtime hours; "fragile" tracks site-change surface. Between FP8
and NVFP4 those two orderings are close to inverted.

## 6. Refactoring options

Ranked by cost and benefit, on the assumption that both GLM lanes eventually get
archived:

1. **Extract a `shared/` (or `ring-fabric/`) top-level directory.** This is the
   one change that actually decouples the lanes: move the fabric preflight, its
   `cluster.env`, and the NCCL 4-PF build directory out of the GLM recipes.
   Three items, no behaviour change, and it deletes every FP8/NVFP4 path
   reference from the DeepSeek docs. Then any single recipe can be archived
   cleanly. Caveat: the netplan *generator* is a vendored jnardiello file inside
   FP8's `upstream/`, so moving it would break the "vendored trees stay
   pristine, modifications documented in `VENDORED-AT.md`" convention — keep the
   generator where it is and share only its inputs (`cluster.env`) plus the
   generated expectations.
2. **Collapse the duplicate netplan truth.** FP8's generated files and NVFP4's
   static `site/netplan/` are byte-identical in content today. Pick one owner
   before it drifts; this is the most likely silent-failure seam in the repo.
3. **Retire by status, not by move, if zero risk is the goal.** Mark the GLM
   lanes `ARCHIVED-CANDIDATE` in their READMEs and keep them as reference — but
   only after (1). Otherwise the repo lands in the worst state: a directory that
   is never booted yet still load-bearing as "fabric authority", silently
   rotting its pins and SHAs while the docs still cite it.
4. **Do not bother unifying start/stop.** The teardown semantics genuinely
   differ (preserve-versus-remove containers, rank-0-first versus worker-first)
   because the upstreams differ. A common front-end would be cosmetic and would
   hide exactly the gotchas that cost boots today.
5. **If DeepSeek becomes the only surviving lane**, its own gaps are the
   priority rather than refactoring — prefix retention first, and it would then
   be the only lane with no independent fabric tooling, which (1) fixes
   preemptively.

## 7. Drift noticed along the way

- The repo `README.md` and `AGENTS.md` still describe "two active lanes"; the
  DeepSeek lane is missing from the repo map.
- The switch runbook still says the DeepSeek lane is "NOT YET brought up", while
  its research log has bring-ups, gates and a vehicle swap.
- The FP8 and NVFP4 READMEs still reference the old per-lane branch
  `glm-v53-flash-nvfp4-4x-noswitch`; everything is on `main` now.
- NVFP4's `materialize-weights.sh` falls back to
  `$HOME/glm53-flash-fp8-zai/chat_template.jinja`, a host path the FP8 recipe
  retired in its 2026-09-27 `$HOME` cleanup — so that fallback is already dead.
  Harmless, since it only fires if the NVIDIA snapshot lacks the template.
- The switch runbook's "each one cost a boot" section points at
  `site/build-engram-packed.sh`, which does not exist in the DeepSeek recipe (it
  is the launcher's `pack` subcommand) — a stale pointer in the worst place for
  one.