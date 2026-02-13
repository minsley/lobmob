---
name: unity-test
description: Run Unity Test Framework tests (EditMode and PlayMode) in batch mode
---

# Unity Test

Use this skill to run Unity Test Framework tests in headless batch mode.

## 1. Find Unity Editor

```bash
UNITY_BIN=$(find /opt/unity -name "Unity" -type f 2>/dev/null | head -1)
```

## 2. Check for Tests

```bash
# EditMode tests
find Assets -path "*/Tests/EditMode/*.cs" -o -path "*/Tests/Editor/*.cs" 2>/dev/null

# PlayMode tests
find Assets -path "*/Tests/PlayMode/*.cs" -o -path "*/Tests/Runtime/*.cs" 2>/dev/null

# Test assembly definitions
find Assets -name "*.asmdef" 2>/dev/null | xargs grep -l "testAssemblies\|UnityEditor.TestRunner" 2>/dev/null
```

## 3. Run EditMode Tests

```bash
$UNITY_BIN -batchmode -nographics -projectPath . \
  -runTests -testPlatform EditMode \
  -testResults /tmp/editmode-results.xml \
  -logFile /tmp/unity-editmode.log -quit
TEST_EXIT=$?

echo "EditMode tests exit code: $TEST_EXIT"
```

## 4. Run PlayMode Tests

PlayMode tests may need Xvfb for rendering:

```bash
xvfb-run --auto-servernum $UNITY_BIN -batchmode -nographics -projectPath . \
  -runTests -testPlatform PlayMode \
  -testResults /tmp/playmode-results.xml \
  -logFile /tmp/unity-playmode.log -quit
TEST_EXIT=$?

echo "PlayMode tests exit code: $TEST_EXIT"
```

## 5. Parse Results

```bash
# Quick summary from NUnit XML results
if [ -f /tmp/editmode-results.xml ]; then
  echo "=== EditMode Results ==="
  grep -oP 'total="\K[^"]+' /tmp/editmode-results.xml | head -1
  grep -oP 'passed="\K[^"]+' /tmp/editmode-results.xml | head -1
  grep -oP 'failed="\K[^"]+' /tmp/editmode-results.xml | head -1
fi

if [ -f /tmp/playmode-results.xml ]; then
  echo "=== PlayMode Results ==="
  grep -oP 'total="\K[^"]+' /tmp/playmode-results.xml | head -1
  grep -oP 'passed="\K[^"]+' /tmp/playmode-results.xml | head -1
  grep -oP 'failed="\K[^"]+' /tmp/playmode-results.xml | head -1
fi
```

## 6. Troubleshooting

- **No tests found**: Check `.asmdef` files reference `UnityEngine.TestRunner` and `UnityEditor.TestRunner`
- **PlayMode tests hang**: Use `xvfb-run` and set a timeout: `timeout 300 xvfb-run ...`
- **Assembly errors**: Check that test assemblies reference the correct production assemblies
- **Exit code 2**: Tests ran but some failed — check the XML results for details
