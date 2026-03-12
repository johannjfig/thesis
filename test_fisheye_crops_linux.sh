#!/bin/bash
# test_fisheye_crops_linux.sh
# Linux/Ubuntu version of test_fisheye_crops.sh
# Uses V4L2 instead of AVFoundation, libx264 instead of VideoToolbox.
#
# Before running, confirm your camera device with:
#   v4l2-ctl --list-devices
#   ffmpeg -f v4l2 -list_formats all -i /dev/video0

# ============================================================
# CONFIGURATION — edit these
# ============================================================
CAMERA_DEVICE="/dev/video0"   # Change to your VR camera device
RES="1552x1552"
PIXEL_FMT="yuyv422"           # V4L2 common formats: yuyv422, mjpeg, nv12
FPS=30
TEST_DURATION=5
OUTPUT_DIR="encoding_results/crop_tests"

# Encoder: use libx264 (software). If you have NVIDIA GPU:
#   change to: ENCODER="h264_nvenc" with ENCODER_OPTS="-preset llhp"
ENCODER="libx264"
ENCODER_OPTS="-preset ultrafast -tune zerolatency"

# ============================================================
# Derived geometry (same as Mac version)
# ============================================================
TOTAL_W=$(echo "$RES" | cut -dx -f1)
TOTAL_H=$(echo "$RES" | cut -dx -f2)
EYE_W=$((TOTAL_W / 2))
EYE_H=$TOTAL_H
LEFT_CX=$((EYE_W / 2))
LEFT_CY=$((EYE_H / 2))
RIGHT_CX=$((EYE_W + EYE_W / 2))
RIGHT_CY=$LEFT_CY

# ============================================================
# Setup
# ============================================================
mkdir -p "$OUTPUT_DIR"
RESULTS_FILE="$OUTPUT_DIR/crop_results.csv"
CLIP_COUNT=0; OK_COUNT=0; FAIL_COUNT=0

echo "Group,Clip,Status" > "$RESULTS_FILE"

print_header() {
    echo ""
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
}

log_result() { echo "$1" >> "$RESULTS_FILE"; }

# ============================================================
# Core encode function
# ============================================================
encode_clip() {
    local group="$1"
    local clip_name="$2"
    local fc_filter="$3"
    local stereo_meta="$4"

    CLIP_COUNT=$(( CLIP_COUNT + 1 ))

    local out_file="$OUTPUT_DIR/${group}_${clip_name}.mp4"
    local log_file="$OUTPUT_DIR/${group}_${clip_name}.log"

    printf "  [%s] %-50s " "$group" "$clip_name"

    local args=(-y
        -f v4l2
        -framerate "$FPS"
        -video_size "$RES"
        -input_format "$PIXEL_FMT"
        -i "$CAMERA_DEVICE"
        -t "$TEST_DURATION"
    )

    if [ -n "$fc_filter" ]; then
        args+=(-filter_complex "$fc_filter" -map "[v]")
    fi

    args+=(-c:v $ENCODER $ENCODER_OPTS)

    if [ -n "$stereo_meta" ]; then
        args+=(-metadata:s:v:0 "stereo_mode=$stereo_meta")
    fi

    args+=("$out_file")

    local result
    result=$(timeout $((TEST_DURATION + 15)) ffmpeg "${args[@]}" 2>&1) || true
    echo "$result" > "$log_file"

    if echo "$result" | grep -q "frame="; then
        echo "✅"
        OK_COUNT=$(( OK_COUNT + 1 ))
        log_result "$group,${group}_${clip_name},OK"
    else
        local err
        err=$(echo "$result" | grep -iE "error|invalid|no such|not supported|cannot" \
            | head -1 | sed 's/\[.*\] //' | cut -c1-70)
        echo "❌  $err"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        log_result "$group,${group}_${clip_name},FAIL"
    fi
}

# ============================================================
# Symmetric SBS crop filter (identical logic to Mac version)
# ============================================================
sbs_crop() {
    local cw="$1" ch="$2" cx_off="${3:-0}" cy_off="${4:-0}"

    local lx=$(( LEFT_CX  - cw/2 + cx_off ))
    local rx=$(( RIGHT_CX - cw/2 + cx_off ))
    local ty=$(( LEFT_CY  - ch/2 + cy_off ))

    [ $lx -lt 0 ]                   && lx=0
    [ $ty -lt 0 ]                   && ty=0
    [ $(( lx + cw )) -gt $EYE_W ]  && lx=$(( EYE_W  - cw ))
    [ $(( rx + cw )) -gt $TOTAL_W ] && rx=$(( TOTAL_W - cw ))
    [ $(( ty + ch )) -gt $EYE_H ]  && ty=$(( EYE_H  - ch ))
    [ $rx -lt $EYE_W ]              && rx=$EYE_W

    echo "[0:v]split[l][r];[l]crop=${cw}:${ch}:${lx}:${ty}[le];[r]crop=${cw}:${ch}:${rx}:${ty}[re];[le][re]hstack=inputs=2[v]"
}

