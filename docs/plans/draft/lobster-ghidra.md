---
status: draft
tags: [lobster, variants, ghidra, reverse-engineering, security]
maturity: research
created: 2026-02-23
updated: 2026-02-23
---
# Lobster Variant: Ghidra

## Summary

Lobster image with Ghidra and supporting binary analysis tools for reverse engineering tasks — malware analysis, vtable recreation, method naming, binary patching, and generating documentation for undocumented software. Runs isolated from other lobsters given the nature of work (malware samples).

## Toolchain

| Tool | Purpose | Notes |
|---|---|---|
| Ghidra | Disassembly, decompilation, analysis | NSA open-source RE framework; Java-based, headless mode available |
| Java (JDK 17+) | Ghidra runtime | Required |
| `binwalk` | Firmware extraction, binary analysis | Useful for embedded/firmware tasks |
| `radare2` | Alternate disassembler/debugger | Complements Ghidra; scriptable |
| `strings`, `file`, `xxd` | Basic binary inspection | Usually in base image |
| `objdump`, `readelf` | ELF analysis | `binutils` package |
| `patchelf` | ELF binary patching | For editing and rebuilding |
| `LIEF` (Python) | Binary format parsing and modification | Python library, good for scripted patching |
| VirusTotal API | Malware intelligence lookups | Via `vt-py` Python client |

## Open Questions

- [ ] **Isolation**: malware samples should not be able to escape the container. Standard k8s pod isolation is probably sufficient (no hostPath mounts, no privileged mode), but worth being explicit in the Dockerfile and Job template. Should ghidra lobsters run in a separate namespace?
- [ ] **Ghidra headless analysis**: Ghidra's `analyzeHeadless` script runs fully without GUI. Confirm it can be driven end-to-end by Agent SDK without interactive prompts.
- [ ] **Ghidra scripts**: Ghidra has a Java and Python (Jython) scripting API. Can the lobster write and execute Ghidra scripts mid-task? This would significantly extend capability.
- [ ] **Binary input**: how does the lobster receive the binary to analyze? Via vault task body (base64?), object storage, or URL download? Binaries can be large.
- [ ] **Output format**: analysis results (renamed functions, vtables, pseudocode) go to vault task Result section. Any structured format (JSON, CSV) worth standardizing?
- [ ] **VirusTotal API key**: separate secret, or share with lobwife? Needs to be in `secrets.env`.

## Phases

### Phase 1: Base image
- `containers/lobster-ghidra/Dockerfile` extending `lobmob-lobster`
- Install Ghidra + JDK, radare2, binwalk, binutils, patchelf, LIEF
- Smoke test: `analyzeHeadless` on a known-good ELF binary, verify output

### Phase 2: Overlay + skills
- Add `LOBSTER_GHIDRA_IMAGE` to ConfigMaps and overlays
- Validate existing lobster skills work for RE tasks
- Document expected task body format (binary location, analysis goals)
- Write variant smoke test

### Phase 3: Ghidra scripting
- Investigate lobster-authored Ghidra scripts for deeper automation
- VT lookup integration if API key available

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|

## Scratch

- Ghidra headless: `$GHIDRA_HOME/support/analyzeHeadless <project-dir> <project-name> -import <binary> -postScript <script>`
- `GHIDRA_HOME=/opt/ghidra`
- Ghidra releases on GitHub: `https://github.com/NationalSecurityAgency/ghidra/releases`
- Image size: Ghidra ~500MB + JDK ~300MB — manageable (~2-3GB total)
- `r2` (radare2) has an agent-friendly JSON output mode (`-j` flag)
- Binary input via vault: probably a URL or path in the task body — lobster downloads to `/tmp/` for analysis
- Jython in Ghidra is Python 2.7 — for scripting, prefer Ghidra's Java API or use radare2's Python 3 bindings

## Related

- [Lobster Variants overview](./lobster-variants.md)
