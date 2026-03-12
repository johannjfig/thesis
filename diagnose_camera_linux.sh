#!/bin/bash
# diagnose_camera_linux.sh
# Run this on Ubuntu to diagnose why the VR camera isn't showing up.
# Does not require any special tools beyond what ships with Ubuntu.

echo "============================================================"
echo "  VR CAMERA DIAGNOSTIC — Linux / Ubuntu"
echo "============================================================"
echo ""

PASS=0
WARN=0
FAIL=0

ok()   { echo "  ✅  $1"; PASS=$((PASS+1)); }
warn() { echo "  ⚠️   $1"; WARN=$((WARN+1)); }
fail() { echo "  ❌  $1"; FAIL=$((FAIL+1)); }

# ============================================================
# 1. Check required tools
# ============================================================
echo "--- Tools ---"

for tool in ffmpeg v4l2-ctl lsusb dmesg; do
    if command -v "$tool" &>/dev/null; then
        ok "$tool found: $(command -v $tool)"
    else
        fail "$tool NOT found  →  install: sudo apt install ${tool/dmesg/util-linux}"
    fi
done
echo ""

# ============================================================
# 2. USB device detection
# ============================================================
echo "--- USB Devices (lsusb) ---"
echo ""

if command -v lsusb &>/dev/null; then
    lsusb
    echo ""

    # Look for known VR/360 camera vendors
    echo "Searching for known VR/camera USB vendors..."

    local_found=false
    while IFS= read -r line; do
        # Check for common camera-related identifiers
        if echo "$line" | grep -iqE "camera|video|vr|360|ricoh|insta|gopro|logitech|elp|uvc|imaging"; then
            echo "  -> $line"
            local_found=true
        fi
    done < <(lsusb)

    if ! $local_found; then
        warn "No obviously named camera USB device found."
        echo "     This could mean the VR camera uses a generic USB ID."
        echo "     Look at the full lsusb list above — any unfamiliar entry"
        echo "     could be the camera. Try unplugging/replugging and run:"
        echo "     watch -n1 lsusb"
    fi
else
    warn "lsusb not available — cannot check USB devices"
fi
echo ""

# ============================================================
# 3. V4L2 device files
# ============================================================
echo "--- V4L2 Video Devices (/dev/video*) ---"
echo ""

