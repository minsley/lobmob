---
status: draft
tags: [lobster, variants, unity, gamedev, android, ios]
maturity: research
created: 2026-02-23
updated: 2026-02-23
---
# Lobster Variant: Unity

## Summary

Lobster image with Unity Editor (headless, Linux), Android SDK, and .NET SDK for Unity game development tasks — builds, tests, asset pipeline operations, and code work across Unity projects. Largest planned image (~15-20GB); validates the large-image strategy for the variants framework. Most pre-existing research.

## Toolchain

| Tool | Purpose | Notes |
|---|---|---|
| Unity Editor (headless) | Build, test, batch mode operations | Linux installer; no GUI needed |
| .NET SDK | C# compilation | Unity uses Mono/.NET |
| Android SDK | Android build target | Shared with lobster-android |
| Android NDK | Native Android builds | Required for IL2CPP |
| Java (JDK 17) | Android toolchain dependency | |
| `unity-activator` or license file | License management | Personal license is free (<$200k revenue) |

## Open Questions

- [ ] **Unity licensing**: Unity Personal is free but requires license activation, which is machine-bound and requires contacting Unity's license server. How does this work headlessly in a k8s Job (new pod = new machine ID)? Options: floating license (Unity Teams), license file baked into image (not ideal), or Unity's CI/CD license approach (`UNITY_LICENSE` env var).
- [ ] **Unity version strategy**: pin one version (e.g., 6000.0.39f1) in the image? Multiple versions = multiple image tags. How does lobboss select the right version?
- [ ] **iOS builds**: iOS builds require macOS + Xcode. Unity on Linux can generate Xcode project files but cannot compile them. iOS build lobster blocked pending macOS infra (see lobster-xcode plan).
- [ ] **Image size mitigation**: 15-20GB is large. Pre-pull DaemonSet on lobster nodes? Or accept slow cold starts? Consider stripping Unity components not needed for CI (e.g., skip iOS module on Linux build).
- [ ] **Unity MCP**: scratch sheet mentions `unity-mcp` — investigate. Could give lobster access to Unity Editor API beyond batch mode.
- [ ] **Test runner**: Unity has a built-in Test Runner (EditMode + PlayMode). How to capture results and surface to lobwife?

## Phases

### Phase 1: Base image
- `containers/lobster-unity/Dockerfile` extending `lobmob-lobster`
- Install Unity Editor headless (Linux, Unity 6 LTS)
- Install Android SDK + NDK, JDK 17, .NET SDK
- Resolve license activation for headless/CI use
- Smoke test: `$UNITY_PATH -batchmode -quit -nographics -logFile -` exits cleanly

### Phase 2: Overlay integration
- Build + push `lobmob-lobster-unity:latest` to GHCR
- Add pre-pull DaemonSet or node annotation for large image caching
- Verify lobboss dispatches unity-workflow tasks to correct image

### Phase 3: Skills + test runner
- Validate existing lobster skills work for Unity tasks
- Surface Unity Test Runner results to lobwife
- Write variant smoke test in `tests/`

### Phase 4: Version strategy
- Decide: single-version tag or multi-version tags
- If multi-version: `lobster-unity:6000.0.39f1`, `lobster-unity:2022.3-lts`
- lobboss selects version from task metadata `unity_version` field (or falls back to latest)

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-23 | Implement after Android | Android validates the pipeline; Unity then validates large-image strategy |

## Scratch

- Unity headless install command: `/opt/unity/UnitySetup -u 6000.0.39f1 -c Unity -c Android -c iOS --headless`
- `ENV UNITY_PATH=/opt/unity/6000.0.39f1/Editor/Unity`
- `ENV ANDROID_HOME=/opt/android-sdk`
- iOS module on Linux installs the Xcode project generator but can't compile — skip `-c iOS` to save space
- Unity license via env: `UNITY_LICENSE` (XML), `UNITY_LICENSE_FILE`, or `UNITY_SERIAL` + `UNITY_USERNAME` + `UNITY_PASSWORD`
- Layer caching: Android SDK layers can be shared with lobster-android if build order is managed
- `libgtk-3-0 libgbm1 libasound2 libvulkan1` are required Linux deps for Unity headless

## Related

- [Lobster Variants overview](./lobster-variants.md)
- [Lobster Android](./lobster-android.md) — shares Android SDK toolchain
- [Lobster Xcode](./lobster-xcode.md) — required for iOS compilation
- [Research: Agent SDK deep dive](../../research/agent-sdk-deep-dive.md) — detailed Unity image notes
