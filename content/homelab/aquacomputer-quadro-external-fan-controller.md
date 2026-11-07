---
title: "Powering an Aquacomputer QUADRO from the wall and driving it from an ARM Linux box"
date: 2026-11-07
summary: "The QUADRO needs +12 V and +5 V on one Molex, has no ARM or Linux aquasuite, and speaks plain USB HID — here is the PSU parts list, the USB-C wiring, and a userspace daemon that curves two Noctua NF-A12x25 G2s off a DGX Spark's GPU and SoC temperatures."
tags: [dgx-spark, cooling, fans, aquacomputer, linux, hardware]
---

A QUADRO fan controller (Aquacomputer 53256), two Noctua NF-A12x25 G2 PWM
fans, and a DGX Spark that should end up as the thing telling the fans what
to do. The QUADRO was designed to live inside a PC: it expects a Molex from
an ATX supply and an internal USB 2.0 header from a motherboard. Running it
from a 120 V outlet next to a GB10 box is entirely doable, but there are
three traps in it, and only one of them is wiring.

The traps, up front:

1. **The QUADRO needs +12 V *and* +5 V.** A 12 V brick alone will not run
   it, and plenty of 12 V bricks with a Molex on the end are 12 V-only or
   lie about the 5 V pin.
2. **aquasuite is Windows-only.** There is no Linux build and certainly no
   ARM64 build, so the Spark can never run it — which is fine, because the
   controller keeps its configuration in its own flash and never needs
   aquasuite again after setup.
3. **Two 5 V sources want to meet in the middle.** Powering the board
   externally *and* plugging in USB puts an external 5 V rail in parallel
   with the host's VBUS. Aqua Computer's own forum regulars say don't do
   that, and blocking VBUS costs $8.

Everything below was assembled from the QUADRO manual, the Linux kernel's
`aquacomputer_d5next` driver, liquidctl's driver source, and the NVIDIA DGX
Spark docs. It pairs with
[Cooling a DGX Spark with an External 120 mm Fan](../dgx-spark-external-fan-power-and-control/)
(the airflow side) and
[DGX Spark thermal control](../dgx-spark-thermal-control/)
(what the temperatures mean and which levers move them).

## What the board actually wants

Straight out of the QUADRO manual (Aqua Computer, February 2024 revision),
section 5:

| Connector | Pinout | Notes |
|---|---|---|
| Power supply | 1: +12 V · 2: GND · 3: GND · 4: +5 V | "Connect a HDD power plug of your PSU" — a standard 4-pin Molex |
| Fan 1–4 | 1: GND · 2: 12 V (max 2 A) · 3: speed signal · 4: PWM | 4-pin PWM fans only; 25 W per channel; each channel switchable fully off |
| USB | 1: +5 V (red) · 2: D− (white) · 3: D+ (green) · 4: GND (black) · 5: n/c | 5-pin "miniature" header, not a motherboard 2×5 |
| Temp sensors | 4 × 2-pin | Ships with one 70 cm probe |
| aquabus | 1: GND · 2: SDA · 3: SCL · 4: +5 V | Only relevant if an aquaero is in the loop |

Board is 54 × 49 × 17 mm, supply voltage listed as "5 V, 12 V", ambient
10–40 °C. USB ID is `0c70:f00d`.

The fans are not a load problem. Per Noctua's spec sheet the NF-A12x25 G2
PWM is 12 V, **1.8 W / 0.15 A max**, 1800 rpm, 0 rpm at 0 % PWM, 360 rpm at
20 % PWM, and it will not start below a 7 V rail. Two of them plus the
controller's logic is well under 5 W against a 25 W-per-channel budget.
This is a PSU sizing question with the answer "anything", and a connector
question with the answer "the hard part".

## It is not a 12 V device

