#!/bin/bash
# test_fov_projection.sh
#
# Targeted test for fixing stereo depth perception in VR.
#
# ROOT CAUSE:
#   A fisheye lens maps angles LINEARLY to pixels (equidistant projection).
#   A perspective/rectilinear projection maps angles via TAN (perspective divide).
#   When a fisheye image is shown fullscreen in VR without reprojection:
#     - The angular mapping is wrong
#     - Left/right disparity no longer corresponds to correct depth cues
#     - The brain cannot correctly fuse the stereo pair → no depth perceived
#
# THE FIX:
#   Convert fisheye → rectilinear (flat) using ffmpeg v360 BEFORE sending.
#   The output FOV must match the headset's actual display FOV.
#   HP Reverb G2: ~114° horizontal, ~98° vertical per eye.
#   (Exact values vary per user IPD/fit — test a range)
#
# HOW TO USE:
#   1. Run this script — it records test clips with different projection settings
#   2. Play each clip fullscreen on the HP Reverb G2 in SBS mode
#   3. The correct clip will show objects with proper 3D depth (not flat)
#   4. Note the FOV values from the filename and use them in the live stream

# ============================================================
# CONFIGURATION
# ============================================================
CAMERA_DEVICE="/dev/video0"   # Edit to your VR camera device
RES="2200x1100"
PIXEL_FMT="mjpeg"
FPS=30
TEST_DURATION=8               # Longer clips — easier to judge depth quality
OUTPUT_DIR="encoding_results/fov_projection_tests"

ENCODER="libx264"
ENCODER_OPTS="-preset fast -crf 18"   # Better quality than ultrafast for review

# HP Reverb G2 specs (per eye):
#   Horizontal FOV: ~114°  (range seen in literature: 100°–120°)
#   Vertical FOV:   ~98°   (range: 90°–106°)
#   Aspect ratio per eye: ~1920x2160 native panel, display ~16:9 or 3:2 effective
#
# We test a range because the effective FOV depends on IPD adjustment and
# lens distance, which varies per user.
H_FOVS=(80 90 100 110 114 120 130 140)   # horizontal output FOV to test
V_FOV_RATIO="9/16"                         # v_fov = h_fov * this ratio (approx)

# ============================================================
# Geometry
# ============================================================
TOTAL_W=$(echo "$RES" | cut -dx -f1)   # 2200
TOTAL_H=$(echo "$RES" | cut -dx -f2)   # 1100
EYE_W=$((TOTAL_W / 2))                 # 1100
EYE_H=$TOTAL_H                         # 1100

mkdir -p "$OUTPUT_DIR"
RESULTS_FILE="$OUTPUT_DIR/projection_results.csv"
echo "Group,Clip,hFOV,vFOV,cx,cy,Status" > "$RESULTS_FILE"

CLIP_COUNT=0; OK_COUNT=0; FAIL_COUNT=0

print_header() {
    echo ""
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
}

encode_clip() {
    local group="$1"
    local clip_name="$2"
    local fc_filter="$3"
    local stereo_meta="${4:-left_right}"

    CLIP_COUNT=$(( CLIP_COUNT + 1 ))

    local out_file="$OUTPUT_DIR/${group}_${clip_name}.mp4"
    local log_file="$OUTPUT_DIR/${group}_${clip_name}.log"

    printf "  %-55s " "$clip_name"

    local result
    result=$(timeout $((TEST_DURATION + 15)) ffmpeg -nostdin -y \
        -f v4l2 -framerate "$FPS" -video_size "$RES" \
        -input_format "$PIXEL_FMT" \
        -i "$CAMERA_DEVICE" \
        -t "$TEST_DURATION" \
        -filter_complex "$fc_filter" -map "[v]" \
        -c:v $ENCODER $ENCODER_OPTS \
        -metadata:s:v:0 "stereo_mode=$stereo_meta" \
        "$out_file" 2>&1) || true

    echo "$result" > "$log_file"

    if echo "$result" | grep -q "frame="; then
        echo "✅"
        OK_COUNT=$(( OK_COUNT + 1 ))
    else
        local err
        err=$(echo "$result" | grep -iE "error|invalid|no such|not supported" \
            | head -1 | sed 's/\[.*\] //' | cut -c1-60)
        echo "❌  $err"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi
}

