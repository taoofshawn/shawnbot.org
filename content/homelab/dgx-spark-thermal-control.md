---
title: "DGX Spark thermal control: why the CPU runs hotter than the GPU, and what to do about it"
date: 2026-10-14
summary: "The GB10's CPU-outpacing-GPU temperatures come from a performance-pinned CPU governor and a GPU-temperature-driven fan curve; fan override via the EC, schedutil, and SoC power caps fix it better than more GPU downclocking."
tags: [dgx-spark, gb10, thermal, cooling, fans, cpufreq, nvidia]
---

Two-node DGX Spark (GB10) cluster, both nodes idling at 82–83 °C on the SoC
ACPI zones while the GPUs sit at 62 °C and ~25 W. This note is the research
write-up behind that snapshot: why it happens, what control surfaces the
machine actually exposes, and which levers are worth pulling, ranked. It
pairs with [Cooling a DGX Spark with an External 120 mm Fan](../dgx-spark-external-fan-power-and-control/)
(hardware/ambient cooling) — this one covers the software side. Everything
below was gathered read-only: no host was modified, and conflicting sources
are flagged inline.

**Bottom line:** the CPU-hotter-than-GPU symptom has a two-part root cause,
and the best fix is not more GPU downclocking — it's fan + CPU-frequency
control.

## Root cause

1. **NVIDIA ships the CPU pinned at max clock.** A stock service,
   `nv-cpu-governor.service`, runs `cpupower frequency-set -g performance`
   at boot, so all 20 cores stay pegged (A725 cluster: 2.808 GHz; X925
   cluster: 3.9 GHz) even when idle. Measured on the nodes: `gov=performance`,
   `cur=2808000/3900000` on every policy, boost already off
   (`/sys/devices/system/cpu/cpufreq/boost` = 0).
