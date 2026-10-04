---
title: "Cooling a DGX Spark with an External 120 mm Fan"
date: 2026-10-03
summary: "How to power and RPM-control an external 120 mm duct fan for a GB10 machine from a 5 V USB-C port, a $28 thermostat, or a scripted controller reading nvidia-smi."
tags: [dgx-spark, cooling, fans, homelab]
---

From the
[Dual Spark Ducted Cooling Cage](https://forums.developer.nvidia.com/t/dual-spark-ducted-cooling-cage/365302)
thread (330 posts of GB10 owners comparing cooling setups) plus follow-up
research on fan-control hardware. Pairs with
[What It Costs to 3D Print Cooling Parts for a DGX Spark](./cost-of-3d-printing-dgx-spark-cooling-parts.md).

## What the thread established

- The duct takes a standard 120 × 120 × 25 mm fan; the designer's own unit
  is a Noctua, powered at 5 V from the Spark's USB-C port through a
  4-pin-to-barrel/USB-C cable.
- Noctua PWM fans run at full speed when the PWM wire is unconnected — the
  common "plug into USB-C" setup is static 100% speed, no control.
- Users distrust the Spark's USB-C for fan load (a 120 mm fan draws
  ~0.2–0.3 A); a plain USB wall wart removes the risk.
- Cheap Aliexpress PWM controllers + external 12 V PSU work but are
  knob-set, not automatic.
- A proven automatic setup: Aquacomputer OCTO fan controller driving four
  Noctua NF-A8s — idle GPUs ~40 °C at 30% fan, high-60s to low-70s °C under
  load at 100%.
- Expectations from systematic RPM benchmarking (400/2000/4000 RPM):
  typical loads stay under 75 °C at 2000 RPM; under heavy long-context
  workloads even 4000 RPM cannot fully eliminate throttling. Exhaust air
  measured 52 °C at 1000 RPM, 42 °C at 4000 RPM — exhaust temperature is a
  usable control signal.

## Ways to get RPM control, ranked by effort

**1. AC Infinity Controller 1 (~$28) — thermostat, zero software.** Probe
taped near the duct's exhaust, dial in a target temperature, it PWMs the
fan. The boring, reliable choice for "fan speed follows temperature."

**2. Aquacomputer OCTO (~$45).** Eight channels, external temp-sensor
inputs, configurable curves, USB interface. Overkill for one fan,
future-proof for a second duct or more fans; runs standalone once
configured.

**3. Scripted control from the Spark itself.** The Spark exposes
`nvidia-smi --query-gpu=temperature.gpu,utilization.gpu`, but has no fan
header — the bridge is a small PWM controller the Spark talks to:

- ESP32/ESPHome (~$10 in parts) accepting a duty-cycle value over network
  or MQTT, fan powered by a 12 V wall wart.
- A cron/systemd timer or small daemon on the Spark polls `nvidia-smi`
  every few seconds and computes duty, e.g.
  `duty = clamp(30 + (temp − 45) × 2, 30, 100)` — blending GPU temperature
  with utilization if you want the fan to react to load before heat
  catches up (thermal mass lags utilization by tens of seconds).

This is the DIY equivalent of the OCTO and the only route that responds to
system load directly rather than waiting for temperature to rise.

**4. Static 5 V from USB — free, no control.** Quiet Noctua at full speed
always. Fine if fan noise never bothers you.

## Practical notes

- The duct is designed for intake at the side vent; several thread members
  found intake (rather than exhaust) placement more effective, and sealing
  gaps around the duct adds several degrees of benefit.
- Axial 120 mm fans have low static pressure; the Spark's internal
  centrifugal fans do most of the heatsink work. The external duct fan
  mainly lowers case and ambient temperatures — expect ~10 °C improvement,
  matching the designer's measurements.
- The Spark's internal fans remain in control of the heatsink; the external
  fan is assistance, not replacement.
