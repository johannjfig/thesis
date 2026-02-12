@echo off
REM ============================================================================
REM Optimized Stereoscopic Stream Receiver (VR Headset Side)
REM Matches encoder settings for minimal latency
REM ============================================================================

SET LISTEN_PORT=5004

REM ============================================================================
REM OPTION 1: Direct display with FFplay (for testing/validation)
REM ============================================================================
echo Starting stereoscopic receiver (display mode)...
ffplay -fflags nobuffer+fastseek+flush_packets -flags low_delay+global_header -analyzeduration 1 ^
    -probesize 32 -sync ext ^
    -framedrop -infbuf ^
    -i rtp://0.0.0.0:%LISTEN_PORT% ^
    -vf "setpts=0,split[left][right];[left]crop=iw/2:ih:0:0[l];[right]crop=iw/2:ih:iw/2:0[r];[l][r]hstack" ^
    -autoexit
goto :end

REM ============================================================================
REM OPTION 2: Decode to shared memory for VR application
REM Provides separate left/right streams
REM ============================================================================
:shared_memory
echo Starting receiver with shared memory output...
ffmpeg -fflags nobuffer+fastseek -flags low_delay ^
    -probesize 32 -analyzeduration 1 ^
    -i rtp://0.0.0.0:%LISTEN_PORT% ^
    -filter_complex ^
    "[0:v]split[left][right];^
     [left]crop=iw/2:ih:0:0,format=rgb24[l];^
     [right]crop=iw/2:ih:iw/2:0,format=rgb24[r]" ^
    -map "[l]" -f rawvideo -pix_fmt rgb24 \\.\pipe\vr_left_eye ^
    -map "[r]" -f rawvideo -pix_fmt rgb24 \\.\pipe\vr_right_eye
goto :end

REM ============================================================================
REM OPTION 3: UDP receiver (matches Option 4 encoder)
REM ============================================================================
:udp_receiver
echo Starting UDP receiver...
ffplay -fflags nobuffer -flags low_delay -framedrop ^
    -probesize 32 -analyzeduration 1 ^
    -i udp://0.0.0.0:%LISTEN_PORT%?overrun_nonfatal=1^&buffer_size=212992 ^
    -vf "setpts=0" ^
    -autoexit
goto :end

REM ============================================================================
REM OPTION 4: Decode with point cloud quantization emulation
REM Reduces precision to 16-bit spatial + 16-bit color (6-6-4 RGB)
REM ============================================================================
:quantized_output
echo Starting receiver with quantization...
ffmpeg -fflags nobuffer -flags low_delay ^
    -i rtp://0.0.0.0:%LISTEN_PORT% ^
    -vf "format=rgb48le,lutrgb=r='floor(val/1024)*1024':g='floor(val/1024)*1024':b='floor(val/4096)*4096',format=rgb24" ^
    -f rawvideo -pix_fmt rgb24 \\.\pipe\vr_quantized_pipe
goto :end

:end
pause