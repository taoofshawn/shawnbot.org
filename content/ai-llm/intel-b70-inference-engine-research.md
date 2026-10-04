---
title: "Qwen3.8-Flash-Next on an Intel Arc Pro B70: what Strata, TensorFold and the new specialized engines can actually do"
date: 2026-10-04
summary: "The 125B Qwen3.8-Flash-Next MoE really does run on a 12GB GPU — via Strata, whose experimental SYCL port already hit 70-78 tok/s decode on an Arc Pro B70. But the bigger surprise is on the B70 itself: 35B-A3B-class MoE models already clear 40 tok/s decode and 1000 tok/s prefill on plain llama.cpp SYCL. Evidence and caveats for both paths."
tags: [llm, intel-arc, b70, inference, llama-cpp, qwen, strata, tensorfold]
---

## The baseline and the bar

Measured on this machine (llama.cpp build b11146, SYCL backend, Windows 11, Arc Pro B70 32 GB):

| Model | Quant | Decode | Prefill |
|---|---|---|---|
| Qwen3.8-27B (dense, MTP head) | UD-Q4_K_M | 21.1 t/s | 309 t/s |
| Qwen3.8-27B (dense, MTP head) | UD-Q6_K | 21.3 t/s | 328 t/s |

The 27B Q6_K recipe also gets ~27 t/s with built-in MTP speculative decoding at temperature 0.
The bar to beat: **≥40 t/s generation and ≥1000 t/s prefill on a model at or above 27B**.

**Short answer after the research:** both targets are already being met on this exact card — not by a new engine, but
by **small-active-param MoE models on plain llama.cpp SYCL** (a 35B-total/A3B-active model does 52–101 t/s decode and
1157–3005 t/s prefill on B70s), and Strata's experimental SYCL port is the one credible path to the specific
Flash-Next model. Details and caveats below.

## What "Qwen3.8-Flash-Next" actually is

[Qwen/Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) (released 2026-08-26, an architectural
preview of Qwen4) is **not a smaller model than the 27B** — it is much bigger:

- **125B-parameter MoE** + a **51B n-gram embedding table** + a **4B MTP draft layer** (~354 GB in BF16);
  only **~6B parameters activate per token** across 24,576 experts (top-10 + 1 shared per layer).
- Hybrid attention: **Gated DeltaNet** (linear) in 3 of 4 layers, **Qwen Sparse Attention** in the rest;
  "gated residual" hyper-connections; native 262K context (YaRN-extendable toward 1M).
- Native multimodal (text/image/video via the Qwen3-VL ViT).
- License: `qwen-community-1.0` — **not Apache 2.0** like the 27B.

