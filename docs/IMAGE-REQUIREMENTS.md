# rn-impeller on a linux-arm64 image: what the image must provide

For the author of the console image recipe. Source:
linux matrix M7 on feat/linux-arm64. Everything here was measured under qemu-aarch64
with Mesa llvmpipe. There was no board, so anything that needs one is listed at
the end as UNVERIFIED-ON-HARDWARE.

## The package

`engine-linux-arm64.tar.gz` (made by `tools/package-engine-linux.sh --arch
arm64`) holds one directory, `engine-linux-arm64/`:

- `rn-impeller`: the engine. RUNPATH is `$ORIGIN`, so it finds the two libraries
  next to it.
- `libimpeller.so`, `libhermesvm.so`: these need only the C and C++ runtime.
- `rni-webhelper`: the web view helper. It links the image's WPE WebKit. Its
  rpath is `$ORIGIN`, and no path from the build machine ships.
- `BUILD-INFO`: git sha, Impeller SDK sha, sysroot sha, the WPE version the
  helper was built against, glibc and GLIBCXX floors, the ffmpeg copies built
  and the ffmpeg header versions.

Install all four files into one directory, for example `/opt/rn-impeller/`. The
engine finds `rni-webhelper` when it sits next to `rn-impeller`.

What the tarball does NOT bundle: WPE WebKit, WPEPlatform, libwpe, libsoup,
GLib, the OpenCDM library, the Widevine CDM, ffmpeg, EGL/GLES and Wayland. The
image provides all of them.

Floors (BUILD-INFO): the engine needs glibc 2.35 and GLIBCXX_3.4.30.
rni-webhelper needs glibc 2.38, because it was cross-built against Debian
sid's WPE stack. The image's glibc 2.43 meets both. Debian bookworm (2.36) runs
the engine but cannot run the helper.

## Libraries

### Linked (DT_NEEDED): the loader refuses to start without them

- libEGL.so.1, libGLESv2.so.2: from any vendor, libmali (rockchip-libmali) or Mesa
- libwayland-client.so.0: wayland
- libssl.so.3, libcrypto.so.3: openssl 3
- libatomic.so.1: gcc-runtime (found by the M1 launch check)
- libstdc++.so.6, libgcc_s.so.1, libm, libc: gcc-runtime, glibc

If one is missing, `rn-impeller` exits 127 and the loader names the library.
Yocto's shlibdeps adds these automatically when the recipe installs the
binaries.

### Loaded with dlopen: list these as RDEPENDS by hand

shlibdeps cannot see a dlopen, so the recipe has to list these.

- libwayland-cursor.so.0: GLFW's Wayland backend. If missing, glfwInit fails and there is no window.
- libwayland-egl.so.1: GLFW's Wayland backend. If missing, glfwInit fails and there is no window.
- libxkbcommon.so.0: GLFW's Wayland backend. If missing, glfwInit fails and there is no window.
- libfontconfig.so.1, plus at least one font: system font lookup. If missing, text falls back to bundled fonts only.

The recipe names are wayland, libxkbcommon and fontconfig. They are recipe names,
not package names, so check the package split in the layer. On libmali,
`libwayland-egl.so.1` still comes from the wayland recipe (rockchip-libmali.bb
builds with `-Dwayland-egl=false`, and Rockchip's HACK patch forwards it to the
blob).

Optional dlopens, reported but never required:
- `libgbm.so.1`: the GBM rung of the headless EGL ladder. libmali ships one.
- `libX11.so.6` and GLFW's other X11 libraries: the X11 backend. The board has no
  X11. libmali's X11 flavour needs DRI2, so leave X11 out.
- `libdecor-0.so.0`: not wanted. Under kiosk-shell the engine turns decorations
  off itself.

### Web view: WPE WebKit 2.54 + WPEPlatform

`rni-webhelper` NEEDs `libWPEWebKit-2.0.so.1 libwpe-1.0.so.1 libsoup-3.0.so.0
libgio-2.0.so.0 libgobject-2.0.so.0 libgmodule-2.0.so.0 libglib-2.0.so.0`. That
means meta-webkit `wpewebkit` 2.54.x (2.54.1 on wrynose; the helper was built
against 2.54.0 headers), plus libwpe, libsoup and glib-2.0. WPEPlatform (headless)
is inside libWPEWebKit-2.0 in 2.54. The WPE runtime libraries are NOT bundled.
They must come from the image.

