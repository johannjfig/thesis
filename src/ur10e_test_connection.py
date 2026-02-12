#!/usr/bin/env python3
"""
UR10e Connection Test Script
Tests connection to either URSim or real robot via RTDE
"""

import rtde_control
import rtde_receive
import time
import sys

# Configuration - change this to your robot's IP
# For URSim running in Docker on Windows: "localhost" or "127.0.0.1"
# For real robot: the robot's actual IP address
ROBOT_IP = "127.0.0.1"

def test_connection():
    print(f"Attempting to connect to robot at {ROBOT_IP}...")
    
    try:
        # Connect to receive interface (read robot state)
        rtde_r = rtde_receive.RTDEReceiveInterface(ROBOT_IP)
        print("✓ Connected to RTDE Receive interface")
        
        # Read current joint positions
        joint_positions = rtde_r.getActualQ()
        print(f"✓ Current joint positions (radians): {joint_positions}")
        
        # Read TCP pose (Tool Center Point - end effector position)
        tcp_pose = rtde_r.getActualTCPPose()
        print(f"✓ Current TCP pose [x, y, z, rx, ry, rz]: {tcp_pose}")
        
        # Check robot mode
        robot_mode = rtde_r.getRobotMode()
        mode_names = {
            -1: "ROBOT_MODE_NO_CONTROLLER",
            0: "ROBOT_MODE_DISCONNECTED",
            1: "ROBOT_MODE_CONFIRM_SAFETY",
            2: "ROBOT_MODE_BOOTING",
            3: "ROBOT_MODE_POWER_OFF",
            4: "ROBOT_MODE_POWER_ON",
            5: "ROBOT_MODE_IDLE",
            6: "ROBOT_MODE_BACKDRIVE",
            7: "ROBOT_MODE_RUNNING",
        }
        print(f"✓ Robot mode: {mode_names.get(robot_mode, 'UNKNOWN')} ({robot_mode})")
        
        # Connect to control interface (send commands)
        rtde_c = rtde_control.RTDEControlInterface(ROBOT_IP)
        print("✓ Connected to RTDE Control interface")
        
        print("\n" + "="*50)
        print("CONNECTION TEST SUCCESSFUL!")
        print("="*50)
        print("\nYou can now send motion commands to the robot.")
        print("For safety, no motion commands were executed in this test.")
        
        # Clean disconnect
        rtde_c.disconnect()
        rtde_r.disconnect()
        
        return True
        
    except Exception as e:
        print(f"\n✗ Connection failed: {e}")
        print("\nTroubleshooting:")
        print("1. Is URSim running? Check: docker ps")
        print("2. Is the robot powered on in URSim? Access http://localhost:6080")
        print("3. Are the ports exposed? Check Docker port mappings")
        print("4. Firewall blocking connections?")
        return False

if __name__ == "__main__":
    if len(sys.argv) > 1:
        ROBOT_IP = sys.argv[1]
    
    test_connection()
