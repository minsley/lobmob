---
name: unity-build
description: Build a Unity project in batch mode — StandaloneLinux64, WebGL, or Android targets
---

# Unity Build

Use this skill to build Unity projects in headless batch mode.

## 1. Find Unity Editor

```bash
UNITY_BIN=$(find /opt/unity -name "Unity" -type f 2>/dev/null | head -1)
echo "Unity: $UNITY_BIN"
$UNITY_BIN -version 2>/dev/null || echo "Check UNITY_EDITOR_PATH"
```

## 2. Check for Build Script

The project needs a static build method. Check for one:

```bash
find Assets/Editor -name "*.cs" 2>/dev/null | xargs grep -l "BuildPipeline" 2>/dev/null
```

If no build script exists, create `Assets/Editor/BuildScript.cs`:

```csharp
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;

public class BuildScript
{
    [MenuItem("Build/Linux64")]
    public static void BuildLinux64()
    {
        var options = new BuildPlayerOptions
        {
            scenes = EditorBuildSettings.scenes
                .Where(s => s.enabled)
                .Select(s => s.path).ToArray(),
            locationPathName = "Build/Linux64/game",
            target = BuildTarget.StandaloneLinux64,
            options = BuildOptions.None
        };
        var report = BuildPipeline.BuildPlayer(options);
        if (report.summary.result != BuildResult.Succeeded)
            throw new System.Exception("Build failed");
    }
}
```

## 3. Build

```bash
# StandaloneLinux64
$UNITY_BIN -batchmode -nographics -projectPath . \
  -executeMethod BuildScript.BuildLinux64 \
  -logFile /tmp/unity-build.log -quit
BUILD_EXIT=$?

# Check result
if [ $BUILD_EXIT -ne 0 ]; then
  echo "Build failed. Last 50 lines of log:"
  tail -50 /tmp/unity-build.log
fi
```

## 4. Verify Output

```bash
find Build/ -type f -name "*.x86_64" -o -name "*.html" -o -name "*.apk" 2>/dev/null
```

## 5. Troubleshooting

- **Exit code 0 but no output**: Check `-executeMethod` target exists and is `static`
- **License error**: Activate with `$UNITY_BIN -batchmode -serial $UNITY_SERIAL -username $UNITY_EMAIL -password $UNITY_PASSWORD -quit`
- **Script compilation errors**: Check `/tmp/unity-build.log` for `error CS`
- **Missing scenes**: Ensure scenes are added to Build Settings (`EditorBuildSettings.scenes`)