# Build a per-eye fisheye→flat filter with explicit FOV and center offset
# Args: h_fov  v_fov  cx_offset  cy_offset
# cx/cy offset: pixels from geometric center of each eye's area
fisheye_to_flat_sbs() {
    local h_fov="$1"
    local v_fov="$2"
    local cx_off="${3:-0}"
    local cy_off="${4:-0}"

    local left_cx=$(( EYE_W/2 + cx_off ))
    local right_cx=$(( EYE_W + EYE_W/2 + cx_off ))
    local cy=$(( EYE_H/2 + cy_off ))

    # Crop each eye (with center offset), then convert fisheye→flat at target FOV
    # v360 pitch/yaw can shift the view direction within the fisheye
    # We crop first to isolate each eye, then reproject
    local pitch_deg=0
    local yaw_deg=0

    # Convert pixel offset to approximate degrees offset for v360 yaw/pitch
    # For equidistant fisheye: 1px ≈ 180/EYE_W degrees from center
    # So cx_off pixels ≈ cx_off * 180/EYE_W degrees of yaw
    if [ "$cx_off" -ne 0 ]; then
        yaw_deg=$(echo "scale=1; $cx_off * 180 / $EYE_W" | bc 2>/dev/null || echo "0")
    fi
    if [ "$cy_off" -ne 0 ]; then
        pitch_deg=$(echo "scale=1; -1 * $cy_off * 180 / $EYE_H" | bc 2>/dev/null || echo "0")
    fi

    echo "[0:v]split[l][r];\
[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=180:iv_fov=180:h_fov=${h_fov}:v_fov=${v_fov}:yaw=${yaw_deg}:pitch=${pitch_deg}[le];\
[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=180:iv_fov=180:h_fov=${h_fov}:v_fov=${v_fov}:yaw=${yaw_deg}:pitch=${pitch_deg}[re];\
[le][re]hstack=inputs=2[v]"
}

# ============================================================
# GROUP R — Reference (no reprojection, just crop)
# Compare these against the reprojected clips.
# If these look flat/wrong and the P clips look 3D → reprojection is the fix.
# ============================================================
run_group_R() {
    print_header "Group R: Reference crops (NO reprojection)"

    echo "  These are simple crops with NO fisheye correction."
    echo "  Expected: objects visible but stereo depth feels wrong/flat."
    echo ""

    # R1: Full frame, no crop, no reprojection
    encode_clip "R1" "full_frame_no_reproj" \
        "[0:v]copy[v]"

    # R2: Center crop ~matching headset FOV (equidistant approximation)
    local fov_crop=$(( EYE_W * 114 / 180 ))
    fov_crop=$(( (fov_crop + 1) & ~1 ))
    local lx=$(( EYE_W/2 - fov_crop/2 ))
    local rx=$(( EYE_W + EYE_W/2 - fov_crop/2 ))
    local ty=$(( EYE_H/2 - fov_crop/2 ))

    encode_clip "R2" "crop_${fov_crop}px_no_reproj" \
        "[0:v]split[l][r];\
[l]crop=${fov_crop}:${fov_crop}:${lx}:${ty}[le];\
[r]crop=${fov_crop}:${fov_crop}:${rx}:${ty}[re];\
[le][re]hstack=inputs=2[v]"
}

