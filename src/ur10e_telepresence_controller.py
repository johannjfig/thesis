#!/usr/bin/env python3
"""
VR Telepresence Controller for UR10e
Maps VR headset orientation/position to robot end-effector motion

This script:
1. Receives head tracking data (position + orientation) via UDP
2. Transforms it to robot coordinate space
3. Sends motion commands to UR10e via RTDE

For your thesis: 6DOF (position + orientation) vs 3DOF (orientation only)
"""

import rtde_control
import rtde_receive
import socket
import struct
import threading
import time
import numpy as np
from dataclasses import dataclass
from typing import Optional
import json

# ============================================================================
# CONFIGURATION
# ============================================================================

@dataclass
class Config:
    # Robot connection
    robot_ip: str = "127.0.0.1"  # localhost for URSim, real IP for actual robot
    
    # Head tracking UDP receiver
    tracking_port: int = 5005
    
    # Motion parameters
    max_linear_speed: float = 0.25      # m/s - REDUCE FOR SAFETY TESTING
    max_angular_speed: float = 0.5      # rad/s
    acceleration: float = 0.5           # m/s² or rad/s²
    
    # Workspace limits (meters) - prevents robot from going out of bounds
    # Adjust these based on your actual setup!
    workspace_min: tuple = (-0.8, -0.8, 0.1)   # x, y, z minimum
    workspace_max: tuple = (0.8, 0.8, 1.2)     # x, y, z maximum
    
    # Control mode: "6dof" or "3dof"
    control_mode: str = "6dof"
    
    # Scaling factors (VR movement to robot movement)
    position_scale: float = 1.0         # 1:1 mapping
    rotation_scale: float = 1.0         # 1:1 mapping
    
    # Safety
    enable_motion: bool = False         # Set True to actually move robot!

config = Config()

# ============================================================================
# HEAD TRACKING RECEIVER
# ============================================================================

@dataclass
class HeadPose:
    """6DOF head pose from VR headset"""
    # Position (meters)
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0
    # Orientation (radians) - roll, pitch, yaw
    rx: float = 0.0
    ry: float = 0.0
    rz: float = 0.0
    timestamp: float = 0.0

class HeadTrackingReceiver:
    """Receives head tracking data via UDP"""
    
    def __init__(self, port: int):
        self.port = port
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("0.0.0.0", port))
        self.socket.settimeout(0.1)
        
        self.latest_pose: Optional[HeadPose] = None
        self.lock = threading.Lock()
        self.running = False
        self.thread: Optional[threading.Thread] = None
        
    def start(self):
        self.running = True
        self.thread = threading.Thread(target=self._receive_loop, daemon=True)
        self.thread.start()
        print(f"Head tracking receiver started on port {self.port}")
        
    def stop(self):
        self.running = False
        if self.thread:
            self.thread.join(timeout=1.0)
        self.socket.close()
        
    def _receive_loop(self):
        while self.running:
            try:
                data, addr = self.socket.recvfrom(1024)
                pose = self._parse_packet(data)
                if pose:
                    with self.lock:
                        self.latest_pose = pose
            except socket.timeout:
                continue
            except Exception as e:
                print(f"Tracking receive error: {e}")
                
    def _parse_packet(self, data: bytes) -> Optional[HeadPose]:
        """
        Parse incoming head tracking packet.
        Expected format: JSON with x, y, z, rx, ry, rz, timestamp
        Or binary: 7 floats (28 bytes)
        """
        try:
            # Try JSON first
            if data.startswith(b'{'):
                d = json.loads(data.decode('utf-8'))
                return HeadPose(
                    x=d.get('x', 0), y=d.get('y', 0), z=d.get('z', 0),
                    rx=d.get('rx', 0), ry=d.get('ry', 0), rz=d.get('rz', 0),
                    timestamp=d.get('timestamp', time.time())
                )
            # Binary format: 7 floats
            elif len(data) == 28:
                values = struct.unpack('7f', data)
                return HeadPose(*values)
        except Exception as e:
            print(f"Parse error: {e}")
        return None
    
    def get_pose(self) -> Optional[HeadPose]:
        with self.lock:
            return self.latest_pose

# ============================================================================
# ROBOT CONTROLLER
# ============================================================================

