#!/bin/bash
# fisheye_crop_tests.sh
#
# Tests different crop regions from a 180° dual-camera SBS stereo feed.
# Both eyes are always cropped symmetrically (same relative window per eye).
#
# WHY THIS HELPS:
#   The camera outputs two fisheye images side-by-side (SBS). Each half is
#   one camera's 180° fisheye view. Unity displays this on a projection mesh,
#   and if the crop window doesn't match Unity's assumed center/FOV, stereo
#   depth breaks (objects appear at wrong positions per eye).
#
#   By sweeping crop centers and sizes, one test will produce clips that look
#   correctly centered and depth-correct on the HP Reverb G2.
#
# FOV REFERENCE (equidistant fisheye, 776px half-width = 90° from center):
#   776px crop = 180° total FOV  (full fisheye, heavy distortion at edges)
#   640px crop = 148° total FOV
#   540px crop = 125° total FOV
#   500px crop = ~116° total FOV  <- close to HP Reverb G2 FOV (114°)
#   400px crop =  93° total FOV
#   300px crop =  70° total FOV  (narrow, rectilinear-like)
#
# ============================================================
# CONFIGURATION — edit these if needed
# ============================================================
RES="1552x1552"         # Camera resolution to capture
PIXEL_FMT="uyvy422"     # Pixel format; try: uyvy422, yuyv422, nv12
CAMERA_DEVICE="1"       # Device index (0 = Mac built-in, 1 = VR cam usually)
FPS=30
TEST_DURATION=5         # Seconds per clip (keep short; you'll have many)
OUTPUT_DIR="encoding_results/crop_tests"

# ============================================================
# Derived geometry (auto-computed from RES)
# ============================================================
TOTAL_W=$(echo "$RES" | cut -dx -f1)    # 1552
TOTAL_H=$(echo "$RES" | cut -dx -f2)    # 1552
EYE_W=$((TOTAL_W / 2))                  # 776  — width of each eye's area
EYE_H=$TOTAL_H                          # 1552 — height of each eye's area

# Geometric center of each eye in the FULL frame coordinate space
LEFT_CX=$((EYE_W / 2))                  # 388
LEFT_CY=$((EYE_H / 2))                  # 776
RIGHT_CX=$((EYE_W + EYE_W / 2))        # 1164
RIGHT_CY=$LEFT_CY                       # 776

# ============================================================
# Setup
# ============================================================
mkdir -p "$OUTPUT_DIR"
RESULTS_FILE="$OUTPUT_DIR/crop_results.csv"
CLIP_COUNT=0
OK_COUNT=0
FAIL_COUNT=0

echo "Group,Clip,CropW,CropH,CxOffset,CyOffset,Status" > "$RESULTS_FILE"

print_header() {
    echo ""
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
}

log_result() {
    echo "$1" >> "$RESULTS_FILE"
}

# ============================================================
# Core: encode one test clip
#
# Args:
#   $1 = group label     (e.g. "B")
#   $2 = clip name       (e.g. "square_600x600_center")
#   $3 = filter_complex  (full string ending in [v], or "" for passthrough)
#   $4 = stereo_meta     ("left_right", "right_left", "top_bottom", or "")
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

    # Build ffmpeg argument list
    local args=(-y
        -f avfoundation
        -framerate "$FPS"
        -pixel_format "$PIXEL_FMT"
        -video_size "$RES"
        -i "$CAMERA_DEVICE"
        -t "$TEST_DURATION"
    )

    if [ -n "$fc_filter" ]; then
        args+=(-filter_complex "$fc_filter" -map "[v]")
    fi

    args+=(-c:v h264_videotoolbox -b:v 12M)

    if [ -n "$stereo_meta" ]; then
        args+=(-metadata:s:v:0 "stereo_mode=$stereo_meta")
    fi

    args+=("$out_file")

    local result
    result=$(timeout $((TEST_DURATION + 10)) ffmpeg "${args[@]}" 2>&1) || true
    echo "$result" > "$log_file"

    if echo "$result" | grep -q "frame="; then
        echo "✅"
        OK_COUNT=$(( OK_COUNT + 1 ))
        log_result "$group,${group}_${clip_name},,,,,OK"
    else
        local err
        err=$(echo "$result" | grep -iE "error|invalid|no such filter|not supported" \
            | head -1 | sed 's/\[.*\] //' | cut -c1-60)
        echo "❌  $err"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        log_result "$group,${group}_${clip_name},,,,,FAIL"
    fi
}

