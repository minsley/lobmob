---
status: draft
tags: [lobster, variants, pcb, kicad, hardware, electronics]
maturity: research
created: 2026-02-23
updated: 2026-02-23
---
# Lobster Variant: PCB

## Summary

Lobster image with KiCad, ngspice, and related tools for PCB design tasks — schematic capture, layout, SPICE simulation, DRC/ERC, Gerber export, and BOM generation. KiCad is Linux-native with a Python scripting API, making it well-suited to headless/scripted operation.

## Toolchain

| Tool | Purpose | Notes |
|---|---|---|
| KiCad | Schematic + PCB layout | Linux-native; Python scripting API via `pcbnew` module |
| `kicad-cli` | Headless KiCad operations | Introduced in KiCad 7; export, DRC, ERC without GUI |
| ngspice | SPICE circuit simulation | Open-source; LTspice is Windows-only |
| `python-kicad` / `pcbnew` | Scripted board manipulation | KiCad's built-in Python API |
| KiCad component libraries | Standard parts database | Install with KiCad |
| Gerber viewers / validators | Output verification | `gerbv`, `gerber-rs274x-parser` |
| `kikit` | Panel creation, DRC automation | Popular KiCad automation toolkit |
| Manufacturer DRC rules | JLCPCB, PCBWay rule files | Import as custom DRC rules |

## Open Questions

- [ ] **KiCad headless**: `kicad-cli` (KiCad 7+) enables scripted schematic/PCB operations without GUI. Verify full design workflow (schematic → layout → DRC → Gerber) is possible headlessly.
- [ ] **SPICE simulation scope**: ngspice can run SPICE netlists exported from KiCad. Can the lobster write a schematic, export netlist, run simulation, and interpret results? What level of circuit complexity is practical?
- [ ] **3D model rendering**: KiCad can render 3D board previews. Requires display/renderer — headless 3D render via Xvfb or skip for now?
- [ ] **Image size**: KiCad + libraries is substantial (~2-3GB). Component libraries especially large. Which libraries to include? Standard KiCad libs cover most use cases.
- [ ] **Manufacturer rules**: JLCPCB/PCBWay publish DRC rule files. Pre-bundle the most common ones in the image?
- [ ] **PCB image processing**: scratch sheet mentions "models with image processing" — board photo analysis? Component placement from image? Needs clarification.

## Phases

### Phase 1: Base image
- `containers/lobster-pcb/Dockerfile` extending `lobmob-lobster`
- Install KiCad (with `kicad-cli`), ngspice, KiKit
- Install standard KiCad component + footprint libraries
- Smoke test: `kicad-cli --version`, export Gerbers from a sample board

### Phase 2: Headless workflow validation
- Validate full schematic → DRC → Gerber pipeline without GUI
- SPICE simulation via exported netlist

### Phase 3: Manufacturer rules + skills
- Bundle JLCPCB, PCBWay DRC rule files
- Document expected task body format (what the lobster needs to start a PCB task)
- Write variant smoke test

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-23 | ngspice over LTspice | LTspice is Windows-only; ngspice runs natively on Linux |

## Scratch

- KiCad 8 is current stable; `kicad-cli` available since KiCad 7
- `kicad-cli pcb export gerbers --output ./gerbers board.kicad_pcb`
- `kicad-cli pcb drc --output drc.json board.kicad_pcb`
- `pcbnew` Python module: `import pcbnew; board = pcbnew.LoadBoard("board.kicad_pcb")`
- KiKit: `pip install kikit`; automates panelization, mousebites, DRC reports
- ngspice is available in Ubuntu repos: `apt-get install ngspice`
- "image processing" in scratch sheet — probably refers to analyzing photos of physical boards or component datasheets (PDF). Agent SDK multimodal capability handles this without special tooling.
- Gerber preview: `gerbv` is CLI-capable with Xvfb for PNG export if needed

## Related

- [Lobster Variants overview](./lobster-variants.md)
- [Lobster Arduino](./lobster-arduino.md) — complementary hardware domain