For EME, wpewebkit needs `PACKAGECONFIG` `encryptedmedia thunder`. Its
libWPEWebKit then NEEDs `libocdm.so.1`, and that file is the DRM backend. Ours
is the OpenCDM shim (wpe-impeller-probe 9a97508, `ocdm-shim/`), packaged by a
recipe that PROVIDES `virtual/open-cdm`. The shim is not in this tarball. Details
are in `docs/eng/webview-wpe.md`, "DRM: the CDM plug point is libocdm.so.1".

Without WPE the engine still runs. A `<WebView>` then gets onError, and the
doctor names the missing library (see "Proving it on the image").

### Video: ffmpeg 8.0.1 (optional)

The engine dlopens ffmpeg; it links no libav* or libsw* library. It compiles
its decoder once per ffmpeg release (copies 8 and 6) and picks the newest copy
whose libraries load AND report the major versions it was compiled against.
For the image's ffmpeg 8.0.1, all five libraries must be present:

`libavutil.so.60 libavcodec.so.62 libavformat.so.62 libswscale.so.9 libswresample.so.6`

The engine never opens libswresample itself, but libavcodec NEEDs it (the opus
decoder uses it). Without it libavcodec does not load. The doctor then says
`dlopen.ffmpeg.8=missing:libavcodec.so.62`, and `video.status` quotes
`libswresample.so.6: cannot open shared object file`.

Decode is software only (oe-core keeps its software decoders and swscale). The
image's rkmpp hardware decoder is not used. Without ffmpeg the engine still runs:
video reports `video.status=unusable:...`, and creating a player rejects in JS
with the same reason.

The image pins openembedded-core at `yocto-6.0`, whose `ffmpeg_8.0.1.bb` has the
same tarball sha256 we build against (05ee0b03...5a41). oe-core master is on
ffmpeg 9.0.2 (libavcodec.so.63, libavformat.so.63), and the 8,6 selector refuses
that. It matters only if the layer pin moves past wrynose.

### The Widevine CDM (arm64)

