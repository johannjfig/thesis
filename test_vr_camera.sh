#!/bin/bash
# VR Camera Resolution & Stereo Format Test Script
# Purpose:
#   1. Auto-detect the VR camera device (not the Mac built-in)
#   2. Test all resolutions supported by the device
#   3. Record stereo format comparison clips for HP Reverb G2 review
#
# FOV/Stereo issue explanation:
#   - 1552x1552 (square) = likely dual fisheye (776px per eye side-by-side)
#   - 1920x1080, 1760x1328 = likely SBS stereo (half-width per eye)
#   - 1080x1920, 1328x1760 = likely top-bottom stereo
#   All test variants are saved so you can compare on the headset.

OUTPUT_DIR="encoding_results"
RESULTS_DIR="$OUTPUT_DIR/resolution_tests"
STEREO_DIR="$OUTPUT_DIR/stereo_tests"
TEST_DURATION=5
RESULTS_FILE="$OUTPUT_DIR/vr_camera_results.csv"
WORKING_FILE="$OUTPUT_DIR/working_configs.txt"
CAMERA_DEVICE=""

# All resolutions reported by device
ALL_RESOLUTIONS=("640x480" "1280x720" "1920x1080" "1080x1920" "1328x1760" "1552x1552" "1760x1328")
PIXEL_FORMATS=("uyvy422" "yuyv422" "nv12")

mkdir -p "$RESULTS_DIR" "$STEREO_DIR"
> "$WORKING_FILE"
echo "Phase,Test_Name,Device,Resolution,FPS,PixelFmt,Encoder,Speed,Status,Notes" > "$RESULTS_FILE"

print_header() {
    echo ""
    echo "========================================================"
    echo "  $1"
    echo "========================================================"
}

log_result() {
    echo "$1" >> "$RESULTS_FILE"
}

# ============================================
# Phase 0: Camera Detection
# ============================================

detect_vr_camera() {
    print_header "Phase 0: Camera Detection"

    echo "Listing all AVFoundation video devices..."
    echo ""

    local device_list
    device_list=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1)

    # Show only video devices section
    echo "$device_list" | awk '/AVFoundation video devices/,/AVFoundation audio devices/' | \
        grep -v "AVFoundation audio devices" | head -20
    echo ""

    # Try to auto-detect VR camera by common name patterns
    local detected_index
    detected_index=$(echo "$device_list" | \
        grep -iE "\[([0-9]+)\].*(VR|360|vr\.cam|ricoh|insta|theta|stereoscopic)" | \
        head -1 | grep -oE "\[[0-9]+\]" | head -1 | tr -d "[]")

    if [ -n "$detected_index" ]; then
        local cam_name
        cam_name=$(echo "$device_list" | grep "\[$detected_index\]" | head -1)
        echo "Auto-detected VR camera at index [$detected_index]: $cam_name"
        CAMERA_DEVICE="$detected_index"
    else
        echo "No VR camera name detected automatically."
        echo "(Built-in FaceTime/webcam is usually [0])"
        echo ""
        echo "Enter the device index for your VR camera (default: 1):"
        read -r user_input
        CAMERA_DEVICE="${user_input:-1}"
    fi

    echo ""
    echo "Selected camera device: [$CAMERA_DEVICE]"

    # Probe selected device to show its supported modes
    echo ""
    echo "Probing device [$CAMERA_DEVICE] for supported modes..."
    timeout 8 ffmpeg -f avfoundation -pixel_format uyvy422 \
        -video_size "9999x9999" -i "$CAMERA_DEVICE" \
        -t 0.001 -f null - 2>&1 | \
        grep -E "Supported modes|@[0-9].*fps|Error opening" | head -15 || true
    echo ""
}

# ============================================
# Phase 1: Resolution Tests
# ============================================

