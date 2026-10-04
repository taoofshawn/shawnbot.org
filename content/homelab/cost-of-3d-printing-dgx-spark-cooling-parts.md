---
title: "What It Costs to 3D Print Cooling Parts for a DGX Spark"
date: 2026-10-03
summary: "Measured STL volumes, filament prices, and service-bureau quotes for a GB10 cooling duct and risers: DIY in ASA costs about $27 in filament versus $120–$450 delivered from a service, a 5–15× markup."
tags: [3d-printing, dgx-spark, cooling, homelab]
---

Measured from the actual STL files (mesh volume, not bounding box), priced
against July 2026 filament market data and real service-bureau quote
statistics. The parts are Henry Thomas's (whpthomas)
[DGX Spark side-vent cooling duct](https://www.printables.com/model/1751889-2-x-node-nvidia-dgx-spark-gb10cluster-side-vent-co)
and its risers, from the
[Dual Spark Ducted Cooling Cage](https://forums.developer.nvidia.com/t/dual-spark-ducted-cooling-cage/365302)
thread on the NVIDIA forums.

## The parts

| File | Size (mm) | Solid mesh volume |
|---|---|---|
| Side vent duct (right) | 225 × 230 × 127.5 | 834 cm³ |
| Riser (tall, per unit) | 32 × 140 × 7 | 24.5 cm³ |

A 2-node stack needs 1 duct + 4 risers; each riser carries weight, so print
risers at 60–100% infill and the duct at 15–20% with 3 walls. Effective
filament use is ~30–40% of the solid mesh volume for the duct, plus
supports.

## Material choice: heat resistance is the constraint

This duct moves warm exhaust air, so glass-transition temperature (Tg,
where the plastic softens) and heat-deflection temperature (HDT, where it
bends under load) decide the material. Official TDS values (Polymaker
PolyLite line):

| Material | Tg | HDT @ 1.8 MPa | Filament median (US, 2026) |
|---|---|---|---|
| PLA | ~60 °C | ~55 °C | $20.99/kg — unsuitable here |
| PETG | 81 °C | 75 °C | $19.99/kg |
| ASA / ABS | 98–101 °C | 98–100 °C | $26.99/kg |
| PC | 113 °C | 107 °C | ~$33/kg — hardest to print |

ASA is the sweet spot: nearly PC's heat performance, far easier to print,
UV-stable. Carbon-fiber ASA (ASA-CF, ~$27/kg on Amazon) adds stiffness and
needs only a hardened nozzle. ABS matches ASA's heat numbers but warps more
and emits more fumes — the reason it belongs in a garage, not an apartment.

## Cost: one spool vs a service bureau

Two complete sets (2 ducts + 8 tall risers) in ASA-CF (density ~1.2 g/cm³),
by infill choice — recommended settings first:

| Duct infill | Riser infill | Filament (2 sets) | Spools (1 kg) |
|---|---|---|---|
| **15%** (recommended) | **100%** (recommended) | ~735 g | 1 (tight) |
| **20%** (recommended) | **100%** (recommended) | ~835 g | 1 (tight) |
| 15% | 60% | ~665 g | 1 (comfortable) |
| 25% | 100% | ~935 g | 1 (barely) |
| 40% | 100% | ~1,235 g | 2 |

Each estimate includes ~10% for supports and failed first layers. The
recommended settings fit one 1 kg spool with no margin for a failed duct
print; buying two spools (~$54) covers every row with leftover stock. That
is **~$27–$54 in material**.

Service-bureau quotes for the same parts (2026 market data, FDM):

- Budget bureau (PLA, standard lead): $65–$120 delivered
- Mid-tier US bureau (PLA/PETG): $120–$220
- Industrial FDM in ASA (Xometry/Protolabs class): $200–$450

Real medians from Makelab's published data (4,277 dispatched parts): a
150–250 mm FDM part runs $60.81, an XL part $153.32. Material is only
10–20% of a service quote — the rest is machine time, labor, setup fees
($5–15/file), and shipping. The markup over raw filament is roughly
**5–15×**.

STL files carry no units; the convention is millimeters (confirm in any
quote tool). And watch bed size: the duct at 230 mm does not fit flat on a
250 × 220 mm bed (Prusa CORE One+); it prints standing on end, which fits
with ~10–20 mm margin.

## Printing considerations

- Infill: strength in FDM comes from wall count, not infill. 3–4 perimeters
  beats raising infill from 15% to 50%. Higher infill adds material and
  print time nearly linearly and increases warp on ASA/ABS.
- Carbon-fiber filaments destroy brass nozzles in under a kilogram —
  hardened steel nozzle required.
- ASA/ABS fumes mean printing in a ventilated space, not a living area.
- Riser height matters: the design has Tall (DGX Spark, Dell Pro Max,
  ThinkStation PGX, Gigabyte AI TOP Atom), Medium (ASUS Ascent, HP ZGX),
  and Short (MSI EdgeXpert) variants. The DGX Spark uses Tall.

## Related

- [Cooling a DGX Spark with an External 120 mm Fan](./dgx-spark-external-fan-power-and-control.md)
  covers powering and controlling that duct's fan.
