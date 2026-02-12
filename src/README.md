# VR Telepresence System for UR10e with HP Reverb G2

A complete Windows-based telepresence system for controlling a UR10e robotic arm via VR head tracking, with stereoscopic video feedback.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           WINDOWS HOST MACHINE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐   │
│  │  HP Reverb G2    │     │   Telepresence   │     │  Video Receiver  │   │
│  │  Head Tracking   │────▶│   Controller     │     │  (FFmpeg/OpenCV) │   │
│  │  (OpenVR/WMR)    │     │                  │     │                  │   │
│  └──────────────────┘     │  - 6DOF/3DOF     │     └────────▲─────────┘   │
│                           │  - Safety limits  │              │             │
│                           │  - Transforms     │              │             │
│                           └────────┬─────────┘              │             │
│                                    │                         │             │
│  ┌─────────────────────────────────┼─────────────────────────┼───────────┐ │
│  │              Docker / WSL2      │     RTDE (port 30004)   │           │ │
│  │  ┌──────────────────────────────▼─────────────────────┐   │           │ │
│  │  │                    URSim                           │   │           │ │
│  │  │            (Robot Simulation)                      │   │           │ │
│  │  │                                                    │   │           │ │
│  │  │  - Same API as real robot                         │   │           │ │
│  │  │  - Web GUI at http://localhost:6080               │   │           │ │
│  │  │  - Ports: 29999, 30001-30004                      │   │           │ │
│  │  └────────────────────────────────────────────────────┘   │           │ │
│  └───────────────────────────────────────────────────────────┘           │ │
│                                                                           │ │
└───────────────────────────────────────────────────────────────────────────┘ │
                                    │                         │               
                                    │ (Same code works)       │               
                                    ▼                         │               
┌───────────────────────────────────────────────────────────────────────────┐
│                         ROBOT CELL (Real Hardware)                        │
│                                                                           │
│  ┌────────────────────┐          ┌────────────────────────────────────┐  │
│  │      UR10e         │◀─────────│  Stereoscopic Camera Rig          │  │
│  │   Robotic Arm      │          │  (2x cameras on end effector)     │  │
│  │                    │          │                                    │  │
│  │  IP: 192.168.1.x   │          │  FFmpeg stream ───────────────────┼──┼─▶ To VR
│  └────────────────────┘          └────────────────────────────────────┘  │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Windows Software
- Windows 10/11 with WSL2
- Docker Desktop
- Python 3.10 or 3.11
- SteamVR
- Windows Mixed Reality Portal
- FFmpeg (with NVENC support for NVIDIA GPUs)

### Python Packages
```powershell
pip install ur-rtde numpy opencv-python pyopenvr
```

## Quick Start

### Step 1: Start Robot Simulation

```powershell
# Pull and run URSim
docker run -d --name ursim ^
    -p 30001:30001 -p 30002:30002 -p 30003:30003 -p 30004:30004 ^
    -p 29999:29999 -p 6080:6080 ^
    universalrobots/ursim_e-series

# Access teach pendant GUI
start http://localhost:6080
```

In the URSim web interface:
1. Power on the robot (green button)
2. Release brakes
3. The robot is now ready to receive commands

### Step 2: Test Robot Connection

```powershell
python ur10e_test_connection.py
```

You should see:
```
Attempting to connect to robot at 127.0.0.1...
✓ Connected to RTDE Receive interface
✓ Current joint positions (radians): [...]
✓ Current TCP pose [x, y, z, rx, ry, rz]: [...]
✓ Robot mode: ROBOT_MODE_RUNNING (7)
✓ Connected to RTDE Control interface
CONNECTION TEST SUCCESSFUL!
```

### Step 3: Start VR Head Tracking

Make sure SteamVR is running and the G2 is detected, then:

```powershell
python vr_head_tracking_sender.py
```

### Step 4: Start Telepresence Controller

```powershell
python ur10e_telepresence_controller.py
```

**IMPORTANT**: Motion is disabled by default for safety. Edit the config to enable:
```python
config.enable_motion = True  # Only after testing in simulation!
```

### Step 5: (Optional) Video Streaming

On the robot side (where cameras are):
```powershell
ffmpeg_stereo_stream_sender.bat
```

On the VR side:
```powershell
python vr_video_receiver.py
```

## Configuration

