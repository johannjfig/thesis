import openvr
import time
import math
import json
import argparse

"""
VR POSE RECORDER - CORRECTED

Records headset position and rotation at a specified rate.
Saves to JSON file for playback testing.

VR Axis Mapping (verified):
  Position: X=left/right, Y=up/down, Z=forward/back
  Rotation: RX=pitch(nod), RY=yaw(turn), RZ=roll(tilt)
"""

def matrix_to_euler(m):
    """Extract euler angles from OpenVR 3x4 matrix"""
    r00, r01, r02 = m[0][0], m[0][1], m[0][2]
    r10, r11, r12 = m[1][0], m[1][1], m[1][2]
    r20, r21, r22 = m[2][0], m[2][1], m[2][2]
    
    if abs(r20) < 0.99999:
        ry = math.asin(-r20)
        rx = math.atan2(r21, r22)
        rz = math.atan2(r10, r00)
    else:
        ry = math.pi / 2 if r20 < 0 else -math.pi / 2
        rx = math.atan2(-r12, r11)
        rz = 0
    
    return [rx, ry, rz]

def normalize_angle(a):
    """Normalize angle to [-pi, pi]"""
    while a > math.pi:
        a -= 2 * math.pi
    while a < -math.pi:
        a += 2 * math.pi
    return a

def get_hmd_pose(vr):
    """Get position and rotation from HMD"""
    poses = vr.getDeviceToAbsoluteTrackingPose(openvr.TrackingUniverseStanding, 0, 1)
    m = poses[0].mDeviceToAbsoluteTracking
    
    # Position: X=left/right, Y=up/down, Z=forward/back
    position = [m[0][3], m[1][3], m[2][3]]
    
    # Rotation: RX=pitch, RY=yaw, RZ=roll
    rotation = matrix_to_euler(m)
    
    return position, rotation

def main():
    parser = argparse.ArgumentParser(description="Record VR headset poses")
    parser.add_argument("--rate", type=int, default=60, help="Recording rate in Hz (default: 30)")
    parser.add_argument("--duration", type=float, default=30.0, help="Recording duration in seconds (default: 10)")
    parser.add_argument("--output", type=str, default="vr_recording.json", help="Output file (default: vr_recording.json)")
    args = parser.parse_args()
    
    rate = args.rate
    duration = args.duration
    output_file = args.output
    loop_time = 1.0 / rate
    
    print("="*50)
    print("VR POSE RECORDER")
    print("="*50)
    print(f"Rate: {rate} Hz")
    print(f"Duration: {duration} seconds")
    print(f"Output: {output_file}")
    print(f"Expected samples: {int(rate * duration)}")
    
    # Connect to VR
    print("\nConnecting to VR...")
    vr = openvr.init(openvr.VRApplication_Other)
    print("Connected!")
    
    # Recording data structure
    recording = {
        "rate": rate,
        "duration": duration,
        "samples": []
    }
    
    print(f"\nRecording starts in 3 seconds...")
    print("Move your head naturally during recording.")
    time.sleep(3)
    
    print("RECORDING...")
    print("Live view (deltas from start in cm and degrees):\n")
    
    start_time = time.perf_counter()
    sample_count = 0
    
    # Capture reference position
    ref_position, ref_rotation = get_hmd_pose(vr)
    
    while True:
        loop_start = time.perf_counter()
        elapsed = loop_start - start_time
        
        if elapsed >= duration:
            break
        
        # Get pose
        position, rotation = get_hmd_pose(vr)
        
        # Calculate deltas for display
        dx = (position[0] - ref_position[0]) * 100  # cm
        dy = (position[1] - ref_position[1]) * 100
        dz = (position[2] - ref_position[2]) * 100
        
        drx = math.degrees(normalize_angle(rotation[0] - ref_rotation[0]))
        dry = math.degrees(normalize_angle(rotation[1] - ref_rotation[1]))
        drz = math.degrees(normalize_angle(rotation[2] - ref_rotation[2]))
        
        # Store sample (raw values, not deltas)
        sample = {
            "t": elapsed,
            "pos": position,
            "rot": rotation
        }
        recording["samples"].append(sample)
        sample_count += 1
        
        # Live display
        print(f"\r  {elapsed:5.1f}s | "
              f"L/R:{dx:+6.1f}cm  U/D:{dy:+6.1f}cm  F/B:{dz:+6.1f}cm | "
              f"Pitch:{drx:+6.1f}°  Yaw:{dry:+6.1f}°  Roll:{drz:+6.1f}°  "
              f"[{sample_count} samples]", end='')
        
        # Maintain rate
        loop_elapsed = time.perf_counter() - loop_start
        if loop_elapsed < loop_time:
            time.sleep(loop_time - loop_elapsed)
    
    end_time = time.perf_counter()
    actual_duration = end_time - start_time
    
    print(f"\n\nRECORDING COMPLETE")
    print(f"  Actual duration: {actual_duration:.2f}s")
    print(f"  Samples recorded: {sample_count}")
    print(f"  Actual rate: {sample_count/actual_duration:.1f} Hz")
    
    # Calculate and show movement ranges
    samples = recording["samples"]
    ref_pos = samples[0]["pos"]
    ref_rot = samples[0]["rot"]
    
    dx_vals = [(s["pos"][0] - ref_pos[0]) * 100 for s in samples]
    dy_vals = [(s["pos"][1] - ref_pos[1]) * 100 for s in samples]
    dz_vals = [(s["pos"][2] - ref_pos[2]) * 100 for s in samples]
    
    drx_vals = [math.degrees(normalize_angle(s["rot"][0] - ref_rot[0])) for s in samples]
    dry_vals = [math.degrees(normalize_angle(s["rot"][1] - ref_rot[1])) for s in samples]
    drz_vals = [math.degrees(normalize_angle(s["rot"][2] - ref_rot[2])) for s in samples]
    
    print(f"\nMovement ranges:")
    print(f"  Left/Right (X): {min(dx_vals):.1f} to {max(dx_vals):.1f} cm (range: {max(dx_vals)-min(dx_vals):.1f} cm)")
    print(f"  Up/Down (Y):    {min(dy_vals):.1f} to {max(dy_vals):.1f} cm (range: {max(dy_vals)-min(dy_vals):.1f} cm)")
    print(f"  Fwd/Back (Z):   {min(dz_vals):.1f} to {max(dz_vals):.1f} cm (range: {max(dz_vals)-min(dz_vals):.1f} cm)")
    print(f"  Pitch (nod):    {min(drx_vals):.1f} to {max(drx_vals):.1f}° (range: {max(drx_vals)-min(drx_vals):.1f}°)")
    print(f"  Yaw (turn):     {min(dry_vals):.1f} to {max(dry_vals):.1f}° (range: {max(dry_vals)-min(dry_vals):.1f}°)")
    print(f"  Roll (tilt):    {min(drz_vals):.1f} to {max(drz_vals):.1f}° (range: {max(drz_vals)-min(drz_vals):.1f}°)")
    
    # Save to file
    with open(output_file, 'w') as f:
        json.dump(recording, f, indent=2)
    
    print(f"\nSaved to: {output_file}")
    
    # Cleanup
    openvr.shutdown()

if __name__ == "__main__":
    main()