The QUADRO runs its logic and the RGBpx output from +5 V; the fan headers
get +12 V. On the Aqua Computer forum, a user planning exactly this
off-board build was told flatly: *"The Quadro will not work with a pure 12 V
power supply!"* and *"The Quadro requires +5V for the Controller and the LED
functions. 5V 1A is enough for the Controller."* The thread ends with a
working bench photo, so the requirement is real and the 12 V + 5 V answer is
what worked.

That kills the obvious plan of buying one 12 V adapter. It also means a
USB-C PD trigger at 12 V is only half a solution — you still need a 5 V rail
from somewhere.

Test before you trust any adapter: with the adapter unplugged from
everything, meter pin 1 → pin 2 (should be ~12 V) and pin 4 → pin 2 (should
be ~5 V). Cheap "12 V/5 V Molex" bricks are frequently 12 V on both rails
because the 5 V pin is just pass-through on a single-winding supply. Getting
this wrong puts 12 V into a 5 V rail.

## Power supply options, ranked

**A. Dual-rail Molex brick — one part, zero soldering.** The category is
sold as an *external hard drive power adapter*: 100–240 V AC in, 12 V @ 2 A
and 5 V @ 2 A out on a female 4-pin Molex. Search "12 V 5 V DC power adapter
4-pin Molex 2 A". $15–25. Verify both rails with a meter before the board
sees it. This is the recommendation unless you want to solder.

**B. USB-C PD trigger + 12→5 V buck + Molex pigtail — the "USB adapter"
version.** A USB-C PD 12 V trigger cable (needs a PD source that actually
offers the 12 V profile — most 30 W+ chargers do) gives you the 12 V rail; a
MP1584/mini-360-class buck module set to **5.0 V** gives you the second rail;
both land in a female Molex housing you crimp or solder. ~$20 in parts, one
wall plug, and every piece is reusable. Set and *verify* the buck output into
a dummy load before connecting the controller — a buck that boots at 12 V out
will kill the board.

**C. ATX PSU + start jumper.** Bulletproof, has both rails natively, has
Molex connectors, and is what the forum thread settled on. Costs $40+, is
the size of a brick, and needs the green-wire-to-black jumper (or a proper
ATX start plug) plus an ATX 2.4-era unit so the 12 V rail doesn't need a
minimum load to stay up. Choose this if you already have a spare PSU.

**D. Mean Well RD-35A — best quality per dollar, needs an enclosure.**
Open-frame, 5 V @ 4 A + 12 V @ 1 A, screw terminals, ~$25. It is a mains
device with exposed terminals, so it goes in a box with a strain relief and
a fuse. Only pick this if you are comfortable with mains wiring.

Anything rated ≥1 A on both rails is fine; do not buy a 12 V/5 A "LED"
supply and assume the 5 V pin exists.

## USB, and the two-supply problem

The QUADRO's USB port is a 5-pin header, so a normal cable will not
plug in. Two ways to reach the Spark:

- **Buy the adapter cable.** Aquacomputer part **53213**, "USB cable A-plug
  to 5 pin miniature connector, 200 cm", €4.90, explicitly listed as
  compatible with the QUADRO. Then a **USB-C male → USB-A female adapter**
  (the same dongle people use to plug a USB-A stick into a USB-C laptop;
  it carries the CC pull-up the C host needs to see) into any of the Spark's
  four USB-C ports. No soldering.
- **Solder it.** Cut a USB-C-male-to-USB-A-male cable in half, keep the C
  end (it has the host-side CC resistors), and splice D+, D−, GND to a
  5-pin housing. Do not use a C-to-C cable end — a C plug wired as a device
  needs 5.1 kΩ pull-downs on CC1/CC2 or the port will never enumerate.

Now the part worth slowing down for. With the board powered from an external
supply, the Molex 5 V and the USB port's VBUS are two independent 5 V
sources meeting on the same board. On the Aqua Computer forum: *"Do not use
an external Power supply and the USB connection at the same time! This can
damage your Hardware."* That advice comes from a forum regular rather than a
datasheet, and plenty of people probably get away with it — but the fix is
cheap and removes the question entirely:

