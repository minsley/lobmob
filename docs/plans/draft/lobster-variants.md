---
status: draft
tags: [lobster, variants, infrastructure, containers]
maturity: planning
created: 2026-02-23
updated: 2026-02-23
---
# Lobster Variants

## Summary

Specialized lobster container images that extend `lobmob-lobster` with domain-specific toolchains. Each variant is a Dockerfile that inherits the base lobster and adds the tools needed for a class of tasks. Lobboss selects the right image at job creation time via the task's `workflow` field. This plan covers the cross-cutting framework; individual variant plans cover toolchain specifics.

## Variants

| Variant | Image | Status | Plan |
|---|---|---|---|
| android | `lobmob-lobster-android` | Scaffolded (image ref in overlays, no Dockerfile) | [lobster-android](./lobster-android.md) |
| unity | `lobmob-lobster-unity` | Scaffolded (image ref in overlays, no Dockerfile) | [lobster-unity](./lobster-unity.md) |
| ghidra | `lobmob-lobster-ghidra` | Planned | [lobster-ghidra](./lobster-ghidra.md) |
| xcode | `lobmob-lobster-xcode` | Blocked (needs macOS) | [lobster-xcode](./lobster-xcode.md) |
| arduino | `lobmob-lobster-arduino` | Planned | [lobster-arduino](./lobster-arduino.md) |
| pcb | `lobmob-lobster-pcb` | Planned | [lobster-pcb](./lobster-pcb.md) |
| ros2 | `lobmob-lobster-ros2` | Planned | [lobster-ros2](./lobster-ros2.md) |
| homeassistant | `lobmob-lobster-homeassistant` | Speculative (may be separate project) | [lobster-homeassistant](./lobster-homeassistant.md) |

## Image Hierarchy

```
lobmob-base                        (Python + Node.js + Agent SDK)
└── lobmob-lobster                 (+ lobster skills + run_task.py)
    ├── lobmob-lobster-android     (+ Android SDK + ADB + Gradle)
    ├── lobmob-lobster-unity       (+ Unity Editor + Android SDK + .NET)
    ├── lobmob-lobster-ghidra      (+ Ghidra + Java + binary tools)
    ├── lobmob-lobster-xcode       (macOS only — separate infra required)
    ├── lobmob-lobster-arduino     (+ PlatformIO + Arduino CLI + simulators)
    ├── lobmob-lobster-pcb         (+ KiCad + ngspice + Gerber tools)
    ├── lobmob-lobster-ros2        (+ ROS2 + Gazebo + DDS)
    └── lobmob-lobster-homeassistant (+ HA client libs + MQTT + IoT tools)
```

## Workflow Field

Task metadata uses a `workflow` field to select the image. Lobboss maps workflow → image via ConfigMap:

```yaml
# task frontmatter
workflow: unity   # → lobmob-lobster-unity image
```

Mapping lives in lobboss ConfigMap (see `LOBSTER_ANDROID_IMAGE`, `LOBSTER_UNITY_IMAGE` in overlays). Each new variant adds a `LOBSTER_<NAME>_IMAGE` key.

## Cross-Cutting Concerns

### Device Tunneling
Several variants need access to physical hardware (Android, Xcode/iOS, Arduino, ROS2 robots). Options:
- **USB/IP**: expose USB devices over the network, mount in container
- **ADB over TCP**: Android only, works over LAN
- **Serial bridge**: network serial server for Arduino/embedded
- **Dedicated lobsigliere hardware node**: lobsigliere has physical USB access, proxies to lobster

No decision made. Needs a dedicated investigation. See open questions.

### Tool Self-Discovery
Lobsters should be able to identify missing tools mid-task, install them, and surface the install steps back to the container definition. Rough flow:
1. Lobster hits a missing tool during a task
2. Installs it locally for the current job
3. Files a task (or PR) to add the tool to the Dockerfile
4. Maintainer reviews and merges

This prevents lobsters from silently failing on missing toolchain components and creates a feedback loop for improving images. See scratch sheet: "allow lobsters to identify missing tools that they need, install them, have a process for ensuring these make it back into the lobster container's install requirements."

### Variant Test Flows
Each variant needs a smoke test that verifies the toolchain is functional — not a full task, just a proof that the key tools are installed and runnable. These live in `tests/` and run against the local k3d cluster or as a build-time `RUN` step in the Dockerfile.

### Image Size Management
Large images (Unity: ~15-20GB, ML: ~8-12GB) need mitigation:
- Layer caching: all variants share lobmob-base layers
- Pre-pull DaemonSet on lobster nodes for large images
- Multi-stage builds to separate build-time deps from runtime
- Version-tagged images (`lobster-unity:6000.0.39f1`) for pinning

## Open Questions

- [ ] **Device tunneling**: what's the right architecture for hardware-connected lobsters? USB/IP, ADB over TCP, serial bridge, or lobsigliere proxy?
- [ ] **Tool self-discovery**: what's the mechanism for lobsters to surface missing tools back to the image definition? File a PR? Create a lobmob task? Post to Discord?
- [ ] **MCP servers**: several variants could benefit from domain-specific MCP servers (unity-mcp, android-studio-mcp, etc.) — see scratch sheet. Investigate availability and integration path.
- [ ] **`mise` for tool management**: scratch sheet mentions `mise.jdx.dev` for managing tool versions in lobsters. Worth evaluating as a cross-variant pattern.
- [ ] **Build order**: unity and android share toolchain components. Build android first (smaller, simpler) as the proof-of-concept, then unity.
- [ ] **Xcode path**: requires macOS infrastructure. Separate Mac node? GitHub Actions macOS runner as a lobster target? Out of scope until macOS infra is defined.

## Phases

### Phase 1: Framework
- Add `containers/lobster-<variant>/` directory structure
- Establish Dockerfile conventions (FROM lobmob-lobster, ENTRYPOINT, ENV vars)
- Add variant image build to CI/CD (when CI/CD plan is implemented)
- Add `LOBSTER_<NAME>_IMAGE` pattern to lobboss ConfigMap + overlay template

### Phase 2: Android (proof of concept)
- First real variant — smallest image, well-understood toolchain
- Validates the full pipeline: Dockerfile → build → overlay → job dispatch

### Phase 3: Unity
- Largest image, most research done
- Validates large-image strategy (pre-pull DaemonSet, layer caching)

### Phase 4: Remaining variants
- Ghidra, Arduino, PCB, ROS2 — can proceed in parallel once Phase 1 pattern is established
- Xcode blocked on macOS infra decision

### Phase 5: Cross-cutting
- Device tunneling architecture
- Tool self-discovery feedback loop
- MCP server integration for applicable variants

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-23 | Android before Unity as proof-of-concept | Smaller image, simpler toolchain, validates the pipeline without 15-20GB build |
| 2026-02-23 | Xcode variant blocked pending macOS infra | Xcode cannot run on Linux; requires separate investigation |

## Scratch

- `mcp_tools.py` already has `android` and `unity` in the workflow→image map (lines 29-30)
- Both are currently mapped to the base lobster image as fallback — no variant Dockerfiles exist yet
- `mise.jdx.dev` worth evaluating — handles multiple language runtimes and tool versions, could replace ad-hoc apt installs in Dockerfiles
- `catsyphon` (scratch sheet) for Claude usage insight — unrelated to variants but noted

## Related

- [Roadmap](../roadmap.md)
- [CI/CD plan](./ci-cd.md)
- [Local overlay](./local-overlay.md)
- [Research: Agent SDK deep dive](../../research/agent-sdk-deep-dive.md)