# ============================================================
# Build a symmetric SBS crop filter
#
# Crops the SAME relative region from each eye and hstacks them.
# Both eyes see the same angular region → stereo remains valid.
#
# Args: crop_w  crop_h  cx_offset  cy_offset
#   cx_offset: pixels right of each eye's geometric center (positive = right)
#   cy_offset: pixels below each eye's geometric center   (positive = down)
#
# Output: filter_complex string ending in [v]
# ============================================================
sbs_crop() {
    local cw="$1"
    local ch="$2"
    local cx_off="${3:-0}"
    local cy_off="${4:-0}"

    # Top-left of crop in full-frame coordinates
    local lx=$(( LEFT_CX  - cw/2 + cx_off ))
    local rx=$(( RIGHT_CX - cw/2 + cx_off ))
    local ty=$(( LEFT_CY  - ch/2 + cy_off ))

    # Clamp to valid bounds (avoid ffmpeg crop errors)
    [ $lx -lt 0 ]                    && lx=0
    [ $ty -lt 0 ]                    && ty=0
    [ $(( lx + cw )) -gt $EYE_W ]   && lx=$(( EYE_W  - cw ))
    [ $(( rx + cw )) -gt $TOTAL_W ]  && rx=$(( TOTAL_W - cw ))
    [ $(( ty + ch )) -gt $EYE_H ]    && ty=$(( EYE_H  - ch ))

    # Re-clamp rx lower bound (must stay in right eye area)
    [ $rx -lt $EYE_W ] && rx=$EYE_W

    echo "[0:v]split[l][r];[l]crop=${cw}:${ch}:${lx}:${ty}[le];[r]crop=${cw}:${ch}:${rx}:${ty}[re];[le][re]hstack=inputs=2[v]"
}

# Format a signed offset into a filename-safe tag: +50 -> "p50", -50 -> "m50"
offset_tag() {
    local n="$1"
    if [ "$n" -ge 0 ]; then echo "p${n}"; else echo "m$(( -n ))"; fi
}

# ============================================================
# GROUP A — Baseline clips (no crop modification)
# These are the reference. Compare all other groups against A1.
# ============================================================
run_group_A() {
    print_header "Group A: Baseline (no crop)"

    # A1: Raw full frame — no filter, no metadata
    encode_clip "A1" "full_raw_no_meta" "" ""

    # A2: Raw full frame + SBS left_right metadata
    #     Tells VR player: left half of frame = left eye
    encode_clip "A2" "full_SBS_left_right_meta" "" "left_right"

    # A3: Raw full frame + eyes flipped metadata
    #     Tells VR player: left half of frame = RIGHT eye
    encode_clip "A3" "full_SBS_right_left_meta" "" "right_left"

    # A4: Left eye only (mono — see what the left camera actually sees)
    #     If this looks like a normal fisheye: camera is SBS as expected
    encode_clip "A4" "mono_LEFT_eye_only" \
        "[0:v]crop=${EYE_W}:${EYE_H}:0:0[v]" ""

    # A5: Right eye only (mono — see what the right camera sees)
    encode_clip "A5" "mono_RIGHT_eye_only" \
        "[0:v]crop=${EYE_W}:${EYE_H}:${EYE_W}:0[v]" ""

    # A6: Eyes swapped — right camera on left, left camera on right
    #     Fixes inverted stereo depth (objects float instead of having depth)
    encode_clip "A6" "SBS_eyes_SWAPPED" \
        "[0:v]split[l][r];[l]crop=${EYE_W}:${EYE_H}:${EYE_W}:0[le];[r]crop=${EYE_W}:${EYE_H}:0:0[re];[le][re]hstack=inputs=2[v]" \
        "left_right"

    # A7: Horizontal flip of whole frame (if both cameras appear mirrored)
    encode_clip "A7" "full_hflip" \
        "[0:v]hflip[v]" "left_right"
}