2. **The stock fan curve is driven primarily by GPU temperature** — a forum
   finding from the exact same situation (two-node Spark, CPU 92–95 °C on
   the head node, "GPU underclocking caused such low GPU temperature that
   the CPU was starved of cooling"). GPU downclocking helps total power but
   can *reduce* CPU cooling, because both share one heatsink weighted toward
   the GPU ([t/381549](https://forums.developer.nvidia.com/t/381549)).

Measured read-only snapshot (2026-09-05, both nodes idle, GPU ~25 W):

- SoC ACPI zones: head 82.7 °C, worker 80.9 °C; GPU 62 °C on both. Critical
  trip on zone0: **104.8 °C**.
- No `nvpmodel`, no `nvfancontrol`, no fan pwm/hwmon node, no GPU power
  limit (`nvidia-smi -pl` unsupported: N/A), no CPU power telemetry, no BMC.
  DGX OS 7.2.3 / OTA 7.5.0, kernel `6.17.0-1031-nvidia`, driver `580.173.02`.

## Available control surfaces (verified on the hosts)

| Knob | Status | Notes |
|---|---|---|
| CPU governor / freq (cpufreq) | fully exposed | `cppc_cpufreq`, 6 governors, root-writable `scaling_*`, plus `auto_select`, `min_perf`/`max_perf` (present in 6.17), `scaling_setspeed` (active under the `userspace` governor) |
| GPU clock lock `nvidia-smi -lgc` | supported (already in use) | Confirmed by an NVIDIA engineer (`sudo nvidia-smi -lgc 208,2418`); community reports `-lgc 0,2000` ≈ half power at similar tok/s. The gb10-experiments tuning guide claims `-lgc` is unsupported, but driver-580 experience and [t/360631](https://forums.developer.nvidia.com/t/360631) say it works. Worth confirming the lock is actually active after each reboot. |
| GPU power limit `-pl` | unsupported | `Power Limit: N/A` on GB10 |
| `nvpmodel` power modes | Jetson-only | Not on Spark — NVIDIA: "power management is different than the 72-core Grace CPU" ([t/360631](https://forums.developer.nvidia.com/t/360631)) |
| Fan control (stock) | none | NVIDIA: "There is no method to control fan speed" ([t/360020](https://forums.developer.nvidia.com/t/360020)) |
| Fan control (community) | `dgx-spark-fan-override` | EC command 5 via FF-A eSPI; `arm-ffa-17` exists on both FE units; sysfs knob `/sys/bus/arm_ffa/devices/arm-ffa-17/fan` (`max` / `auto`) |
| SoC power caps (community) | `antheas/spark_hwmon` | PL1/PL2/SysPL1/SysPL2 `power_cap` — the only OS-level power-capping path |

## Ranked options, each with evidence

**1. Fan override — best ROI for this specific problem.**
[Z841973620/dgx-spark-fan-override](https://github.com/Z841973620/dgx-spark-fan-override)
([t/380995](https://forums.developer.nvidia.com/t/380995)) is a DKMS module
that drives the EC's existing command 5 through the SoC's FF-A eSPI service.
Two fans: fan0 1260–9000 RPM, fan1 1890–13500 RPM; the EC picks the higher
of two temperature sensors. A community user-space controller driving the
module measured **9000 RPM as the efficiency sweet spot** — hottest zone
86.2 → 81.7 °C (GPU −3.4 °C too) for ~+2.1 W of fan power — and recommends
the curve `auto <70 °C, 7000 @70, 9000 @80, 11000 @86, 13500 @90`.

Caveats: needs Secure Boot MOK signing; it writes volatile EC SRAM, so the
override reverts on power cycle — wrap it in a boot service; the mailbox
address is hardcoded for the NVIDIA Founders Edition (fine here, but check
before using on an OEM variant); long-term fan wear is unknown; and it sets
an override, not a curve — a wrapper has to do the ramping.

**2. CPU downclocking — real, with one known wrinkle.** Fully exposed on
this kernel:

```bash
# Runtime A/B (survives until reboot — nv-cpu-governor re-pins performance at boot)
# Load-based instead of always-max:
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  echo schedutil | sudo tee $p/scaling_governor
done
# Or cap the hot X925 group (cores 5-9, 15-19) to 2.8 GHz:
for i in 5 6 7 8 9 15 16 17 18 19; do
  echo 2800000 | sudo tee /sys/devices/system/cpu/cpufreq/policy$i/scaling_max_freq
done
# Make it permanent — don't just overwrite the service, systemd restores it:
sudo systemctl mask nv-cpu-governor.service   # or a drop-in changing ExecStart to schedutil
```

Wrinkle: forum users report pinning is **flaky on NVIDIA FE units** —
`scaling_max_freq` caps sometimes don't hold, and `cpuinfo_cur_freq` readback
is misleading ([t/367604](https://forums.developer.nvidia.com/t/367604),
[t/362513](https://forums.developer.nvidia.com/t/362513)). On DGX OS 7.4+ /
kernel 6.17, the reported working combo is `userspace` governor +
`scaling_setspeed` + `auto_select=0`, verified with `perf stat` (not
`cpuinfo_cur_freq`; NVIDIA's own guidance is to check `cpuinfo_avg_freq`).
So: validate every change with `perf stat` or `cpuinfo_avg_freq`, and treat
any single method as unproven until measured. `schedutil` alone is likely
the 80/20 win — it stops idle cores sitting at 3.9 GHz, and the 82 °C
*idle* temperature is largely exactly that.

**3. SoC power caps — the most direct "cap the heat budget" lever.**
[antheas/spark_hwmon](https://github.com/antheas/spark_hwmon)
([t/360631](https://forums.developer.nvidia.com/t/360631)) exposes
`power_cap` on `pl1/pl2/syspl1/syspl2` (e.g.
`echo 100000000 | sudo tee /sys/class/hwmon/hwmonN/power11_cap`, where `0`
restores the EC default), plus PROCHOT state, per-domain power/temperature
telemetry and fan speeds. Caveats: community/"vibe-coded", the SPBM ABI is
still shifting (update EC firmware via `fwupdmgr` first), needs MOK signing,
and per-E/P-core controls are currently non-functional. It is also the only
way to get CPU power telemetry at all — which matters, because the open
question is whether it's the cores or the LPDDR5X/SoC fabric driving CPU
temperature; if it's the fabric, a power cap beats a frequency cap.
(`powertop` exists on the head node for corroboration.)

**4. GPU: stay with `-lgc`, but watch the fan interaction.** Keep 2000 MHz,
matching the community `-lgc 0,2000` result (~half power, near-identical
tok/s). But per the root-cause mechanism above, going *lower* may raise CPU
temperature via fan starvation on the shared heatsink — so pair any GPU
clock change with the fan override and measure both temperatures. The
`glm-v53-flash-4x-noswitch` recipe repo also documents the `-lgc` power-state
trap: apply `nvidia-smi -lgc <max>` on **both** nodes of a pair.

**5. Hardware/ambient — highest community confidence, zero software risk.**
Single heatsink shared CPU+GPU, weighted toward the GPU
([t/365302](https://forums.developer.nvidia.com/t/365302)). Real reports:
replacing/adding a fan (Arctic P12 Pro, 3000 RPM), an external exhaust fan,
repasting, 3D-printed housings (note: the outer shell is part of the
heatsink design). Official operating ambient is 5–30 °C (140 W TDP, 240 W
PSU) per [NVIDIA's hardware docs](https://docs.nvidia.com/dgx/dgx-spark/hardware.html).
The hardware side is covered in depth in
[the external-fan note](../dgx-spark-external-fan-power-and-control/).

**6. Ops guardrails.** `sudo nvidia-smi -pm 1` for persistence mode (also in
the gb10-experiments tuning doc); pause or degrade serving at CPU > 91 °C —
the community pattern from a real shutdown incident
([t/358280](https://forums.developer.nvidia.com/t/358280)). `thermald` and
OPP editing have no user-accessible path on Spark.

## Suggested experiment

To run on the nodes — the research itself was read-only. With the serving
stack up (warm), record: `sensors` (acpitz zones),
`nvidia-smi --query-gpu=temperature.gpu,clocks.sm,power.draw`, fan RPM (only
visible via `spark_hwmon` after install) and tok/s. Then A/B in this order:

1. (a) baseline GPU `-lgc 2000`
2. (b) + `schedutil` governor
3. (c) + X925 cap 2.8 GHz
4. (d) + fan override 9000 RPM
5. (e) + SysPL1 cap

Watch zone0/zone4 specifically — those are the 90 °C culprits. Expect (b)
to shave idle temperatures fastest and (d) to be the strongest load-side
lever.

## Sources

- [t/381549 — GPU underclock warning, CPU 92–95 °C, GPU-temp-driven fan, shared heatsink](https://forums.developer.nvidia.com/t/381549)
- [t/380995 — fan override / EC command 5, 9000 RPM sweet spot (−4.5 °C)](https://forums.developer.nvidia.com/t/380995) · [repo: Z841973620/dgx-spark-fan-override](https://github.com/Z841973620/dgx-spark-fan-override)
- [t/367604 — CPU frequency pinning on FE; `auto_select` / `userspace` + `scaling_setspeed` on 6.17](https://forums.developer.nvidia.com/t/367604)
- [t/362513 — frequency pinning flakiness follow-up](https://forums.developer.nvidia.com/t/362513)
- [t/360631 — no CPU power telemetry per NVIDIA; antheas's SPBM driver + `-lgc` support](https://forums.developer.nvidia.com/t/360631) · [repo: antheas/spark_hwmon](https://github.com/antheas/spark_hwmon)
- [t/360020 — NVIDIA: no fan control method](https://forums.developer.nvidia.com/t/360020)
- [t/358280 — shutdown incident, 91 °C pause threshold](https://forums.developer.nvidia.com/t/358280)
- [t/365302 — Dual Spark Ducted Cooling Cage thread, shared-heatsink details](https://forums.developer.nvidia.com/t/365302)
- [gb10-experiments tuning.md](https://github.com/potable-anarchy/gb10-experiments/blob/main/docs/tuning.md) — boost defaults, governor default, big.LITTLE map; its `-lgc` "not supported" claim conflicts with driver-580 reality, treat as outdated
- [NVIDIA DGX Spark hardware docs](https://docs.nvidia.com/dgx/dgx-spark/hardware.html) — 140 W TDP, 240 W PSU, 5–30 °C operating ambient

Nothing was modified in producing this note — no repo changes, no host
writes; everything is read-only observation plus published sources. Conflicts
are noted inline: the `-lgc` support question (guide vs. NVIDIA
engineer/experience) and FE CPU-pinning reliability (workaround per the 6.17
kernel).
