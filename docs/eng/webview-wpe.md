# Web view on rn-impeller: WPE WebKit in a helper process

Status: linux-x64 v1 landed on `feat/webview-wpe` (gate `tools/ci-webview.sh`,
mutants `tools/mutation-verify-webview.sh`). linux-arm64 runs under qemu only
(linux matrix M5, gate `tools/ci-webview-arm64.sh`, see "linux-arm64 under qemu"
below). Nothing has run on the board (libmali, Weston on the panel): that part
of this doc is still the contract, UNVERIFIED-ON-HARDWARE.

## Shape

```
JS  <WebView> (package/src/webview, react-native-webview API; metro maps the package name here)
     |  ImpellerWebView TurboModule (engine/modules/WebViewModule.h)
     v
rn-impeller  WebViewHost (engine/webview/WebViewHostLinux.cpp, WebHelperLink.cpp)
     |  AF_UNIX SOCK_SEQPACKET, protocol v1 (engine/webview/WebViewProtocol.h)
     |  frames: 3-slot memfd per view, fd passed once with SCM_RIGHTS
     v
rni-webhelper  (engine/webview/helper/*.cpp, links libWPEWebKit-2.0 + WPEPlatform headless)
     |  WebKit EME -> libocdm.so.1 (OpenCDM C API)  <- THE CDM PLUG POINT
     v
CDM (L3: Google library CDM via our OpenCDM shim; L1: Thunder + Widevine CE CDM + OEMCrypto TA)
```

Each web view is an FP-42 `ExternalTexture` producer, painted by
`<ImpellerTextureView textureId>` like a video: it clips, transforms and fades
with the RN tree. The engine binary links no GLib, WebKit or CDM; without a
helper, `create` fails and the component fires `onError`.

Why a process: WebKit is already multi-process; the UI-process half needs a
GLib main loop the engine does not run; a renderer crash must not take the app
down; and on WSL WebKit only exists inside a container (Ubuntu 24.04 has no
WPE packages), so the same engine binary drives a containerised helper here
and a native one on the device.