> **Block VBUS.** Use a USB "data blocker" (A-male to A-female, ~$8, sold
> for charging-station hygiene) in the chain, or cut the red conductor in
> the 53213 cable. The board is then a textbook self-powered USB device:
> 5 V from the Molex, data-only from the host. Enumeration is unaffected,
> because the D+ pull-up comes from the board's own MCU.

The same logic explains a useful diagnostic: if you meter ~5 V on Molex pin
4 with **only** USB connected, the rails are shared and a 12 V-only brick
plus USB would technically boot the board. That behaviour is undocumented;
the dual-rail supply sidesteps it, so don't build on it.

## Parts list

| # | Part | Spec / part number | ~Cost | Why |
|---|---|---|---|---|
| 1 | Dual-rail AC adapter | 100–240 V AC → 12 V 2 A + 5 V 2 A, female 4-pin Molex | $15–25 | Only rail requirement the QUADRO has |
| 2 | Molex 4-pin extension | male–female, 30–50 cm | $6 | Strain relief, lets you place the board anywhere |
| 3 | USB adapter cable | Aquacomputer **53213** (A-plug → 5-pin, 200 cm) | €4.90 | The off-the-shelf cable whose compatibility list names the QUADRO |
| 4 | USB-C → USB-A female adapter | any, with CC pull-up (host side) | $7 | Spark has USB-C only |
| 5 | USB data blocker | A-male → A-female, VBUS-blocking | $8 | Stops two 5 V rails from fighting |
| 6 | Fans | 2 × Noctua NF-A12x25 G2 PWM (already owned) | — | 4-pin, 1.8 W each, 0 rpm at 0 % |
| 7 | Enclosure / standoffs | small project box or M3 standoffs + double-sided tape | $5–10 | The board is bare and the manual warns against it touching metal |
| 8 | *Optional* multimeter check | — | $0 | Non-negotiable if you build option B or D |

Budget path: ~$40 with the purchased cable and adapters. Option B parts
(PD trigger ~$10, buck ~$3, Molex pigtail ~$4, USB-C pigtail ~$4) come in
under that if you already own a PD charger.

## Wiring

```text
 120 V outlet
      │
 [dual-rail adapter]  12 V 2 A + 5 V 2 A
      │
 4-pin Molex  pin1 +12V ─┐
              pin2 GND  ─┤
              pin3 GND  ─┤
              pin4 +5V  ─┘
                          │
                    ┌─────┴──────┐
                    │  QUADRO    │
                    │  53256     │
                    └─┬───┬───┬──┘
        Fan 1 (4-pin) │   │   │ Fan 2 (4-pin)
             ┌────────┘   │   └────────┐
      NF-A12x25 G2 #1    │      NF-A12x25 G2 #2
                         │
              USB 5-pin  │  pin1 +5V ← leave disconnected (VBUS blocked)
                         │  pin2 D−   ──┐
                         │  pin3 D+   ──┼── 53213 ── [data blocker] ── USB-C ── DGX Spark
                         │  pin4 GND  ──┘
                    ┌────┴─────┐
                    │ 70 cm    │  temp probe (optional; see "zero-software mode")
                    │ probe    │
                    └──────────┘
```

Fan headers are standard 4-pin; the Noctua connectors go straight in, and
each fan ships with a 30 cm extension (NA-EC1) and a Y-splitter (NA-YC1) if
you would rather run both fans from one channel. Give them separate channels
— the QUADRO has four, and you get independent RPM telemetry for free.

Skip the included NA-RC7 Low-Noise Adapter. It is a series resistor on +12 V
and only makes sense for voltage-controlled fans; inline with a PWM fan it
just caps your ceiling.

## Step 1: configure it once, on any Windows PC

The QUADRO stores its whole configuration in flash and runs standalone from
then on, so this is a five-minute job on a borrowed or dual-booted machine.
aquasuite requires internet for activation and a device with an active
update-service window.

