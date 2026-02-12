import rtde_control
import rtde_receive
import time
import math
import json
import argparse
import numpy as np

"""
ROBOT PLAYBACK v3 - HYBRID CONTROL

The key insight: 
- Position (translation) should move base/shoulder/elbow
- Rotation should move wrist1/wrist2/wrist3 directly

This version:
1. Uses the CURRENT joint positions as a base
2. Calculates desired TCP position change -> adjusts base/shoulder/elbow via IK
3. Applies rotation directly to wrist joints (no IK for rotation)

This prevents the "orbiting" problem where TCP rotation causes the whole arm to move.
"""

# ============================================================================
# CONFIGURATION
# ============================================================================

HOME_JOINTS = [
    math.radians(0),      # Base
    math.radians(-90),    # Shoulder
    math.radians(90),     # Elbow
    math.radians(-90),    # Wrist1 - pitch/nod
    math.radians(90),     # Wrist2 - roll/tilt
    math.radians(-90),    # Wrist3 - yaw/turn
]

# Scale factors
POSITION_SCALE = 0.5    # Increased for more visible movement
ROTATION_SCALE = 1.0    # Direct 1:1 mapping for wrist joints

# ============================================================================
# UTILITIES
# ============================================================================

def normalize_angle(angle):
    """Normalize angle to [-pi, pi]"""
    while angle > math.pi:
        angle -= 2 * math.pi
    while angle < -math.pi:
        angle += 2 * math.pi
    return angle

# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Playback VR recording - Hybrid control v3")
    parser.add_argument("--input", type=str, default="base_vr_recording.json", help="Input recording file")
    parser.add_argument("--output", type=str, default="playback_results_v3.json", help="Output results file")
    args = parser.parse_args()
    
    print("="*60)
    print("ROBOT PLAYBACK v3 - HYBRID CONTROL")
    print("="*60)
    print("""
This version separates position and rotation:
- HEAD POSITION -> moves base/shoulder/elbow (translates tool)
- HEAD ROTATION -> moves wrist1/2/3 directly (rotates tool in place)
""")
    
    # Load recording
    print(f"Loading: {args.input}")
    with open(args.input, 'r') as f:
        recording = json.load(f)
    
    rate = recording["rate"]
    samples = recording["samples"]
    loop_time = 1.0 / rate
    
    print(f"  Rate: {rate} Hz, Samples: {len(samples)}")
    
    # Reference pose
    ref_pos = np.array(samples[0]["pos"])
    ref_rot = np.array(samples[0]["rot"])
    
    # Connect to robot
    print("\nConnecting to robot...")
    rtde_r = rtde_receive.RTDEReceiveInterface("127.0.0.1")
    rtde_c = rtde_control.RTDEControlInterface("127.0.0.1")
    print("Connected!")
    
    # Move to home
    print("Moving to home position...")
    rtde_c.moveJ(HOME_JOINTS, 0.3, 0.3)
    time.sleep(1)
    
    home_joints = list(HOME_JOINTS)
    home_tcp = rtde_r.getActualTCPPose()
    print(f"Home TCP: [{home_tcp[0]:.3f}, {home_tcp[1]:.3f}, {home_tcp[2]:.3f}]")
    print(f"Home joints: [{', '.join([f'{math.degrees(j):.0f}°' for j in home_joints])}]")
    
    # Results
    results = {
        "input_file": args.input,
        "rate": rate,
        "measurements": [],
    }
    
    print(f"\nStarting playback in 2 seconds...")
    time.sleep(2)
    print("PLAYING...")
    
    playback_start = time.perf_counter()
    errors_count = 0
    
    for i, sample in enumerate(samples):
        loop_start = time.perf_counter()
        
        # Calculate deltas from reference
        pos_delta = np.array(sample["pos"]) - ref_pos
        rot_delta = np.array(sample["rot"]) - ref_rot
        
        # Normalize rotation deltas
        rot_delta = np.array([normalize_angle(r) for r in rot_delta])
        
        # ============================================================
        # POSITION: Calculate target TCP position (only XYZ, keep rotation)
        # ============================================================
        
        # VR -> Robot position mapping
        robot_dx = pos_delta[2] * POSITION_SCALE   # VR Z -> Robot X
        robot_dy = -pos_delta[0] * POSITION_SCALE  # VR X -> Robot -Y  
        robot_dz = pos_delta[1] * POSITION_SCALE   # VR Y -> Robot Z
        
        # Target TCP position (keep home orientation for IK)
        target_tcp_pos = [
            home_tcp[0] + robot_dx,
            home_tcp[1] + robot_dy,
            home_tcp[2] + robot_dz,
            home_tcp[3],  # Keep home rotation for position IK
            home_tcp[4],
            home_tcp[5],
        ]
        
        # Clamp position
        MAX_POS = 0.3
        for j in range(3):
            target_tcp_pos[j] = np.clip(target_tcp_pos[j], 
                                        home_tcp[j] - MAX_POS, 
                                        home_tcp[j] + MAX_POS)
        target_tcp_pos[2] = max(0.15, target_tcp_pos[2])
        
        # ============================================================
        # Get IK solution for position (this moves base/shoulder/elbow)
        # ============================================================
        
        current_joints = rtde_r.getActualQ()
        
        try:
            # Get IK for the position, using current joints as seed
            ik_joints = rtde_c.getInverseKinematics(target_tcp_pos, current_joints)
            
            if ik_joints and len(ik_joints) == 6:
                target_joints = list(ik_joints)
            else:
                # IK failed, use current joints
                target_joints = list(current_joints)
                errors_count += 1
        except:
            target_joints = list(current_joints)
            errors_count += 1
        
        # ============================================================
        # ROTATION: Apply directly to wrist joints
        # ============================================================
        
        # VR rotation -> Wrist joint mapping
        # VR: rx=pitch(nod), ry=yaw(turn), rz=roll(tilt)
        # Robot: wrist1=pitch, wrist2=roll, wrist3=yaw
        
        vr_pitch = rot_delta[0]  # Nod up/down
        vr_yaw = rot_delta[1]    # Turn left/right
        vr_roll = rot_delta[2]   # Tilt left/right
        
        # Clamp rotations
        MAX_ROT = math.radians(60)
        vr_pitch = np.clip(vr_pitch, -MAX_ROT, MAX_ROT)
        vr_yaw = np.clip(vr_yaw, -MAX_ROT, MAX_ROT)
        vr_roll = np.clip(vr_roll, -MAX_ROT, MAX_ROT)
        
        # Apply to wrist joints (override IK result for wrists)
        target_joints[3] = home_joints[3] - vr_pitch * ROTATION_SCALE  # Wrist1 = pitch
        target_joints[4] = home_joints[4] - vr_roll * ROTATION_SCALE   # Wrist2 = roll
        target_joints[5] = home_joints[5] - vr_yaw * ROTATION_SCALE    # Wrist3 = yaw
        
        # ============================================================
        # Send command
        # ============================================================
        
        cmd_start = time.perf_counter()
        try:
            rtde_c.servoJ(target_joints, 0.5, 0.5, loop_time, 0.1, 300)
        except Exception as e:
            errors_count += 1
        cmd_end = time.perf_counter()
        
        # Get actual position
        actual_tcp = rtde_r.getActualTCPPose()
        actual_joints = rtde_r.getActualQ()
        
        # Calculate position error (only XYZ)
        pos_error = math.sqrt(
            (target_tcp_pos[0] - actual_tcp[0])**2 +
            (target_tcp_pos[1] - actual_tcp[1])**2 +
            (target_tcp_pos[2] - actual_tcp[2])**2
        )
        
        # Store measurement
        results["measurements"].append({
            "sample_idx": i,
            "sample_time": sample["t"],
            "cmd_latency": cmd_end - cmd_start,
            "pos_error": pos_error,
            "target_tcp": list(target_tcp_pos[:3]),
            "actual_tcp": list(actual_tcp[:3]),
            "target_joints": target_joints,
            "actual_joints": list(actual_joints),
            "vr_pos_delta": pos_delta.tolist(),
            "vr_rot_delta": [math.degrees(r) for r in rot_delta],
        })
        
        # Progress
        if i % rate == 0 and i > 0:
            elapsed = time.perf_counter() - playback_start
            print(f"  {elapsed:.1f}s - Sample {i}/{len(samples)}, "
                  f"PosErr: {pos_error*1000:.1f}mm, "
                  f"Base: {math.degrees(actual_joints[0]):.0f}°, "
                  f"Errors: {errors_count}")
        
        # Maintain timing
        loop_elapsed = time.perf_counter() - loop_start
        if loop_elapsed < loop_time:
            time.sleep(loop_time - loop_elapsed)
    
    # Stop
    rtde_c.servoStop()
    
    # Stats
    pos_errors = [m["pos_error"] for m in results["measurements"]]
    cmd_latencies = [m["cmd_latency"] for m in results["measurements"]]
    
    # Check how much each joint moved
    base_angles = [m["actual_joints"][0] for m in results["measurements"]]
    shoulder_angles = [m["actual_joints"][1] for m in results["measurements"]]
    elbow_angles = [m["actual_joints"][2] for m in results["measurements"]]
    
    results["stats"] = {
        "pos_error_mean_mm": np.mean(pos_errors) * 1000,
        "pos_error_max_mm": np.max(pos_errors) * 1000,
        "cmd_latency_mean_ms": np.mean(cmd_latencies) * 1000,
        "errors": errors_count,
        "base_range_deg": math.degrees(max(base_angles) - min(base_angles)),
        "shoulder_range_deg": math.degrees(max(shoulder_angles) - min(shoulder_angles)),
        "elbow_range_deg": math.degrees(max(elbow_angles) - min(elbow_angles)),
    }
    
    print("\n" + "="*60)
    print("PLAYBACK COMPLETE")
    print("="*60)
    
    print(f"\nPosition Error:")
    print(f"  Mean: {results['stats']['pos_error_mean_mm']:.1f} mm")
    print(f"  Max:  {results['stats']['pos_error_max_mm']:.1f} mm")
    
    print(f"\nJoint Movement Ranges (should be > 0 for translation):")
    print(f"  Base:     {results['stats']['base_range_deg']:.1f}°")
    print(f"  Shoulder: {results['stats']['shoulder_range_deg']:.1f}°")
    print(f"  Elbow:    {results['stats']['elbow_range_deg']:.1f}°")
    
    print(f"\nErrors: {errors_count}")
    
    # Save
    with open(args.output, 'w') as f:
        json.dump(results, f, indent=2)
    print(f"\nSaved to: {args.output}")
    
    # Return home
    print("\nReturning to home...")
    rtde_c.moveJ(HOME_JOINTS, 0.3, 0.3)
    rtde_c.stopScript()
    print("Done!")

if __name__ == "__main__":
    main()