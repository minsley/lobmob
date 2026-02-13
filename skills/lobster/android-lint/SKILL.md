---
name: android-lint
description: Run Android Lint and optional Kotlin static analysis (ktlint/detekt) on an Android project
---

# Android Lint

Use this skill to run static analysis on Android projects.

## 1. Android Lint

```bash
# Run lint on debug variant
./gradlew lintDebug

# Check for lint report
cat app/build/reports/lint-results-debug.txt 2>/dev/null \
  || echo "Check app/build/reports/lint-results-debug.html"
```

### Interpreting Results

- **Error**: Must fix — will cause build failures or runtime crashes
- **Warning**: Should fix — potential bugs or performance issues
- **Informational**: Nice to fix — style and best practices

### Suppressing False Positives

If lint reports a false positive, suppress with `@SuppressLint("IssueId")` in code or add to `lint.xml`:

```xml
<lint>
  <issue id="IssueId" severity="ignore" />
</lint>
```

## 2. Kotlin Static Analysis (if available)

### ktlint

```bash
# Check if ktlint is configured
./gradlew tasks --all 2>/dev/null | grep -i ktlint

# Run if available
./gradlew ktlintCheck 2>/dev/null || echo "ktlint not configured"
```

### detekt

```bash
# Check if detekt is configured
./gradlew tasks --all 2>/dev/null | grep -i detekt

# Run if available
./gradlew detekt 2>/dev/null || echo "detekt not configured"
```

## 3. Unit Tests

```bash
# Run unit tests (JVM-based, no emulator needed)
./gradlew test

# View test results
find app/build/reports/tests -name "index.html" 2>/dev/null
```
