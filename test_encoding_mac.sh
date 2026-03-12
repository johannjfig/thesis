#!/bin/bash
# Mac FFmpeg Encoding Test Script for VR Telepresence
# Tests VideoToolbox (hardware) and libx264 (software) encoding

set -e

# Configuration
CAMERA_DEVICE="0"  # VR.Cam 02 (check with: ffmpeg -f avfoundation -list_devices true -i "")
PIXEL_FORMAT="uyvy422"
TEST_DURATION=10
OUTPUT_DIR="encoding_results"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Results file
RESULTS_FILE="$OUTPUT_DIR/results.csv"
echo "Test,Encoder,Resolution,Framerate,Bitrate_Mbps,Speed,EncodingFPS,TimePerFrame_ms" > "$RESULTS_FILE"

# Test function
run_test() {
    local name="$1"
    local encoder="$2"
    local resolution="$3"
    local framerate="$4"
    local bitrate="$5"
    local extra_opts="$6"
    
    echo ""
    echo "============================================"
    echo "Test: $name"
    echo "Encoder: $encoder | Resolution: $resolution | FPS: $framerate | Bitrate: ${bitrate}M"
    echo "============================================"
    
    # Run encoding test
    local log_file="$OUTPUT_DIR/log_${name// /_}.txt"
    
    ffmpeg -y -f avfoundation -framerate "$framerate" -pixel_format "$PIXEL_FORMAT" \
        -video_size "$resolution" -i "$CAMERA_DEVICE" \
        -t "$TEST_DURATION" \
        -c:v "$encoder" $extra_opts -b:v "${bitrate}M" \
        -f null - 2>&1 | tee "$log_file"
    
    # Extract speed from log
    local speed=$(grep "speed=" "$log_file" | tail -1 | sed -n 's/.*speed=\s*\([0-9.]*\)x.*/\1/p')
    
    if [ -n "$speed" ] && [ "$speed" != "0" ]; then
        local encoding_fps=$(echo "scale=2; $speed * $framerate" | bc)
        local time_per_frame=$(echo "scale=3; 1000 / $encoding_fps" | bc)
        
        echo ""
        echo "Results:"
        echo "  Speed: ${speed}x"
        echo "  Encoding FPS: $encoding_fps"
        echo "  Time per frame: ${time_per_frame}ms"
        
        # Check if meets 90fps target (<11.1ms per frame)
        if (( $(echo "$time_per_frame < 11.1" | bc -l) )); then
            echo "  Status: ✅ PASS (meets 90fps target)"
        else
            echo "  Status: ❌ FAIL (too slow for 90fps)"
        fi
        
        echo "$name,$encoder,$resolution,$framerate,$bitrate,$speed,$encoding_fps,$time_per_frame" >> "$RESULTS_FILE"
    else
        echo "  Status: ⚠️ Could not extract speed"
        echo "$name,$encoder,$resolution,$framerate,$bitrate,ERROR,ERROR,ERROR" >> "$RESULTS_FILE"
    fi
}

echo "========================================================"
echo "    VR TELEPRESENCE ENCODING TEST - Mac Version"
echo "========================================================"
echo ""
echo "Camera: $CAMERA_DEVICE"
echo "Test Duration: ${TEST_DURATION}s per test"
echo "Output: $OUTPUT_DIR"
echo ""

# ============================================
# Phase 1: Test Camera Capabilities
# ============================================
echo ""
echo "========================================================"
echo "Phase 1: Camera Capability Test"
echo "========================================================"

echo "Testing maximum framerate at different resolutions..."
echo "(VR.Cam 02 specs: 3840x1920 @ 30fps max)"

for res in "3840x1920" "1920x1080" "1280x720"; do
    for fps in 30 60; do
        echo -n "Testing $res @ ${fps}fps... "
        if timeout 5 ffmpeg -f avfoundation -framerate $fps -pixel_format "$PIXEL_FORMAT" \
            -video_size "$res" -i "$CAMERA_DEVICE" \
            -t 2 -f null - 2>&1 | grep -q "frame="; then
            echo "✅ OK"
        else
            echo "❌ Failed"
        fi
    done
done

# ============================================
# Phase 2: Encoding Speed Tests
# ============================================
echo ""
echo "========================================================"
echo "Phase 2: Encoding Speed Tests"
echo "========================================================"

# VideoToolbox H.264 (Hardware) - Native VR camera resolution
run_test "VT_H264_stereo_3840x1920_30fps_15M" "h264_videotoolbox" "3840x1920" "30" "15" ""
run_test "VT_H264_stereo_3840x1920_30fps_20M" "h264_videotoolbox" "3840x1920" "30" "20" ""
run_test "VT_H264_stereo_3840x1920_30fps_10M" "h264_videotoolbox" "3840x1920" "30" "10" ""

# Lower resolution tests
run_test "VT_H264_1080p_30fps_15M" "h264_videotoolbox" "1920x1080" "30" "15" ""
run_test "VT_H264_720p_30fps_10M" "h264_videotoolbox" "1280x720" "30" "10" ""

# VideoToolbox HEVC (Hardware)
run_test "VT_HEVC_stereo_3840x1920_30fps_15M" "hevc_videotoolbox" "3840x1920" "30" "15" ""
run_test "VT_HEVC_stereo_3840x1920_30fps_10M" "hevc_videotoolbox" "3840x1920" "30" "10" ""

# libx264 (Software) - ultrafast
run_test "x264_ultrafast_stereo_3840x1920_30fps_15M" "libx264" "3840x1920" "30" "15" "-preset ultrafast"
run_test "x264_ultrafast_1080p_30fps_15M" "libx264" "1920x1080" "30" "15" "-preset ultrafast"

# ============================================
# Phase 3: Low Latency Specific Tests
# ============================================
echo ""
echo "========================================================"
echo "Phase 3: Low Latency Tests"
echo "========================================================"

# VideoToolbox with realtime flag - native stereo
run_test "VT_H264_realtime_stereo" "h264_videotoolbox" "3840x1920" "30" "15" "-realtime true"

# libx264 with zero latency tuning - native stereo
run_test "x264_zerolatency_stereo" "libx264" "3840x1920" "30" "15" "-preset ultrafast -tune zerolatency"

# ============================================
# Summary
# ============================================
echo ""
echo "========================================================"
echo "TEST COMPLETE"
echo "========================================================"
echo ""
echo "Results saved to: $RESULTS_FILE"
echo ""
echo "Summary:"
cat "$RESULTS_FILE" | column -t -s ','
echo ""
echo "For 90fps VR streaming, you need <11.1ms per frame"
echo "Run NVENC tests on Windows for GPU hardware encoding"