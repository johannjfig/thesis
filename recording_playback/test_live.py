import openvr
import time

vr = openvr.init(openvr.VRApplication_Other)

print("Move your head and watch the values...")
print("Move 50cm LEFT then RIGHT - X should change by ~0.5")
print("Move 50cm UP then DOWN - Y should change by ~0.5")
print("Move 50cm FORWARD then BACK - Z should change by ~0.5")
print()

start_pos = None
while True:
    poses = vr.getDeviceToAbsoluteTrackingPose(openvr.TrackingUniverseStanding, 0, 1)
    m = poses[0].mDeviceToAbsoluteTracking
    x, y, z = m[0][3], m[1][3], m[2][3]
    
    if start_pos is None:
        start_pos = (x, y, z)
    
    dx = (x - start_pos[0]) * 100
    dy = (y - start_pos[1]) * 100
    dz = (z - start_pos[2]) * 100
    
    print(f"\rX:{dx:+6.1f}cm  Y:{dy:+6.1f}cm  Z:{dz:+6.1f}cm", end='')
    time.sleep(0.05)