What to set:

1. **Fan channels 1 and 2 → fixed/"power preset" mode** (manual §10.1), not
   the curve or setpoint controllers. The Linux side will be supplying the
   duty cycle, and a channel left in curve mode may ignore external writes.
2. **Min power 0 %, max power 100 %, "hold minimum power" unchecked** — so a
   0 % write really stops the fans, and a 100 % write really means 100 %.
3. **Start boost on** if you plan to sit at very low duty; the G2 needs
   ~20 % to spin up from rest.
4. **RGBpx off / no LEDs configured** — saves 5 V headroom and one thing to
   get wrong.
5. **Save to the device** (the disk icon in the device header). Settings are
   not written to flash until you do.
6. Note the firmware version — it is the first thing to check if the board
   misbehaves later.

Channels 3 and 4 can be left alone.

If you would rather never run aquasuite at all, skip to "zero-software mode"
below — but you lose GPU-temperature response, which is the whole point.

### "Can't we just run aquasuite on the Spark?"

Not natively. aquasuite ships as a Windows x86-64 application; there is no
Linux or ARM64 build, and Aqua Computer has not signalled one is coming.
Windows 11 on ARM does emulate x86-64, so in principle a Windows-for-ARM VM
on the Spark with the QUADRO's HID device passed through would work — but you
would be stacking a Windows licence, GPU-less emulation, USB passthrough of a
HID device, and the aquasuite update-service licensing on top of each other,
to produce a control loop whose availability is the VM's. Use a VM for the
one-time configuration if you truly have no Windows machine to borrow; do not
make it the steady state. The device's flash config plus the Linux daemon is
the durable answer.

## Step 2: bring it up on the Spark

The board talks USB HID, and Linux has had a driver for it since kernel 6.0.
DGX OS 7 runs a 6.17 NVIDIA kernel, so the driver should already be there:

```bash
lsusb | grep -i 0c70                 # 0c70:f00d Aqua Computer QUADRO
modinfo aquacomputer_d5next          # present?
cat /sys/class/hwmon/hwmon*/name     # one of these should read "quadro"
sensors                              # lm-sensors picks it up as quadro-hid-*
```

What the driver exposes for a QUADRO, per the kernel docs: `temp1..4_input`
(plus 16 virtual ones), `fan1..4_input` in RPM, `in*_input`, `curr*_input`,
`power*_input`, `fan5_pulses` for the flow sensor, and **`pwm1..4` (0–255)
writable**.

Then prove control actually works before writing any code:

```bash
HWM=$(grep -l quadro /sys/class/hwmon/hwmon*/name | xargs dirname)
echo 128 | sudo tee $HWM/pwm1
sleep 3; cat $HWM/fan1_input      # should be ~900–1000 rpm, not 0 and not 1800
echo 255 | sudo tee $HWM/pwm1
sleep 3; cat $HWM/fan1_input      # ~1800 rpm
```

**Read the RPM back.** This is the single most important step in the whole
build. The kernel driver exposes `pwm*` but *not* `pwm*_enable`, so it has no
standard way to say "put this channel in direct-percent mode first". If the
channel is in a curve or setpoint mode, your write may be silently ignored.
liquidctl does it properly — its driver explicitly writes the channel mode
byte before the duty — so if the sysfs write above does not move the fan:

```bash
pip install liquidctl          # or: apt install liquidctl
sudo liquidctl initialize      # prints firmware + serial
sudo liquidctl status
sudo liquidctl set fan1 speed 50     # 0–100 %
```

liquidctl will note that the kernel driver lacks the PWM attributes it wants
and fall back to direct HID access, which is fine — it is talking to the same
device, just with the mode byte set explicitly. Either path works; pick the
one your board honours and use it consistently.