llama.cpp support (`qwen4exp` arch) was merged upstream on 2026-08-27 ([PR #27742](https://github.com/ggml-org/llama.cpp/pull/27742))
with **no new ggml ops**. I verified the local b11146 build (2026-09-23) contains the `qwen4exp` arch string in
`llama.dll`, so this build can already load the GGUFs — but there are **no known reports of the SYCL backend running
the qwen4exp graph** (the PR was tested on CPU/CUDA/Metal). Known llama.cpp gaps for this arch: the MTP draft layer is
**not used yet** (`--spec-type draft-mtp` OOMs), and no KVarN KV quant exists (q8_0 KV + flash-attn is the practical best).

GGUFs: [unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF) (UD-IQ1_S ~72.5 GB up
to UD-Q6_K_XL ~169 GB, Q8_0 ~188 GB), [bartowski](https://huggingface.co/bartowski/Qwen3.8-Flash-Next-GGUF) (standard
names), and [ISTA-DASLab's GSQ-RCO builds](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF) (Q2_0
66.4 GB … IQ3_S 83.6 GB, plus a pruned **"Coder"** variant with half the experts removed — 29.6 GB, 91% of full
SWE-bench Verified). Even the smallest quants **cannot fit in 32 GB VRAM**; every size needs system-RAM offload, so
**RAM capacity, not VRAM, is the gating resource**.

## The 12 GB claim, verified

[Strata](https://github.com/Niko1221/Strata) (MIT, ~v0.1.39 this week) is a C++ engine built around exactly one model
family — Qwen3.8-Flash-Next — using parts of llama.cpp/ggml. Its README benchmark (RTX 5070, **12 GB VRAM**, Ryzen 5
7600, **64 GB RAM**):

| Quant | Decode | Prefill |
|---|---:|---:|
| Q2_0 | **94 t/s** | **2,650 t/s** |
| IQ2_XS | 79 t/s | 2,090 t/s |
| IQ3_XXS | 62 t/s | 1,750 t/s |
| IQ3_S | 53 t/s | 1,620 t/s |
| Coder | 55 t/s | 2,180 t/s |

The trick is not a small model and not just quantization — it is a memory hierarchy ([How it works](https://github.com/Niko1221/Strata/blob/main/docs/HOW_IT_WORKS.md)):
the hottest experts live in VRAM, **all experts are pinned in system RAM** (the CPU computes uncached ones in parallel
with the GPU), and a 28.8 GB n-gram lookup table streams from SSD. Each extra GB of VRAM caches ~700 more experts.
That's why "12 GB GPU" is true but incomplete: **12 GB+ VRAM and 48–64 GB of fast RAM** is the real requirement
(32 GB RAM only fits the pruned Coder build). An independent test on a 5070-Ti laptop (12 GB, 64 GB RAM): 51 t/s
decode at 43K context, 1,500 t/s prefill, 11 GB VRAM used.

## Strata on Intel Arc: the one real port

Officially Strata supports CUDA (RTX 20/30/40/50) and HIP (RX 7900/9070/6800/6900 class), Windows or Linux, one
request at a time by default. No Vulkan. But **v0.1.39 ships an experimental Intel Arc SYCL port**
([docs/INTEL_ARC.md](https://github.com/Niko1221/Strata/blob/main/docs/INTEL_ARC.md), written by community member
maxfridbe in [PR #423](https://github.com/Niko1221/Strata/pull/423)). Reported results on real Arc hardware
(community, earlier port versions):

| Hardware | Result |
|---|---|
| **Arc Pro B70 (32 GB), Ubuntu 24.04** | Coder IQ1_M: **70–78 t/s decode, ~790 t/s prefill**; IQ2_XS: 51–64 t/s; 256K context |
| 2× Arc Pro B70 (`--layer-split`) | Flash-Next IQ3_XXS: 66 t/s decode, 394 t/s prefill |
| Arc Pro B50 (16 GB) | Coder IQ1_M ~23 t/s; IQ2_XS ~25–27 t/s |
| Arc B580 (12 GB, WSL2) | IQ2_XS ~21 t/s; Coder ~15 t/s; device loss seen |

**Caveats, all significant:**

- **Linux only, built from source** (oneAPI DPC++ + oneMKL, ~5 GB install; optional AOT compile for `bmg-g31` = Arc
  Pro B70). No Windows build path exists; WSL2 card detection is broken.
- The Strata maintainers own no Arc: the 0.1.39 port is compile-checked and kernel-tested on a CPU, but **nobody has
  run the 0.1.39 port on an Arc yet** — the B70 numbers above are from earlier versions, self-reported.
- Stability is rough: a B580 tester saw GPU device loss; over-allocating VRAM on the `xe` driver can stall the machine;
  a known hang (#667) affects the expert-mirroring path used when experts don't fit VRAM; `SYCL_CACHE_PERSISTENT=0` is
  required (the same Xe2 JIT-cache crash llama.cpp documents).
- The B70 results are on **1–3-bit quants** of a 125B model — a real quality trade against the 27B Q6_K running fully
  in VRAM today.

## TensorFold and the rest: CUDA/Metal only

[TensorFold](https://github.com/ashhart/TensorFold) ([site](https://tensorfold.dev/), Apache-2.0 from v0.6.0, first
released late Sept 2026) serves an OpenAI-compatible endpoint with **exact speculative decoding** — drafted tokens are
verified byte-identical to serial decoding — and ships custom kernels per model family (Qwen3.8-27B, Flash Next,
GLM-5.3-Flash, Nemotron 3.5 Lightning, Gemma 4 26B-A4B, DeepSeek-V4-Flash). Backends: **MLX (Apple Silicon) and CUDA
only**, and CUDA requires **compute capability ≥ 8.9** — even RTX 30 cards are refused. No Intel, AMD, Vulkan, or SYCL
path of any kind. Reported speeds are strong (Nemotron 30B-A3B at 188–206 t/s on M5 Max; GLM-5.3-Flash ~50 t/s vs
~21–23 on vLLM across 2× DGX Spark per [NVIDIA forum users](https://forums.developer.nvidia.com/t/who-has-tested-tensorfold/384789)),
but none of it is reachable from Arc.

The same picture across the current wave of "engine built for one model" projects:

| Engine | Backends | Model focus | Arc? |
|---|---|---|---|
| [Splash](https://github.com/incoai/splash) (Inco AI) | Metal only | Qwen3.8-27B, Qwen3.6-35B-A3B, Bonsai 2 | No |
| [NInfer](https://github.com/Neroued/ninfer) | CUDA, RTX 5090 only | Qwen3.5/3.6 dense+MoE (claims 15,544 t/s prefill, ~700 t/s decode) | No |
| [HyperQwen](https://github.com/syv-ai/HyperQwen) | CUDA (vLLM patches) | Qwen3.8-27B: 127 t/s single-stream on a 3090 | No |
| [DGPP](https://forums.developer.nvidia.com/t/dgpp-a-gb10-optimized-c-cuda-inference-engine/383406) | CUDA/GB10 | DGX Spark models | No |
| [MTPLX](https://www.mtplx.com/) / [oMLX](https://github.com/jundot/omlx) | MLX only | Qwen MTP-head decoding on Macs | No |

The pattern is consistent: this specialization wave wins by hand-tuning kernels for one model family on one vendor's
toolchain, and every one of them picked Metal or CUDA.

## The part nobody's posting about: the B70 already meets both targets — with MoE models

Two community benchmark repos are the references here: [PMZFX/intel-arc-pro-b70-benchmarks](https://github.com/PMZFX/intel-arc-pro-b70-benchmarks)
(Linux, SYCL, `GGML_SYCL_F16=ON`) and [jeffgrover/b70-setup](https://github.com/jeffgrover/b70-setup) (B70 over USB4
eGPU, Ubuntu, oneAPI 2026.1, builds b10356→b11337). Their measured numbers, all llama.cpp SYCL:

| Model (≥27B) | Quant | Decode | Prefill (pp512) |
|---|---|---:|---:|
| Agents-A1 35B-A3B (hybrid MoE) | Q4_K_M | **81.6–101 t/s** | 1140 t/s |
| Qwen3.6-35B-A3B | UD-Q4_K_M / UD-Q4_K_S | **54.7–78.9 t/s** | 615–1157 t/s |
| Nemotron 3.5 Lightning 30B-A3B | Q4_K_S | **58.6 t/s** | 1062 t/s |
| Gemma4 26B-A4B (MoE) | Q4_K_M | **52.6 t/s** | 1129 t/s |
| Qwen3.8-27B (dense) + MTP, 3 drafts | Q4_K_S | **~50 t/s** short-context | 836–839 t/s |
| Qwen3.5-27B (dense, no MTP) | Q4_K_M | 20.4 t/s | 718 t/s |

So: **40+ t/s decode on ≥27B is demonstrated today** — via MoE (52–101 t/s, all fitting a 32 GB card at Q4) or via
dense-27B + MTP speculative decoding (~30–50 t/s). And **1000+ t/s prefill** is cleared by every MoE row and by a dense
27B with tuned batching: jeffgrover measured **1068–1071 t/s @8K** on Qwen3.8-27B Q4_K_S with `-DGGML_SYCL_F16=ON` and
`-b 4096 -ub 1024` (+18–34% prompt processing vs default batching). The fp32-accumulation portable build used in this
repo (~328 t/s) is far below what the same card does with an F16-accum build.

Why dense decode stays stuck near ~21–27 t/s: per [issue #26581](https://github.com/ggml-org/llama.cpp/issues/26581),
ggml decode attention on Xe2 is memory-**latency**-bound (~21–25 ns per KV position per full-attention layer,
identical on Vulkan and SYCL) — decode also collapses with context depth on all ggml backends. The ways around it are
MTP/speculative decoding, MoE active-param reduction, or leaving ggml: Intel's `llm-scaler` **vLLM XPU** fork decodes
flat to 127K and does **prefill 2.4–15× faster** than llama.cpp SYCL (XMX flash attention + varlen batching; a dual
B70+B60 box did 1010 t/s prefill on a 27B dense). vLLM XPU is Linux/Docker-only and weaker on model coverage;
[IPEX-LLM is archived by Intel (Jan 2026)](https://github.com/intel/ipex-llm) — a dead end despite still-circulating
guides. LM Studio's bundled Vulkan path detects the B70 but decodes ~2–3× slower than SYCL.

Upstream llama.cpp work most likely to move these numbers further ([tracked by PMZFX](https://github.com/PMZFX/intel-arc-pro-b70-benchmarks/blob/master/upstream-contributions.md)):

- [PR #29864](https://github.com/ggml-org/llama.cpp/pull/29864) (open, B70-tested, Windows): **multi-column mul_mat_vec_q on XMX** —
  accelerates spec-decode verification; end-to-end MTP Qwen3.8-27B went Q4_K_S 38.7→**51.0 t/s**, Q8_0 32.4→43.1 in the PR's measurements.
- [PR #29357](https://github.com/ggml-org/llama.cpp/pull/29357) (open, Intel-authored): Vulkan Xe2 flash-attention prefill
  kernel — Qwen3.6-35B-A3B 2089→**3005 t/s** pp8192, dense 27B 659→932 t/s (Windows B70). Vulkan decode stays bad; this is a prefill lever.
- [PR #29245](https://github.com/ggml-org/llama.cpp/pull/29245) (open): SYCL grouped-MoE XMX GEMM.
- Landed in mid/late 2026 builds: oneMKL GEMM flash attention for prefill ([PR #25025](https://github.com/ggml-org/llama.cpp/pull/25025)),
  oneDNN-graph SDPA XMX attention ([PR #25222](https://github.com/ggml-org/llama.cpp/pull/25222) — up to ×4.26 prefill at p80k),
  Q8_0 reorder fixes, fused GDN/SSM kernels. ESIMD XMX attention in SYCL is shelved on an Intel IGC codegen bug — one reason vLLM keeps the prefill crown.

One caution for this repo's exact recipe: issue [#26581](https://github.com/ggml-org/llama.cpp/issues/26581) also
reports SYCL failing to allocate single weight buffers above ~16.5 GiB on some driver versions (Vulkan chunks
allocations; SYCL doesn't). The 20.5 GiB Q6_K runs here, but it sits above that reported ceiling — worth remembering
before any driver or build change.

## Bottom line

1. **The 40 t/s / 1000 t/s bar is already met on the B70 — no new engine required.** A 30–35B A3B-class MoE GGUF on
   the current llama.cpp SYCL stack (F16-accum build, tuned batching) does 52–101 t/s decode and 1062–3005 t/s
   prefill; a dense 27B with MTP reaches ~50 t/s short-context, and PR #29864 pushes that further. This is the
   cheapest path and it stays on Windows.
2. **Qwen3.8-Flash-Next specifically is a Strata-only proposition on Arc today.** Its experimental SYCL port already
   reported 51–78 t/s decode on Arc Pro B70 hardware — above the decode bar but below it on prefill (~790 t/s
   single-card) — and demands Linux + oneAPI source builds, 1–3-bit quants of a 125B model, 64 GB-class system RAM,
   and tolerance for a port nobody has validated on 0.1.39. The 12 GB headline is real but it is RAM offloading, not
   model smallness.
3. **TensorFold, Splash, NInfer, HyperQwen, DGPP, MTPLX: not viable on Intel** — hard-locked to Metal/CUDA (TensorFold
   also demands CUDA cc ≥ 8.9). The whole specialization wave is CUDA/Metal-only so far.
4. **If the research question is "what should this machine run next":** a Qwen3.6-35B-A3B or Nemotron-3.5-Lightning
   30B-A3B Q4 GGUF on an F16-accum SYCL build is the evidence-backed answer for "larger and much faster than the 27B
   Q6_K recipe"; Strata-on-Linux is the answer for Flash-Next itself.

*Unverified items:* Strata's B70 SYCL numbers are community-reported and self-measured (maintainers own no Arc);
llama.cpp SYCL support for the qwen4exp graph is untested publicly (the arch loads in this build — verified locally —
but no successful run has been reported); several speed figures come from author/vendor benchmark tables rather than
independent measurement; Reddit threads were corroborated only second-hand (Reddit's JSON API blocked direct fetching
during this research).
