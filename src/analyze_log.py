import json
import argparse
import matplotlib.pyplot as plt
import numpy as np
import math

"""
TELEPRESENCE LOG ANALYZER

Analyzes logged data from vr_telepresence_v9_logging.py
Compares VR input to robot output to identify issues.
"""

def main():
    parser = argparse.ArgumentParser(description="Analyze telepresence log")
    parser.add_argument("--input", type=str, default="telepresence_log.json")
    parser.add_argument("--output", type=str, default="telepresence_analysis")
    args = parser.parse_args()
    
    print("="*60)
    print("TELEPRESENCE LOG ANALYZER")
    print("="*60)
    
    # Load data
    with open(args.input, 'r') as f:
        log = json.load(f)
    
    samples = log["samples"]
    rate = log["rate"]
    
    print(f"\nLog info:")
    print(f"  Samples: {len(samples)}")
    print(f"  Rate: {rate} Hz")
    print(f"  Duration: {log.get('duration', 0):.1f}s")
    print(f"  IK failures: {log.get('ik_failures', 0)}")
    
    # Extract data
    times = [s["t"] for s in samples]
    
    # VR position deltas
    vr_dx = [s["vr_pos_delta"][0] * 100 for s in samples]  # cm
    vr_dy = [s["vr_pos_delta"][1] * 100 for s in samples]
    vr_dz = [s["vr_pos_delta"][2] * 100 for s in samples]
    
    # VR rotation deltas
    vr_pitch = [math.degrees(s["vr_rot_delta"][0]) for s in samples]
    vr_yaw = [math.degrees(s["vr_rot_delta"][1]) for s in samples]
    vr_roll = [math.degrees(s["vr_rot_delta"][2]) for s in samples]
    
    # Robot commanded deltas
    robot_dx = [s["robot_delta"][0] * 100 for s in samples]  # cm
    robot_dy = [s["robot_delta"][1] * 100 for s in samples]
    robot_dz = [s["robot_delta"][2] * 100 for s in samples]
    
    # Robot target TCP
    target_x = [s["target_tcp_pos"][0] for s in samples]
    target_y = [s["target_tcp_pos"][1] for s in samples]
    target_z = [s["target_tcp_pos"][2] for s in samples]
    
    # Robot actual TCP
    actual_x = [s["actual_tcp"][0] for s in samples]
    actual_y = [s["actual_tcp"][1] for s in samples]
    actual_z = [s["actual_tcp"][2] for s in samples]
    
    # IK success
    ik_success = [s["ik_success"] for s in samples]
    
    # Calculate position errors
    pos_errors = [math.sqrt((t[0]-a[0])**2 + (t[1]-a[1])**2 + (t[2]-a[2])**2) * 1000 
                  for t, a in zip(zip(target_x, target_y, target_z), 
                                  zip(actual_x, actual_y, actual_z))]
    
    # Statistics
    print(f"\nVR POSITION DELTAS:")
    print(f"  L/R (X): {min(vr_dx):.1f} to {max(vr_dx):.1f} cm (range: {max(vr_dx)-min(vr_dx):.1f} cm)")
    print(f"  U/D (Y): {min(vr_dy):.1f} to {max(vr_dy):.1f} cm (range: {max(vr_dy)-min(vr_dy):.1f} cm)")
    print(f"  F/B (Z): {min(vr_dz):.1f} to {max(vr_dz):.1f} cm (range: {max(vr_dz)-min(vr_dz):.1f} cm)")
    
    print(f"\nROBOT COMMANDED DELTAS:")
    print(f"  X: {min(robot_dx):.1f} to {max(robot_dx):.1f} cm (range: {max(robot_dx)-min(robot_dx):.1f} cm)")
    print(f"  Y: {min(robot_dy):.1f} to {max(robot_dy):.1f} cm (range: {max(robot_dy)-min(robot_dy):.1f} cm)")
    print(f"  Z: {min(robot_dz):.1f} to {max(robot_dz):.1f} cm (range: {max(robot_dz)-min(robot_dz):.1f} cm)")
    
    print(f"\nPOSITION ERROR (target vs actual):")
    print(f"  Mean: {np.mean(pos_errors):.1f} mm")
    print(f"  Max:  {max(pos_errors):.1f} mm")
    
    print(f"\nIK SUCCESS RATE: {sum(ik_success)}/{len(ik_success)} ({100*sum(ik_success)/len(ik_success):.1f}%)")
    
    # Check for issues
    print(f"\n{'='*60}")
    print("ANALYSIS")
    print(f"{'='*60}")
    
    vr_total_range = math.sqrt((max(vr_dx)-min(vr_dx))**2 + (max(vr_dy)-min(vr_dy))**2 + (max(vr_dz)-min(vr_dz))**2)
    robot_total_range = math.sqrt((max(robot_dx)-min(robot_dx))**2 + (max(robot_dy)-min(robot_dy))**2 + (max(robot_dz)-min(robot_dz))**2)
    
    print(f"\nVR total movement: {vr_total_range:.1f} cm")
    print(f"Robot total commanded: {robot_total_range:.1f} cm")
    print(f"Ratio: {robot_total_range/vr_total_range:.2f}x (expected: {log.get('position_scale', 0.5)}x)")
    
    if vr_total_range < 10:
        print("\n⚠️  WARNING: VR movement very small (<10cm)")
        print("   - Check if SteamVR tracking is working")
        print("   - Make sure you're NOT in SteamVR Home")
    
    if sum(ik_success)/len(ik_success) < 0.9:
        print("\n⚠️  WARNING: High IK failure rate")
        print("   - Robot may be near joint limits")
        print("   - Try reducing POSITION_SCALE")
    
    if np.mean(pos_errors) > 50:
        print("\n⚠️  WARNING: High position error (>50mm)")
        print("   - Robot may not be keeping up")
        print("   - Try reducing control rate")
    
    # Create plots
    fig = plt.figure(figsize=(18, 14))
    fig.suptitle(f'Telepresence Analysis\n{len(samples)} samples at {rate}Hz, {log.get("duration", 0):.1f}s duration', fontsize=14)
    
    # Plot 1: VR position over time
    ax1 = fig.add_subplot(3, 3, 1)
    ax1.plot(times, vr_dx, 'r-', label='X (L/R)', alpha=0.8)
    ax1.plot(times, vr_dy, 'g-', label='Y (U/D)', alpha=0.8)
    ax1.plot(times, vr_dz, 'b-', label='Z (F/B)', alpha=0.8)
    ax1.set_xlabel('Time (s)')
    ax1.set_ylabel('Position delta (cm)')
    ax1.set_title('VR Head Position')
    ax1.legend()
    ax1.grid(True, alpha=0.3)
    
    # Plot 2: Robot commanded position over time
    ax2 = fig.add_subplot(3, 3, 2)
    ax2.plot(times, robot_dx, 'r-', label='X', alpha=0.8)
    ax2.plot(times, robot_dy, 'g-', label='Y', alpha=0.8)
    ax2.plot(times, robot_dz, 'b-', label='Z', alpha=0.8)
    ax2.set_xlabel('Time (s)')
    ax2.set_ylabel('Position delta (cm)')
    ax2.set_title('Robot Commanded Position')
    ax2.legend()
    ax2.grid(True, alpha=0.3)
    
    # Plot 3: Position error over time
    ax3 = fig.add_subplot(3, 3, 3)
    ax3.plot(times, pos_errors, 'k-', alpha=0.8)
    ax3.axhline(y=np.mean(pos_errors), color='r', linestyle='--', label=f'Mean: {np.mean(pos_errors):.1f}mm')
    ax3.set_xlabel('Time (s)')
    ax3.set_ylabel('Position error (mm)')
    ax3.set_title('Target vs Actual Error')
    ax3.legend()
    ax3.grid(True, alpha=0.3)
    
    # Plot 4: VR rotation over time
    ax4 = fig.add_subplot(3, 3, 4)
    ax4.plot(times, vr_pitch, 'r-', label='Pitch (nod)', alpha=0.8)
    ax4.plot(times, vr_yaw, 'g-', label='Yaw (turn)', alpha=0.8)
    ax4.plot(times, vr_roll, 'b-', label='Roll (tilt)', alpha=0.8)
    ax4.set_xlabel('Time (s)')
    ax4.set_ylabel('Rotation delta (degrees)')
    ax4.set_title('VR Head Rotation')
    ax4.legend()
    ax4.grid(True, alpha=0.3)
    
    # Plot 5: VR vs Robot X comparison
    ax5 = fig.add_subplot(3, 3, 5)
    ax5.plot(times, vr_dz, 'b-', label='VR Z (F/B)', alpha=0.8)
    ax5.plot(times, robot_dx, 'r--', label='Robot X', alpha=0.8)
    ax5.set_xlabel('Time (s)')
    ax5.set_ylabel('Position (cm)')
    ax5.set_title('VR Forward/Back → Robot X')
    ax5.legend()
    ax5.grid(True, alpha=0.3)
    
    # Plot 6: IK success over time
    ax6 = fig.add_subplot(3, 3, 6)
    ik_fail_times = [times[i] for i, s in enumerate(ik_success) if not s]
    ax6.scatter(ik_fail_times, [1]*len(ik_fail_times), c='red', s=10, label=f'IK failures ({len(ik_fail_times)})')
    ax6.set_xlabel('Time (s)')
    ax6.set_title('IK Failures')
    ax6.set_ylim(0, 2)
    ax6.legend()
    ax6.grid(True, alpha=0.3)
    
    # Plot 7: VR trajectory top-down
    ax7 = fig.add_subplot(3, 3, 7)
    ax7.plot(vr_dz, vr_dx, 'b-', alpha=0.5, linewidth=0.5)
    ax7.scatter([vr_dz[0]], [vr_dx[0]], c='green', s=100, marker='o', label='Start', zorder=5)
    ax7.scatter([vr_dz[-1]], [vr_dx[-1]], c='red', s=100, marker='x', label='End', zorder=5)
    ax7.set_xlabel('Z (Forward/Back) cm')
    ax7.set_ylabel('X (Left/Right) cm')
    ax7.set_title('VR Trajectory (Top-Down)')
    ax7.legend()
    ax7.grid(True, alpha=0.3)
    ax7.axis('equal')
    
    # Plot 8: Robot trajectory top-down
    ax8 = fig.add_subplot(3, 3, 8)
    ax8.plot(robot_dx, robot_dy, 'r-', alpha=0.5, linewidth=0.5)
    ax8.scatter([robot_dx[0]], [robot_dy[0]], c='green', s=100, marker='o', label='Start', zorder=5)
    ax8.scatter([robot_dx[-1]], [robot_dy[-1]], c='red', s=100, marker='x', label='End', zorder=5)
    ax8.set_xlabel('X (Forward) cm')
    ax8.set_ylabel('Y (Left) cm')
    ax8.set_title('Robot Commanded (Top-Down)')
    ax8.legend()
    ax8.grid(True, alpha=0.3)
    ax8.axis('equal')
    
    # Plot 9: Robot actual TCP trajectory
    home_tcp = log.get("home_tcp", [0, 0, 0])
    actual_dx = [(a - home_tcp[0])*100 for a in actual_x]
    actual_dy = [(a - home_tcp[1])*100 for a in actual_y]
    
    ax9 = fig.add_subplot(3, 3, 9)
    ax9.plot(actual_dx, actual_dy, 'g-', alpha=0.5, linewidth=0.5)
    ax9.scatter([actual_dx[0]], [actual_dy[0]], c='green', s=100, marker='o', label='Start', zorder=5)
    ax9.scatter([actual_dx[-1]], [actual_dy[-1]], c='red', s=100, marker='x', label='End', zorder=5)
    ax9.set_xlabel('X (Forward) cm')
    ax9.set_ylabel('Y (Left) cm')
    ax9.set_title('Robot Actual TCP (Top-Down)')
    ax9.legend()
    ax9.grid(True, alpha=0.3)
    ax9.axis('equal')
    
    plt.tight_layout()
    
    output_file = f"{args.output}.png"
    plt.savefig(output_file, dpi=150, bbox_inches='tight')
    print(f"\nSaved plot to: {output_file}")
    
    plt.show()

if __name__ == "__main__":
    main()