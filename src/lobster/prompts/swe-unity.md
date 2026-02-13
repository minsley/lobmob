## Unity Development Environment

This container has Unity 6000.3 LTS installed for headless/batch mode operations. All Unity operations must use the CLI — there is no GUI.

### Unity CLI (Batch Mode)

The Unity editor binary is at `$UNITY_EDITOR_PATH` or can be found via:
```bash
UNITY_BIN=$(find /opt/unity -name "Unity" -type f 2>/dev/null | head -1)
```

All commands use `-batchmode -nographics` for headless operation:
```bash
$UNITY_BIN -batchmode -nographics -projectPath /path/to/project <command>
```

### Common Operations

#### Build
```bash
# Build StandaloneLinux64
$UNITY_BIN -batchmode -nographics -projectPath . \
  -executeMethod BuildScript.BuildLinux64 \
  -buildTarget Linux64 -quit

# Build WebGL
$UNITY_BIN -batchmode -nographics -projectPath . \
  -executeMethod BuildScript.BuildWebGL \
  -buildTarget WebGL -quit
```

Note: The project needs a `BuildScript` class with static build methods. If one doesn't exist, create it at `Assets/Editor/BuildScript.cs`.

#### Run Tests
```bash
# EditMode tests
$UNITY_BIN -batchmode -nographics -projectPath . \
  -runTests -testPlatform EditMode \
  -testResults /tmp/editmode-results.xml -quit

# PlayMode tests
$UNITY_BIN -batchmode -nographics -projectPath . \
  -runTests -testPlatform PlayMode \
  -testResults /tmp/playmode-results.xml -quit
```

#### Import/Refresh
```bash
# Force reimport all assets
$UNITY_BIN -batchmode -nographics -projectPath . \
  -importPackage -quit
```

### Project Structure Conventions

```
Assets/               — All project assets
  Editor/             — Editor-only scripts (build scripts, custom inspectors)
  Scripts/            — Runtime scripts
  Prefabs/            — Prefab assets
  Scenes/             — Scene files
  Resources/          — Runtime-loadable resources
  Tests/              — Test assemblies
    EditMode/         — EditMode test scripts
    PlayMode/         — PlayMode test scripts
Packages/
  manifest.json       — Package Manager dependencies
ProjectSettings/      — Unity project settings
```

### Package Manager

Edit `Packages/manifest.json` directly to add/remove packages:
```json
{
  "dependencies": {
    "com.unity.textmeshpro": "3.2.0-pre.2",
    "com.unity.2d.sprite": "1.0.0"
  }
}
```

After editing, Unity will resolve packages on next batch mode invocation.

### Limitations

- **No GUI**: Cannot open scenes visually or use the Scene/Game views
- **No Play mode preview**: PlayMode tests run headless via Xvfb
- **License required**: Unity Plus/Pro license needed for headless Linux builds
- **Large image**: Container is 5-10GB due to Unity editor
- **Build methods**: Custom build scripts (`-executeMethod`) must exist in the project under `Assets/Editor/`

### Xvfb for Rendering

Some operations need a virtual display (PlayMode tests, screenshot tests):
```bash
xvfb-run --auto-servernum $UNITY_BIN -batchmode -nographics -projectPath . -runTests ...
```

### Troubleshooting

- **License expired**: Check `UNITY_SERIAL` env var, re-activate via `-serial`
- **Import errors**: Run with `-logFile /tmp/unity.log` and check the log
- **Missing assembly references**: Ensure `.asmdef` files are correct
- **Build fails silently**: Always use `-logFile` and check exit code