test_single_resolution() {
    local res="$1"
    local fps="$2"
    local pfmt="$3"

    local safe_name="${res}_${fps}fps_${pfmt}"
    local out_file="$RESULTS_DIR/res_${safe_name}.mp4"
    local log_file="$RESULTS_DIR/res_${safe_name}.log"

    local result exit_code
    result=$(timeout $((TEST_DURATION + 8)) ffmpeg -y \
        -f avfoundation \
        -framerate "$fps" \
        -pixel_format "$pfmt" \
        -video_size "$res" \
        -i "$CAMERA_DEVICE" \
        -t "$TEST_DURATION" \
        -c:v h264_videotoolbox \
        -b:v 10M \
        "$out_file" 2>&1) || true

    echo "$result" > "$log_file"

    local speed
    speed=$(echo "$result" | grep "speed=" | tail -1 | sed -n 's/.*speed=\([0-9.]*\)x.*/\1/p')

    if echo "$result" | grep -q "frame="; then
        echo "    ✅ $res @ ${fps}fps [$pfmt]: OK (speed=${speed}x)"
        log_result "resolution,res_${safe_name},$CAMERA_DEVICE,$res,$fps,$pfmt,h264_videotoolbox,$speed,OK,"
        # Track this as a working config
        echo "${res}:${fps}:${pfmt}" >> "$WORKING_FILE"
        return 0
    else
        local err
        err=$(echo "$result" | grep -iE "error|not supported|invalid|failed" | \
            head -1 | tr ',' ';' | tr '\n' ' ' | cut -c1-80)
        echo "    ❌ $res @ ${fps}fps [$pfmt]: FAIL"
        log_result "resolution,res_${safe_name},$CAMERA_DEVICE,$res,$fps,$pfmt,h264_videotoolbox,0,FAIL,$err"
        return 1
    fi
}

run_resolution_tests() {
    print_header "Phase 1: Resolution Tests (All Supported Modes)"

    echo "Testing all device-supported resolutions at 15fps and 30fps."
    echo "Trying pixel formats: ${PIXEL_FORMATS[*]}"
    echo "Clips saved to: $RESULTS_DIR/"
    echo ""

    for res in "${ALL_RESOLUTIONS[@]}"; do
        echo ""
        echo "--- $res ---"
        for fps in 15 30; do
            local worked=false
            for pfmt in "${PIXEL_FORMATS[@]}"; do
                if test_single_resolution "$res" "$fps" "$pfmt"; then
                    worked=true
                    break  # Found a working pixel format; move to next fps
                fi
            done
            if ! $worked; then
                echo "    ⚠️  $res @ ${fps}fps: No pixel format worked"
            fi
        done
    done
}

# ============================================
# Phase 2: Stereo Format Tests
# ============================================

test_stereo_clip() {
    local test_name="$1"
    local res="$2"
    local fps="$3"
    local pfmt="$4"
    local vf_filter="$5"    # -vf argument, or "" for none
    local stereo_meta="$6"  # container stereo_mode value, or ""

    local out_file="$STEREO_DIR/${test_name}_${res}_${fps}fps.mp4"
    local log_file="$STEREO_DIR/${test_name}_${res}_${fps}fps.log"

    printf "  %-40s " "$test_name"

    local ffmpeg_args=(-y
        -f avfoundation
        -framerate "$fps"
        -pixel_format "$pfmt"
        -video_size "$res"
        -i "$CAMERA_DEVICE"
        -t "$TEST_DURATION"
    )

    if [ -n "$vf_filter" ]; then
        ffmpeg_args+=(-vf "$vf_filter")
    fi

    ffmpeg_args+=(-c:v h264_videotoolbox -b:v 15M)

    if [ -n "$stereo_meta" ]; then
        ffmpeg_args+=(-metadata:s:v:0 "stereo_mode=$stereo_meta")
    fi

    ffmpeg_args+=("$out_file")

    local result
    result=$(timeout $((TEST_DURATION + 10)) ffmpeg "${ffmpeg_args[@]}" 2>&1) || true
    echo "$result" > "$log_file"

    if echo "$result" | grep -q "frame="; then
        echo "✅  -> $(basename "$out_file")"
        log_result "stereo,$test_name,$CAMERA_DEVICE,$res,$fps,$pfmt,h264_videotoolbox,,OK,vf='$vf_filter' meta='$stereo_meta'"
    else
        local err
        err=$(echo "$result" | grep -iE "error|failed|invalid|no such filter" | \
            head -1 | tr ',' ';' | cut -c1-60)
        echo "❌  $err"
        log_result "stereo,$test_name,$CAMERA_DEVICE,$res,$fps,$pfmt,h264_videotoolbox,,FAIL,$err"
    fi
}

