import openvr
import rtde_control
import rtde_receive
import time
import numpy as np
import math

"""
JOINT-SPACE HEAD TRACKING

Maps VR head movements directly to robot joints for natural control:

ROTATIONS (wrist joints = neck):
- Head yaw (turn left/right) -> Wrist3
- Head tilt (ear to shoulder) -> Wrist2  
- Head pitch (nod up/down) -> Wrist1

POSITIONS (arm = body):
- Head left/right -> Base rotation
- Head up/down -> Shoulder + Elbow
- Head forward/back -> Shoulder + Elbow (reach)

Reference pose: Wrist3 = -90° is "looking forward"
"""

# ============================================================================
# CONFIGURATION
# ============================================================================

# Home position in joint space (radians)
# This is the "looking straight ahead" reference
HOME_JOINTS = [
    math.radians(0),      # Base: centered
    math.radians(-90),    # Shoulder: horizontal
    math.radians(90),     # Elbow: bent up
    math.radians(-90),    # Wrist1: looking straight (pitch neutral)
    math.radians(90),     # Wrist2: no tilt (roll neutral)
    math.radians(-90),    # Wrist3: looking forward (yaw reference)
]

# Scale factors
ROTATION_SCALE = 1.0      # 1:1 for head rotations -> wrist joints
POSITION_SCALE = 0.3      # Smaller for body movements

# Joint limits (relative to home, in radians)
WRIST_LIMIT = math.radians(45)      # ±45° for wrist joints
BASE_LIMIT = math.radians(30)       # ±30° for base
SHOULDER_LIMIT = math.radians(20)   # ±20° for shoulder
ELBOW_LIMIT = math.radians(20)      # ±20° for elbow

MOVE_SPEED = 0.5
MOVE_ACCEL = 0.5

# ============================================================================
# UTILITIES
# ============================================================================

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
    
    return np.array([rx, ry, rz])

def get_hmd_pose(vr):
    """Get 6DOF pose from HMD"""
    poses = vr.getDeviceToAbsoluteTrackingPose(openvr.TrackingUniverseStanding, 0, 1)
    m = poses[0].mDeviceToAbsoluteTracking
    position = np.array([m[0][3], m[1][3], m[2][3]])
    rotation = matrix_to_euler(m)
    return position, rotation

def normalize_angle(a):
    """Normalize angle to [-pi, pi]"""
    return ((a + math.pi) % (2 * math.pi)) - math.pi

# ============================================================================
# MAPPING FUNCTIONS
# ============================================================================

def map_head_to_joints(pos_delta, rot_delta, home_joints):
    """
    Map VR head pose deltas to robot joint deltas.
    
    VR coordinate system:
    - Position: X=right, Y=up, Z=backward
    - Rotation: rx=pitch(nod), ry=yaw(turn), rz=roll(tilt)
    
    Robot joint mapping (Wrist3=-90° is "forward"):
    - Wrist3: horizontal rotation (yaw/turn left-right)
    - Wrist2: tilt rotation (roll/ear to shoulder)
    - Wrist1: vertical rotation (pitch/nod up-down)
    - Base: body rotation left-right
    - Shoulder/Elbow: body position up-down and forward-back
    
    Returns target joint positions.
    """
    vr_x, vr_y, vr_z = pos_delta
    vr_pitch, vr_yaw, vr_roll = rot_delta  # rx, ry, rz
    
    # Start from home
    joints = list(home_joints)
    
    # === ROTATIONS (wrist joints = neck) ===
    
    # Head yaw (turn left/right) -> Wrist3
    # Home is -90°, turning left should increase angle, turning right decreases
    joints[5] -= vr_yaw * ROTATION_SCALE
    
    # Head tilt (ear to shoulder) -> Wrist2
    joints[4] -= vr_roll * ROTATION_SCALE
    
    # Head pitch (nod up/down) -> Wrist1
    joints[3] -= vr_pitch * ROTATION_SCALE
    
    # === POSITIONS (arm joints = body) ===
    
    # Head left/right -> Base rotation
    joints[0] -= vr_z * POSITION_SCALE * 2
    
    # Head up/down -> Shoulder AND Elbow together
    # To move straight up/down, both joints need to move in coordination
    # Shoulder up (less negative) + Elbow compensates
    joints[1] -= vr_y * POSITION_SCALE * 2  # Shoulder
    joints[2] += vr_y * POSITION_SCALE * 2  # Elbow moves opposite to keep tool level
    
    # Head forward/back -> Elbow (reach)
    joints[2] -= vr_x * POSITION_SCALE * 2
    
    # === APPLY LIMITS ===
    
    # Wrist limits
    joints[3] = np.clip(joints[3], home_joints[3] - WRIST_LIMIT, home_joints[3] + WRIST_LIMIT)
    joints[4] = np.clip(joints[4], home_joints[4] - WRIST_LIMIT, home_joints[4] + WRIST_LIMIT)
    joints[5] = np.clip(joints[5], home_joints[5] - WRIST_LIMIT, home_joints[5] + WRIST_LIMIT)
    
    # Arm limits
    joints[0] = np.clip(joints[0], home_joints[0] - BASE_LIMIT, home_joints[0] + BASE_LIMIT)
    joints[1] = np.clip(joints[1], home_joints[1] - SHOULDER_LIMIT, home_joints[1] + SHOULDER_LIMIT)
    joints[2] = np.clip(joints[2], home_joints[2] - ELBOW_LIMIT, home_joints[2] + ELBOW_LIMIT)
    
    return joints

