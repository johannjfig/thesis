#!/usr/bin/env python3
"""
Windows Mixed Reality Head Tracking Extractor
Extracts 6DOF pose from HP Reverb G2 and sends via UDP

Requirements:
    pip install pyopenvr numpy

This uses OpenVR (SteamVR) to access the WMR headset.
Make sure SteamVR and Windows Mixed Reality Portal are running.
"""

import openvr
import socket
import struct
import json
import time
import numpy as np
from typing import Optional, Tuple
import argparse

# ============================================================================
# CONFIGURATION
# ============================================================================

# Where to send tracking data
TARGET_IP = "127.0.0.1"  # localhost if robot controller is on same machine
TARGET_PORT = 5005

# Output format: "json" or "binary"
OUTPUT_FORMAT = "json"

# Update rate
UPDATE_RATE_HZ = 90  # Match headset refresh rate

# ============================================================================
# OPENVR TRACKING
# ============================================================================

class VRTracker:
    """Extracts head tracking from SteamVR/OpenVR"""
    
    def __init__(self):
        self.vr_system = None
        self.hmd_index = openvr.k_unTrackedDeviceIndex_Hmd
        
    def init(self) -> bool:
        """Initialize OpenVR connection"""
        try:
            self.vr_system = openvr.init(openvr.VRApplication_Other)
            print("OpenVR initialized successfully")
            
            # Check if HMD is connected
            if not self.vr_system.isTrackedDeviceConnected(self.hmd_index):
                print("Warning: HMD not detected as connected")
                return False
                
            # Get HMD info
            manufacturer = self.vr_system.getStringTrackedDeviceProperty(
                self.hmd_index,
                openvr.Prop_ManufacturerName_String
            )
            model = self.vr_system.getStringTrackedDeviceProperty(
                self.hmd_index,
                openvr.Prop_ModelNumber_String
            )
            print(f"HMD: {manufacturer} {model}")
            
            return True
            
        except Exception as e:
            print(f"OpenVR init failed: {e}")
            print("\nMake sure:")
            print("1. SteamVR is running")
            print("2. Windows Mixed Reality Portal is running")
            print("3. The headset is connected and detected")
            return False
            
    def shutdown(self):
        if self.vr_system:
            openvr.shutdown()
            
    def get_hmd_pose(self) -> Optional[Tuple[np.ndarray, np.ndarray]]:
        """
        Get current HMD pose.
        Returns: (position [x,y,z], rotation [rx,ry,rz]) or None if not tracking
        """
        poses = self.vr_system.getDeviceToAbsoluteTrackingPose(
            openvr.TrackingUniverseStanding,
            0,  # Predicted seconds from now
            openvr.k_unMaxTrackedDeviceCount
        )
        
        hmd_pose = poses[self.hmd_index]
        
        if not hmd_pose.bPoseIsValid:
            return None
            
        # Extract 3x4 transform matrix
        matrix = hmd_pose.mDeviceToAbsoluteTracking
        
        # Position is in the last column
        position = np.array([
            matrix[0][3],  # x
            matrix[1][3],  # y  
            matrix[2][3]   # z
        ])
        
        # Extract rotation (convert matrix to euler angles)
        rotation = self._matrix_to_euler(matrix)
        
        return position, rotation
        
    def _matrix_to_euler(self, matrix) -> np.ndarray:
        """Convert 3x4 transformation matrix to euler angles (rx, ry, rz)"""
        # Extract rotation matrix (3x3)
        r00 = matrix[0][0]
        r01 = matrix[0][1]
        r02 = matrix[0][2]
        r10 = matrix[1][0]
        r11 = matrix[1][1]
        r12 = matrix[1][2]
        r20 = matrix[2][0]
        r21 = matrix[2][1]
        r22 = matrix[2][2]
        
        # Convert to euler angles (XYZ order)
        sy = np.sqrt(r00 * r00 + r10 * r10)
        singular = sy < 1e-6
        
        if not singular:
            rx = np.arctan2(r21, r22)
            ry = np.arctan2(-r20, sy)
            rz = np.arctan2(r10, r00)
        else:
            rx = np.arctan2(-r12, r11)
            ry = np.arctan2(-r20, sy)
            rz = 0
            
        return np.array([rx, ry, rz])

# ============================================================================
# UDP SENDER
# ============================================================================

class TrackingSender:
    """Sends tracking data via UDP"""
    
    def __init__(self, target_ip: str, target_port: int, format: str = "json"):
        self.target = (target_ip, target_port)
        self.format = format
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        
    def send(self, position: np.ndarray, rotation: np.ndarray):
        """Send pose data"""
        timestamp = time.time()
        
        if self.format == "json":
            data = json.dumps({
                "x": float(position[0]),
                "y": float(position[1]),
                "z": float(position[2]),
                "rx": float(rotation[0]),
                "ry": float(rotation[1]),
                "rz": float(rotation[2]),
                "timestamp": timestamp
            }).encode('utf-8')
        else:
            # Binary format: 7 floats
            data = struct.pack('7f',
                position[0], position[1], position[2],
                rotation[0], rotation[1], rotation[2],
                timestamp
            )
            
        self.socket.sendto(data, self.target)
        
    def close(self):
        self.socket.close()

# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="VR Head Tracking Sender")
    parser.add_argument("--ip", default=TARGET_IP, help="Target IP address")
    parser.add_argument("--port", type=int, default=TARGET_PORT, help="Target port")
    parser.add_argument("--format", choices=["json", "binary"], default=OUTPUT_FORMAT)
    parser.add_argument("--rate", type=int, default=UPDATE_RATE_HZ, help="Update rate Hz")
    args = parser.parse_args()
    
    print("="*60)
    print("VR Head Tracking Sender")
    print("="*60)
    print(f"Target: {args.ip}:{args.port}")
    print(f"Format: {args.format}")
    print(f"Rate: {args.rate} Hz")
    print()
    
    # Initialize VR tracking
    tracker = VRTracker()
    if not tracker.init():
        return
        
    # Initialize sender
    sender = TrackingSender(args.ip, args.port, args.format)
    
    print("\nTracking active. Press Ctrl+C to stop.\n")
    
    loop_time = 1.0 / args.rate
    packet_count = 0
    
    try:
        while True:
            loop_start = time.time()
            
            # Get pose
            result = tracker.get_hmd_pose()
            if result is not None:
                position, rotation = result
                sender.send(position, rotation)
                packet_count += 1
                
                # Print status every second
                if packet_count % args.rate == 0:
                    print(f"Pos: [{position[0]:+.3f}, {position[1]:+.3f}, {position[2]:+.3f}] "
                          f"Rot: [{np.degrees(rotation[0]):+.1f}°, {np.degrees(rotation[1]):+.1f}°, {np.degrees(rotation[2]):+.1f}°]")
            else:
                if packet_count % args.rate == 0:
                    print("Waiting for valid tracking...")
                    
            # Maintain loop rate
            elapsed = time.time() - loop_start
            if elapsed < loop_time:
                time.sleep(loop_time - elapsed)
                
    except KeyboardInterrupt:
        print("\nStopping...")
    finally:
        sender.close()
        tracker.shutdown()
        print("Shutdown complete.")

if __name__ == "__main__":
    main()
