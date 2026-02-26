---
status: draft
tags: [lobster, variants, android, mobile]
maturity: research
created: 2026-02-23
updated: 2026-02-23
---
# Lobster Variant: Android

## Summary

Lobster image with Android SDK, ADB, Gradle, and related toolchain for Android development tasks — building APKs, running instrumented tests, code analysis, and dependency management. First variant to implement as proof-of-concept for the variants framework; smaller and simpler than Unity.

## Toolchain

| Tool | Purpose | Notes |
|---|---|---|
| Android SDK (cmdline-tools) | Build tools, platform tools | `sdkmanager` for package management |
| ADB | Device/emulator communication | Needed for on-device testing |
| Gradle | Build system | Most Android projects use Gradle |
| Java (JDK 17+) | Android build requirement | OpenJDK, already in many base images |
| Android Emulator | Local device simulation | x86_64 emulation — may not work on arm64 nodes |
| `.apk` / `.aab` signing tools | Release builds | `apksigner`, `zipalign` |

## Open Questions

- [ ] **Emulator on k8s**: Android emulator requires KVM (hardware virtualization). DOKS nodes likely don't expose KVM. Options: skip emulator (build + lint only), run emulator on lobsigliere node, use Firebase Test Lab API.
- [ ] **Device tunneling**: physical Android device access for instrumented tests. ADB over TCP is straightforward on LAN but lobsters run in cloud k8s. See variants overview device tunneling question.
- [ ] **SDK version pinning**: which Android API levels to include? Bigger = larger image. Start with latest stable (API 35) + one LTS level.
- [ ] **NDK**: include Android NDK for native (C/C++) code? Adds ~2GB. Make optional or a separate image tag.
- [ ] **Android Studio MCP**: scratch sheet mentions `android-studio-mcp` — investigate availability. Could give lobster richer IDE-level tooling.

## Phases

### Phase 1: Base image
- `containers/lobster-android/Dockerfile` extending `lobmob-lobster`
- Install: cmdline-tools, platform-tools, ADB, JDK 17, Gradle wrapper
- Accept Android SDK licenses non-interactively
- Smoke test: `adb version`, `sdkmanager --list`, `gradle --version`

### Phase 2: Overlay integration
- Add `LOBSTER_ANDROID_IMAGE` to prod overlay (already in dev overlay — confirm it points to a real image)
- Build + push `lobmob-lobster-android:latest` to GHCR
- Verify lobboss dispatches android-workflow tasks to correct image

### Phase 3: Skills
- Confirm existing lobster skills (code-task, verify-task) work for Android tasks
- Add Android-specific guidance to system prompt or skill if needed
- Write variant smoke test in `tests/`

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-23 | Implement before Unity | Smaller image (~2-3GB vs 15-20GB), simpler toolchain, validates variants pipeline |

## Scratch

- `sdkmanager` accepts `--licenses` flag for non-interactive license acceptance
- Base image has Python + Node.js; JDK adds ~300MB
- `ANDROID_HOME=/opt/android-sdk` is the conventional env var
- Emulator KVM problem: build-only lobster (no emulator) is still very useful for most Android tasks
- `fastlane` worth considering for release automation tasks

## Related

- [Lobster Variants overview](./lobster-variants.md)
- [mcp_tools.py](../../../src/lobboss/mcp_tools.py) — workflow→image mapping
