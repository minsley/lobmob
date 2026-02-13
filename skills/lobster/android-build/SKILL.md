---
name: android-build
description: Build an Android project using Gradle — assembleDebug, assembleRelease, or bundleRelease
---

# Android Build

Use this skill to build Android projects. Supports debug APK, release APK, and AAB bundle targets.

## 1. Verify Environment

```bash
java -version
echo "ANDROID_HOME=$ANDROID_HOME"
sdkmanager --list_installed 2>/dev/null | head -20
```

## 2. Check Project Setup

```bash
# Verify gradlew exists and is executable
ls -la gradlew
chmod +x gradlew

# Check required SDK versions
grep -E "compileSdk|buildToolsVersion|targetSdk" app/build.gradle.kts 2>/dev/null \
  || grep -E "compileSdk|buildToolsVersion|targetSdk" app/build.gradle 2>/dev/null
```

If the project needs SDK components not installed, use `sdkmanager` to add them.

## 3. Build

```bash
# Debug build (fastest, for development)
./gradlew assembleDebug

# Release build (unsigned)
./gradlew assembleRelease

# Android App Bundle (for Play Store)
./gradlew bundleRelease
```

## 4. Verify Output

```bash
# APK location
find app/build/outputs -name "*.apk" -type f 2>/dev/null

# Bundle location
find app/build/outputs -name "*.aab" -type f 2>/dev/null
```

## 5. Troubleshooting

- **OOM during build**: Add `org.gradle.jvmargs=-Xmx2g` to `gradle.properties`
- **Missing SDK**: `sdkmanager "platforms;android-<version>"`
- **Dependency resolution failure**: Check network access, try `./gradlew --refresh-dependencies`
- **Kotlin version mismatch**: Check `kotlin` version in project-level `build.gradle.kts`