# ============================================================
# GROUP B — FOV / Size Sweep
# Center is fixed at the geometric center of each eye.
# Crop size controls how much of the 180° FOV is transmitted.
# See FOV reference table at the top of this file.
# ============================================================
run_group_B() {
    print_header "Group B: FOV/Size Sweep (center fixed, crop size varies)"

    echo "  Eye area per camera: ${EYE_W}x${EYE_H}px"
    echo "  Geometric center: (${LEFT_CX}, ${LEFT_CY})"
    echo "  HP Reverb G2 FOV ~114° → best match is ~500px crop"
    echo ""

    # Square crops — different FOV amounts
    for size in 776 700 640 540 500 440 400 300; do
        encode_clip "B" "square_${size}x${size}" \
            "$(sbs_crop $size $size 0 0)" "left_right"
    done

    # Landscape crops (wide, short) — tests if Unity expects 16:9 input
    local h16_9=$(( EYE_W * 9 / 16 ))   # 776 * 9/16 = 436
    encode_clip "B" "landscape_16x9_${EYE_W}x${h16_9}" \
        "$(sbs_crop $EYE_W $h16_9 0 0)" "left_right"

    local h4_3=$(( EYE_W * 3 / 4 ))     # 776 * 3/4 = 582
    encode_clip "B" "landscape_4x3_${EYE_W}x${h4_3}" \
        "$(sbs_crop $EYE_W $h4_3 0 0)" "left_right"

    # Portrait crops (narrow, tall) — tests top-to-bottom view
    local wp=$(( EYE_W / 2 ))
    encode_clip "B" "portrait_narrow_${wp}x${EYE_W}" \
        "$(sbs_crop $wp $EYE_W 0 0)" "left_right"
}

# ============================================================
# GROUP C — Horizontal Center Sweep
# Crop size fixed at 540px (≈125° FOV, good starting point).
# Shifts the crop window left/right within each eye's area.
#
# USE THIS IF: the VR view appears shifted left or right,
# or if the stereo overlap seems wrong horizontally.
# ============================================================
run_group_C() {
    local CW=540
    local CH=540

    print_header "Group C: Horizontal Center Sweep (crop ${CW}x${CH}, cx varies)"

    echo "  Range: ±$(( (EYE_W - CW) / 2 ))px before hitting eye boundary"
    echo "  Positive offset = shift crop RIGHT within each eye's area"
    echo ""

    for cx_off in -100 -75 -50 -25 0 25 50 75 100; do
        local tag
        tag=$(offset_tag $cx_off)
        encode_clip "C" "cx_${tag}_crop${CW}x${CH}" \
            "$(sbs_crop $CW $CH $cx_off 0)" "left_right"
    done
}

# ============================================================
# GROUP D — Vertical Center Sweep
# Crop size fixed at 540px. Shifts the window up/down.
#
# USE THIS IF: the horizon is wrong, ground/ceiling cut off,
# or fisheye circle is offset vertically from center.
# (The fisheye circle may only occupy the middle 776px of the
#  776x1552 eye area, leaving ~388px black bands top & bottom)
# ============================================================
run_group_D() {
    local CW=540
    local CH=540

    print_header "Group D: Vertical Center Sweep (crop ${CW}x${CH}, cy varies)"

    echo "  Positive offset = shift crop DOWN within each eye's area"
    echo "  Testing ±300px — covers the full fisheye circle range"
    echo ""

    for cy_off in -300 -225 -150 -100 -75 -50 -25 0 25 50 75 100 150 225 300; do
        local tag
        tag=$(offset_tag $cy_off)
        encode_clip "D" "cy_${tag}_crop${CW}x${CH}" \
            "$(sbs_crop $CW $CH 0 $cy_off)" "left_right"
    done
}

