# Video over the network (ImpellerVideo http, https, HLS)

`ImpellerVideo.create(uri)` (and the package's `createVideoPlayer` /
`useVideoPlayer`) opens these sources on the linux ffmpeg backend:

| Source | Example |
| --- | --- |
| Local file | `file:///abs/route.mp4`, `/abs/route.mp4` |
| HTTP or HTTPS MP4/MOV | `https://cdn.example/a.mp4?Expires=...&Signature=...&Key-Pair-Id=...` |
| HLS, VOD or live | `https://example/master.m3u8` |

Darwin has no video backend (CMake builds the ffmpeg backend on Linux only), so
`create()` fails there for every source.

## Behaviour

- `create()` returns at once. The source opens on the player's thread, and a
  failure turns `getStatus().status` to `error` with the reason in `.error`. A
  404 reads `could not open http://host/path?<redacted>: Server returned 404 Not Found`.
- The URL goes to the server unchanged, so a signed query keeps working. In
  every log line and error string the query and any user info are replaced
  with `<redacted>`, and ffmpeg's own log is limited to errors
  (`RNI_VIDEO_LOG=1` turns its INFO lines back on, URLs included).
- `seek()` on an HTTP MP4 uses byte-range requests. The server must answer
  `Range` with 206.
- A read-ahead thread keeps up to 10 s (or 64 MB) of video queued past the
  decoder. A slow request or an HLS segment fetch doesn't stall the picture
  unless the queue runs dry.
- The media clock starts when the first frame is on screen and restarts at the
  frame a seek shows. Time spent waiting on the network does not advance it,
  so a slow open, seek or stall pauses the video instead of skipping frames.
- `release()` interrupts a blocked network read, so it returns at once even
  when the server has stopped answering. A server that stops sending fails
  the read after 15 s (`rw_timeout`).
- HLS: only the chosen video stream and the audio stream that goes with it
  are read. The video stream is the one `av_find_best_stream` picks, which for
  a master playlist means the highest bitrate variant. Other variants are
  discarded, so they are not downloaded. Live playlists work, and `duration`
  is 0 for them.
- Sound plays on Linux through ALSA. See Audio below.

## Audio

The source's audio stream (for HLS, the one in the chosen variant) is decoded
by the same ffmpeg copy that decodes the video (AAC, or any decoder the copy
has), resampled by libswresample to S16 stereo 48 kHz, and written to the ALSA
PCM `default` (override with `RNI_AUDIO_DEVICE=<pcm name>`). libasound.so.2 and
libswresample are loaded at run time, so the engine starts without them.

- The video clock is the master. A sound thread keeps each sample within 40 ms
  of the clock, counting the device's own delay (`snd_pcm_delay`); late audio
  is skipped and early audio waits. The device buffer is 200 ms.
- Rate other than 1: muted. There is no pitch-keeping time stretch, so the
  thread drops what is queued in the device and skips the audio the clock
  passes. Sound comes back in sync when the rate returns to 1.
- Pause, seek and loading: the device is emptied at once (`snd_pcm_drop`), so
  sound stops immediately rather than after the buffer.
- No sound never stops the picture. The video reader is gated by the video
  queue only. If the sound thread stops draining (a blocked device), its
  packets are dropped once they are 12 s ahead, and the video keeps playing at
  full rate. When sound fails the thread stops reading audio for good.
- The PCM is opened non-blocking. A write waits at most 50 ms for room, so
  `release()` (which joins the sound thread on the JS thread) returns at once
  even when the device is stuck, and a device that takes no samples for 4 s
  is reported as failed. A blocking write would sit in the kernel until its
  DMA timeout, about 10 s.