If `modinfo` comes up empty, two fallbacks: build the driver from
[aleksamagicka/aquacomputer_d5next-hwmon](https://github.com/aleksamagicka/aquacomputer_d5next-hwmon)
with its `dkms-install.sh` (DKMS on DGX OS means MOK-signing the module, same
as `spark_hwmon` and the fan-override module), or skip the kernel entirely and
use liquidctl's direct HID access permanently. The latter has no Secure Boot
consequences and is the lowest-risk option on an NVIDIA kernel.

## Step 3: the software plan

There is no aquasuite on ARM, and there never will be, so the control loop
moves to the Spark. That is not a downgrade — it is strictly more capable,
because the Spark's GPU temperature and power draw are visible to it, and
those are exactly the signals the QUADRO cannot see on its own. (aquasuite's
answer to this is to push values into the QUADRO's 16 "software sensors"
from Windows; the Linux driver explicitly does not implement writing those,
so on Linux the loop lives in userspace instead.)

Data sources, all confirmed available on DGX Spark hosts:

| Signal | Where |
|---|---|
| GPU temperature | `nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits` |
| GPU utilisation / power | `nvidia-smi --query-gpu=utilization.gpu,power.draw` |
| SoC/CPU temperature | `/sys/class/thermal/thermal_zone*/temp` (ACPI zones; the hot ones are zone0/zone4), or `sensors` acpitz |
| Per-domain power, 8 temp zones | [antheas/spark_hwmon](https://github.com/antheas/spark_hwmon) DKMS module (MOK signing) |

Design rules that matter more than the curve shape:

- **Take the max of the sensor curves**, not the average. The GB10 shares one
  heatsink weighted toward the GPU, and the CPU is routinely the hotter of
  the two — a GPU-only curve will under-fan exactly when the CPU needs air.
- **Smooth and dwell.** Temperatures on this box are noisy at 1 s resolution;
  an EMA with a ~20 s time constant plus a 10 s minimum dwell between duty
  changes stops audible hunting.
- **Fail loud, not quiet.** If every sensor read fails, go to 100 %, not to
  the minimum. A broken thermometer should sound like a jet, not like silence.
- **Fail safe on exit.** systemd's `ExecStopPost` (and the service's
  `Restart=always`) should drive the fans to 100 % or to a known minimum
  rather than leave the last duty value stuck in the controller's RAM.
- **One writer.** Do not let a cron job, a GUI, and the daemon all write
  `pwm1`; last-writer-wins makes for confusing debugging.

A working daemon, roughly 100 lines, no dependencies beyond Python 3 and an
optional liquidctl:

```python
#!/usr/bin/env python3
"""Drive QUADRO fan channels from DGX Spark thermals."""
import os, subprocess, sys, time, glob, signal

CFG = {
    # (temp_degC, duty_pct) breakpoints, applied to whichever sensor is hottest
    "curve": [(40, 0), (55, 30), (65, 55), (75, 80), (85, 100)],
    "deadband_pct": 2,         # ignore duty changes smaller than this
    "min_dwell_s": 10,         # minimum seconds between duty changes
    "ema_tau_s": 20.0,         # exponential moving average time constant
    "fail_duty": 100,          # duty if every sensor is unreadable
    "channels": [1, 2],        # quadro fan channels in use
    "writer": "hwmon",         # "hwmon" or "liquidctl"
    "interval_s": 2,
}

def read_gpu_temp():
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5).stdout
        return float(out.strip().splitlines()[0])
    except Exception:
        return None

def read_soc_temp():
    """Hottest ACPI thermal zone (GB10 exposes several; zone0/zone4 run hot)."""
    temps = []
    for z in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
        try:
            with open(z) as f:
                temps.append(int(f.read().strip()) / 1000.0)
        except Exception:
            pass
    return max(temps) if temps else None

def duty_for(temp):
    pts = CFG["curve"]
    if temp <= pts[0][0]:
        return pts[0][1]
    if temp >= pts[-1][0]:
        return pts[-1][1]
    for (t0, d0), (t1, d1) in zip(pts, pts[1:]):
        if t0 <= temp <= t1:
            return d0 + (d1 - d0) * (temp - t0) / (t1 - t0)

def find_hwmon():
    for path in glob.glob("/sys/class/hwmon/hwmon*"):
        try:
            if open(os.path.join(path, "name")).read().strip() == "quadro":
                return path
        except Exception:
            pass
    return None

def write_duty(hwm, ch, pct):
    if CFG["writer"] == "liquidctl":
        subprocess.run(["liquidctl", "set", f"fan{ch}", "speed", str(int(round(pct)))],
                       check=False, capture_output=True)
    else:
        with open(os.path.join(hwm, f"pwm{ch}"), "w") as f:
            f.write(str(int(round(pct * 255 / 100))))

def main():
    hwm = find_hwmon()
    if hwm is None:
        sys.exit("no quadro hwmon device found (driver loaded? cable plugged in?)")

    last_duty, last_change = -1, 0.0
    ema = None
    while True:
        gpu, soc = read_gpu_temp(), read_soc_temp()
        hot = max([t for t in (gpu, soc) if t is not None], default=None)
        if hot is None:
            target = CFG["fail_duty"]
        else:
            dt, tau = CFG["interval_s"], CFG["ema_tau_s"]
            ema = hot if ema is None else ema + (hot - ema) * dt / (tau + dt)
            target = duty_for(ema)
            if last_duty >= 0 and abs(target - last_duty) < CFG["deadband_pct"]:
                target = last_duty
        now = time.monotonic()
        if target != last_duty and now - last_change >= CFG["min_dwell_s"]:
            for ch in CFG["channels"]:
                write_duty(hwm, ch, target)
            print(f"gpu={gpu} soc={soc} ema={None if ema is None else round(ema, 1)} duty={target}%",
                  flush=True)
            last_duty, last_change = target, now
        time.sleep(CFG["interval_s"])

def _term(*_):
    try:
        hwm = find_hwmon()
        if hwm:
            for ch in CFG["channels"]:
                write_duty(hwm, ch, CFG["fail_duty"])
    finally:
        sys.exit(0)

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _term)
    main()
```

Install it as a service that fails loud:

```ini
# /etc/systemd/system/quadro-fanctl.service
[Unit]
Description=QUADRO fan control from DGX Spark thermals
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/quadro-fanctl.py
ExecStopPost=/bin/sh -c 'for f in /sys/class/hwmon/hwmon*/name; do \
  [ "$(cat $f)" = quadro ] && echo 255 | tee $(dirname $f)/pwm1 \
  $(dirname $f)/pwm2 >/dev/null; done'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

(`pwm` writes need root or a udev rule; running the service as root is the
path of least resistance on a single-purpose box.)

Tuning: start conservative, log for a day (`journalctl -u quadro-fanctl -f`),
and compare against `nvidia-smi` telemetry. The useful target is that the
fans are at 0–30 % at idle and reach 100 % *before* the SoC zones pass
~90 °C — on a GB10 the ACPI zones can sit in the low 80s at idle with the
stock configuration, so the curve above starts lifting early by design.

## Zero-software mode

If the Spark should never be in the control path, the QUADRO can run this on
its own: put the included 70 cm probe in the exhaust stream, set a curve
controller **on the device** against that sensor in aquasuite, and it runs
forever with no host involvement. Exhaust air is a lagging but genuinely
usable proxy — the [ducted-cage thread](https://forums.developer.nvidia.com/t/dual-spark-ducted-cooling-cage/365302)
measured 52 °C exhaust at low RPM and 42 °C at high RPM, which is a real
signal.

It cannot see GPU temperature, though, and because the channel has to be in
curve mode for this to work, it is mutually exclusive with the userspace
daemon — pick one. The pragmatic version of "both" is: zero-software mode as
the steady state, and the daemon only when you are actively benchmarking.

## Gotchas, collected

- **Meter the Molex before connecting.** Both rails, both ways round. A
  swapped 12 V into the 5 V pin is the fastest way to destroy the board.
- **A 12 V-only supply will not work.** 12 V + 5 V, or nothing.
- **Block VBUS if you power it externally.** The board is a self-powered USB
  device the moment the Molex is live.
- **The controller caches its last duty value.** Kill the daemon mid-run and
  the fans keep that speed until something writes again — hence `Restart=`
  and `ExecStopPost=`.
- **Mount it on something.** Bare board, metal case, manual warns about
  contact. Standoffs or double-sided tape onto plastic.
- **Fan headers are 4-pin PWM only.** No 3-pin voltage control, no DC mode.
- **Channel mode is the invisible failure.** If duty writes "do nothing",
  it is almost always a channel still sitting in curve/setpoint mode from an
  earlier aquasuite session — not a dead fan.

## Sources

- [QUADRO user and installation manual (PDF, Feb 2024)](https://aquacomputer.de/handbuecher.html?file=tl_files/aquacomputer/downloads/manuals/QUADRO_english.pdf) — connector pinouts §5, fan modes §10, technical details §17
- [Aqua Computer shop: QUADRO 53256](https://shop.aquacomputer.de/Monitoring-and-Controlling/QUADRO-and-OCTO/QUADRO-fan-controller-for-PWM-fans::3773.html?language=en) — 25 W/channel, 5 V + 12 V, Windows 10+ requirement, scope of delivery
- [Aqua Computer shop: USB cable A-plug to 5-pin miniature connector, 53213](https://shop.aquacomputer.de/USB-accessories/USB-cable-A-plug-to-5-pin-miniature-connector-length-200-cm::3586.html) — listed compatible with QUADRO 53256
- [Aqua Computer forum: can the QUADRO run unplugged from the motherboard?](https://forum.aquacomputer.de/weitere-foren/english-forum/p1455151-can-the-quadro-fan-controller-run-unplugged-from-the-motherboard-after-it-has-been-programmed/) — needs 12 V *and* 5 V; 5 V/1 A is enough for the controller; the external-PSU-plus-USB warning; ATX 2.4 minimum-load note
- [Kernel driver aquacomputer-d5next](https://docs.kernel.org/hwmon/aquacomputer_d5next.html) — QUADRO sensors and writable `pwm[1-4]`
- [aleksamagicka/aquacomputer_d5next-hwmon](https://github.com/aleksamagicka/aquacomputer_d5next-hwmon) — QUADRO supported since kernel 6.0 with direct fan PWM control; DKMS instructions
- [liquidctl: Aquacomputer Quadro guide](https://github.com/liquidctl/liquidctl/blob/main/docs/aquacomputer-quadro-guide.md) — `set fan1 speed`, status output, hwmon interaction
- [liquidctl driver source](https://github.com/liquidctl/liquidctl/blob/main/liquidctl/driver/aquacomputer.py) — writes channel mode byte before duty; falls back to direct HID when the kernel driver lacks `pwmX_enable`
- [Noctua NF-A12x25 G2 PWM specifications](https://www.noctua.at/en/products/nf-a12x25-g2-pwm/specifications) — 12 V, 1.8 W / 0.15 A max, 0 rpm at 0 % PWM, 360 rpm at 20 %, 7 V starting voltage
- [DGX Spark hardware overview](https://docs.nvidia.com/dgx/dgx-spark/hardware.html) — 4× USB-C, 140 W TDP, 5–30 °C ambient
- [antheas/spark_hwmon](https://github.com/antheas/spark_hwmon) — 8 temperature zones and 14 power channels via DKMS

Untested on this exact hardware: the daemon and the `ExecStopPost` line are
written against the documented sysfs and liquidctl interfaces, not measured
on a QUADRO. The bring-up step that writes `pwm1` and reads `fan1_input` back
is what tells you whether your unit needs the liquidctl writer instead — do
that before trusting the curve.