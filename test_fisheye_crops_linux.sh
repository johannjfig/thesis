#!/bin/bash
# test_fisheye_crops_linux.sh
# Linux/Ubuntu version — updated for confirmed stereoscopic resolutions.
#
# Camera outputs MJPEG compressed stereo at 2:1 aspect ratios.
# Per-eye area is SQUARE (e.g. 2200x1100 → 1100x1100 per eye).
#
# Stereoscopic resolutions confirmed on this camera:
#   3840x1920  3600x1800  3408x1704  3200x1600
#   3008x1504  2608x1304  2200x1100
# Anything below 2200x1100 drops to mono (non-stereoscopic).
#
# FOV reference (equidistant fisheye, square per-eye):
#   1px from center = 180 / EYE_W degrees
#   For EYE_W=1100:  1px ≈ 0.164°
#   Crop 1100px = 180° (full fisheye, heavy edge distortion)
#   Crop  900px = 147°
#   Crop  700px = 115°  ← closest to HP Reverb G2 FOV (~114°)
#   Crop  500px =  82°  (comfortable, minimal distortion)
#   Crop  300px =  49°  (narrow, rectilinear-like)

# ============================================================
# CONFIGURATION — edit these
# ============================================================
CAMERA_DEVICE="/dev/video0"   # Confirm with: v4l2-ctl --list-devices

# Use the smallest stereoscopic resolution to keep CPU load low.
# Change to 3840x1920 for maximum quality, or any size from the list above.
RES="2200x1100"

# Camera outputs MJPEG (compressed). Do not change unless detect_pixel_format
# finds something different.
PIXEL_FMT="mjpeg"

FPS=30
TEST_DURATION=5
OUTPUT_DIR="encoding_results/crop_tests"

# Encoder: libx264 (CPU). Change to h264_nvenc if NVIDIA GPU available.
ENCODER="libx264"
ENCODER_OPTS="-preset ultrafast -tune zerolatency"

# ============================================================
# Derived geometry — auto-computed from RES
# ============================================================
recompute_geometry() {
    TOTAL_W=$(echo "$RES" | cut -dx -f1)
    TOTAL_H=$(echo "$RES" | cut -dx -f2)
    EYE_W=$((TOTAL_W / 2))   # Per-eye width  (= height for square per-eye)
    EYE_H=$TOTAL_H            # Per-eye height
    LEFT_CX=$((EYE_W / 2))
    LEFT_CY=$((EYE_H / 2))
    RIGHT_CX=$((EYE_W + EYE_W / 2))
    RIGHT_CY=$LEFT_CY

    # FOV match crop size for HP Reverb G2 (~114°):
    # crop_size = EYE_W * 114 / 180  (rounded to even)
    FOV_MATCH_CROP=$(( (EYE_W * 114 / 180) & ~1 ))
}

recompute_geometry

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
    result=$(timeout $((TEST_DURATION + 15)) ffmpeg -nostdin "${args[@]}" 2>&1) || true
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
# Symmetric SBS crop filter
# Crops the same relative region from both eyes and hstacks.
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
    if [ "$1" -ge 0 ]; then echo "p${1}"; else echo "m$(( -$1 ))"; fi
}

# ============================================================
# Phase 0: Confirm pixel format and resolution work
# ============================================================
detect_pixel_format() {
    print_header "Phase 0: Confirming camera access at $RES"

    echo "Camera outputs MJPEG compressed stereo at stereoscopic resolutions."
    echo "Trying pixel formats: mjpeg, yuyv422, nv12"
    echo ""

    for fmt in mjpeg yuyv422 nv12; do
        printf "  %-12s @ $RES  " "$fmt"
        local result
        result=$(timeout 8 ffmpeg -nostdin -y \
            -f v4l2 -framerate "$FPS" -video_size "$RES" \
            -input_format "$fmt" \
            -i "$CAMERA_DEVICE" \
            -t 1 -f null - 2>&1) || true

        if echo "$result" | grep -q "frame="; then
            echo "✅"
            PIXEL_FMT="$fmt"
            echo ""
            echo "  Using format: $PIXEL_FMT"
            return
        elif echo "$result" | grep -q "Invalid data"; then
            echo "❌  wrong format"
        elif echo "$result" | grep -qiE "not supported|no such"; then
            echo "❌  not supported at this resolution"
        else
            echo "❌  failed"
        fi
    done

    echo ""
    echo "⚠️  No format worked at $RES."
    echo "   Verify the camera is connected and the resolution is correct:"
    echo "   ffmpeg -f v4l2 -list_formats all -i $CAMERA_DEVICE"
    echo "   Then edit RES at the top of this script."
    exit 1
}

