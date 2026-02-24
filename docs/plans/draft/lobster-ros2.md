---
status: draft
tags: [lobster, variants, ros2, robotics, embedded]
maturity: research
created: 2026-02-23
updated: 2026-02-23
---
# Lobster Variant: ROS2

## Summary

Lobster image with ROS2 (Robot Operating System 2), Gazebo simulation, and supporting tools for robotics development tasks — writing nodes, configuring launch files, simulation, navigation stack work, and interfacing with robot hardware. ROS2 is Linux-native (Ubuntu) and has strong headless/CI support.

## Toolchain

| Tool | Purpose | Notes |
|---|---|---|
| ROS2 (Humble or Jazzy) | Core robotics middleware | Ubuntu packages; Humble=LTS, Jazzy=current |
| Gazebo (Harmonic) | 3D robot simulation | `gz sim` headless mode available |
| `colcon` | ROS2 build system | Replaces catkin from ROS1 |
| `rosdep` | Dependency management | Installs ROS package dependencies |
| Python 3 `rclpy` | Python ROS2 client library | Already have Python in base |
| `rclcpp` + build tools | C++ ROS2 support | For C++ node development |
| `ros2 bag` | Data recording and playback | For testing with recorded sensor data |
| `nav2` stack | Navigation / SLAM | Optional; large dependency set |
| `moveit2` | Manipulation planning | Optional; large dependency set |

## Open Questions

- [ ] **ROS2 distribution**: Humble (LTS, Ubuntu 22.04) or Jazzy (current, Ubuntu 24.04)? Base image OS version matters — current lobmob-base likely Ubuntu 22.04 or 24.04.
- [ ] **Gazebo headless**: `gz sim -s` runs server-only (no GUI). Confirm rendering/sensor simulation works without display for camera/lidar sensor testing.
- [ ] **DDS middleware**: ROS2 uses DDS for inter-process comms. In a container this is fine. Multiple lobster Jobs talking over ROS topics would need shared DDS domain — probably not a use case, but worth noting.
- [ ] **Robot hardware access**: physical robots connected via USB/serial face the same problem as Arduino/Xcode. Lobsigliere or USB/IP proxy needed.
- [ ] **nav2 / MoveIt2**: these are large optional stacks. Include in base image or as sub-tags (`lobster-ros2:nav2`)?
- [ ] **`rosbag2` playback**: testing with pre-recorded sensor data is a strong use case for simulation tasks — no physical robot needed. Should be the default test pattern.

## Phases

### Phase 1: Base image
- `containers/lobster-ros2/Dockerfile` extending `lobmob-lobster`
- Install ROS2 (Humble or Jazzy) from official apt repos
- Install Gazebo, colcon, rosdep, rclpy
- Source ROS2 in entrypoint: `. /opt/ros/${ROS_DISTRO}/setup.bash`
- Smoke test: `ros2 --help`, `gz sim --version`

### Phase 2: Simulation flow
- Validate headless Gazebo simulation
- Lobster writes a node, builds with colcon, runs in simulation, reports to vault

### Phase 3: Optional stacks
- Evaluate nav2 and MoveIt2 inclusion (size vs utility tradeoff)
- Consider sub-tags for heavy optional stacks

### Phase 4: Hardware integration
- Pending device tunneling decision from variants overview

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|

## Scratch

- ROS2 install: `apt-get install ros-humble-desktop` (full) or `ros-humble-ros-base` (minimal, ~300MB lighter)
- `ros-humble-ros-base` is probably right for a lobster — no GUI tools needed
- Entrypoint must source ROS2 setup: `echo 'source /opt/ros/humble/setup.bash' >> ~/.bashrc` or set in Dockerfile `ENV` + `ENTRYPOINT`
- Gazebo headless: `gz sim -s -r world.sdf` (server-only, runs physics)
- `ros2 bag play` for sensor replay — great for testing perception/nav without hardware
- ROS2 + Docker: official `ros:humble` Docker images exist as a starting point, could extend those instead of building from lobmob-lobster

## Related

- [Lobster Variants overview](./lobster-variants.md)
- [Lobster Arduino](./lobster-arduino.md) — complementary hardware/embedded domain
- [Lobster Xcode](./lobster-xcode.md) — shares hardware access concern