offset_tag() {
    local n="$1"
    if [ "$n" -ge 0 ]; then echo "p${n}"; else echo "m$(( -n ))"; fi
}

# ============================================================
# Phase 0: Detect pixel format automatically
# V4L2 devices often need a specific -input_format
# ============================================================
detect_pixel_format() {
    print_header "Phase 0: Auto-detecting pixel format for $CAMERA_DEVICE"

    echo "Trying formats in order: yuyv422, mjpeg, nv12, yuv420p"
    echo ""

    for fmt in yuyv422 mjpeg nv12 yuv420p; do
        printf "  %-12s " "$fmt"
        local result
        result=$(timeout 6 ffmpeg -y \
            -f v4l2 -framerate "$FPS" -video_size "$RES" \
            -input_format "$fmt" \
            -i "$CAMERA_DEVICE" \
            -t 1 -f null - 2>&1) || true

        if echo "$result" | grep -q "frame="; then
            echo "✅  works"
            PIXEL_FMT="$fmt"
            return
        elif echo "$result" | grep -qiE "not supported|invalid|no such"; then
            echo "❌  not supported"
        else
            echo "❌  failed"
        fi
    done

    echo ""
    echo "⚠️  Could not auto-detect pixel format."
    echo "   Check supported formats with:"
    echo "   ffmpeg -f v4l2 -list_formats all -i $CAMERA_DEVICE"
    echo ""
    echo "Using default: $PIXEL_FMT  (may fail — edit PIXEL_FMT at top of script)"
}

# ============================================================
# GROUP A — Baseline
# ============================================================
run_group_A() {
    print_header "Group A: Baseline (no crop)"

    encode_clip "A1" "full_raw_no_meta" "" ""
    encode_clip "A2" "full_SBS_left_right_meta" "" "left_right"
    encode_clip "A3" "full_SBS_right_left_meta" "" "right_left"

    encode_clip "A4" "mono_LEFT_eye_only" \
        "[0:v]crop=${EYE_W}:${EYE_H}:0:0[v]" ""

    encode_clip "A5" "mono_RIGHT_eye_only" \
        "[0:v]crop=${EYE_W}:${EYE_H}:${EYE_W}:0[v]" ""

    encode_clip "A6" "SBS_eyes_SWAPPED" \
        "[0:v]split[l][r];[l]crop=${EYE_W}:${EYE_H}:${EYE_W}:0[le];[r]crop=${EYE_W}:${EYE_H}:0:0[re];[le][re]hstack=inputs=2[v]" \
        "left_right"

    encode_clip "A7" "full_hflip" \
        "[0:v]hflip[v]" "left_right"
}

# ============================================================
# GROUP B — FOV/Size Sweep
# ============================================================
run_group_B() {
    print_header "Group B: FOV/Size Sweep (center fixed)"

    for size in 776 700 640 540 500 440 400 300; do
        encode_clip "B" "square_${size}x${size}" \
            "$(sbs_crop $size $size 0 0)" "left_right"
    done

    local h16_9=$(( EYE_W * 9 / 16 ))
    encode_clip "B" "landscape_16x9_${EYE_W}x${h16_9}" \
        "$(sbs_crop $EYE_W $h16_9 0 0)" "left_right"

    local h4_3=$(( EYE_W * 3 / 4 ))
    encode_clip "B" "landscape_4x3_${EYE_W}x${h4_3}" \
        "$(sbs_crop $EYE_W $h4_3 0 0)" "left_right"
}

# ============================================================
# GROUP C — Horizontal Center Sweep
# ============================================================
run_group_C() {
    local CW=540 CH=540
    print_header "Group C: Horizontal Center Sweep (crop ${CW}x${CH})"

    for cx_off in -100 -75 -50 -25 0 25 50 75 100; do
        local tag; tag=$(offset_tag $cx_off)
        encode_clip "C" "cx_${tag}_crop${CW}x${CH}" \
            "$(sbs_crop $CW $CH $cx_off 0)" "left_right"
    done
}

# ============================================================
# GROUP D — Vertical Center Sweep
# ============================================================
run_group_D() {
    local CW=540 CH=540
    print_header "Group D: Vertical Center Sweep (crop ${CW}x${CH})"

    for cy_off in -300 -225 -150 -100 -75 -50 -25 0 25 50 75 100 150 225 300; do
        local tag; tag=$(offset_tag $cy_off)
        encode_clip "D" "cy_${tag}_crop${CW}x${CH}" \
            "$(sbs_crop $CW $CH 0 $cy_off)" "left_right"
    done
}

