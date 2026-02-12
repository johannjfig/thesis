import json
import argparse
import matplotlib.pyplot as plt
import numpy as np

"""
PLAYBACK RESULTS PLOTTER

Visualizes:
1. Command latency over time
2. Position error over time
3. Target vs Actual trajectory (X, Y, Z)
4. Latency histogram
5. Error histogram
6. Summary statistics
"""

def load_results(filename):
    """Load playback results from JSON"""
    with open(filename, 'r') as f:
        return json.load(f)

def plot_results(results, output_prefix="plot"):
    """Generate all plots"""
    
    measurements = results["measurements"]
    stats = results["stats"]
    rate = results["rate"]
    
    # Extract data
    times = [m["sample_time"] for m in measurements]
    cmd_latencies = [m["cmd_latency"] * 1000 for m in measurements]  # Convert to ms
    pos_errors = [m["pos_error"] * 1000 for m in measurements]  # Convert to mm
    
    target_x = [m["target_tcp"][0] for m in measurements]
    target_y = [m["target_tcp"][1] for m in measurements]
    target_z = [m["target_tcp"][2] for m in measurements]
    
    actual_x = [m["actual_tcp"][0] for m in measurements]
    actual_y = [m["actual_tcp"][1] for m in measurements]
    actual_z = [m["actual_tcp"][2] for m in measurements]
    
    # Create figure with subplots
    fig = plt.figure(figsize=(16, 12))
    fig.suptitle(f'VR Telepresence Playback Analysis\n'
                 f'Rate: {rate} Hz, Samples: {len(measurements)}, '
                 f'Duration: {results["stats"]["actual_duration"]:.1f}s', 
                 fontsize=14, fontweight='bold')
    
    # ========================================
    # Plot 1: Command Latency over Time
    # ========================================
    ax1 = fig.add_subplot(3, 2, 1)
    ax1.plot(times, cmd_latencies, 'b-', linewidth=0.8, alpha=0.7)
    ax1.axhline(y=stats["cmd_latency_mean_ms"], color='r', linestyle='--', 
                label=f'Mean: {stats["cmd_latency_mean_ms"]:.2f} ms')
    ax1.fill_between(times, 0, cmd_latencies, alpha=0.3)
    ax1.set_xlabel('Time (s)')
    ax1.set_ylabel('Latency (ms)')
    ax1.set_title('Command Latency Over Time')
    ax1.legend()
    ax1.grid(True, alpha=0.3)
    ax1.set_ylim(bottom=0)
    
    # ========================================
    # Plot 2: Position Error over Time
    # ========================================
    ax2 = fig.add_subplot(3, 2, 2)
    ax2.plot(times, pos_errors, 'g-', linewidth=0.8, alpha=0.7)
    ax2.axhline(y=stats["pos_error_mean_mm"], color='r', linestyle='--',
                label=f'Mean: {stats["pos_error_mean_mm"]:.2f} mm')
    ax2.fill_between(times, 0, pos_errors, alpha=0.3, color='green')
    ax2.set_xlabel('Time (s)')
    ax2.set_ylabel('Position Error (mm)')
    ax2.set_title('Position Error Over Time')
    ax2.legend()
    ax2.grid(True, alpha=0.3)
    ax2.set_ylim(bottom=0)
    
    # ========================================
    # Plot 3: Trajectory Comparison (X, Y, Z)
    # ========================================
    ax3 = fig.add_subplot(3, 2, 3)
    ax3.plot(times, target_x, 'r-', linewidth=1, label='Target X', alpha=0.8)
    ax3.plot(times, actual_x, 'r--', linewidth=1, label='Actual X', alpha=0.5)
    ax3.plot(times, target_y, 'g-', linewidth=1, label='Target Y', alpha=0.8)
    ax3.plot(times, actual_y, 'g--', linewidth=1, label='Actual Y', alpha=0.5)
    ax3.plot(times, target_z, 'b-', linewidth=1, label='Target Z', alpha=0.8)
    ax3.plot(times, actual_z, 'b--', linewidth=1, label='Actual Z', alpha=0.5)
    ax3.set_xlabel('Time (s)')
    ax3.set_ylabel('Position (m)')
    ax3.set_title('Target vs Actual Trajectory')
    ax3.legend(loc='upper right', fontsize=8)
    ax3.grid(True, alpha=0.3)
    
    # ========================================
    # Plot 4: Latency Histogram
    # ========================================
    ax4 = fig.add_subplot(3, 2, 4)
    ax4.hist(cmd_latencies, bins=50, color='blue', alpha=0.7, edgecolor='black')
    ax4.axvline(x=stats["cmd_latency_mean_ms"], color='r', linestyle='--',
                label=f'Mean: {stats["cmd_latency_mean_ms"]:.2f} ms')
    ax4.axvline(x=np.percentile(cmd_latencies, 95), color='orange', linestyle='--',
                label=f'95th %ile: {np.percentile(cmd_latencies, 95):.2f} ms')
    ax4.set_xlabel('Latency (ms)')
    ax4.set_ylabel('Count')
    ax4.set_title('Command Latency Distribution')
    ax4.legend()
    ax4.grid(True, alpha=0.3)
    
    # ========================================
    # Plot 5: Error Histogram
    # ========================================
    ax5 = fig.add_subplot(3, 2, 5)
    ax5.hist(pos_errors, bins=50, color='green', alpha=0.7, edgecolor='black')
    ax5.axvline(x=stats["pos_error_mean_mm"], color='r', linestyle='--',
                label=f'Mean: {stats["pos_error_mean_mm"]:.2f} mm')
    ax5.axvline(x=np.percentile(pos_errors, 95), color='orange', linestyle='--',
                label=f'95th %ile: {np.percentile(pos_errors, 95):.2f} mm')
    ax5.set_xlabel('Position Error (mm)')
    ax5.set_ylabel('Count')
    ax5.set_title('Position Error Distribution')
    ax5.legend()
    ax5.grid(True, alpha=0.3)
    
    # ========================================
    # Plot 6: Summary Statistics Text
    # ========================================
    ax6 = fig.add_subplot(3, 2, 6)
    ax6.axis('off')
    
    summary_text = f"""
    SUMMARY STATISTICS
    ══════════════════════════════════════
    
    Recording Info:
      • Input file: {results.get('input_file', 'N/A')}
      • Update rate: {rate} Hz
      • Total samples: {len(measurements)}
      • Expected duration: {len(measurements)/rate:.2f} s
      • Actual duration: {stats['actual_duration']:.2f} s
    
    Command Latency:
      • Mean:   {stats['cmd_latency_mean_ms']:.3f} ms
      • Min:    {stats['cmd_latency_min_ms']:.3f} ms
      • Max:    {stats['cmd_latency_max_ms']:.3f} ms
      • Std:    {np.std(cmd_latencies):.3f} ms
      • 95th %: {np.percentile(cmd_latencies, 95):.3f} ms
    
    Position Error:
      • Mean:   {stats['pos_error_mean_mm']:.2f} mm
      • Min:    {stats['pos_error_min_mm']:.2f} mm
      • Max:    {stats['pos_error_max_mm']:.2f} mm
      • Std:    {np.std(pos_errors):.2f} mm
      • 95th %: {np.percentile(pos_errors, 95):.2f} mm
    
    Timing Accuracy:
      • Target loop time: {1000/rate:.2f} ms
      • Timing drift: {(stats['actual_duration'] - len(measurements)/rate)*1000:.1f} ms total
    """
    
    ax6.text(0.1, 0.95, summary_text, transform=ax6.transAxes, fontsize=10,
             verticalalignment='top', fontfamily='monospace',
             bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.5))
    
    plt.tight_layout()
    
    # Save figure
    output_file = f"{output_prefix}_analysis.png"
    plt.savefig(output_file, dpi=150, bbox_inches='tight')
    print(f"Saved plot to: {output_file}")
    
    # Also create a 3D trajectory plot
    fig2 = plt.figure(figsize=(10, 8))
    ax3d = fig2.add_subplot(111, projection='3d')
    
    ax3d.plot(target_x, target_y, target_z, 'b-', linewidth=1.5, label='Target', alpha=0.8)
    ax3d.plot(actual_x, actual_y, actual_z, 'r--', linewidth=1.5, label='Actual', alpha=0.6)
    
    # Mark start and end
    ax3d.scatter([target_x[0]], [target_y[0]], [target_z[0]], c='green', s=100, marker='o', label='Start')
    ax3d.scatter([target_x[-1]], [target_y[-1]], [target_z[-1]], c='red', s=100, marker='x', label='End')
    
    ax3d.set_xlabel('X (m)')
    ax3d.set_ylabel('Y (m)')
    ax3d.set_zlabel('Z (m)')
    ax3d.set_title('3D Trajectory: Target vs Actual')
    ax3d.legend()
    
    output_file_3d = f"{output_prefix}_trajectory_3d.png"
    plt.savefig(output_file_3d, dpi=150, bbox_inches='tight')
    print(f"Saved 3D plot to: {output_file_3d}")
    
    plt.show()

def main():
    parser = argparse.ArgumentParser(description="Plot playback results")
    parser.add_argument("--input", type=str, default="playback_results.json", 
                        help="Input results file (default: playback_results.json)")
    parser.add_argument("--output", type=str, default="plot",
                        help="Output file prefix (default: plot)")
    args = parser.parse_args()
    
    print("="*50)
    print("PLAYBACK RESULTS PLOTTER")
    print("="*50)
    
    print(f"\nLoading: {args.input}")
    results = load_results(args.input)
    
    print(f"Generating plots...")
    plot_results(results, args.output)
    
    print("\nDone!")

if __name__ == "__main__":
    main()