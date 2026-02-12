#!/usr/bin/env python3
"""
Stereoscopic Video Receiver for VR Display
Receives FFmpeg stream and renders to VR headset via OpenVR

This is a simplified example - for production you'd want:
- GPU-accelerated decoding (NVDEC)
- Direct texture upload to VR compositor
- Proper async frame handling

Requirements:
    pip install opencv-python numpy pyopenvr
"""

import cv2
import numpy as np
import openvr
import threading
import time
from dataclasses import dataclass
from typing import Optional
import subprocess

@dataclass
class Config:
    # Stream source
    stream_url: str = "rtp://0.0.0.0:5004"
    
    # Resolution per eye (HP Reverb G2)
    eye_width: int = 2160
    eye_height: int = 2160
    
    # Input format (side-by-side means total width is 2x eye_width)
    stereo_format: str = "sbs"  # "sbs" = side-by-side, "tb" = top-bottom

config = Config()

class VideoReceiver:
    """Receives and decodes video stream using OpenCV/FFmpeg"""
    
    def __init__(self, url: str):
        self.url = url
        self.cap: Optional[cv2.VideoCapture] = None
        self.latest_frame: Optional[np.ndarray] = None
        self.lock = threading.Lock()
        self.running = False
        
    def start(self) -> bool:
        # Configure for low latency
        self.cap = cv2.VideoCapture(self.url, cv2.CAP_FFMPEG)
        
        if not self.cap.isOpened():
            print(f"Failed to open stream: {self.url}")
            return False
            
        # Set buffer size to minimum
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        
        self.running = True
        self.thread = threading.Thread(target=self._receive_loop, daemon=True)
        self.thread.start()
        
        print(f"Video receiver started: {self.url}")
        return True
        
    def stop(self):
        self.running = False
        if self.cap:
            self.cap.release()
            
    def _receive_loop(self):
        while self.running:
            ret, frame = self.cap.read()
            if ret:
                with self.lock:
                    self.latest_frame = frame
            else:
                time.sleep(0.001)
                
    def get_frame(self) -> Optional[np.ndarray]:
        with self.lock:
            return self.latest_frame.copy() if self.latest_frame is not None else None

class VRRenderer:
    """Renders stereoscopic frames to VR headset"""
    
    def __init__(self):
        self.vr_system = None
        self.compositor = None
        
    def init(self) -> bool:
        try:
            self.vr_system = openvr.init(openvr.VRApplication_Scene)
            self.compositor = openvr.VRCompositor()
            print("VR renderer initialized")
            return True
        except Exception as e:
            print(f"VR init failed: {e}")
            return False
            
    def shutdown(self):
        if self.vr_system:
            openvr.shutdown()
            
    def submit_frame(self, left_eye: np.ndarray, right_eye: np.ndarray):
        """
        Submit stereoscopic frame to VR compositor.
        
        Note: This is a simplified version. For production, you'd want to:
        1. Use OpenGL/Vulkan textures directly
        2. Upload to GPU without CPU copy
        3. Use the VR compositor's texture submission API properly
        """
        # For now, this is a placeholder showing the concept
        # Real implementation would use openvr's texture submission
        
        # Create OpenVR texture structures
        # left_texture = openvr.Texture_t()
        # left_texture.handle = <OpenGL texture ID>
        # left_texture.eType = openvr.TextureType_OpenGL
        # left_texture.eColorSpace = openvr.ColorSpace_Gamma
        
        # self.compositor.submit(openvr.Eye_Left, left_texture)
        # self.compositor.submit(openvr.Eye_Right, right_texture)
        
        pass  # Placeholder - see vr_display_opengl.py for full implementation

def split_stereo_frame(frame: np.ndarray, format: str = "sbs") -> tuple:
    """Split stereoscopic frame into left and right eye images"""
    h, w = frame.shape[:2]
    
    if format == "sbs":  # Side-by-side
        mid = w // 2
        left = frame[:, :mid]
        right = frame[:, mid:]
    else:  # Top-bottom
        mid = h // 2
        left = frame[:mid, :]
        right = frame[mid:, :]
        
    return left, right

def main():
    print("="*60)
    print("VR Stereoscopic Video Receiver")
    print("="*60)
    print(f"Stream URL: {config.stream_url}")
    print(f"Eye resolution: {config.eye_width}x{config.eye_height}")
    print()
    
    # Initialize video receiver
    receiver = VideoReceiver(config.stream_url)
    if not receiver.start():
        return
        
    # Initialize VR (optional - can run without for testing)
    # vr = VRRenderer()
    # vr.init()
    
    print("\nReceiving video. Press 'q' to quit.\n")
    
    frame_count = 0
    start_time = time.time()
    
    try:
        while True:
            frame = receiver.get_frame()
            
            if frame is not None:
                frame_count += 1
                
                # Split into left/right
                left, right = split_stereo_frame(frame, config.stereo_format)
                
                # Display for testing (remove in production)
                # Resize for display
                display_scale = 0.25
                left_small = cv2.resize(left, None, fx=display_scale, fy=display_scale)
                right_small = cv2.resize(right, None, fx=display_scale, fy=display_scale)
                combined = np.hstack([left_small, right_small])
                
                # Add FPS counter
                elapsed = time.time() - start_time
                fps = frame_count / elapsed if elapsed > 0 else 0
                cv2.putText(combined, f"FPS: {fps:.1f}", (10, 30),
                           cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 0), 2)
                
                cv2.imshow("Stereo Stream", combined)
                
                # Submit to VR
                # vr.submit_frame(left, right)
                
            if cv2.waitKey(1) & 0xFF == ord('q'):
                break
                
    except KeyboardInterrupt:
        pass
    finally:
        receiver.stop()
        cv2.destroyAllWindows()
        # vr.shutdown()
        print("Shutdown complete.")

if __name__ == "__main__":
    main()