# ============================================================
# GROUP P — Fisheye → Perspective reprojection, FOV sweep
#
# Each clip is the correct stereo pair reprojected to rectilinear.
# The h_fov value that matches the headset's actual display FOV
# will produce correct stereo depth.
#
# HOW TO IDENTIFY THE CORRECT CLIP:
#   - Hold a known object (e.g. your hand) at arm's length
#   - It should appear to be at arm's length in VR
#   - Objects should pop out correctly when you move your head
#   - The clip that achieves this has the correct h_fov
# ============================================================
run_group_P() {
    print_header "Group P: Fisheye → Rectilinear reprojection, FOV sweep"

    echo "  These convert fisheye to perspective projection."
    echo "  One of these will produce correct stereo depth on the G2."
    echo "  The correct h_fov matches the headset's actual display FOV."
    echo ""
    echo "  HP Reverb G2 spec: ~114° horizontal FOV per eye"
    echo "  Testing range: ${H_FOVS[*]}"
    echo ""

    for h_fov in "${H_FOVS[@]}"; do
        # Compute v_fov proportional to h_fov (approximate G2 aspect ratio)
        # G2 is roughly 16:9 effective per eye display
        local v_fov=$(( h_fov * 9 / 16 ))
        v_fov=$(( v_fov & ~1 ))

        local filter
        filter=$(fisheye_to_flat_sbs "$h_fov" "$v_fov" 0 0)
        encode_clip "P" "flat_hfov${h_fov}_vfov${v_fov}_center" "$filter"
        echo "     -> hFOV=${h_fov}° vFOV=${v_fov}°  (center)" >> "$RESULTS_FILE"
    done
}

# ============================================================
# GROUP Q — Best FOV with center sweep
#
# Once you identify the best h_fov from Group P, this tests
# different optical center offsets at that FOV.
# The v360 yaw/pitch parameters shift the view direction.
#
# Edit H_FOV_BEST after reviewing Group P.
# ============================================================
run_group_Q() {
    local H_FOV_BEST=114    # <- edit after reviewing Group P
    local V_FOV_BEST=$(( H_FOV_BEST * 9 / 16 ))

    print_header "Group Q: Center sweep at best FOV (hFOV=${H_FOV_BEST}°)"

    echo "  Sweeps optical center using v360 yaw/pitch."
    echo "  Use if objects are correctly 3D but the center feels off."
    echo ""

    # Horizontal center sweep (yaw)
    for yaw in -20 -15 -10 -5 0 5 10 15 20; do
        local tag
        if [ $yaw -ge 0 ]; then tag="yaw_p${yaw}"; else tag="yaw_m$((-yaw))"; fi

        local filter="[0:v]split[l][r];\
[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=180:iv_fov=180:h_fov=${H_FOV_BEST}:v_fov=${V_FOV_BEST}:yaw=${yaw}[le];\
[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=180:iv_fov=180:h_fov=${H_FOV_BEST}:v_fov=${V_FOV_BEST}:yaw=${yaw}[re];\
[le][re]hstack=inputs=2[v]"
        encode_clip "Q" "hfov${H_FOV_BEST}_${tag}" "$filter"
    done

    echo ""
    # Vertical center sweep (pitch)
    for pitch in -20 -15 -10 -5 0 5 10 15 20; do
        local tag
        if [ $pitch -ge 0 ]; then tag="pitch_p${pitch}"; else tag="pitch_m$((-pitch))"; fi

        local filter="[0:v]split[l][r];\
[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=180:iv_fov=180:h_fov=${H_FOV_BEST}:v_fov=${V_FOV_BEST}:pitch=${pitch}[le];\
[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=180:iv_fov=180:h_fov=${H_FOV_BEST}:v_fov=${V_FOV_BEST}:pitch=${pitch}[re];\
[le][re]hstack=inputs=2[v]"
        encode_clip "Q" "hfov${H_FOV_BEST}_${tag}" "$filter"
    done
}