class UR10eController:
    """Controls UR10e via RTDE based on head tracking input"""
    
    def __init__(self, robot_ip: str):
        self.robot_ip = robot_ip
        self.rtde_c: Optional[rtde_control.RTDEControlInterface] = None
        self.rtde_r: Optional[rtde_receive.RTDEReceiveInterface] = None
        self.connected = False
        
        # Reference pose (where robot starts / center of workspace)
        self.reference_tcp: Optional[np.ndarray] = None
        self.reference_head: Optional[HeadPose] = None
        
    def connect(self) -> bool:
        try:
            print(f"Connecting to robot at {self.robot_ip}...")
            self.rtde_r = rtde_receive.RTDEReceiveInterface(self.robot_ip)
            self.rtde_c = rtde_control.RTDEControlInterface(self.robot_ip)
            self.connected = True
            
            # Store initial TCP pose as reference
            self.reference_tcp = np.array(self.rtde_r.getActualTCPPose())
            print(f"Connected! Reference TCP: {self.reference_tcp}")
            return True
            
        except Exception as e:
            print(f"Connection failed: {e}")
            return False
            
    def disconnect(self):
        if self.rtde_c:
            self.rtde_c.stopScript()
            self.rtde_c.disconnect()
        if self.rtde_r:
            self.rtde_r.disconnect()
        self.connected = False
        
    def set_reference_head_pose(self, pose: HeadPose):
        """Set the head pose that corresponds to robot's reference position"""
        self.reference_head = pose
        print(f"Reference head pose set: pos=({pose.x:.3f}, {pose.y:.3f}, {pose.z:.3f})")
        
    def compute_target_pose(self, head_pose: HeadPose) -> Optional[np.ndarray]:
        """
        Compute target TCP pose based on head movement relative to reference.
        Returns [x, y, z, rx, ry, rz] or None if invalid.
        """
        if self.reference_head is None or self.reference_tcp is None:
            return None
            
        # Compute delta from reference head pose
        dx = (head_pose.x - self.reference_head.x) * config.position_scale
        dy = (head_pose.y - self.reference_head.y) * config.position_scale
        dz = (head_pose.z - self.reference_head.z) * config.position_scale
        
        drx = (head_pose.rx - self.reference_head.rx) * config.rotation_scale
        dry = (head_pose.ry - self.reference_head.ry) * config.rotation_scale
        drz = (head_pose.rz - self.reference_head.rz) * config.rotation_scale
        
        # Apply to reference TCP
        target = self.reference_tcp.copy()
        
        if config.control_mode == "6dof":
            # Full 6DOF: position + orientation
            target[0] += dx
            target[1] += dy
            target[2] += dz
            target[3] += drx
            target[4] += dry
            target[5] += drz
        else:
            # 3DOF: orientation only (for your thesis comparison!)
            target[3] += drx
            target[4] += dry
            target[5] += drz
            
        # Apply workspace limits
        target[0] = np.clip(target[0], config.workspace_min[0], config.workspace_max[0])
        target[1] = np.clip(target[1], config.workspace_min[1], config.workspace_max[1])
        target[2] = np.clip(target[2], config.workspace_min[2], config.workspace_max[2])
        
        return target
        
    def move_to_pose(self, target_pose: np.ndarray) -> bool:
        """Send motion command to robot"""
        if not self.connected or not config.enable_motion:
            return False
            
        try:
            # Use servoL for real-time control (low latency)
            # Parameters: pose, speed, acceleration, time, lookahead_time, gain
            self.rtde_c.servoL(
                target_pose.tolist(),
                config.max_linear_speed,
                config.acceleration,
                0.008,  # time (control cycle)
                0.1,    # lookahead_time
                300     # gain
            )
            return True
        except Exception as e:
            print(f"Motion error: {e}")
            return False
            
    def get_current_pose(self) -> Optional[np.ndarray]:
        if self.rtde_r:
            return np.array(self.rtde_r.getActualTCPPose())
        return None

# ============================================================================
# MAIN CONTROL LOOP
# ============================================================================

def main():
    print("="*60)
    print("UR10e VR Telepresence Controller")
    print("="*60)
    print(f"Control mode: {config.control_mode}")
    print(f"Motion enabled: {config.enable_motion}")
    print()
    
    if not config.enable_motion:
        print("⚠️  MOTION DISABLED - Set config.enable_motion = True to move robot")
        print("    This is a safety feature for testing!")
        print()
    
    # Initialize components
    tracker = HeadTrackingReceiver(config.tracking_port)
    robot = UR10eController(config.robot_ip)
    
    # Connect to robot
    if not robot.connect():
        print("Failed to connect to robot. Exiting.")
        return
        
    # Start tracking receiver
    tracker.start()
    
    print("\nWaiting for head tracking data...")
    print("Send UDP packets to port", config.tracking_port)
    print("Press Ctrl+C to stop\n")
    
    # Wait for first tracking data to set reference
    while tracker.get_pose() is None:
        time.sleep(0.1)
    
    # Set reference pose (current head position = robot's current position)
    robot.set_reference_head_pose(tracker.get_pose())
    print("Reference pose captured! Starting control loop...\n")
    
    # Control loop
    loop_rate = 125  # Hz (matches RTDE)
    loop_time = 1.0 / loop_rate
    
    try:
        while True:
            loop_start = time.time()
            
            # Get latest head pose
            head_pose = tracker.get_pose()
            if head_pose is None:
                time.sleep(loop_time)
                continue
                
            # Compute target robot pose
            target = robot.compute_target_pose(head_pose)
            if target is not None:
                # Send motion command
                if config.enable_motion:
                    robot.move_to_pose(target)
                    
                # Debug output (reduce frequency for readability)
                current = robot.get_current_pose()
                if current is not None and int(time.time() * 10) % 10 == 0:
                    print(f"Target: [{target[0]:.3f}, {target[1]:.3f}, {target[2]:.3f}] "
                          f"Current: [{current[0]:.3f}, {current[1]:.3f}, {current[2]:.3f}]")
            
            # Maintain loop rate
            elapsed = time.time() - loop_start
            if elapsed < loop_time:
                time.sleep(loop_time - elapsed)
                
    except KeyboardInterrupt:
        print("\nStopping...")
    finally:
        robot.disconnect()
        tracker.stop()
        print("Shutdown complete.")

if __name__ == "__main__":
    main()
