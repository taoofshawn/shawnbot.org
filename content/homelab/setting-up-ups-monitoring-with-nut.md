---
title: "Setting up UPS monitoring with NUT"
date: 2026-02-14
summary: "How Network UPS Tools are wired into the cluster so power events drain nodes cleanly."
tags: [nut, ups, kubernetes]
---

## Why NUT

The UPS is attached to the main host; everything else needs to know when the
power drops so VMs and nodes shut down in order.

## Setup

1. Install `nut` on the host with the USB driver.
2. Run `nut-webapi` so remote clients can poll battery status.
3. Point node shutdown scripts at the NUT server status.

## Gotchas

- The USB driver claims the device exclusively — only one server can talk to it.
- Test with `upsc ups@localhost` before wiring anything into shutdown hooks.