run_stereo_tests() {
    print_header "Phase 2: Stereo Format Tests"

    echo "Recording comparison clips at different stereo layouts."
    echo "Transfer clips from '$STEREO_DIR/' to your VR PC and compare"
    echo "playback in a VR player (DeoVR, SkyBox, VLC) configured as SBS."
    echo ""
    echo "Resolution stereo hypotheses:"
    echo "  1920x1080  -> SBS stereo (left 960px = left eye, right 960px = right eye)"
    echo "  1760x1328  -> SBS stereo (left 880px = left eye, right 880px = right eye)"
    echo "  1552x1552  -> Dual fisheye 360 (left 776px = left fisheye, right = right)"
    echo "  1080x1920  -> Top-bottom stereo (top 960px = left eye)"
    echo "  1328x1760  -> Top-bottom stereo (top 880px = left eye)"
    echo ""

    # Process only resolutions that worked in Phase 1
    # Prefer 30fps; fall back to 15fps
    local processed_resolutions=""

    while IFS=: read -r w_res w_fps w_pfmt; do
        # Only process each resolution once (prefer 30fps entry)
        if echo "$processed_resolutions" | grep -q "$w_res"; then
            continue
        fi

        # Skip low-value resolutions for stereo testing
        if [ "$w_res" = "640x480" ]; then
            continue
        fi

        processed_resolutions="$processed_resolutions $w_res"

        local w h hw hh
        w=$(echo "$w_res" | cut -dx -f1)
        h=$(echo "$w_res" | cut -dx -f2)
        hw=$((w / 2))
        hh=$((h / 2))

        echo ""
        echo "====== Stereo tests: $w_res @ ${w_fps}fps [${w_pfmt}] ======"

        # --- Always run: basic stereo interpretation tests ---

        # 1. Raw baseline - unmodified capture
        test_stereo_clip "01_raw_baseline" \
            "$w_res" "$w_fps" "$w_pfmt" "" ""

        # 2. SBS metadata: left half = left eye (most common VR camera default)
        test_stereo_clip "02_SBS_left_right_meta" \
            "$w_res" "$w_fps" "$w_pfmt" "" "left_right"

        # 3. SBS metadata: left half = right eye (swapped - try if 02 looks wrong)
        test_stereo_clip "03_SBS_right_left_meta" \
            "$w_res" "$w_fps" "$w_pfmt" "" "right_left"

        # 4. Stereo3d filter: swap L/R eyes while keeping SBS layout
        #    Use this if stereo depth appears inverted (convergence behind screen)
        test_stereo_clip "04_SBS_eyes_swapped" \
            "$w_res" "$w_fps" "$w_pfmt" "stereo3d=sbsl:sbsr" "left_right"

        # 5. Mono left half - isolate left 50% of frame
        #    Should look like a normal undistorted image if camera is SBS
        test_stereo_clip "05_mono_left_half" \
            "$w_res" "$w_fps" "$w_pfmt" "crop=${hw}:${h}:0:0" ""

        # 6. Mono right half - isolate right 50% of frame
        test_stereo_clip "06_mono_right_half" \
            "$w_res" "$w_fps" "$w_pfmt" "crop=${hw}:${h}:${hw}:0" ""

        # 7. Horizontal flip (fixes mirrored camera output)
        test_stereo_clip "07_hflip" \
            "$w_res" "$w_fps" "$w_pfmt" "hflip" ""

        # --- Portrait resolutions: test top-bottom stereo ---
        if [ "$h" -gt "$w" ]; then
            echo "  [Portrait] Testing top-bottom stereo extraction..."

            test_stereo_clip "08_TB_top_bottom_meta" \
                "$w_res" "$w_fps" "$w_pfmt" "" "top_bottom"

            test_stereo_clip "09_mono_top_half" \
                "$w_res" "$w_fps" "$w_pfmt" "crop=${w}:${hh}:0:0" ""

            test_stereo_clip "10_mono_bottom_half" \
                "$w_res" "$w_fps" "$w_pfmt" "crop=${w}:${hh}:0:${hh}" ""
        fi

        # --- Square resolution: test dual fisheye conversion ---
        if [ "$w" = "$h" ]; then
            echo "  [Square/Fisheye] Testing dual fisheye -> equirectangular conversion..."

            # Dual fisheye to equirectangular (ffmpeg v360 filter)
            # dfisheye = two fisheye images side by side in one frame
            test_stereo_clip "08_dfisheye_to_equirect" \
                "$w_res" "$w_fps" "$w_pfmt" "v360=dfisheye:equirect" ""

            # Same but with SBS stereo metadata for 360 player
            test_stereo_clip "09_dfisheye_equirect_meta" \
                "$w_res" "$w_fps" "$w_pfmt" "v360=dfisheye:equirect" "left_right"

            # Single left fisheye eye only (should show ~180° FOV image)
            test_stereo_clip "10_fisheye_left_eye_only" \
                "$w_res" "$w_fps" "$w_pfmt" "crop=${hw}:${h}:0:0" ""

            # Single right fisheye eye only
            test_stereo_clip "11_fisheye_right_eye_only" \
                "$w_res" "$w_fps" "$w_pfmt" "crop=${hw}:${h}:${hw}:0" ""

            # Convert single left fisheye to rectilinear (flat) view
            test_stereo_clip "12_fisheye_left_rectilinear" \
                "$w_res" "$w_fps" "$w_pfmt" \
                "crop=${hw}:${h}:0:0,v360=fisheye:flat:ih_fov=180:iv_fov=180" ""
        fi

    done < "$WORKING_FILE"

    if [ -z "$processed_resolutions" ]; then
        echo ""
        echo "⚠️  No working resolutions from Phase 1 to run stereo tests on."
        echo "    Check that the correct camera device was selected."
    fi
}