Helper lifetime: at engine exit (after the windowed run, so every view's
`kDestroy` is already sent) `WebViewHost::Shutdown` sends `kQuit`, reaps the
helper within `$RNI_WEBHELPER_EXIT_MS` (default 3000; a hang-up and 1 s more if
it ignores kQuit) and prints `rn-impeller: webview_helper_exit pid=P code=C ms=M`
(or `signal=S` / `timeout_ms=`). Every gate run with a real helper requires
`code=0`, each `webview_destroy` matched by the helper's `view N destroyed`, and
no glibc abort line (`webview_check.py helper-exit`). Until 2026-10-19 the
helper aborted on every view destroy (`DestroyView` deleted a View that
`H().views`' unique_ptr deleted again) and every gate stayed green, because
only the engine's exit status was read.

## Frames (v1 = CPU/SHM, as agreed)

WPE headless `buffer-rendered` -> `wpe_buffer_import_to_pixels` -> BGRA->RGBA
swizzle into a free memfd slot -> `FRAME(gen, slot, w, h, seq)`. The engine
copies the slot into an `ExternalFrame`, answers `RELEASE_SLOT`, and marks the
texture. With all 3 slots held the newest frame waits and is written on the
next release, so a static page's last frame is never dropped.

DMA-BUF next step (measure on the board first): WPE gives `WPEBufferDMABuf`
(fd, fourcc, modifier, planes). Send those fds instead of a memfd slot and
import them in the engine as `EGLImage` -> GL texture ->
`ImpellerTextureCreateWithOpenGLTextureHandleNew` (the ExternalFrame
"backend texture" contract). The protocol change is one message type.

## Input model (engine/webview/WebViewInput.cpp)

- hover, right, middle -> WPE pointer events (mouse source)
- left press .. drag .. release -> ONE touch sequence. WebKit's gesture
  controller (WPEWebViewPlatform.cpp `handleGesture`) turns an unconsumed tap
  into a click and a drag into a scroll; pages with touch handlers get real
  touches. This is the touchscreen's behaviour, so device and desktop match.
- wheel over a view -> page scroll (consumed: an RN ScrollView behind it stays)
- keys -> the focused view (focus = last press in it); text arrives through
  the char callback (layout and dead keys honoured), chords (Ctrl/Alt/Meta+key)
  as key events.

### App-drawn keyboard (the device has no OS input method)

- `onEditableFocus({nativeEvent: {focused, isPassword, purpose}})`, also raw as
  `impellerWebViewEvent` type `editableFocus`. The helper installs its own
  `WebKitInputMethodContext` per view (`helper/input.cpp`). WebKit's
  InputMethodFilter calls `notify_focus_in`/`notify_focus_out` when an editable
  gains or loses input focus while the view is focused, with `input-purpose`
  already set. Password fields DO use the input method on WPE
  (`PasswordInputType::shouldUseInputMethod`), so `isPassword` =
  `purpose == password`. Tapping straight from one field to another fires no
  focus-out/in, only an `input-purpose` change; that is reported too. A tap on
  the page outside the fields, or outside the web view, reports `focused:false`
  (purpose `null`); outside the web view only while `setKeepFocus` is off.
- `ref.sendText(text)` -> `kText` -> the context's `committed` signal, the
  signal a real IME commit uses: one `beforeinput insertText` with the whole
  string, any Unicode, no keysym mapping. WebKit fires one `keydown` with key
  `Unidentified` (keyCode 229) per commit, as browsers do for IME input. WebKit
  drops text when no page editable is focused; the helper logs any text sent
  while its last report was `focused:false`.
- `ref.sendKey(name)` -> the engine's `KeysymForKey` -> the same `kKey`
  down + up the GLFW key callback sends: Backspace Enter Tab Escape Delete
  Insert Home End PageUp PageDown Arrow* F1..F24. An unknown name throws.
  A key is asynchronous like a physical one: an `injectJavaScript` sent right
  after it can run before the page has seen the key (measured), so read results
  from the page's own `input` event, not from a single inject.
- `ref.setKeepFocus(keep)` (TurboModule `setKeepFocus(id, keep)`). The app's keys
  are RN views outside the web view, and a press outside every web view blurs
  the page (`WebViewInput::MouseButton` -> `Focus(id, false)` ->
  `wpe_view_focus_out` -> `focused:false`), so the editable is gone before the
  key's `sendText` arrives (helper: `text sent while no editable has input
  focus`). While the flag is set for the focused view, that press keeps focus
  instead and logs `webview_input keep_focus id=N at=X,Y`; the press still
  reaches RN (the key's `onPress`). The flag lives in `WebViewHost` (JS thread
  sets, input thread reads, under a mutex); each change logs
  `webview keep_focus id=N on=0|1`. Set it when the keyboard opens, clear it
  when it closes. Clearing it on the focused view blurs that view
  (`webview keep_focus id=N on=0 blur=1`, then `focused:false`). Without that
  blur the field kept focus, and a tap on a field that already has focus
  changes nothing WebKit reports, so the console's keyboard could never reopen
  from the same field. The focused view id and the flag live together in
  `WebViewHost` under one mutex (`SetFocused` / `PressOutside` /
  `SetKeepFocus`, called from the input thread and the JS thread), and each
  `Focus()` is sent while holding it, so the helper sees focus changes in the
  order they were decided. Presses inside the page are unchanged (tapping the
  page outside a field still blurs the field, and the app should close its
  keyboard on that `focused:false`). `release(id)` clears it. The helper is
  unchanged.
- Wire: `kText = 16` is a new kind; no existing message changed, so the
  protocol stays v1. An older helper logs `unknown message type 16` and drops it.
- Gate `tools/ci-webview-osk.sh` (real XTEST taps, fixture `fixtures/webview-osk`),
  mutants `tools/mutation-verify-webview-osk.sh` (O1..O14; O9 proves
  `ci-webview.sh`'s physical typing arm catches a context that swallows keys;
  O10..O12 break setKeepFocus in the router, the clear, and the JS shim; O13
  drops the blur on clear, O14 blurs the page but leaves the engine's focus on
  the view). The gate runs 5 cycles of Done (an RN key) -> setKeepFocus(false)
  -> a tap on the same field, each of which must report `focused:true` again,
  and presses a physical key after the last Done, which must reach RN.

## react-native-webview surface (v1)

source.uri, source.headers (top-level request only), injectedJavaScript (after
every loaded page; bfcache restores do not re-run, as in WKWebView),
injectedJavaScriptBeforeContentLoaded, userAgent, onLoadStart, onLoad,
onLoadEnd, onError (cancelled loads are not errors; no WebKit error page),
onNavigationStateChange {url,title,loading,canGoBack,canGoForward}; ref
goBack, goForward, reload, stopLoading, injectJavaScript, clearCache.
Extras: `clearWebsiteData()` (member sign-out), `status()`, and the app keyboard
(`onEditableFocus`, ref `sendText`/`sendKey`/`setKeepFocus`, above).
Helper policy: persistent cookie jar (SQLite in the data dir), autoplay with
audio, window.open / target=_blank load in the same view, EME permission
allowed (WebKit denies it by default), everything else denied, no file upload.
Not in v1: onMessage/postMessage, source.html, file upload, popups, cursor
shapes from the page, IME preview.

## DRM: the CDM plug point is libocdm.so.1

WebKit is built with `-DENABLE_ENCRYPTED_MEDIA=ON -DENABLE_THUNDER=ON` and links
`libocdm.so.1`, importing exactly 15 OpenCDM functions:
`opencdm_create_system, opencdm_destruct_system, opencdm_is_type_supported,
opencdm_system_supports_server_certificate, opencdm_system_set_server_certificate,
opencdm_construct_session, opencdm_destruct_session, opencdm_get_system_session,
opencdm_session_id, opencdm_session_status, opencdm_session_update,
opencdm_session_load, opencdm_session_remove, opencdm_session_close,
opencdm_gstreamer_session_decrypt_buffer` (measured: `nm -D --undefined-only
libWPEWebKit-2.0.so`). Whatever provides `libocdm.so.1` IS the DRM backend;
WebKit, the helper and the engine do not change between backends.

Two providers:

1. L3, our shim (`~/projects/wpe-impeller-probe/ocdm-shim`, ~670 lines): hosts a
   Chromium-ABI library CDM through `cdm::Host_10`. Runtime path in
   `OCDM_WIDEVINE_CDM`. In Yocto: a recipe that PROVIDES `virtual/open-cdm`,
   so meta-webkit's `wpewebkit` `PACKAGECONFIG[thunder]` links it unchanged.
2. L1, RDK: ThunderClientLibraries `libocdm` + Thunder OCDM plugin + a Widevine
   CE CDM plugin, on an OEMCrypto TA for the SoC. Needs the Widevine CE CDM
   licence from Google and an RK3588 OEMCrypto/OP-TEE port. Same .so name and API.

## What the arm64 L3 CDM must provide (measured 2026-10-18)

Google's component updater serves `linux_arm64` Widevine 4.10.3112.0
(`omaha-widevine-query.py`; same version as x64). From that crx3:

- artifact: `_platform_specific/linux_arm64/libwidevinecdm.so`, ELF64 AArch64,
  NEEDED only libdl/libpthread/libm/libgcc_s/libc, glibc floor `GLIBC_2.17`,
  64 KiB-aligned LOAD segments (loads on 4K/16K/64K-page kernels)
- exports: `InitializeCdmModule_4`, `CreateCdmInstance`, `DeinitializeCdmModule`,
  `GetCdmVersion`, `VerifyCdmHost_0`
- manifest: `x-cdm-module-versions 4`, `x-cdm-interface-versions 10`,
  `x-cdm-host-versions 10,11`, codecs `vp8,vp09,avc1,av01`, schemes
  `cenc,cbcs`, no persistent licences
- the shim asks for `ContentDecryptionModule_10` and implements `Host_10`:
  an exact match. The shim itself must be rebuilt for aarch64 (no deps beyond libc/libdl).

The x64 4.10.3050.0 the gate uses exports the same five symbols. Downloading
the CDM grants no right to ship it: product use needs Google's agreement.

## Build and run

- WSL: `tools/webhelper-build.sh` (in the `wpe-ocdm:sid` image, against the
  10-01 probe prefix), then `RNI_WEBHELPER=tools/webhelper-docker.sh`.
  `RNI_WIDEVINE_CDM=<libwidevinecdm.so>` enables the CDM. That image was lost on
  2026-10-30; without it, `tools/webhelper-debian-x64.sh image|build|env` runs
  the helper on Debian sid's amd64 WPE 2.54.2 (the board tarball's WebKit, no EME).
- Device: build `engine/webview/helper/*.cpp` in a Yocto recipe against
  meta-webkit `wpewebkit` (2.54.1, wrynose) with `PACKAGECONFIG` `thunder
  encryptedmedia` plus `virtual/open-cdm` from the shim recipe; install
  `rni-webhelper` next to `rn-impeller` (found automatically there).
  WPE's headless platform needs no Wayland connection; WebKit renders through
  its own EGL/GBM (libmali). Untested on the board.

## linux-arm64 under qemu (linux matrix M5, 2026-10-19)

On the real board (2026-10-30), the bench board runs the web view from a self-contained
tarball: Debian's WPE 2.54.2 plus the helper, with no cross build. See
`docs/eng/webview-wpe.md`. The M5 qemu build below is still the EME/Thunder path.

No board: everything below runs under qemu-aarch64 (binfmt) on WSL with Mesa
llvmpipe. Anything that needs libmali, a real panel or real touch hardware is
UNVERIFIED-ON-HARDWARE.

Build (x86_64 host, two docker images):

1. `docker build --platform linux/arm64 -t rni-webview-arm64:sid tools/webview-arm64`
   (arm64 sid: WebKit build-deps, Weston + libweston dev, Mesa). It is both
   the cross SYSROOT and the gate's RUNTIME, so WebKit loads the exact
   libraries it was linked against.
2. `docker build -t rni-wpe-cross:sid -f tools/webview-arm64/Dockerfile.cross tools/webview-arm64`
   (the x64 `wpe-ocdm:sid` toolchain + aarch64 binutils).
3. `bash tools/webview-arm64/wpe-cross-build.sh all`: exports the sysroot, builds
   the OpenCDM shim natively under qemu, then cross-builds WPE WebKit 2.54.0
   (the x64 tarball) with clang `--target=aarch64-linux-gnu`: WPEPlatform
   headless, `ENABLE_ENCRYPTED_MEDIA=ON`, `ENABLE_THUNDER=ON` against the shim,
   JIT on. Output prefix `~/.cache/rni/wpe-arm64/prefix`, mounted at
   `/opt/rni-wpe` (WebKit's compiled-in path). The script checks that
   libWPEWebKit-2.0.so is aarch64 and NEEDS libocdm.so.1.
4. `bash tools/webhelper-build.sh --arch arm64` (cross clang, ~10 s, prints `eme=1`).
5. `bash tools/engine-build-linux-arm64.sh` (the arm64 rn-impeller, Wayland GLFW).

Measured times (load average 40-78 on 22 threads, other builds running):
sysroot export 34 s, shim 75 s, WebKit 7856 ninja steps in 3563 s (59 min, -j20).

Gate `bash tools/ci-webview-arm64.sh` (~40 s), in `rni-webview-arm64:sid`
under qemu: headless Weston 16 with kiosk-shell and the `rni-touch-inject`
module (tools/arm64-testenv), the arm64 engine as its Wayland client, the
committed webview bundle, pages from `fixtures/webview-arm64/pages`:

- pixels: 7 points (the RN bar + 6 page blocks) exact in the ENGINE's own
  `--screenshot` readback, taken by `--screenshot-when-file` once frames settle
- touch: wl_touch tap on the RN bar reaches no page; tap at window 100,145 is a
  page touchstart + click at page 100,105 on #btn
- nohelper (negative): RNI_WEBHELPER=/bin/false, onError reaches JS, exit 0
- the output names the WebKit sha, `thunder=yes|NO` (it refuses a WebKit
  without libocdm.so.1) and `jit=on|OFF`. JIT on works under qemu-user for
  this page; `RNI_ARM64_JIT=0` sets JSC_useJIT=0 if it ever stops working.

Mutants `MUTANTS="P T N" bash tools/mutation-verify-webview-arm64.sh` (P helper
swizzle, T touch origin, N dead-helper onError): killed=3 survived=0, each by its
own arm's rule, post-restore gate PASS, same engine sha after the restore
(1244 s; most of it is full engine rebuilds, see the first trap).

Traps:
- The sysroot is merged-usr (`lib -> usr/lib`). clang reaches libstdc++ via
  `lib/gcc/...`, ninja canonicalises the depfile path lexically, sees every C++
  header as missing, and rebuilt everything on every run (engine and WebKit).
  Fixed in both toolchain files with `--gcc-toolchain=<sysroot>/usr`
  (`CMAKE_<LANG>_COMPILER_EXTERNAL_TOOLCHAIN`): a no-op engine rebuild is now
  0 compile steps. A build tree configured before the fix rebuilds in full once.
- sid's `usr/include/<triple>/asm/*.h` are symlinks into `usr/lib/linux/uapi`:
  export that tree too, or every `<linux/types.h>` fails.
- WebKit's installed WPE{Web,Network,GPU}Process have no RUNPATH: the gate sets
  `LD_LIBRARY_PATH=/opt/rni-wpe/lib` (x64 does the same in webhelper-docker.sh).
  Symptom: "libWPEWebKit-2.0.so.1: cannot open shared object file" and a page
  that never loads.
- Under qemu the first web view frame lands seconds after the load event: the
  gate waits for a NEWER frame plus 3 quiet seconds before the capture.

## Widevine through the engine texture, x64 + arm64 (linux matrix M6, 2026-10-19)

Proof target (Mac decision 2026-10-18): the Shaka test asset sintel-widevine only,
licence from `https://cwip-shaka-proxy.appspot.com/no_auth`. Both arches load the
same `fixtures/webview/pages/eme.html` (Shaka 4.16, start at 120 s, audio off).
Measured: Shaka's own demo (`demo/common/assets.js`, main) pairs sintel-widevine
with `proxy.uat.widevine.com/proxy` and uses cwip-shaka-proxy only for its service
certificate. cwip-shaka-proxy issues the sintel licence anyway (x64 and arm64).

- x64: `ARMS="eme eme-nocdm eme-skipdecrypt" bash tools/ci-webview.sh` (~4 min).
  CDM 4.10.3050.0 (wv-cdm-probe). Since M6 the verdict reads the same 8 ENGINE
  readbacks as arm64 (`tools/webview_eme_series.py` drives the when-file), not
  the window through the X server, and `tools/webview_eme_check.py` judges both
  arches (provenance mode `off` on x64: the helper runs in docker; the shim's
  version line is reported). Measured: eme PLAYING (clock 121.4 -> 136.4 s, detail
  14.7-44.2, pairs 20-85% moving, 1500+ decrypts), eme-nocdm NOT_PLAYING (6006),
  eme-skipdecrypt NOT_PLAYING (detail median 7.0, 1 of 7 pairs moving). Mutants
  M9 (helper freeze) and M10 (series burst) in mutation-verify-webview.sh.
- arm64 under qemu: `ARMS="eme eme-nocdm eme-skipdecrypt eme-g3112" bash
  tools/ci-webview-arm64.sh` (~4 min). arm64 rni-webhelper + WPE 2.54 (M5), the
  aarch64 shim built into the M5 prefix, and the Asahi-fixed lacros CDM
  4.10.2662.3 (`~/projects/wv-arm64-ocdm-gate/work/cdm/asahi`, sha256 pinned in
  the gate: 8cb3119c...). The verdict reads 8 ENGINE readbacks, 2 s apart
  (`rn-impeller --screenshot-series 8`: after each capture the engine removes the
  `--screenshot-when-file` file and session.sh creates it again).
  Rules: `tools/webview_eme_check.py`: licence, first capture at t >= 120 s,
  median luma stddev >= 10 (as x64), and, because the captures are 2 s apart
  instead of 400 ms, page clock >= 7 s from the first capture to the last and
  >= 60% of pairs with >= 15% of the rect changing. Provenance: session.sh dumps `/proc/*/maps` once the shim is in use
  and after the last capture. Exactly one libwidevinecdm file may be mapped, with
  the pinned sha256 and a matching inode, by a process under rni-webhelper. It
  is WPEWebProcess: the shim, and so the CDM, lives in the web process.
- Arms, measured on 2026-10-19 (qemu-aarch64, llvmpipe):
  - eme: PLAYING. Licence accepted by the shim, 500+ decrypts, clock 126 -> 144 s
    over the series, detail 15-44 (7 of 8 captures), video at ~24 fps (frames 645,
    dropped 3 at t=149). Shaka picks the 426x182 H.264 rendition on BOTH arches
    (x64 too: w=427), with the same page.
  - eme-nocdm: NOT_PLAYING (shaka 6006, black rect, no CDM mapped).
  - eme-skipdecrypt: NOT_PLAYING (detail median 5.2, and 1 of 7 pairs moving).
  - eme-g3112: Google's 4.10.3112.0 also plays, and the provenance check REJECTS
    it (sha 46a70f3a... != pin).
- Trap: a mutation run edits the live tree. A keep-green gate that rebuilds the
  engine while it runs (ci-partial-repaint, ci-window) stages the MUTANT: the x64
  package once carried mutant S, and the x64 eme arm read 8 readbacks in one burst.
  Run nothing that builds in this worktree during mutation-verify.
- Mutants (`MUTANTS="F S" bash tools/mutation-verify-webview-arm64.sh`): F, the
  helper stops forwarding frames after the 10th; S, the series stops waiting for
  the gate (8 captures in a burst). Both must end NOT_PLAYING on the eme arm.
  S SURVIVED the first rule set (clock read from the last tick of the whole run,
  3% per pair): the burst spans 2.1 s of clock and moves 3-8% per pair. Hence the
  clock at the last capture and the 15% pair rule (real playback: 25-85%).
- Everything here is qemu + llvmpipe: libmali, the RK3588 video path and real
  frame rates are UNVERIFIED-ON-HARDWARE. The lacros CDM also needs libnspr4 on
  the image (IMAGE-REQUIREMENTS.md defect 3): `rni-webview-arm64:sid` has it.

