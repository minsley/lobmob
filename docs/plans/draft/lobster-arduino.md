---
status: draft
tags: [lobster, variants, arduino, embedded, hardware]
maturity: research
created: 2026-02-23
updated: 2026-02-23
---
# Lobster Variant: Arduino

## Summary

Lobster image with PlatformIO, Arduino CLI, and simulation tools for embedded development tasks — writing firmware, compiling sketches, simulating circuits, and deploying to physical boards. PlatformIO is Linux-native and cross-platform, making this one of the more tractable hardware-adjacent variants.

## Toolchain

| Tool | Purpose | Notes |
|---|---|---|
| PlatformIO CLI (`pio`) | Cross-platform embedded build system | pip install; manages board packages, libraries, toolchains |
| Arduino CLI (`arduino-cli`) | Arduino board compilation and upload | Go binary; alternative/complement to PlatformIO |
| Python 3 | PlatformIO runtime | Already in base image |
| `avr-gcc`, `arm-none-eabi-gcc` | Cross-compilers | Managed by PlatformIO automatically |
| Wokwi CLI / simulator | Circuit simulation | `wokwi-cli` — runs `.wokwi` project files headlessly |
| `pyserial` | Serial communication | Python library for serial port interaction |
| Serial bridge client | Access to physical board serial port | For device-connected tasks — see open questions |

## Open Questions

- [ ] **Physical board access**: Arduino upload and serial monitoring require USB access to the physical board. Lobsters run in cloud k8s with no USB. Options: USB/IP tunneling from a host with physical access, serial bridge server, or lobsigliere as USB proxy. What's the right model?
- [ ] **Simulation-only lobster**: for tasks that don't require physical hardware (firmware logic, simulation), Wokwi can run fully headless. Is a simulation-only image useful as a first step?
- [ ] **Wokwi licensing**: `wokwi-cli` requires a Wokwi account/token for CI use. Free tier available. Add `WOKWI_CLI_TOKEN` to secrets.
- [ ] **Board package management**: PlatformIO downloads board packages on first use — adds network calls and disk I/O mid-task. Pre-install common packages (AVR, ESP32, STM32) in the image to avoid cold downloads?
- [ ] **SimulIDE**: alternative simulator with more hardware-accurate simulation. Worth including alongside or instead of Wokwi?

## Phases

### Phase 1: Base image
- `containers/lobster-arduino/Dockerfile` extending `lobmob-lobster`
- Install PlatformIO CLI, Arduino CLI
- Pre-install common board platforms (AVR, ESP32) to avoid mid-task downloads
- Install Wokwi CLI
- Smoke test: `pio --version`, `arduino-cli version`, compile a blink sketch

### Phase 2: Simulation flow
- Validate simulation-only tasks (firmware logic + Wokwi) without physical hardware
- Lobster writes firmware, runs simulation, reports results to vault

### Phase 3: Physical board integration
- Evaluate device tunneling approach (pending variants overview decision)
- Implement serial bridge or USB/IP if applicable

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|

## Scratch

- PlatformIO install: `pip install platformio`
- Arduino CLI install: single Go binary, `curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | sh`
- `pio run -t upload` for physical board upload (requires serial port)
- `pio device monitor` for serial output (requires serial port)
- Wokwi CLI: `npm install -g @wokwi/cli` or binary download
- Pre-installing board platforms: `pio pkg install --platform atmelavr --platform espressif32`
- Simulation-only use case is genuinely useful — most firmware logic can be tested without hardware
- `pyserial` for raw serial if lobster needs to communicate with a device directly

## Related

- [Lobster Variants overview](./lobster-variants.md)
- [Lobster Xcode](./lobster-xcode.md) — shares device tunneling concern