# ============================================
# Phase 3: Low-Latency Streaming Tests
# ============================================

run_latency_tests() {
    print_header "Phase 3: Low-Latency Encoding (Streaming Mode)"

    echo "Tests hardware encoder in realtime mode - relevant for live VR streaming."
    echo ""

    while IFS=: read -r w_res w_fps w_pfmt; do
        local safe_name="latency_VT_${w_res}_${w_fps}fps"
        local log_file="$RESULTS_DIR/${safe_name}.log"

        printf "  %-35s " "$w_res @ ${w_fps}fps"

        local result
        result=$(timeout $((TEST_DURATION + 8)) ffmpeg -y \
            -f avfoundation \
            -framerate "$w_fps" \
            -pixel_format "$w_pfmt" \
            -video_size "$w_res" \
            -i "$CAMERA_DEVICE" \
            -t "$TEST_DURATION" \
            -c:v h264_videotoolbox \
            -realtime true \
            -b:v 15M \
            -f null - 2>&1) || true

        echo "$result" > "$log_file"

        local speed
        speed=$(echo "$result" | grep "speed=" | tail -1 | \
            sed -n 's/.*speed=\([0-9.]*\)x.*/\1/p')

        if echo "$result" | grep -q "frame="; then
            local fps_achieved
            fps_achieved=$(echo "scale=1; ${speed:-0} * $w_fps" | bc 2>/dev/null || echo "?")
            echo "✅  speed=${speed}x  (${fps_achieved} fps encoded)"
            log_result "latency,${safe_name},$CAMERA_DEVICE,$w_res,$w_fps,$w_pfmt,h264_vt_realtime,$speed,OK,"
        else
            echo "❌  Failed"
            log_result "latency,${safe_name},$CAMERA_DEVICE,$w_res,$w_fps,$w_pfmt,h264_vt_realtime,0,FAIL,"
        fi

    done < "$WORKING_FILE"
}