### Telepresence Controller (`ur10e_telepresence_controller.py`)

```python
@dataclass
class Config:
    robot_ip: str = "127.0.0.1"      # URSim or real robot IP
    tracking_port: int = 5005         # UDP port for head tracking
    
    max_linear_speed: float = 0.25    # m/s - start slow!
    max_angular_speed: float = 0.5    # rad/s
    
    # Workspace limits (meters)
    workspace_min: tuple = (-0.8, -0.8, 0.1)
    workspace_max: tuple = (0.8, 0.8, 1.2)
    
    # For your thesis comparison:
    control_mode: str = "6dof"        # or "3dof"
    
    enable_motion: bool = False       # SAFETY: Set True only when ready
```

### Video Streaming

Edit `ffmpeg_stereo_stream_sender.bat`:
```batch
SET TARGET_IP=192.168.1.100   # VR machine IP
SET WIDTH=2160                 # Per-eye width
SET HEIGHT=2160                # Per-eye height  
SET FPS=90                     # Match headset refresh
```

## Safety Considerations

1. **Always test in URSim first** - never run untested code on the real robot
2. **Start with `enable_motion = False`** - verify tracking data looks correct
3. **Use conservative speed limits** - start at 0.1 m/s and increase gradually
4. **Set appropriate workspace limits** - prevent the robot from reaching unsafe positions
5. **Have emergency stop ready** - know where the e-stop is on the real robot
6. **Test transforms carefully** - verify the VR-to-robot coordinate mapping is correct

## Switching to Real Robot

When ready to use the real UR10e:

1. Change the IP address:
   ```python
   config.robot_ip = "192.168.1.X"  # Your robot's actual IP
   ```

2. Ensure network connectivity:
   ```powershell
   ping 192.168.1.X
   ```

3. Start with very slow speeds and small movements

4. Have someone ready at the teach pendant/e-stop

## 6DOF vs 3DOF Comparison (For Your Thesis)

The controller supports both modes for your research:

```python
# Full 6DOF - position AND orientation
config.control_mode = "6dof"

# 3DOF - orientation ONLY (position stays fixed)  
config.control_mode = "3dof"
```

You can collect metrics like:
- Task completion time
- Path efficiency
- User comfort/immersion ratings
- Control precision

## Latency Optimization

For sub-30ms end-to-end latency:

1. **Video encoding**: Use NVENC with `preset=llhp` (low latency high performance)
2. **Network**: Use UDP/RTP, not TCP
3. **Robot control**: RTDE runs at 500Hz (2ms cycle)
4. **VR rendering**: Target headset refresh rate (90Hz for G2)

Typical latency breakdown:
- Camera capture: 5-10ms
- Encoding: 3-8ms (NVENC)
- Network: 1-5ms (local network)
- Decoding: 2-5ms
- VR rendering: 5-11ms
- **Total**: ~20-40ms achievable

## Troubleshooting

### URSim won't start
```powershell
docker logs ursim
# Check for errors, ensure ports aren't in use
```

### Can't connect to robot
- Check firewall settings
- Verify Docker port mappings
- Ensure robot is powered on in URSim GUI

### VR tracking not working
- Is SteamVR running?
- Is WMR Portal running?
- Check `vr_head_tracking_sender.py` output for errors

### High latency
- Reduce video resolution
- Use hardware encoding (NVENC)
- Check network for packet loss
- Reduce buffer sizes

## File Overview

| File | Purpose |
|------|---------|
| `ur10e_test_connection.py` | Test robot connectivity |
| `ur10e_telepresence_controller.py` | Main control loop |
| `vr_head_tracking_sender.py` | Extract & send head tracking |
| `vr_video_receiver.py` | Receive & display stereo video |
| `ffmpeg_stereo_stream_sender.bat` | Stream video from cameras |
| `ffmpeg_stereo_stream_receiver.bat` | Receive video stream |

## References

- [Universal Robots RTDE Guide](https://www.universal-robots.com/articles/ur/interface-communication/real-time-data-exchange-rtde-guide/)
- [ur_rtde Python Library](https://sdurobotics.gitlab.io/ur_rtde/)
- [OpenVR API Documentation](https://github.com/ValveSoftware/openvr/wiki/API-Documentation)
- [FFmpeg Streaming Guide](https://trac.ffmpeg.org/wiki/StreamingGuide)