# ============================================================================
# MAIN
# ============================================================================

print("="*60)
print("JOINT-SPACE HEAD TRACKING (Natural Movement)")
print("="*60)
print("""
Mapping:
  HEAD ROTATION -> WRIST JOINTS (like neck)
    Turn left/right  -> Wrist3 (yaw)
    Tilt left/right  -> Wrist2 (roll)
    Nod up/down      -> Wrist1 (pitch)
    
  HEAD POSITION -> ARM JOINTS (like body)
    Move left/right  -> Base rotation
    Move up/down     -> Shoulder
    Move fwd/back    -> Elbow
""")

# Connect to robot
print("\n[1/4] Connecting to robot...")
rtde_r = rtde_receive.RTDEReceiveInterface("127.0.0.1")
rtde_c = rtde_control.RTDEControlInterface("127.0.0.1")
print("      Connected!")

# Move to home position
print("\n[2/4] Moving to home position...")
print(f"      Joints: [{', '.join([f'{math.degrees(j):.0f}°' for j in HOME_JOINTS])}]")
rtde_c.moveJ(HOME_JOINTS, MOVE_SPEED, MOVE_ACCEL)
time.sleep(1)
print("      At home position (Wrist3=-90° = looking forward)")

# Connect VR
print("\n[3/4] Connecting to VR...")
vr = openvr.init(openvr.VRApplication_Other)
print("      Connected!")

# Capture reference pose
print("\n[4/4] Capturing reference head pose...")
print("      Look STRAIGHT AHEAD and hold still for 2 seconds...")
time.sleep(2)

start_pos, start_rot = get_hmd_pose(vr)
print(f"      Reference captured!")
print(f"      Pos: [{start_pos[0]:.2f}, {start_pos[1]:.2f}, {start_pos[2]:.2f}]")
print(f"      Rot: [{math.degrees(start_rot[0]):.0f}°, {math.degrees(start_rot[1]):.0f}°, {math.degrees(start_rot[2]):.0f}°]")

print("\n" + "="*60)
print("READY! Move your head to control the robot.")
print("Press Ctrl+C to stop and return home.")
print("="*60 + "\n")

# Control loop
try:
    frame = 0
    while True:
        # Get current head pose
        pos, rot = get_hmd_pose(vr)
        
        # Calculate deltas from reference
        pos_delta = pos - start_pos
        rot_delta = np.array([normalize_angle(r - s) for r, s in zip(rot, start_rot)])
        
        # Map to joint positions
        target_joints = map_head_to_joints(pos_delta, rot_delta, HOME_JOINTS)
        
        # Send to robot using speedJ for smooth motion
        # Or use servoJ for position control
        rtde_c.servoJ(target_joints, 0.5, 0.5, 0.008, 0.1, 300)
        
        # Debug output
        if frame % 15 == 0:
            print(f"Yaw:{math.degrees(rot_delta[1]):+5.0f}° "
                  f"Tilt:{math.degrees(rot_delta[2]):+5.0f}° "
                  f"Nod:{math.degrees(rot_delta[0]):+5.0f}° | "
                  f"W3:{math.degrees(target_joints[5]):+6.0f}° "
                  f"W2:{math.degrees(target_joints[4]):+6.0f}° "
                  f"W1:{math.degrees(target_joints[3]):+6.0f}°", end='\r')
        
        frame += 1
        time.sleep(0.008)
        
except KeyboardInterrupt:
    print("\n\nStopping and returning to home...")
    rtde_c.servoStop()
    time.sleep(0.5)
    rtde_c.moveJ(HOME_JOINTS, MOVE_SPEED, MOVE_ACCEL)
    rtde_c.stopScript()

openvr.shutdown()
print("Done!")