video_devices=(/dev/video*)
if [ ${#video_devices[@]} -eq 0 ] || [ ! -e "${video_devices[0]}" ]; then
    fail "No /dev/video* devices found."
    echo ""
    echo "  Possible causes:"
    echo "    a) Camera not connected or not powered"
    echo "    b) USB cable issue — try a different cable/port"
    echo "    c) Camera needs USB3 — check you're using a blue USB3 port"
    echo "    d) Kernel module not loaded — run: sudo modprobe uvcvideo"
    echo "    e) Camera uses a non-UVC protocol (rare for webcam-style devices)"
else
    for dev in /dev/video*; do
        # Get device name if v4l2-ctl is available
        if command -v v4l2-ctl &>/dev/null; then
            name=$(v4l2-ctl --device="$dev" --info 2>/dev/null | grep "Card type" | cut -d: -f2 | xargs)
            if [ -n "$name" ]; then
                ok "$dev  →  $name"
            else
                warn "$dev  →  (could not read name)"
            fi
        else
            ok "$dev  exists"
        fi
    done
fi
echo ""

# ============================================================
# 4. V4L2 device details and supported formats
# ============================================================
if command -v v4l2-ctl &>/dev/null && ls /dev/video* &>/dev/null 2>&1; then
    echo "--- Supported Formats per Device ---"
    echo ""

    for dev in /dev/video*; do
        echo "Device: $dev"
        v4l2-ctl --device="$dev" --list-formats-ext 2>/dev/null | \
            grep -E "Index|Type|Pixel|Size|Interval|Name" | head -40
        echo ""
    done
fi

# ============================================================
# 5. Permission check
# ============================================================
echo "--- Permissions ---"
echo ""

current_user=$(whoami)

# Check video group membership
if groups "$current_user" | grep -q "video"; then
    ok "User '$current_user' is in the 'video' group"
else
    fail "User '$current_user' is NOT in the 'video' group"
    echo "     Fix: sudo usermod -aG video $current_user"
    echo "     Then log out and back in (or run: newgrp video)"
fi

# Check plugdev group (needed on some distros for USB devices)
if groups "$current_user" | grep -q "plugdev"; then
    ok "User '$current_user' is in the 'plugdev' group"
else
    warn "User '$current_user' is not in 'plugdev' group (may be needed)"
    echo "     Fix: sudo usermod -aG plugdev $current_user"
fi

# Check actual file permissions
for dev in /dev/video*; do
    if [ -e "$dev" ]; then
        perms=$(ls -la "$dev" 2>/dev/null)
        if [ -r "$dev" ] && [ -w "$dev" ]; then
            ok "$dev is readable and writable"
        elif [ -r "$dev" ]; then
            warn "$dev is readable but not writable  ($perms)"
        else
            fail "$dev is not accessible  ($perms)"
            echo "     Fix: sudo chmod a+rw $dev  (temporary)"
            echo "     Permanent: add udev rule (see below)"
        fi
    fi
done
echo ""

# ============================================================
# 6. Recent kernel messages about USB / cameras
# ============================================================
echo "--- Recent Kernel Messages (camera/USB/UVC related) ---"
echo ""
echo "  (showing last 30 relevant lines from dmesg)"
echo ""

if command -v dmesg &>/dev/null; then
    dmesg 2>/dev/null | grep -iE "uvc|video|usb.*cam|cam.*usb|vr|v4l" | tail -30 || \
        warn "No camera-related kernel messages found in dmesg"
    echo ""
    echo "  If you see 'uvcvideo: Failed to query' or 'device not responding',"
    echo "  try a powered USB hub — the camera may need more current."
else
    warn "Cannot read dmesg"
fi
echo ""

# ============================================================
# 7. FFmpeg V4L2 probe (if any /dev/video* exists)
# ============================================================
if command -v ffmpeg &>/dev/null && ls /dev/video* &>/dev/null 2>&1; then
    echo "--- FFmpeg V4L2 Format Probe ---"
    echo ""

    for dev in /dev/video*; do
        echo "Probing $dev with ffmpeg..."
        ffmpeg -f v4l2 -list_formats all -i "$dev" 2>&1 | \
            grep -E "Raw|Compressed|yuyv|mjpeg|h264|nv12|uyvy|[0-9]+x[0-9]+" | head -15
        echo ""
    done
fi

# ============================================================
# 8. UVC driver status
# ============================================================
echo "--- UVC Driver ---"
echo ""

if lsmod 2>/dev/null | grep -q "uvcvideo"; then
    ok "uvcvideo kernel module is loaded"
else
    fail "uvcvideo kernel module is NOT loaded"
    echo "     Fix: sudo modprobe uvcvideo"
    echo "     Permanent: echo 'uvcvideo' | sudo tee /etc/modules-load.d/uvcvideo.conf"
fi
echo ""

# ============================================================
# 9. VM / Container detection
# ============================================================
echo "--- Virtual Machine / Container Check ---"
echo ""

if systemd-detect-virt &>/dev/null 2>&1; then
    virt=$(systemd-detect-virt 2>/dev/null)
    if [ "$virt" = "none" ]; then
        ok "Running on bare metal (no virtualization detected)"
    else
        warn "Running inside: $virt"
        echo "     USB device passthrough to VMs often requires extra setup:"
        echo "       VMware:     VM > Settings > USB Controller > USB 3.1"
        echo "                   Then: VM > Removable Devices > [camera] > Connect"
        echo "       VirtualBox: Devices > USB > [camera]  (needs Extension Pack)"
        echo "       WSL2:       Use usbipd-win: usbipd bind --busid <id>"
        echo "                              then: usbipd attach --wsl --busid <id>"
    fi
fi
echo ""

# ============================================================
# Summary and next steps
# ============================================================
echo "============================================================"
echo "  SUMMARY"
echo "============================================================"
echo ""
echo "  Passed : $PASS"
echo "  Warnings: $WARN"
echo "  Failed : $FAIL"
echo ""

if [ $FAIL -gt 0 ] || ! ls /dev/video* &>/dev/null 2>&1; then
    echo "NEXT STEPS (try in order):"
    echo ""
    echo "  1. Confirm the camera is physically connected:"
    echo "     Unplug and replug, then immediately run:"
    echo "     sudo dmesg | tail -20"
    echo "     You should see lines about 'New USB device' and 'uvcvideo'"
    echo ""
    echo "  2. If running in a VM, pass the USB device through:"
    echo "     First find it on the host: lsusb"
    echo "     For WSL2: usbipd list  →  usbipd bind --busid X-Y  →  usbipd attach --wsl"
    echo "     For VMware/VirtualBox: use the GUI USB device menu"
    echo ""
    echo "  3. Add yourself to the video group if not already:"
    echo "     sudo usermod -aG video \$(whoami) && newgrp video"
    echo ""
    echo "  4. Force load the UVC driver:"
    echo "     sudo modprobe uvcvideo"
    echo "     sudo dmesg | tail -10"
    echo ""
    echo "  5. If using USB-C adapter or hub, try direct USB3 port"
    echo "     (360 VR cameras often need USB3 bandwidth)"
    echo ""
    echo "  6. Check if the camera is seen at all on the HOST machine"
    echo "     (if Ubuntu is in a VM)"
else
    echo "Camera appears accessible. Next step:"
    echo "  Run the Linux-compatible test script:"
    echo "    bash test_fisheye_crops_linux.sh"
fi
