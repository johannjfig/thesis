import openvr
import time
import json

vr = openvr.init(openvr.VRApplication_Other)

print("Recording 5 seconds of data...")
time.sleep(2)

# Get reference (like recorder does)
poses = vr.getDeviceToAbsoluteTrackingPose(openvr.TrackingUniverseStanding, 0, 1)
m = poses[0].mDeviceToAbsoluteTracking
ref_pos = [m[0][3], m[1][3], m[2][3]]

samples = []
start = time.perf_counter()

while time.perf_counter() - start < 5:
    poses = vr.getDeviceToAbsoluteTrackingPose(openvr.TrackingUniverseStanding, 0, 1)
    m = poses[0].mDeviceToAbsoluteTracking
    pos = [m[0][3], m[1][3], m[2][3]]
    
    dx = (pos[0] - ref_pos[0]) * 100
    dy = (pos[1] - ref_pos[1]) * 100
    dz = (pos[2] - ref_pos[2]) * 100
    
    samples.append({"pos": pos})
    print(f"\rLive: X={dx:+6.1f}cm Y={dy:+6.1f}cm Z={dz:+6.1f}cm", end='')
    time.sleep(0.033)

# Save to file
with open("test_live.json", "w") as f:
    json.dump({"samples": samples}, f)

print("\n\nNow loading back and checking...")

with open("test_live.json", "r") as f:
    loaded = json.load(f)

ref_loaded = loaded["samples"][0]["pos"]
for s in loaded["samples"][-5:]:
    dx = (s["pos"][0] - ref_loaded[0]) * 100
    dy = (s["pos"][1] - ref_loaded[1]) * 100
    dz = (s["pos"][2] - ref_loaded[2]) * 100
    print(f"Loaded: X={dx:+6.1f}cm Y={dy:+6.1f}cm Z={dz:+6.1f}cm")

openvr.shutdown()