# ============================================================
# Phase 0b: Resolution performance check
# Quick test across all stereoscopic resolutions.
# Helps decide which resolution to use for the full crop test.
# ============================================================
test_all_resolutions() {
    print_header "Phase 0b: Stereoscopic Resolution Performance Check"

    echo "Testing all confirmed stereoscopic resolutions."
    echo "The smallest that encodes in realtime is best for crop testing."
    echo ""

    local stereo_resolutions=(
        "2200x1100"
        "2608x1304"
        "3008x1504"
        "3200x1600"
        "3408x1704"
        "3600x1800"
        "3840x1920"
    )

    local res_results_file="$OUTPUT_DIR/resolution_check.csv"
    echo "Resolution,FPS,Speed,Status" > "$res_results_file"

    for res in "${stereo_resolutions[@]}"; do
        printf "  %-14s " "$res"
        local result
        result=$(timeout 12 ffmpeg -nostdin -y \
            -f v4l2 -framerate "$FPS" -video_size "$res" \
            -input_format "$PIXEL_FMT" \
            -i "$CAMERA_DEVICE" \
            -t 3 \
            -c:v $ENCODER $ENCODER_OPTS \
            -f null - 2>&1) || true

        local speed
        speed=$(echo "$result" | grep "speed=" | tail -1 | \
            sed -n 's/.*speed=\([0-9.]*\)x.*/\1/p')

        if echo "$result" | grep -q "frame="; then
            local fps_enc
            fps_enc=$(echo "$result" | grep "fps=" | tail -1 | \
                sed -n 's/.*fps=\s*\([0-9.]*\).*/\1/p')
            echo "✅  speed=${speed}x  (${fps_enc} fps encoded)"
            echo "$res,$fps_enc,$speed,OK" >> "$res_results_file"
        else
            echo "❌  failed"
            echo "$res,0,0,FAIL" >> "$res_results_file"
        fi
    done

    echo ""
    echo "Resolution results: $res_results_file"
    echo "Continuing crop tests with: $RES"
}

# ============================================================
# GROUP A — Baseline
# ============================================================
run_group_A() {
    print_header "Group A: Baseline (no crop, $RES, per-eye ${EYE_W}x${EYE_H})"

    # A1: Raw full frame — reference, no processing
    encode_clip "A1" "full_raw_no_meta" "" ""

    # A2: SBS metadata: left half = left eye
    encode_clip "A2" "full_SBS_left_right_meta" "" "left_right"

    # A3: SBS metadata: left half = right eye (swapped)
    encode_clip "A3" "full_SBS_right_left_meta" "" "right_left"

    # A4/A5: Each eye in isolation — confirm camera is SBS
    # These should look like a normal 180° fisheye photo
    encode_clip "A4" "mono_LEFT_eye_only" \
        "[0:v]crop=${EYE_W}:${EYE_H}:0:0[v]" ""

    encode_clip "A5" "mono_RIGHT_eye_only" \
        "[0:v]crop=${EYE_W}:${EYE_H}:${EYE_W}:0[v]" ""

    # A6: Eyes physically swapped — fixes inverted depth
    encode_clip "A6" "SBS_eyes_SWAPPED" \
        "[0:v]split[l][r];[l]crop=${EYE_W}:${EYE_H}:${EYE_W}:0[le];[r]crop=${EYE_W}:${EYE_H}:0:0[re];[le][re]hstack=inputs=2[v]" \
        "left_right"

    # A7: Horizontal flip
    encode_clip "A7" "full_hflip" "[0:v]hflip[v]" "left_right"
}