Status (`getStatus()` and the package's `player.stats`):

| Field | Values |
| --- | --- |
| `audio` | `"none"` (no audio stream, or not opened yet), `"on"`, `"muted"` (rate is not 1), `"error: <why>"` |
| `audioFrames` | 48 kHz frames written to the device so far |

The error strings, exactly as the engine reports them (also printed as
`rn-impeller: video id=N audio off: <why>`):

- `error: no ALSA library: libasound.so.2 does not load (<dlerror>)`
- `error: ALSA device 'default' does not open: <snd_strerror>`, for example
  `No such file or directory` when there is no card or the card has no
  playback PCM (a capture-only codec)
- `error: ALSA device 'default' refuses S16 stereo 48 kHz: <snd_strerror>`
- `error: ALSA write on default: <snd_strerror>`, when the device fails
  mid-play, for example `No such device` (unplugged)
- `error: ALSA device 'default' took no samples for 4 s` (a stuck device)
- `error: ffmpeg 8 missing libswresample.so.6 (<dlerror>)`, and the other
  libswresample load failures
- `error: open audio decoder: ...`, `error: audio decode: ...`,
  `error: audio resampler: ...`

What the image needs for sound:

1. `IMAGE_INSTALL += "alsa-lib"` (libasound.so.2) and ffmpeg's
   `libswresample` (oe-core's ffmpeg recipe enables `swresample` by default).
   The bench board image on 2026-11-01 already has both
   (`/usr/lib/libasound.so.2.0.0`, `/usr/lib/libswresample.so.6.1.100`).
2. A card with a PLAYBACK PCM from the device tree, which `default` resolves
   to. Check with `cat /proc/asound/pcm`: the line must say `playback 1`. A
   capture-only card (the ES7202 PDM microphone ADC) fails with
   `ALSA device 'default' does not open: No such file or directory`, and the
   video still plays. On 2026-11-01 the bench board listed card 0
   `rockchip-es8388` (`00-00: ... playback 1 : capture 1`) and card 1
   `rockchip,es7202` (`01-00: ... capture 1`).

On the board, a board run runs the fixture in a hidden window
on the kiosk's Weston (the display and the console service are left alone): a
`file` plugin capture of the marker HLS, the real `default` PCM with a
digital-silence HLS (nothing audible), and the capture-only card by name.

## TLS

ffmpeg 8 does NOT verify certificates by default (`TLS_VERIFY_DEFAULT` is 0
until avformat 63), and the hls demuxer passes only headers, user_agent,
cookies, http_proxy, referer, rw_timeout and icy on to its playlist, segment
and key requests. The player therefore sets `tls_verify=1` on every request
it makes, through an `AVFormatContext.io_open` wrapper. A TLS request that
returns without consuming `tls_verify` is refused.

- Trust comes from the system CA store. `RNI_VIDEO_CA_FILE=<pem>` replaces it
  (use it for a LAN test server with its own CA).
- OpenSSL checks the hostname for DNS names only. For an IP-literal URL
  (`https://<lan-ip>/...`) ffmpeg verifies the chain but skips the
  hostname check (`tls_openssl.c`: `numerichost`).

## Hardware decode (rkmpp)

The console's ffmpeg 8.0.1 has `h264_rkmpp`, `hevc_rkmpp` and `vp9_rkmpp`
(also `vp8_rkmpp`, unused), which decode on the RK3588 VPU through
`/dev/mpp_service`. ffmpeg lists its software decoder first for each codec
(n8.0.1 `allcodecs.c:152` h264, `:158` h264_rkmpp), so `av_find_best_stream`
never picks rkmpp. The player (`engine/video/FfmpegCopyHw.cpp`) asks for it by
name and uses it only when:

- `RNI_VIDEO_HW` is not `0`. `RNI_VIDEO_HW=0` forces software, so one build can
  A/B the two (like `RNI_MEM_TRIM=0`);
- the stream is 8-bit 4:2:0 (yuv420p/yuvj420p). rkmppdec gives every MPP format
  other than NV12 the software format NONE (`rkmppdec.c:360`), so a 10-bit or
  4:2:2 frame could not be copied out, and a file that plays in software today
  would fail on the VPU;
- `avcodec_open2` succeeds. A missing device, or no permission on it, fails
  here, and the software decoder opens exactly as before.

Otherwise nothing changes: the software decoder gets `thread_count=0` (one
frame thread per core, `av:h264:df*`). The rkmpp decoder gets no thread count.

rkmpp hands out `AV_PIX_FMT_DRM_PRIME` frames only (NV12 dmabufs,
`rkmppdec.c:162, 389`). `av_hwframe_transfer_data` copies each shown frame into
a reused NV12 frame (`hwcontext_drm.c:223-252` maps the dmabuf and copies the
planes at MPP's pitch), then the same swscale path converts it to RGBA. Step A
keeps that CPU copy and convert; zero-copy (EGLImage import) is step B.

rkmpp takes at most 4 queued packets (`rkmppdec.c:46, 499`). Past that,
`avcodec_send_packet` returns EAGAIN and keeps nothing (`decode.c:717`). The
player then reads the decoder's output and sends the SAME packet again. Before
this change, that packet was dropped. Any other send error is logged
(`rn-impeller: video decoder <name> refused a packet: <error>`) and the packet
is skipped, as before.

One line per opened stream, then the reason when it is software:

```
rn-impeller: VIDEO_DECODER source=1 codec=h264_rkmpp hw=1 convert=sws
rn-impeller: VIDEO_DECODER source=1 codec=h264 hw=0 convert=sws
rn-impeller: video id=1 hw decode off: no h264_rkmpp decoder in this ffmpeg
```

Reasons: `RNI_VIDEO_HW=0`, `no rkmpp decoder for <codec>`, `no <name> decoder
in this ffmpeg`, `<name> hands out NV12 only and this stream is <pix_fmt>`,
`<name> did not open (<error>)`.

What each place proves:

- linux-x64 (`ci-video-ffmpeg8.sh`): no ffmpeg on the dev host has rkmpp, so
  every play must print `hw=0` with `no h264_rkmpp decoder in this ffmpeg`, and
  `RNI_VIDEO_HW=0` must give that reason instead (arm HW0). Videos play as
  before (every video gate). Mutants M5 (hw=1 on the fallback) and M6 (env var
  ignored) are killed.
- arm64 under qemu: the same fallback line. qemu has no VPU, so nothing about
  the hardware path is proven there.
- The board only (a board check): that rkmpp opens
  (`hw=1`, `/dev/mpp_service` held, no `av:h264:df*` threads), the EAGAIN
  resend, the DRM_PRIME copy-out, frames shown and dropped, and CPU%.

## What the board image needs

Checked against oe-core wrynose `ffmpeg_8.0.1.bb` and FFmpeg n8.0.1
`configure`:

1. TLS, which https and https HLS need. The recipe's default PACKAGECONFIG
   has no TLS library, and configure autodetects none, so `https://` fails
   with "Protocol not found". Add this to
   `recipes-multimedia/ffmpeg/ffmpeg_%.bbappend`:

   ```
   PACKAGECONFIG:append = " openssl"
   USE_NONFREE = ""
   ```

   The recipe sets `USE_NONFREE` whenever `openssl` is on (line 88), and that
   makes the libraries "nonfree and unredistributable". n8.0.1 configure
   (line 7265) accepts OpenSSL >= 3.0 without `--enable-nonfree` when `gpl`
   is off. The image has no `gpl`, and wrynose ships openssl 3.5.6. The dev
   build (`tools/ffmpeg8-fetch.sh --arch x64 --tls`) configures this way and
   prints `License: LGPL version 2.1 or later`. The image prints version 3,
   because of rkmpp's `--enable-version3`. On the board, check with
   `ffmpeg -protocols | grep -w https`.
2. HLS: nothing to add. The hls demuxer and http protocol are on by default,
   and AES-128 HLS uses ffmpeg's built-in crypto protocol.
3. Hardware decode: the console service runs as `weston` (uid 1000, groups
   include `video`), and on 2026-11-06 the bench board had
   `crw------- root root /dev/mpp_service`, which the kiosk user cannot open.
   `h264_rkmpp` should then fail to open and the player fall back to software;
   the KIOSK run of the board check shows what happens. The image needs a
   udev rule like its `99-dma-heap.rules`, for example
   `KERNEL=="mpp_service", MODE="0660", GROUP="video"`.

## Gates

- `tools/ci-video-net.sh` runs on linux-x64 with the TLS ffmpeg 8 and a local
  test server (`tools/video_net_server.py`). It has 10 arms: VA, HLS, LIVE,
  LAG, SLOW, THROTTLE, E404, FILE, TLS and STALL. The script header describes
  each one.
- `tools/mutation-verify-video-net.sh` checks 9 mutants, and each one must be
  killed by its own arm.
- `tools/ci-video-ffmpeg8.sh` PKG checks the per-copy sources for shared
  COMDATs that name an ffmpeg type. Every play asserts the `VIDEO_DECODER`
  line, and arm HW0 runs with `RNI_VIDEO_HW=0`.
- `tools/ci-video-audio.sh` (linux-x64) has 7 arms: TONE, SYNC, LOST, HANG,
  HANGREL, NODEV and NOLIB. WSL has no sound card and no snd-aloop, so it uses two
  stand-ins. TONE and NODEV run the real alsa-lib with `ALSA_CONFIG_PATH` (a
  `file` plugin writing raw PCM, and a missing `hw` card). SYNC, LOST, HANG and
  HANGREL use `tools/alsa-paced/alsa_paced.c`, a stand-in libasound.so.2 that drains a
  200 ms ring at 48 kHz on a real-time clock, starts at a full buffer like
  `snd_pcm_set_params` sets up, and records what is heard, so the gate can
  measure A/V offset against the video clock. NOLIB hides libasound.so.2 with
  a private mount namespace. The script header describes each arm.
- `tools/mutation-verify-video-audio.sh` checks 8 mutants, and each one must
  be killed by its own arm.
