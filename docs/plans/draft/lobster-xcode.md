---
status: draft
tags: [lobster, variants, xcode, ios, macos, mobile]
maturity: research
created: 2026-02-23
updated: 2026-02-23
---
# Lobster Variant: Xcode

## Summary

Lobster targeting iOS/macOS development with Xcode. **Blocked**: Xcode requires macOS; DOKS nodes run Linux (Ubuntu/amd64). This plan exists to define the requirements and evaluate infrastructure options — the variant cannot be implemented until a macOS execution environment is available.

## The Blocker

Xcode is macOS-only. There is no Linux port. All options involve either:
1. macOS infrastructure (dedicated Mac, cloud Mac, CI runner)
2. Cross-compilation toolchains (limited, not full Xcode)

## Infrastructure Options

| Option | Notes |
|---|---|
| **Mac mini / Mac Studio** (physical) | Full Xcode, full device access. High upfront cost, always-on. Could run k3s or just Docker. |
| **MacStadium / Scaleway Apple Silicon** | Cloud Mac rental. ~$100-150/mo. Full macOS, SSH access. |
| **GitHub Actions macOS runner** | Pay-per-minute ($0.08/min for Apple Silicon). Good for CI builds, not for long-running lobster jobs (90-min Agent SDK sessions). |
| **Orka (MacStadium k8s for Mac)** | k8s cluster of Mac nodes. Expensive, enterprise-focused. |
| **`xcbeautify` + remote build** | Trigger Xcode build on a remote Mac from a Linux lobster. The lobster is Linux, the Mac is a build server. Complex but possible. |

## Open Questions

- [ ] **Infrastructure decision**: which macOS option fits the lobmob model? A dedicated Mac mini in the same network as lobsigliere would allow USB device access too.
- [ ] **Device tunneling**: physical iOS device testing requires USB. If using a remote Mac, need USB forwarding or `devicectl` over the network.
- [ ] **Licensing**: Xcode is free on macOS App Store. No per-seat licensing issue.
- [ ] **k3s on Mac**: k3s runs on macOS via a Linux VM (Lima). A Mac mini running k3s could join the lobmob cluster as a macOS-capable node, allowing the standard lobster Job pattern to work with a macOS nodeSelector.
- [ ] **`xcodebuild` headless**: Xcode has a `xcodebuild` CLI that works without GUI. Lobster would use this rather than the IDE.
- [ ] **`swift` CLI**: Swift compiler runs on Linux (`swiftlang/swift` Docker image). Pure Swift tasks (no UIKit, no Xcode project) could run on Linux. Only full Xcode project builds need macOS.

## Phases (pending infrastructure decision)

### Phase 0: Infrastructure decision
- Evaluate Mac mini vs cloud Mac vs remote build server
- Determine if Mac node joins lobmob k8s cluster or is a standalone build server

### Phase 1: macOS execution environment
- Provision macOS node
- Install Xcode, `xcodebuild`, `xcbeautify`, `fastlane`
- Verify lobster container (or native process) can run on the Mac

### Phase 2: Overlay + integration
- Add macOS nodeSelector or external trigger mechanism
- Wire into lobboss workflow dispatch

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-23 | Marked blocked | Xcode requires macOS; no Linux path exists |

## Scratch

- `swift` Docker images exist for Linux: `swiftlang/swift:nightly-focal` — useful for pure Swift packages
- `xcbeautify` formats `xcodebuild` output — useful but doesn't change the macOS requirement
- `fastlane` runs on macOS and Linux but Xcode-dependent actions still need macOS
- Mac mini M4 starts at ~$599 — one-time cost vs $100-150/mo cloud Mac
- If using a physical Mac, it could double as the lobsigliere node for hardware access (USB to iOS + Android + Arduino)

## Related

- [Lobster Variants overview](./lobster-variants.md)
- [Lobster Unity](./lobster-unity.md) — shares iOS build interest (Unity → Xcode project)
- [Lobster Arduino](./lobster-arduino.md) — shares device tunneling concern
