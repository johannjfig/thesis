@echo off
REM ============================================================================
REM Optimized Stereoscopic VR Telepresence Encoder (Robot Side)
REM Based on research: adaptive compression for <30ms latency
REM ============================================================================

REM Network Configuration
SET TARGET_IP=192.168.1.100
SET TARGET_PORT=5004

REM Camera Configuration
SET LEFT_CAMERA=video="USB Camera Left"
SET RIGHT_CAMERA=video="USB Camera Right"

REM Base Resolution & Frame Rate
SET BASE_WIDTH=1920
SET BASE_HEIGHT=1920
SET TARGET_FPS=60

REM Compression Strategy
REM For high-motion/high-detail: full resolution
REM For low-motion: can drop to 30fps on right eye
REM For low-detail: can spatially subsample right eye

REM ============================================================================
REM OPTION 1: Adaptive Quality - High bandwidth (50-80 Mbps)
REM Best quality for complex scenes with motion
REM ============================================================================
echo Starting HIGH QUALITY stereoscopic stream...
ffmpeg -y ^
    -f dshow -video_size %BASE_WIDTH%x%BASE_HEIGHT% -framerate %TARGET_FPS% -i %LEFT_CAMERA% ^
    -f dshow -video_size %BASE_WIDTH%x%BASE_HEIGHT% -framerate %TARGET_FPS% -i %RIGHT_CAMERA% ^
    -filter_complex "[0:v]format=yuv420p[left];[1:v]format=yuv420p,scale=%BASE_WIDTH%:%BASE_HEIGHT%[right];[left][right]hstack=inputs=2[v]" ^
    -map "[v]" ^
    -c:v hevc_nvenc ^
    -preset p1 ^
    -tune ll ^
    -rc cbr ^
    -b:v 60M ^
    -maxrate 60M ^
    -bufsize 15M ^
    -g 12 ^
    -bf 0 ^
    -refs 1 ^
    -spatial_aq 1 ^
    -temporal_aq 1 ^
    -zerolatency 1 ^
    -forced-idr 1 ^
    -strict_gop 1 ^
    -slices 4 ^
    -f rtp rtp://%TARGET_IP%:%TARGET_PORT%
goto :end

REM ============================================================================
REM OPTION 2: Bandwidth-Constrained - Medium quality (20-30 Mbps)
REM Spatial downsampling of RIGHT eye only (per paper findings)
REM ============================================================================
:medium_quality
echo Starting MEDIUM QUALITY stereoscopic stream (right eye 1/2 spatial)...
ffmpeg -y ^
    -f dshow -video_size %BASE_WIDTH%x%BASE_HEIGHT% -framerate %TARGET_FPS% -i %LEFT_CAMERA% ^
    -f dshow -video_size %BASE_WIDTH%x%BASE_HEIGHT% -framerate %TARGET_FPS% -i %RIGHT_CAMERA% ^
    -filter_complex ^
    "[0:v]format=yuv420p[left];^
     [1:v]format=yuv420p,scale=%BASE_WIDTH%/2:%BASE_HEIGHT%/2:flags=lanczos,scale=%BASE_WIDTH%:%BASE_HEIGHT%:flags=lanczos[right];^
     [left][right]hstack=inputs=2[v]" ^
    -map "[v]" ^
    -c:v hevc_nvenc ^
    -preset p1 ^
    -tune ll ^
    -rc cbr ^
    -b:v 25M ^
    -maxrate 25M ^
    -bufsize 8M ^
    -g 15 ^
    -bf 0 ^
    -zerolatency 1 ^
    -f rtp rtp://%TARGET_IP%:%TARGET_PORT%
goto :end

REM ============================================================================
REM OPTION 3: Low Bandwidth - Aggressive compression (10-15 Mbps)
REM Spatial 1/2 + Temporal 1/2 on right eye (suppression theory)
REM ============================================================================
:low_bandwidth
echo Starting LOW BANDWIDTH stereoscopic stream...
ffmpeg -y ^
    -f dshow -video_size %BASE_WIDTH%x%BASE_HEIGHT% -framerate %TARGET_FPS% -i %LEFT_CAMERA% ^
    -f dshow -video_size %BASE_WIDTH%x%BASE_HEIGHT% -framerate %TARGET_FPS% -i %RIGHT_CAMERA% ^
    -filter_complex ^
    "[0:v]format=yuv420p[left];^
     [1:v]format=yuv420p,fps=%TARGET_FPS%/2,scale=%BASE_WIDTH%/2:%BASE_HEIGHT%/2:flags=lanczos,fps=%TARGET_FPS%,scale=%BASE_WIDTH%:%BASE_HEIGHT%:flags=lanczos[right];^
     [left][right]hstack=inputs=2[v]" ^
    -map "[v]" ^
    -c:v hevc_nvenc ^
    -preset p1 ^
    -tune ll ^
    -rc cbr ^
    -b:v 12M ^
    -maxrate 12M ^
    -bufsize 4M ^
    -g 30 ^
    -bf 0 ^
    -zerolatency 1 ^
    -f rtp rtp://%TARGET_IP%:%TARGET_PORT%
goto :end

REM ============================================================================
REM OPTION 4: Ultra-low latency with UDP/MPEGTS
REM Bypasses some RTP overhead, use for <15ms target latency
REM ============================================================================
:ultra_low_latency
echo Starting ULTRA-LOW LATENCY stream via UDP...
ffmpeg -y ^
    -f dshow -video_size %BASE_WIDTH%x%BASE_HEIGHT% -framerate %TARGET_FPS% -rtbufsize 100M -i %LEFT_CAMERA% ^
    -f dshow -video_size %BASE_WIDTH%x%BASE_HEIGHT% -framerate %TARGET_FPS% -rtbufsize 100M -i %RIGHT_CAMERA% ^
    -filter_complex "[0:v][1:v]hstack=inputs=2,format=yuv420p[v]" ^
    -map "[v]" ^
    -c:v hevc_nvenc ^
    -preset p1 ^
    -tune ull ^
    -rc cbr ^
    -b:v 50M ^
    -maxrate 50M ^
    -bufsize 10M ^
    -g 1 ^
    -bf 0 ^
    -slices 8 ^
    -zerolatency 1 ^
    -f mpegts udp://%TARGET_IP%:%TARGET_PORT%?pkt_size=1316
goto :end

:end
pause