# ============================================================
# GROUP S — Sphere output (equirectangular for Unity sky sphere)
#
# Alternative to the fullscreen pass approach.
# If Unity uses a hemisphere mesh with equirectangular UV mapping,
# this format will display correctly with proper depth.
# ============================================================
run_group_S() {
    print_header "Group S: Equirectangular output (for Unity hemisphere mesh)"

    echo "  Converts fisheye → equirectangular per eye."
    echo "  Use in Unity with a hemisphere mesh (not fullscreen pass)."
    echo "  Each half of the output maps to one eye's hemisphere."
    echo ""

    # S1: Both eyes fisheye→equirect, SBS
    encode_clip "S1" "equirect_SBS" \
        "[0:v]split[l][r];\
[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:equirect:ih_fov=180:iv_fov=180[le];\
[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:equirect:ih_fov=180:iv_fov=180[re];\
[le][re]hstack=inputs=2[v]"

    # S2: Full frame treated as dual fisheye → single equirectangular
    # (alternative interpretation of the SBS format)
    encode_clip "S2" "dfisheye_equirect" \
        "[0:v]v360=dfisheye:equirect[v]"

    # S3: Equirect scaled to standard 2:1 (3840x1920) for VR players
    encode_clip "S3" "equirect_SBS_scaled_2160x1080" \
        "[0:v]split[l][r];\
[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:equirect:ih_fov=180:iv_fov=180[le];\
[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:equirect:ih_fov=180:iv_fov=180[re];\
[le][re]hstack=inputs=2,scale=2160:1080[v]"
}

# ============================================================
# MAIN
# ============================================================

echo "============================================================"
echo "   VR STEREO DEPTH — FOV PROJECTION TEST"
echo "   Camera: $CAMERA_DEVICE @ $RES"
echo "   Per-eye: ${EYE_W}x${EYE_H}px"
echo "============================================================"
echo ""
echo "ROOT CAUSE:"
echo "  Fisheye images shown in a perspective VR display without"
echo "  reprojection cause broken stereo depth because the angular"
echo "  mapping is wrong. The brain can't fuse the pair correctly."
echo ""
echo "WHAT TO LOOK FOR WHEN REVIEWING:"
echo "  Hold your hand at arm's length in front of the camera."
echo "  In the correct clip, your hand should appear to float at"
echo "  arm's length with clear 3D depth. Background should recede."
echo ""
echo "Groups:"
echo "  R (2 clips) : Reference — no reprojection (shows the broken state)"
echo "  P (${#H_FOVS[@]} clips) : FOV sweep — fisheye→rectilinear at different FOVs"
echo "  Q (18 clips): Center sweep at best FOV (edit H_FOV_BEST in script)"
echo "  S (3 clips) : Equirectangular output for Unity hemisphere mesh"
echo ""
echo "Output: $OUTPUT_DIR/"
echo ""
echo "Press Enter to run R and P groups, Ctrl+C to abort..."
read -r

run_group_R
run_group_P

echo ""
echo "================================================================"
echo "  R + P done ($OK_COUNT OK, $FAIL_COUNT failed)."
echo ""
echo "  Review the P clips on the HP Reverb G2 in SBS mode."
echo "  Find the h_fov value that gives correct stereo depth."
echo "  Then:"
echo "    1. Edit H_FOV_BEST in run_group_Q() in this script"
echo "    2. Press Enter to run center sweep (Q) + hemisphere tests (S)"
echo "================================================================"
read -r

run_group_Q
run_group_S

echo ""
echo "================================================================"
echo "  DONE:  $OK_COUNT OK  $FAIL_COUNT failed  Total: $CLIP_COUNT"
echo "  Output: $OUTPUT_DIR/"
echo ""
echo "LIVE STREAM COMMAND (once correct FOV found):"
echo "  Replace H_FOV and V_FOV with values from best P clip:"
echo ""
echo "  ffmpeg -nostdin -f v4l2 -input_format mjpeg \\"
echo "    -video_size $RES -framerate $FPS -i $CAMERA_DEVICE \\"
echo "    -filter_complex \\"
echo "      \"[0:v]split[l][r];\\"
echo "      [l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=180:iv_fov=180:h_fov=H_FOV:v_fov=V_FOV[le];\\"
echo "      [r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=180:iv_fov=180:h_fov=H_FOV:v_fov=V_FOV[re];\\"
echo "      [le][re]hstack=inputs=2[v]\" -map \"[v]\" \\"
echo "    -c:v libx264 -preset ultrafast -tune zerolatency \\"
echo "    -metadata:s:v:0 stereo_mode=left_right \\"
echo "    -f mpegts udp://UNITY_PC_IP:5000"
echo "================================================================"