# ============================================================
# GROUP B — FOV / Size Sweep
# Per-eye is now square (EYE_W x EYE_W).
# FOV_MATCH_CROP (~700px for 1100px eye) matches headset FOV.
# ============================================================
run_group_B() {
    print_header "Group B: FOV/Size Sweep (center fixed at geometric center)"

    echo "  Per-eye: ${EYE_W}x${EYE_H}px (square)"
    echo "  FOV match for HP Reverb G2 (~114°): ${FOV_MATCH_CROP}px crop"
    echo ""

    # Steps from full eye width down to narrow
    # Compute even-numbered steps across the range
    local step=$(( (EYE_W - 300) / 7 ))
    step=$(( (step + 1) & ~1 ))   # round up to even

    local s=$EYE_W
    while [ $s -ge 300 ]; do
        encode_clip "B" "square_${s}x${s}" \
            "$(sbs_crop $s $s 0 0)" "left_right"
        s=$(( s - step ))
    done
    # Always include the FOV-matched size explicitly
    encode_clip "B" "square_${FOV_MATCH_CROP}x${FOV_MATCH_CROP}_FOV_MATCH" \
        "$(sbs_crop $FOV_MATCH_CROP $FOV_MATCH_CROP 0 0)" "left_right"

    # Also test landscape crops (Unity might expect 16:9 or 4:3)
    local h16_9=$(( EYE_W * 9 / 16 ))
    h16_9=$(( h16_9 & ~1 ))
    encode_clip "B" "landscape_16x9_${EYE_W}x${h16_9}" \
        "$(sbs_crop $EYE_W $h16_9 0 0)" "left_right"

    local h4_3=$(( EYE_W * 3 / 4 ))
    h4_3=$(( h4_3 & ~1 ))
    encode_clip "B" "landscape_4x3_${EYE_W}x${h4_3}" \
        "$(sbs_crop $EYE_W $h4_3 0 0)" "left_right"
}

# ============================================================
# GROUP C — Horizontal Center Sweep
# Crop fixed at FOV_MATCH_CROP. Sweeps x center ±150px.
# ============================================================
run_group_C() {
    local CW=$FOV_MATCH_CROP
    local CH=$FOV_MATCH_CROP
    local max_shift=$(( (EYE_W - CW) / 2 ))

    print_header "Group C: Horizontal Center Sweep (crop ${CW}x${CH}, max shift ±${max_shift}px)"

    # Use up to ±150px or the max shift, whichever is smaller
    local range=150
    [ $max_shift -lt $range ] && range=$max_shift

    for cx_off in $(seq -$range $(( range / 6 )) $range); do
        local tag; tag=$(offset_tag $cx_off)
        encode_clip "C" "cx_${tag}" \
            "$(sbs_crop $CW $CH $cx_off 0)" "left_right"
    done
}

# ============================================================
# GROUP D — Vertical Center Sweep
# Per-eye is square so vertical range is same as horizontal.
# ============================================================
run_group_D() {
    local CW=$FOV_MATCH_CROP
    local CH=$FOV_MATCH_CROP
    local max_shift=$(( (EYE_H - CH) / 2 ))

    print_header "Group D: Vertical Center Sweep (crop ${CW}x${CH}, max shift ±${max_shift}px)"

    local range=200
    [ $max_shift -lt $range ] && range=$max_shift

    for cy_off in $(seq -$range $(( range / 8 )) $range); do
        local tag; tag=$(offset_tag $cy_off)
        encode_clip "D" "cy_${tag}" \
            "$(sbs_crop $CW $CH 0 $cy_off)" "left_right"
    done
}

