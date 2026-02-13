## Android Development Environment

This container has Android development tools installed. Use them for building, testing, and linting Android projects.

### Available Tools

- **JDK 17**: `java`, `javac` (OpenJDK 17 headless)
- **Android SDK**: `$ANDROID_HOME=/opt/android-sdk`
  - `sdkmanager` — install additional SDK components
  - `adb` — Android Debug Bridge (limited use in headless container)
- **Installed SDK components**:
  - `platform-tools` (adb, fastboot)
  - `build-tools;34.0.0`
  - `platforms;android-34`

### Gradle Build Commands

Most Android projects use Gradle. The project's `gradlew` wrapper handles Gradle installation.

```bash
# Build debug APK
./gradlew assembleDebug

# Build release APK (unsigned)
./gradlew assembleRelease

# Build AAB (Android App Bundle)
./gradlew bundleRelease

# Run unit tests
./gradlew test

# Run Android lint
./gradlew lintDebug

# Clean build
./gradlew clean
```

### Project Structure Conventions

```
app/
  src/main/
    java/ or kotlin/    — source code
    res/                — resources (layouts, drawables, strings)
    AndroidManifest.xml — app manifest
  src/test/             — unit tests
  src/androidTest/      — instrumented tests (not available headless)
  build.gradle.kts      — module build config
build.gradle.kts         — project-level build config
settings.gradle.kts      — project settings
gradle.properties        — Gradle properties
```

### Limitations

- **No emulator**: This is a headless container. Unit tests (`./gradlew test`) work, but instrumented tests (`./gradlew connectedAndroidTest`) require an emulator and will fail.
- **No GUI**: No Android Studio. All operations via command line.
- **Unsigned builds**: Release builds will be unsigned unless a keystore is provided.

### Installing Additional SDK Components

If the project needs additional SDK components:

```bash
sdkmanager "ndk;26.1.10909125"
sdkmanager "cmake;3.22.1"
```

### Common Issues

- **Gradle daemon memory**: Set `org.gradle.jvmargs=-Xmx2g` in `gradle.properties` if builds OOM
- **SDK license not accepted**: Run `yes | sdkmanager --licenses` if new components need license acceptance
- **Missing build tools version**: Check `build.gradle.kts` for required `buildToolsVersion` and install via `sdkmanager`