# ============================================================
# GROUP E — 2D Center Grid
# ============================================================
run_group_E() {
    local CW=500 CH=500
    print_header "Group E: 2D Center Grid (crop ${CW}x${CH})"

    for cx_off in -75 -25 0 25 75; do
        for cy_off in -150 -75 0 75 150; do
            local xtag ytag
            xtag=$(offset_tag $cx_off)
            ytag=$(offset_tag $cy_off)
            encode_clip "E" "cx${xtag}_cy${ytag}" \
                "$(sbs_crop $CW $CH $cx_off $cy_off)" "left_right"
        done
    done
}

# ============================================================
# GROUP F — Fine Grid (edit CX_BEST/CY_BEST after reviewing E)
# ============================================================
run_group_F() {
    local CW=500 CH=500
    local CX_BEST=0   # <- edit after reviewing Group E
    local CY_BEST=0   # <- edit after reviewing Group E

    print_header "Group F: Fine Grid around (cx=${CX_BEST}, cy=${CY_BEST})"

    for dx in -25 -15 -5 0 5 15 25; do
        for dy in -25 -15 -5 0 5 15 25; do
            local cx=$(( CX_BEST + dx ))
            local cy=$(( CY_BEST + dy ))
            local xtag ytag
            xtag=$(offset_tag $cx)
            ytag=$(offset_tag $cy)
            encode_clip "F" "cx${xtag}_cy${ytag}" \
                "$(sbs_crop $CW $CH $cx $cy)" "left_right"
        done
    done
}

# ============================================================
# GROUP G — Fisheye Projection Conversions
# ============================================================
run_group_G() {
    print_header "Group G: Fisheye Projection Conversions (v360)"

    encode_clip "G1" "dfisheye_to_equirect" \
        "[0:v]v360=dfisheye:equirect[v]" ""

    encode_clip "G2" "dfisheye_to_equirect_SBS_meta" \
        "[0:v]v360=dfisheye:equirect[v]" "left_right"

    encode_clip "G3" "mono_left_fisheye_to_flat" \
        "[0:v]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=180:iv_fov=180[v]" ""

    encode_clip "G4" "mono_right_fisheye_to_flat" \
        "[0:v]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=180:iv_fov=180[v]" ""

    encode_clip "G5" "SBS_both_eyes_flat_rectilinear" \
        "[0:v]split[l][r];[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=180:iv_fov=180[le];[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=180:iv_fov=180[re];[le][re]hstack=inputs=2[v]" \
        "left_right"

    encode_clip "G7" "SBS_both_eyes_flat_120fov" \
        "[0:v]split[l][r];[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=120:iv_fov=120[le];[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=120:iv_fov=120[re];[le][re]hstack=inputs=2[v]" \
        "left_right"
}

# ============================================================
# GROUP H — Scaled Output Sizes
# ============================================================
run_group_H() {
    print_header "Group H: Fixed Output Resolution (scaled)"

    local CW=500 CH=500
    local lx=$(( LEFT_CX  - CW/2 ))
    local rx=$(( RIGHT_CX - CW/2 ))
    local ty=$(( LEFT_CY  - CH/2 ))
    local base="[0:v]split[l][r];[l]crop=${CW}:${CH}:${lx}:${ty}[le];[r]crop=${CW}:${CH}:${rx}:${ty}[re];[le][re]hstack=inputs=2"

    encode_clip "H1" "scale_1920x960_SBS"  "${base},scale=1920:960[v]"  "left_right"
    encode_clip "H2" "scale_1280x640_SBS"  "${base},scale=1280:640[v]"  "left_right"
    encode_clip "H3" "scale_2160x1080_SBS" "${base},scale=2160:1080[v]" "left_right"
    encode_clip "H4" "scale_1000x500_SBS"  "${base},scale=1000:500[v]"  "left_right"
}

# ============================================================
# MAIN
# ============================================================

echo "============================================================"
echo "   VR FISHEYE CROP TEST — Linux/Ubuntu"
echo "   Camera: $CAMERA_DEVICE @ $RES ${FPS}fps"
echo "============================================================"
echo ""
echo "Per-eye: ${EYE_W}x${EYE_H}px"
echo "Eye centers: Left=(${LEFT_CX},${LEFT_CY})  Right=(${RIGHT_CX},${RIGHT_CY})"
echo "Output: $OUTPUT_DIR/"
echo ""
echo "If camera not found, run first:  bash diagnose_camera_linux.sh"
echo ""
echo "Press Enter to start, or Ctrl+C to abort..."
read -r

detect_pixel_format
run_group_A
run_group_B
run_group_C
run_group_D
run_group_E

echo ""
echo "================================================================"
echo "  Groups A–E done. Review clips, then edit CX_BEST and CY_BEST"
echo "  in run_group_F() above, then press Enter for fine-grid + G + H."
echo "================================================================"
read -r

run_group_F
run_group_G
run_group_H

echo ""
echo "================================================================"
echo "  DONE:  $OK_COUNT OK   $FAIL_COUNT failed   Total: $CLIP_COUNT"
echo "  Results: $RESULTS_FILE"
echo "================================================================"