# ============================================================
# GROUP E — 2D Center Grid
# 5×5 grid using FOV_MATCH_CROP size.
# ============================================================
run_group_E() {
    local CW=$FOV_MATCH_CROP
    local CH=$FOV_MATCH_CROP
    local step=$(( CW / 8 ))
    step=$(( (step + 1) & ~1 ))   # round to even

    print_header "Group E: 2D Center Grid (crop ${CW}x${CH}, step ${step}px)"

    echo "  Grid: cx ∈ {-2s,-s,0,s,2s}  cy ∈ {-2s,-s,0,s,2s}  where s=${step}px"
    echo ""

    for cx_mult in -2 -1 0 1 2; do
        for cy_mult in -2 -1 0 1 2; do
            local cx=$(( cx_mult * step ))
            local cy=$(( cy_mult * step ))
            local xtag ytag
            xtag=$(offset_tag $cx)
            ytag=$(offset_tag $cy)
            encode_clip "E" "cx${xtag}_cy${ytag}" \
                "$(sbs_crop $CW $CH $cx $cy)" "left_right"
        done
    done
}

# ============================================================
# GROUP F — Fine Grid (edit CX_BEST/CY_BEST after reviewing E)
# ============================================================
run_group_F() {
    local CW=$FOV_MATCH_CROP
    local CH=$FOV_MATCH_CROP

    # ← Edit these after reviewing Group E output
    local CX_BEST=0
    local CY_BEST=0

    print_header "Group F: Fine Grid ±30px around (cx=${CX_BEST}, cy=${CY_BEST})"

    for dx in -30 -20 -10 0 10 20 30; do
        for dy in -30 -20 -10 0 10 20 30; do
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
# GROUP G — Fisheye Projection Conversions (v360 filter)
# For a square per-eye fisheye, these convert the fisheye to
# rectilinear (flat) which removes distortion at the cost of FOV.
# ============================================================
run_group_G() {
    print_header "Group G: Fisheye Projection Conversions (v360)"

    echo "  These assume the full frame is a dual fisheye (dfisheye)."
    echo "  Or they re-project each eye from fisheye to flat/equirect."
    echo ""

    # G1: Treat full SBS frame as dual fisheye → equirectangular
    encode_clip "G1" "dfisheye_to_equirect" \
        "[0:v]v360=dfisheye:equirect[v]" ""

    encode_clip "G2" "dfisheye_equirect_SBS_meta" \
        "[0:v]v360=dfisheye:equirect[v]" "left_right"

    # G3/G4: Single eye fisheye → flat projection (mono for inspection)
    encode_clip "G3" "mono_left_fisheye_to_flat_180fov" \
        "[0:v]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=180:iv_fov=180[v]" ""

    encode_clip "G4" "mono_right_fisheye_to_flat_180fov" \
        "[0:v]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=180:iv_fov=180[v]" ""

    # G5: Both eyes fisheye → flat (180°), recombined as SBS
    encode_clip "G5" "SBS_both_flat_180fov" \
        "[0:v]split[l][r];[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=180:iv_fov=180[le];[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=180:iv_fov=180[re];[le][re]hstack=inputs=2[v]" \
        "left_right"

    # G6: Both eyes fisheye → flat (120°) — less FOV, more zoom, less distortion
    encode_clip "G6" "SBS_both_flat_120fov" \
        "[0:v]split[l][r];[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=120:iv_fov=120[le];[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=120:iv_fov=120[re];[le][re]hstack=inputs=2[v]" \
        "left_right"

    # G7: Both eyes fisheye → flat (90°) — very narrow, rectilinear
    encode_clip "G7" "SBS_both_flat_90fov" \
        "[0:v]split[l][r];[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=90:iv_fov=90[le];[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=90:iv_fov=90[re];[le][re]hstack=inputs=2[v]" \
        "left_right"
}

# ============================================================
# GROUP H — Scaled Output Sizes
# ============================================================
run_group_H() {
    print_header "Group H: Fixed Output Resolution (scaled)"

    local CW=$FOV_MATCH_CROP
    local CH=$FOV_MATCH_CROP
    local lx=$(( LEFT_CX  - CW/2 ))
    local rx=$(( RIGHT_CX - CW/2 ))
    local ty=$(( LEFT_CY  - CH/2 ))
    local base="[0:v]split[l][r];[l]crop=${CW}:${CH}:${lx}:${ty}[le];[r]crop=${CW}:${CH}:${rx}:${ty}[re];[le][re]hstack=inputs=2"

    encode_clip "H1" "scale_1920x960_SBS"  "${base},scale=1920:960[v]"  "left_right"
    encode_clip "H2" "scale_1280x640_SBS"  "${base},scale=1280:640[v]"  "left_right"
    encode_clip "H3" "scale_2160x1080_SBS" "${base},scale=2160:1080[v]" "left_right"
    encode_clip "H4" "scale_native_SBS"    "${base},scale=${EYE_W}:$((EYE_H/2))[v]" "left_right"
}

# ============================================================
# MAIN
# ============================================================

echo "============================================================"
echo "   VR FISHEYE CROP TEST — Linux/Ubuntu"
echo "   Camera : $CAMERA_DEVICE"
echo "   Res    : $RES  (per-eye: ${EYE_W}x${EYE_H})"
echo "   FOV match crop: ${FOV_MATCH_CROP}px (~114° for HP Reverb G2)"
echo "============================================================"
echo ""
echo "Stereoscopic resolutions (below 2200x1100 = mono only):"
echo "  3840x1920  3600x1800  3408x1704  3200x1600"
echo "  3008x1504  2608x1304  2200x1100  ← using this"
echo ""
echo "If camera not visible: bash diagnose_camera_linux.sh"
echo ""

# ---- Quick device sanity check before wasting time ----
echo "--- Video devices on this machine ---"
if command -v v4l2-ctl &>/dev/null; then
    v4l2-ctl --list-devices 2>/dev/null || ls /dev/video* 2>/dev/null
else
    ls -1 /dev/video* 2>/dev/null || echo "  No /dev/video* devices found"
fi
echo ""

# Check if anything already has the camera open
if command -v fuser &>/dev/null; then
    busy=$(fuser "$CAMERA_DEVICE" 2>/dev/null)
    if [ -n "$busy" ]; then
        echo "⚠️  WARNING: $CAMERA_DEVICE is currently held by process(es): $busy"
        echo "   Close any browser tabs with camera access, cheese, guvcview, etc."
        echo "   Then press Enter to retry, or Ctrl+C to abort."
        read -r
    else
        echo "✅  $CAMERA_DEVICE is not in use by another process"
    fi
fi

# Quick open test — the real fix for "Immediate exit requested"
echo ""
echo "Testing camera opens correctly (with -nostdin)..."
_test=$(ffmpeg -nostdin -y -f v4l2 -i "$CAMERA_DEVICE" -t 0.5 -f null - 2>&1) || true
if echo "$_test" | grep -qiE "immediate exit|error opening|no such file|permission"; then
    echo "❌  Camera open test failed:"
    echo "$_test" | grep -iE "immediate|error|permission|no such" | head -3
    echo ""
    echo "Possible fixes:"
    echo "  1. Wrong device — check list above, edit CAMERA_DEVICE at top of script"
    echo "  2. Device busy — close other apps using the camera"
    echo "  3. Permission — run: sudo usermod -aG video \$(whoami) && newgrp video"
    echo ""
    echo "Press Enter to try anyway, or Ctrl+C to abort."
fi
echo ""
echo "Press Enter to start (A–E), or Ctrl+C to abort..."
read -r

detect_pixel_format
test_all_resolutions
run_group_A
run_group_B
run_group_C
run_group_D
run_group_E

echo ""
echo "================================================================"
echo "  Groups A–E done ($OK_COUNT OK, $FAIL_COUNT failed so far)."
echo ""
echo "  Before continuing:"
echo "  1. Review E_cx*_cy*.mp4 clips to find best center offset"
echo "  2. Edit CX_BEST and CY_BEST in run_group_F() in this script"
echo "  3. Press Enter to run fine-grid (F) + projections (G) + scaled (H)"
echo "================================================================"
read -r

run_group_F
run_group_G
run_group_H

echo ""
echo "================================================================"
echo "  DONE:  $OK_COUNT OK   $FAIL_COUNT failed   Total: $CLIP_COUNT"
echo "  Results CSV : $RESULTS_FILE"
echo "  Output clips: $OUTPUT_DIR/"
echo "================================================================"