# ============================================================
# GROUP E — 2D Center Grid (cx + cy combined)
# Medium crop size (500px ≈ 116° FOV, close to headset FOV).
# Tests a grid of center positions to find the optimal offset.
#
# USE THIS AFTER C and D narrow down the approximate offsets.
# ============================================================
run_group_E() {
    local CW=500
    local CH=500

    print_header "Group E: 2D Center Grid (crop ${CW}x${CH}, cx × cy grid)"

    echo "  Grid: cx ∈ {-75,-25,0,25,75}  cy ∈ {-150,-75,0,75,150}"
    echo "  25 clips total — one should look correctly centered in VR"
    echo ""

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
# GROUP F — Fine Grid Around Best Candidate
# Once you identify the best (cx, cy) from Group E,
# edit CX_BEST and CY_BEST below and re-run just this group
# for fine-grained ±25px tuning.
# ============================================================
run_group_F() {
    local CW=500
    local CH=500

    # Edit these after reviewing Group E results:
    local CX_BEST=0
    local CY_BEST=0

    print_header "Group F: Fine Grid around (cx=${CX_BEST}, cy=${CY_BEST}) ±25px"

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
# Applies ffmpeg's v360 filter to re-project the fisheye image.
# Useful if fisheye distortion (bending straight lines) is the
# main immersion problem, rather than center offset.
# ============================================================
run_group_G() {
    print_header "Group G: Fisheye Projection Conversions (v360 filter)"

    echo "  NOTE: These require ffmpeg built with v360 filter support."
    echo "  If they all fail, your ffmpeg build may lack this filter."
    echo ""

    # G1: Dual fisheye to equirectangular
    #     Treats full frame as two side-by-side fisheye images
    encode_clip "G1" "dfisheye_to_equirect" \
        "[0:v]v360=dfisheye:equirect[v]" ""

    # G2: Same but with SBS metadata
    encode_clip "G2" "dfisheye_to_equirect_SBS_meta" \
        "[0:v]v360=dfisheye:equirect[v]" "left_right"

    # G3: Left eye fisheye → flat (rectilinear) projection
    #     Removes fisheye distortion; straight lines become straight
    encode_clip "G3" "mono_left_fisheye_to_flat" \
        "[0:v]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=180:iv_fov=180[v]" ""

    # G4: Right eye fisheye → flat
    encode_clip "G4" "mono_right_fisheye_to_flat" \
        "[0:v]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=180:iv_fov=180[v]" ""

    # G5: Both eyes fisheye → flat, recombined as SBS
    #     Fully undistorted SBS stereo output
    encode_clip "G5" "SBS_both_eyes_flat_rectilinear" \
        "[0:v]split[l][r];[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=180:iv_fov=180[le];[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=180:iv_fov=180[re];[le][re]hstack=inputs=2[v]" \
        "left_right"

    # G6: Both eyes fisheye → equirect, recombined as SBS
    encode_clip "G6" "SBS_both_eyes_equirect" \
        "[0:v]split[l][r];[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:equirect:ih_fov=180:iv_fov=180[le];[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:equirect:ih_fov=180:iv_fov=180[re];[le][re]hstack=inputs=2[v]" \
        "left_right"

    # G7: Narrower FOV flat conversion (120° instead of 180°)
    #     Less distortion, more zoom
    encode_clip "G7" "SBS_both_eyes_flat_120fov" \
        "[0:v]split[l][r];[l]crop=${EYE_W}:${EYE_H}:0:0,v360=fisheye:flat:ih_fov=120:iv_fov=120[le];[r]crop=${EYE_W}:${EYE_H}:${EYE_W}:0,v360=fisheye:flat:ih_fov=120:iv_fov=120[re];[le][re]hstack=inputs=2[v]" \
        "left_right"
}

# ============================================================
# GROUP H — Scale to Fixed Output Size
# Some Unity video players expect a specific frame size.
# These scale the 500x500 center crop to standard SBS resolutions.
# ============================================================
run_group_H() {
    print_header "Group H: Fixed Output Resolution (scaled)"

    echo "  Scales the center 500x500 crop (per eye) to standard sizes."
    echo "  Use if Unity's video player shows letterboxing or stretching."
    echo ""

    local CW=500
    local CH=500
    local lx=$(( LEFT_CX  - CW/2 ))
    local rx=$(( RIGHT_CX - CW/2 ))
    local ty=$(( LEFT_CY  - CH/2 ))

    local base="[0:v]split[l][r];[l]crop=${CW}:${CH}:${lx}:${ty}[le];[r]crop=${CW}:${CH}:${rx}:${ty}[re];[le][re]hstack=inputs=2"

    # H1: 1920x960 — standard SBS HD (960px per eye)
    encode_clip "H1" "scale_1920x960_SBS" \
        "${base},scale=1920:960[v]" "left_right"

    # H2: 1280x640 — lighter weight SBS
    encode_clip "H2" "scale_1280x640_SBS" \
        "${base},scale=1280:640[v]" "left_right"

    # H3: 2160x1080 — 2K SBS
    encode_clip "H3" "scale_2160x1080_SBS" \
        "${base},scale=2160:1080[v]" "left_right"

    # H4: 1000x1000 — square per-eye output (500x500 each, 2:1 total)
    encode_clip "H4" "scale_1000x500_SBS" \
        "${base},scale=1000:500[v]" "left_right"
}

# ============================================================
# Visualization: sample frame with crop rectangles annotated
# ============================================================
generate_visualization() {
    print_header "Generating Crop Visualization"

    echo "  Captures one frame and draws key crop rectangles on it."
    echo "  Lets you see the crop regions before reviewing VR clips."
    echo ""

    local sample="$OUTPUT_DIR/_sample.png"
    local viz="$OUTPUT_DIR/CROP_VISUALIZATION.png"

    timeout 8 ffmpeg -y \
        -f avfoundation -framerate "$FPS" \
        -pixel_format "$PIXEL_FMT" -video_size "$RES" \
        -i "$CAMERA_DEVICE" \
        -vframes 1 "$sample" 2>/dev/null || {
        echo "  Could not capture sample frame — skipping visualization"
        return
    }

    # Draw crop boxes for key sizes at geometric center
    # Colors: yellow=776, red=640, blue=500, green=400
    local draw_boxes=""
    for size_color in "776:yellow" "640:red" "500:blue" "400:green"; do
        local s c
        s=$(echo "$size_color" | cut -d: -f1)
        c=$(echo "$size_color" | cut -d: -f2)
        local lbx=$(( LEFT_CX  - s/2 ))
        local rbx=$(( RIGHT_CX - s/2 ))
        local bty=$(( LEFT_CY  - s/2 ))
        if [ -n "$draw_boxes" ]; then draw_boxes="${draw_boxes},"; fi
        draw_boxes="${draw_boxes}drawbox=x=${lbx}:y=${bty}:w=${s}:h=${s}:color=${c}@0.8:t=3"
        draw_boxes="${draw_boxes},drawbox=x=${rbx}:y=${bty}:w=${s}:h=${s}:color=${c}@0.8:t=3"
    done

    ffmpeg -y -i "$sample" -vf "$draw_boxes" "$viz" 2>/dev/null && \
        echo "  Saved: $viz" && \
        echo "  Yellow=776px, Red=640px, Blue=500px, Green=400px" || \
        echo "  Visualization failed (non-critical)"

    rm -f "$sample"
}

# ============================================================
# Summary
# ============================================================
print_summary() {
    print_header "DONE"

    echo ""
    echo "Total clips: $CLIP_COUNT   OK: $OK_COUNT   Failed: $FAIL_COUNT"
    echo "Output: $OUTPUT_DIR/"
    echo ""

    echo "================================================================"
    echo "REVIEW GUIDE — compare these on the HP Reverb G2"
    echo "================================================================"
    echo ""
    echo "STEP 1 — Confirm camera & stereo polarity (Group A)"
    echo "  Open A4 and A5 mono clips (no VR mode, just 2D)."
    echo "  They should look like fisheye photos of the scene."
    echo "  If A4 and A5 look correct: camera is SBS, left eye on left."
    echo "  If A6 (eyes swapped) looks better in VR → use that as base."
    echo ""
    echo "STEP 2 — Find the right FOV (Group B)"
    echo "  Open B clips in VR mode (SBS). Compare:"
    echo "    B_square_776  → full 180°, likely too wide/distorted"
    echo "    B_square_500  → ~116° FOV, closest to headset FOV"
    echo "    B_square_300  → narrow, minimal distortion"
    echo "  Pick the size that looks most natural in scale."
    echo ""
    echo "STEP 3 — Find correct horizontal center (Group C)"
    echo "  Look for the clip where objects are centered and"
    echo "  stereo depth feels natural (not cross-eyed)."
    echo "  The correct cx is where both eyes converge on the same point."
    echo ""
    echo "STEP 4 — Find correct vertical center (Group D)"
    echo "  Look for the clip where the horizon is level and"
    echo "  objects appear at the expected vertical position."
    echo "  Large cy offsets test if the fisheye circle is off-center."
    echo ""
    echo "STEP 5 — Fine-tune with the 2D grid (Group E)"
    echo "  The best (cx, cy) combination gives correct stereo depth"
    echo "  AND correct object placement simultaneously."
    echo ""
    echo "STEP 6 (optional) — Remove fisheye distortion (Group G)"
    echo "  If straight lines look curved and that breaks immersion,"
    echo "  try G5 (both eyes undistorted flat projection)."
    echo ""
    echo "STEP 7 — Once best crop found, update the stream sender with:"
    echo "  Add to ffmpeg stream command:"
    echo "    -filter_complex \"$(sbs_crop 500 500 0 0)\""
    echo "  (Replace 500/0/0 with your best size/cx/cy values)"
}

# ============================================================
# MAIN
# ============================================================

echo "============================================================"
echo "   VR FISHEYE CROP CENTER & FOV TEST"
echo "   Camera: device [$CAMERA_DEVICE] @ $RES ${FPS}fps"
echo "============================================================"
echo ""
echo "Frame geometry:"
echo "  Full frame  : ${TOTAL_W}x${TOTAL_H}px"
echo "  Per-eye area: ${EYE_W}x${EYE_H}px"
echo "  Left  eye center (full-frame coords): (${LEFT_CX}, ${LEFT_CY})"
echo "  Right eye center (full-frame coords): (${RIGHT_CX}, ${RIGHT_CY})"
echo ""
echo "Test groups:"
echo "  A  (7 clips)  : Baseline — raw, mono eyes, swap, flip"
echo "  B  (11 clips) : FOV size sweep (776px → 300px)"
echo "  C  (9 clips)  : Horizontal center sweep (cx ±100px)"
echo "  D  (15 clips) : Vertical center sweep   (cy ±300px)"
echo "  E  (25 clips) : 2D center grid          (5cx × 5cy)"
echo "  F  (49 clips) : Fine grid around (0,0) — edit CX_BEST/CY_BEST after E"
echo "  G  (7 clips)  : Fisheye projection conversions (v360)"
echo "  H  (4 clips)  : Scaled output sizes for Unity"
echo ""
echo "Total: ~127 clips × ${TEST_DURATION}s = ~$(( 127 * TEST_DURATION / 60 )) minutes"
echo ""
echo "TIP: Run groups A–E first (83 clips). Only run F after reviewing E."
echo ""
echo "Press Enter to start, or Ctrl+C to abort..."
read -r

generate_visualization
run_group_A
run_group_B
run_group_C
run_group_D
run_group_E

echo ""
echo "================================================================"
echo "  Groups A–E complete. Review before running F (fine grid)."
echo "  Edit CX_BEST and CY_BEST in run_group_F(), then press Enter."
echo "================================================================"
read -r

run_group_F
run_group_G
run_group_H
print_summary
