import openvr
import rtde_control
import rtde_receive
import time
import math
import numpy as np
import json
import argparse

"""
VR TELEPRESENCE - v9 (With Full Logging)

Same hybrid control as playback v3, but logs everything for analysis:
- VR headset position and rotation
- Robot target and actual positions
- IK success/failure
- Timing information
"""

# ============================================================================
# CONFIGURATION
# ============================================================================

HOME_JOINTS = [
    math.radians(0),      # Base
    math.radians(-90),    # Shoulder
    math.radians(90),     # Elbow
    math.radians(-90),    # Wrist1
    math.radians(90),     # Wrist2
    math.radians(-90),    # Wrist3
]

POSITION_SCALE = 0.5
ROTATION_SCALE = 1.0

# ============================================================================
# UTILITIES
# ============================================================================

def normalize_angle(angle):
    while angle > math.pi:
        angle -= 2 * math.pi
    while angle < -math.pi:
        angle += 2 * math.pi
    return angle

def matrix_to_euler(m):
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

def get_hmd_pose(vr):
    poses = vr.getDeviceToAbsoluteTrackingPose(openvr.TrackingUniverseStanding, 0, 1)
    m = poses[0].mDeviceToAbsoluteTracking
    position = [m[0][3], m[1][3], m[2][3]]
    rotation = matrix_to_euler(m)
    return position, rotation

# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="VR Telepresence with logging")
    parser.add_argument("--rate", type=int, default=30, help="Control rate in Hz")
    parser.add_argument("--output", type=str, default="telepresence_log.json", help="Output log file")
    args = parser.parse_args()
    
    rate = args.rate
    loop_time = 1.0 / rate
    output_file = args.output
    
    print("="*60)
    print("VR TELEPRESENCE - v9 (With Logging)")
    print("="*60)
    print(f"Rate: {rate} Hz")
    print(f"Output: {output_file}")
    
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
    
    # Connect to VR
    print("\nConnecting to VR...")
    vr = openvr.init(openvr.VRApplication_Other)
    print("Connected!")
    
    # Capture reference
    print("\nLook STRAIGHT AHEAD for 2 seconds...")
    time.sleep(2)
    ref_pos, ref_rot = get_hmd_pose(vr)
    ref_pos = np.array(ref_pos)
    ref_rot = np.array(ref_rot)
    print(f"Reference: pos=[{ref_pos[0]:.3f}, {ref_pos[1]:.3f}, {ref_pos[2]:.3f}]")
    
    # Initialize log
    log = {
        "rate": rate,
        "position_scale": POSITION_SCALE,
        "rotation_scale": ROTATION_SCALE,
        "home_tcp": list(home_tcp),
        "home_joints": home_joints,
        "vr_reference_pos": ref_pos.tolist(),
        "vr_reference_rot": ref_rot.tolist(),
        "samples": []
    }
    
    print(f"\nStarting in 2 seconds...")
    time.sleep(2)
    print("RUNNING... Press Ctrl+C to stop\n")
    
    errors_count = 0
    ik_failures = 0
    start_time = time.perf_counter()
    frame = 0
    
    try:
        while True:
            loop_start = time.perf_counter()
            elapsed = loop_start - start_time
            
            # ============================================================
            # GET VR DATA
            # ============================================================
            vr_pos, vr_rot = get_hmd_pose(vr)
            
            pos_delta = np.array(vr_pos) - ref_pos
            rot_delta = np.array(vr_rot) - ref_rot
            rot_delta = np.array([normalize_angle(r) for r in rot_delta])
            
            # ============================================================
            # POSITION MAPPING
            # ============================================================
            robot_dx = pos_delta[2] * POSITION_SCALE
            robot_dy = -pos_delta[0] * POSITION_SCALE
            robot_dz = pos_delta[1] * POSITION_SCALE
            
            target_tcp_pos = [
                home_tcp[0] + robot_dx,
                home_tcp[1] + robot_dy,
                home_tcp[2] + robot_dz,
                home_tcp[3],
                home_tcp[4],
                home_tcp[5],
            ]
            
            # Clamp
            MAX_POS = 0.3
            for j in range(3):
                target_tcp_pos[j] = np.clip(target_tcp_pos[j], 
                                            home_tcp[j] - MAX_POS, 
                                            home_tcp[j] + MAX_POS)
            target_tcp_pos[2] = max(0.15, target_tcp_pos[2])
            
            # ============================================================
            # IK
            # ============================================================
            current_joints = rtde_r.getActualQ()
            ik_success = False
            
            try:
                ik_joints = rtde_c.getInverseKinematics(target_tcp_pos, current_joints)
                
                if ik_joints and len(ik_joints) == 6:
                    target_joints = list(ik_joints)
                    ik_success = True
                else:
                    target_joints = list(current_joints)
                    ik_failures += 1
            except:
                target_joints = list(current_joints)
                ik_failures += 1
            
            # ============================================================
            # ROTATION - Direct wrist control
            # ============================================================
            vr_pitch = rot_delta[0]
            vr_yaw = rot_delta[1]
            vr_roll = rot_delta[2]
            
            MAX_ROT = math.radians(60)
            vr_pitch = np.clip(vr_pitch, -MAX_ROT, MAX_ROT)
            vr_yaw = np.clip(vr_yaw, -MAX_ROT, MAX_ROT)
            vr_roll = np.clip(vr_roll, -MAX_ROT, MAX_ROT)
            
            target_joints[3] = home_joints[3] - vr_pitch * ROTATION_SCALE
            target_joints[4] = home_joints[4] - vr_roll * ROTATION_SCALE
            target_joints[5] = home_joints[5] - vr_yaw * ROTATION_SCALE
            
            # ============================================================
            # SEND COMMAND
            # ============================================================
            cmd_start = time.perf_counter()
            try:
                rtde_c.servoJ(target_joints, 0.5, 0.5, loop_time, 0.1, 300)
            except:
                errors_count += 1
            cmd_end = time.perf_counter()
            
            # ============================================================
            # GET ACTUAL ROBOT STATE
            # ============================================================
            actual_tcp = rtde_r.getActualTCPPose()
            actual_joints = rtde_r.getActualQ()
            
            # ============================================================
            # LOG EVERYTHING
            # ============================================================
            sample = {
                "t": elapsed,
                "frame": frame,
                
                # VR data
                "vr_pos": vr_pos,
                "vr_rot": vr_rot,
                "vr_pos_delta": pos_delta.tolist(),
                "vr_rot_delta": rot_delta.tolist(),
                
                # Robot targets
                "robot_delta": [robot_dx, robot_dy, robot_dz],
                "target_tcp_pos": target_tcp_pos[:3],
                "target_joints": target_joints,
                
                # Robot actual
                "actual_tcp": list(actual_tcp[:3]),
                "actual_tcp_rot": list(actual_tcp[3:6]),
                "actual_joints": list(actual_joints),
                
                # Status
                "ik_success": ik_success,
                "cmd_latency": cmd_end - cmd_start,
            }
            log["samples"].append(sample)
            
            # Debug output
            if frame % rate == 0 and frame > 0:
                pos_error = math.sqrt(
                    (target_tcp_pos[0] - actual_tcp[0])**2 +
                    (target_tcp_pos[1] - actual_tcp[1])**2 +
                    (target_tcp_pos[2] - actual_tcp[2])**2
                )
                print(f"{elapsed:5.1f}s | "
                      f"VR: L/R={pos_delta[0]*100:+6.1f}cm U/D={pos_delta[1]*100:+6.1f}cm F/B={pos_delta[2]*100:+6.1f}cm | "
                      f"Robot: X={robot_dx*100:+5.1f}cm Y={robot_dy*100:+5.1f}cm Z={robot_dz*100:+5.1f}cm | "
                      f"Err={pos_error*1000:.0f}mm IK_fail={ik_failures}")
            
            frame += 1
            
            # Timing
            loop_elapsed = time.perf_counter() - loop_start
            if loop_elapsed < loop_time:
                time.sleep(loop_time - loop_elapsed)
    
    except KeyboardInterrupt:
        print("\n\nStopping...")
    
    end_time = time.perf_counter()
    duration = end_time - start_time
    
    # Add summary to log
    log["duration"] = duration
    log["total_frames"] = frame
    log["ik_failures"] = ik_failures
    log["errors"] = errors_count
    
    # Stop robot
    rtde_c.servoStop()
    
    # Calculate stats
    if log["samples"]:
        vr_pos_deltas = [s["vr_pos_delta"] for s in log["samples"]]
        robot_deltas = [s["robot_delta"] for s in log["samples"]]
        
        log["stats"] = {
            "vr_x_range_cm": (min(d[0] for d in vr_pos_deltas)*100, max(d[0] for d in vr_pos_deltas)*100),
            "vr_y_range_cm": (min(d[1] for d in vr_pos_deltas)*100, max(d[1] for d in vr_pos_deltas)*100),
            "vr_z_range_cm": (min(d[2] for d in vr_pos_deltas)*100, max(d[2] for d in vr_pos_deltas)*100),
            "robot_x_range_cm": (min(d[0] for d in robot_deltas)*100, max(d[0] for d in robot_deltas)*100),
            "robot_y_range_cm": (min(d[1] for d in robot_deltas)*100, max(d[1] for d in robot_deltas)*100),
            "robot_z_range_cm": (min(d[2] for d in robot_deltas)*100, max(d[2] for d in robot_deltas)*100),
        }
        
        print(f"\n{'='*60}")
        print("SESSION SUMMARY")
        print(f"{'='*60}")
        print(f"Duration: {duration:.1f}s")
        print(f"Frames: {frame}")
        print(f"IK failures: {ik_failures}")
        print(f"\nVR movement ranges:")
        print(f"  L/R (X): {log['stats']['vr_x_range_cm'][0]:.1f} to {log['stats']['vr_x_range_cm'][1]:.1f} cm")
        print(f"  U/D (Y): {log['stats']['vr_y_range_cm'][0]:.1f} to {log['stats']['vr_y_range_cm'][1]:.1f} cm")
        print(f"  F/B (Z): {log['stats']['vr_z_range_cm'][0]:.1f} to {log['stats']['vr_z_range_cm'][1]:.1f} cm")
        print(f"\nRobot command ranges:")
        print(f"  X: {log['stats']['robot_x_range_cm'][0]:.1f} to {log['stats']['robot_x_range_cm'][1]:.1f} cm")
        print(f"  Y: {log['stats']['robot_y_range_cm'][0]:.1f} to {log['stats']['robot_y_range_cm'][1]:.1f} cm")
        print(f"  Z: {log['stats']['robot_z_range_cm'][0]:.1f} to {log['stats']['robot_z_range_cm'][1]:.1f} cm")
    
    # Save log
    with open(output_file, 'w') as f:
        json.dump(log, f, indent=2)
    print(f"\nLog saved to: {output_file}")
    
    # Return home
    print("\nReturning to home...")
    rtde_c.moveJ(HOME_JOINTS, 0.3, 0.3)
    rtde_c.stopScript()
    openvr.shutdown()
    print("Done!")

if __name__ == "__main__":
    main()