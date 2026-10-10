---
title: "Cooling a DGX Spark with an External 120 mm Fan"
date: 2026-10-03
lastmod: 2026-10-10
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

## Appendix: full parts list for the ESP32 fan controller

The ESP32 option above compresses to "~$10 in parts accepting a duty-cycle
value over network or MQTT, fan powered by a 12 V wall wart." Here is the
complete bill of materials behind that one-liner — the control side, the
power side, and the fan side.

### Control side (the "$10 in parts")

| Part | Spec | Qty | ~Cost | Notes |
|---|---|---|---|---|
| ESP32 dev board | ESP32-C3 **SuperMini** or classic ESP32 DevKitC | 1 | $3–8 | C3 SuperMini is tiny and ~$3; any board with LEDC PWM works with ESPHome. Wi-Fi needed if you're sending duty over network/MQTT rather than USB |
| 4-pin PWM fan connector | Dupont/JST-XH 4-pin header, or steal wires from a $2 fan extension cable | 1 | $1–2 | Cleaner than soldering to the fan — keeps the Noctua stock connector usable |
| Pull-up resistor | 10 kΩ (any 1/4 W) | 1 | $0.05 | Tach line is open-collector; pull it to **3.3 V, never 5 V or 12 V** |
| Series resistor (optional) | 100–330 Ω | 1 | $0.05 | In line with the PWM signal; cheap insurance, most fans don't need it |
| Perfboard / breadboard + headers | — | 1 | $2–3 | Or heatshrink the SuperMini directly for a permanent install |
| 5 V → 3.3 V awareness | nothing to buy | — | — | ESP32 GPIO is 3.3 V. Noctua 4-pin fans accept a 3.3 V PWM signal fine (Intel spec says 5 V but 3.3 V works across the board) |

### Power side

| Part | Spec | Qty | ~Cost | Notes |
|---|---|---|---|---|
| 12 V PSU (wall wart) | 12 V DC, ≥1 A barrel jack | 1 | $8–10 | An NF-A12x25 draws only ~0.05 A, but spec 1 A+ headroom if you ever run a high-static-pressure fan (Arctic S12038-class server fans pull ~1 A+) |
| Buck converter | mini-360 / MP1584 module, 12 V → 5 V | 1 | $2 | Powers the ESP32 from the same 12 V brick so there's one wall plug. Alternative: power the ESP32 from any old USB charger — then skip the buck |
| Barrel jack adapter / DC screw terminal | 5.5×2.1 mm | 1 | $1–2 | To split 12 V to both fan and buck cleanly |
| 2510 connector (optional) | PWM fan male header style | — | $1 | If you want a fully stock-looking harness |

### Fan side (the duct fan)

| Part | Spec | Qty | ~Cost |
|---|---|---|---|
| 120 mm fan | **4-pin PWM, 12 V** — Noctua NF-A12x25 PWM (~$30) or Arctic P12 PWM (~$10) | 1 | $10–30 |

The critical gotcha: it must be the **4-pin PWM version at 12 V**, not the
5 V USB-C variant discussed above. The 5 V fans have their control logic
built for USB power and don't expose a standard PWM input the ESP32 can
drive.

### Totals

- Budget build (Arctic P12, SuperMini, buck): **~$27–35**
- Noctua build: **~$50–60**

### Wiring

```text
12V brick ──┬── fan pin 1 (VCC 12V)      ← fan's red wire
            └── buck IN+ ── 5V ── ESP32 5V/VIN
GND ─────────┬── fan pin 2 (GND)         ← black wire
             └── buck IN− / ESP32 GND
ESP32 GPIO (LEDC) ── 100–330Ω ── fan pin 3 (PWM, blue)   ← 25 kHz output
fan pin 4 (tach, green) ── 10kΩ pull-up to 3.3V ── ESP32 input (pulse_counter)
```

Per the Intel 4-wire fan spec: PWM at **25 kHz**, duty = fan speed; tach
emits 2 pulses per revolution.

### Software

- **ESPHome config:** a `ledc` output at 25 kHz driving a `fan` entity,
  plus a `pulse_counter` sensor on the tach pin for real RPM read-back.
  Expose it via the native ESPHome API (if you run Home Assistant), MQTT,
  or a tiny HTTP endpoint.
- **On the Spark:** a systemd timer polling
  `nvidia-smi --query-gpu=temperature.gpu` every 5–10 s and posting the
  duty from the formula above (`clamp(30 + (temp − 45) × 2, 30, 100)`).
- Bonus read-back loop: log the tach RPM alongside duty so you can detect
  a stalled or dead fan.

Real-world validation from the same thread: matousjk
([post #335](https://forums.developer.nvidia.com/t/dual-spark-ducted-cooling-cage/365302/335))
built exactly this shape of solution — an ESP32-C3 polling a Prometheus
exporter ([ateska/dgx-spark-prometheus](https://github.com/ateska/dgx-spark-prometheus))
for GPU/CPU temps and driving a Noctua NF-A14 industrialPPC on a custom
fan curve. That's the same architecture at 140 mm; it validates the ESP32
route beyond theory.