The CDM is the board BSP layer lacros arm64 file, Widevine 4.10.2662.3, after the
Asahi glibc fixup (sha256 8cb3119cd4f319ea...). It runs in WPEWebProcess, loaded
by the shim from `OCDM_WIDEVINE_CDM`. Defects in the recipe (the board BSP layer (d1a00c8,
its widevine-cdm recipe):

1. `files/widevine_fixup.py` applies 0 patches; its output is byte-identical
   to the lacros file. Use AsahiLinux/widevine-installer `widevine_fixup.py` (MIT).
2. The as-built file fails dlopen on glibc 2.36 and newer with `DT_RELR without
   GLIBC_ABI_DT_RELR dependency`. The board's glibc 2.43 has the same check. The
   Asahi fixup adds the version need and makes the two
   `__aarch64_ldadd4/swp4_acq_rel` imports weak.
3. The file NEEDs `libnspr4.so`, but the recipe's RDEPENDS lists only glibc
   (`file-rdeps` QA is skipped). It loads today only because Chromium pulls nspr
   into the image. A WPE-only image needs `RDEPENDS += "nspr"`.

## Kernel

Recommended, not required: the system dma-buf heap, `/dev/dma_heap/system`,
openable by the engine's user. The web view will allocate its frame slots
there (card 13). Without it the engine still runs, and the web view's frame
slots use shared memory (memfd).

- Kernel config: `CONFIG_DMABUF_HEAPS=y` and `CONFIG_DMABUF_HEAPS_SYSTEM=y`.
  The board kernel has both, plus `CONFIG_DMABUF_HEAPS_CMA=y`;
  `CONFIG_UDMABUF` is not set and is not needed (the vendor rockchip-kernel
  802308e, the vendor rk3588 defconfig).
- The kernel creates the node as root-only 0600. A non-root engine needs this
  udev rule, and its user must be in group `video`. Root needs no rule.
  On the board image the engine runs as `weston`, the same user as the
  kiosk unit (already in `video` and `render`), so it needs the rule. The
  image layer adds it. Until it ships, expect `dma_heap=system:eacces`.

```
SUBSYSTEM=="dma_heap", KERNEL=="system", GROUP="video", MODE="0660"
```

- The CMA heap is not used. CMA is 16 MB on the board, three 1080p RGBA slots
  need about 25 MB, and the Mali-G610 has its own MMU.
- The doctor line: `dma_heap=system:<ok|enoent|eacces|error> cma:<present|absent>`.
  When `system` is not ok, `dma_heap.hint=` says why; on `eacces` it names the
  rule above. The doctor opens and closes the node and allocates nothing.
  `cma` means any heap other than `system` and `system-uncached`, reported for
  information only.

## Device nodes

- libmali (vendor 6.1 BSP, mali_kbase): `/dev/mali0`.
- Panthor or Mesa: `/dev/dri/renderD128` (any `/dev/dri/renderD*`;
  `RNI_DRM_RENDER_NODE` picks one for the GBM rung).
- Weston owns `/dev/dri/card*` and `/dev/input/event*`. The engine is a Wayland
  client and opens neither.
- `/dev/dma_heap/system`: recommended, see "Kernel" above.

The engine's user needs read/write on the GPU node (`video` or `render` group).

## Environment

- `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`: reach Weston (both required for a window)
- `XDG_SESSION_TYPE=wayland`: picks Wayland even if `DISPLAY` is set
- `RNI_GLFW_PLATFORM=wayland` or `x11`: forces the backend
- `RNI_WAYLAND_APP_ID`: xdg_toplevel app_id, default `rn-impeller` (kiosk-shell `app-ids=`)
- `RNI_WAYLAND_DECORATED=1`: GLFW's own frame (desktop compositors only; kiosk-shell rejects it)
- `RNI_EGL_PLATFORM=surfaceless`, `gbm` or `default`, `RNI_EGL_FORCE_PBUFFER=1`, `RNI_DRM_RENDER_NODE`: the headless EGL ladder
- `RNI_FONT_DIRS`: extra font directories
- `RNI_STORAGE_DIR`: AsyncStorage directory
- `RNI_WEBHELPER`: helper command (default: `rni-webhelper` next to the engine)
- `RNI_WEBVIEW_DATA_DIR`: web view cookies and storage (default `$XDG_DATA_HOME/rn-impeller/webview`)
- `OCDM_WIDEVINE_CDM`: path of the Widevine CDM file, read by the shim

`RNI_TEST_*`, `RNI_FORCE_*`, `RNI_*_LOG` and `RNI_DOCTOR_DMA_HEAP_DIR` (the
doctor's dma-heap directory, default `/dev/dma_heap`) are for tests and
diagnostics.

## systemd unit (template, not run under systemd here)

```ini
[Unit]
Description=rn-impeller console app
After=weston.service
Requires=weston.service

[Service]
User=weston
SupplementaryGroups=video render
Environment=XDG_RUNTIME_DIR=/run
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_SESSION_TYPE=wayland
Environment=OCDM_WIDEVINE_CDM=/usr/lib/chromium/libwidevinecdm.so
ExecStart=/opt/rn-impeller/rn-impeller --window --quit-on-term \
  --bundle /opt/console/app.jsbundle --app-name Console
Restart=on-failure

[Install]
WantedBy=graphical.target
```

`--quit-on-term` makes SIGTERM a clean exit 0. Under kiosk-shell the surface
always fills the output. `XDG_RUNTIME_DIR=/run` and `WAYLAND_DISPLAY=wayland-0`
match the image's own kiosk service unit. Match the CDM
path to the widevine-cdm recipe. The unit has not been run on a board.

The unit grants no capabilities. The low-memory purge
(`engine/host/MemoryPressure.cpp`) first sets a PSI trigger on
`/proc/pressure/memory`. On the vendor 6.1 kernel, opening that file for writing
needs CAP_SYS_RESOURCE (`kernel/sched/psi.c:1371` at v6.1), so the open fails
with EPERM. rn-impeller then logs
`memory_pressure source=psi armed=0 ... step=open errno=1 (Operation not permitted)`
and `memory_pressure source=psi-poll armed=1 interval_ms=2000 ...`, and reads the
file every 2 s instead: the same 100 ms threshold, the same purge and the same
`low_memory source=linux-psi` line. Do not grant CAP_SYS_RESOURCE for this: it
also lets the process go past resource limits. From 6.5 an unprivileged process
may set the trigger itself, because the default window is 2 s.
`RNI_MEM_PSI=off` turns off both the trigger and the poll.

## Per-GPU notes

- libmali (Mali-G610, rockchip-libmali, Wayland flavour chosen by
  DISTRO_FEATURES): no `EGL_MESA_platform_surfaceless`, so the headless ladder
  falls through to GBM (libmali's libgbm) and then to a default-display 1x1
  pbuffer. The doctor prints each rung and why. X11 under Xwayland does not
  work (libmali X11 needs DRI2; Xwayland is DRI3 only).
- Panthor: needs a mainline kernel 6.10+ and Mesa 24.1+ for the G610. The vendor
  6.1 BSP uses mali_kbase. The engine uses the same EGL + GLES 3 sonames on both:
  it NEEDs no libmali, libGL or libX11.
- dmabuf zero-copy (web view frames) sits behind a run-time EGL extension check
  and falls back to CPU upload.

## Proving it on the image: `rn-impeller --doctor`

The doctor prints key=value lines and exits 0. On a correct image, expect:

```
image.needed_status=ok
image.missing=none
image.status=ok
egl.headless_init=ok
window.glfw_needs.wayland=libwayland-client.so.0:ok,libwayland-cursor.so.0:ok,libwayland-egl.so.1:ok,libxkbcommon.so.0:ok
dlopen.ffmpeg.8=ok
dlopen.ffmpeg.resolved=8
video.backend=ffmpeg
video.ffmpeg_abi=8
video.ffmpeg_abis_built=8,6
video.status=ok
webhelper.web_view_in_build=1
webhelper.check=ok:webkit=2.54.<n> built=2.54.0 eme=1
image.optional.webview=ok
dma_heap=system:ok cma:present
```

`dma_heap=system:ok` needs the udev rule under "Kernel" (or a root engine).
Without the rule a non-root engine prints `dma_heap=system:eacces` and a
`dma_heap.hint=` that names the rule; the web view then uses shared memory.

A missing required dlopen library shows up as `image.missing=<soname>` with
`image.status=incomplete`. A missing WPE library shows up as
`webhelper.check=fail:exit 127: ... <soname>: cannot open shared object file`.

## Test packages (the gate's stand-in image)

`tools/ci-package-linux.sh` builds an arm64 Debian bookworm image with exactly
the packages between the markers below, unpacks the tarball into it and runs the
doctor there. Its mutant check drops one package and expects the doctor to name
it. Bookworm has no WPE 2.54, so the web view arm runs the same tarball in the M5
image (`rni-webview-arm64:sid` with the cross-built WPE 2.54.0).

<!-- ci-package-linux: bookworm packages begin -->
```
libegl1 libgles2 libegl-mesa0 libgl1-mesa-dri libgbm1
libwayland-client0 libwayland-cursor0 libwayland-egl1 libxkbcommon0
libssl3 ca-certificates
libfontconfig1 fontconfig fonts-dejavu-core
libatomic1 libstdc++6 libgcc-s1
libnspr4
```
<!-- ci-package-linux: bookworm packages end -->

## Verified on the board (2026-10-30, Mac build of c1593ed)

- Windowed EGL on libmali: Wayland, GLES 3.0, `GL_RENDERER=Mali-G610`
- Single-finger touch from the real Weida panel and from evdev writes (kernel,
  libinput, Weston, `wl_touch`). Details: `docs/IMAGE-REQUIREMENTS.md`.

## UNVERIFIED-ON-HARDWARE (never reported as PASS)

- libmali's headless path (GBM or pbuffer)
- Panthor at all
- dmabuf zero-copy on libmali and on Panthor
- Multi-touch (WaylandTouch passes one finger only)
- G610 frame time; software ffmpeg decode time on the A76 cores
- Any timing on the board: first present, frame times, capture latency
- The image's own ffmpeg 8.0.1 binary (ours mirrors its configure, without
  libdrm/rkmpp/version3/zlib)
- The image's own wpewebkit 2.54.1 build, and Widevine on RK3588 hardware
- The doctor's dma_heap line on the board's real `/dev/dma_heap` (here only
  fixture directories: the WSL kernel has no dma heaps), and `cma:present`
- The systemd unit above