# ============================================
# Summary
# ============================================

print_summary() {
    print_header "TESTING COMPLETE"

    echo ""
    echo "Results saved to: $RESULTS_FILE"
    echo ""

    echo "Working resolutions (from Phase 1):"
    if [ -s "$WORKING_FILE" ]; then
        while IFS=: read -r res fps pfmt; do
            echo "  ✅  $res @ ${fps}fps  [pixel_fmt: $pfmt]"
        done < "$WORKING_FILE"
    else
        echo "  None - check camera device index and connections"
    fi

    echo ""
    echo "Stereo test clips:"
    local clip_count
    clip_count=$(ls -1 "$STEREO_DIR"/*.mp4 2>/dev/null | wc -l | tr -d ' ')
    echo "  $clip_count clips in: $STEREO_DIR/"
    echo ""

    echo "========================================================"
    echo "VR FOV DEBUGGING GUIDE"
    echo "========================================================"
    echo ""
    echo "STEP 1: Check if the right camera was used"
    echo "  Look at Phase 1 clips in: $RESULTS_DIR/"
    echo "  Open any clip - does it show the VR camera view or Mac webcam?"
    echo ""
    echo "STEP 2: Transfer stereo clips to your VR PC"
    echo "  Copy: $STEREO_DIR/"
    echo ""
    echo "STEP 3: Open clips in a VR player (DeoVR, SkyBox VR Player, VLC)"
    echo "  Set mode: Side-by-Side (SBS) for landscape clips"
    echo "  Set mode: Top-Bottom (TB) for portrait clips"
    echo ""
    echo "STEP 4: Compare these clips to diagnose your stereo issue:"
    echo "  05_mono_left_half  / 06_mono_right_half"
    echo "    -> Do these look like normal undistorted images?"
    echo "    -> If YES: camera is SBS, use 02_SBS_left_right_meta"
    echo "    -> If they look like fisheye: camera is dual fisheye"
    echo "       Use 08_dfisheye_to_equirect instead"
    echo ""
    echo "  02_SBS_left_right_meta vs 03_SBS_right_left_meta"
    echo "    -> One will have correct depth, one will look cross-eyed"
    echo "    -> Use whichever feels natural"
    echo ""
    echo "  04_SBS_eyes_swapped"
    echo "    -> Try this if depth appears inverted or objects float behind screen"
    echo ""
    echo "STEP 5: Once best format identified, update the stream sender:"
    echo "  For SBS: add  -metadata:s:v:0 stereo_mode=left_right"
    echo "  For fisheye: add  -vf v360=dfisheye:equirect"
}

# ============================================
# MAIN
# ============================================

echo "========================================================"
echo "   VR CAMERA RESOLUTION & STEREO FORMAT TEST"
echo "   HP Reverb G2 + VR.Cam 02"
echo "========================================================"
echo ""
echo "Output:"
echo "  Resolution clips : $RESULTS_DIR/"
echo "  Stereo clips     : $STEREO_DIR/"
echo "  Results CSV      : $RESULTS_FILE"
echo ""
echo "Test duration per clip: ${TEST_DURATION}s"
echo ""

detect_vr_camera

echo ""
echo "Press Enter to start resolution tests, or Ctrl+C to abort..."
read -r

run_resolution_tests
run_latency_tests
run_stereo_tests
print_summary
