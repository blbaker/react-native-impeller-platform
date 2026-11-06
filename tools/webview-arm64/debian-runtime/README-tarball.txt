rni-webhelper + WPE WebKit 2.54.2 runtime for linux-arm64 (a Yocto board image)
Engine: react-native-impeller @SHA@. The helper is built from @SHA@:engine/webview/helper,
so it speaks that engine's WebViewProtocol v1.

Install (as root, next to rn-impeller):
  tar -xzf rni-webhelper-linux-arm64-@SHA@-wpe2.54.2.tar.gz -C /opt/rn-impeller-@SHA@
  ln -sfn /opt/rn-impeller-@SHA@/rni-wpe /opt/rni-wpe
  /opt/rn-impeller-@SHA@/bin/rn-impeller --doctor | grep webhelper.check
  -> webhelper.check=ok:webkit=2.54.2 built=2.54.2 eme=0

Layout:
  bin/rni-webhelper                                  RUNPATH $ORIGIN/../rni-wpe/lib
  rni-wpe/lib/*.so.*                                 RUNPATH $ORIGIN (141 libraries the image lacks
                                                     or ships older: glib 2.90, libstdc++ 16, soup 3.8)
  rni-wpe/lib/gio/modules/libgiognutls.so            https for libsoup (gnutls; trust store
                                                     /etc/ssl/certs/ca-certificates.crt from the image)
  rni-wpe/libexec/wpe-webkit-2.0/WPE{Web,Network,GPU}Process, injected-bundle/
  rni-wpe/libexec/rni-no-sandbox, rni-wpe/b -> it    bubblewrap stand-in (below)
  rni-wpe/share/                                     this file, MANIFEST.sha256, DEBIAN-VERSIONS.txt

Why the one symlink (/opt/rni-wpe): three paths are compiled into Debian's binaries, with no
runtime override in a release build. Each string is repointed in place at the same length
(extra slashes pad it), so nothing else in the library moves:
  - PKGLIBEXECDIR / PKGLIBDIR in libWPEWebKit (Source/WebKit/Shared/glib/ProcessExecutablePathGLib.cpp;
    WEBKIT_EXEC_PATH is read only in DEVELOPER_MODE builds) -> /opt/rni-wpe/libexec/wpe-webkit-2.0
  - GIO_MODULE_DIR in libgio -> /opt/rni-wpe/lib/gio/modules
  - BWRAP_EXECUTABLE in libWPEWebKit -> /opt/rni-wpe/b. In 2.54's 2022 GLib API the web process sandbox
    is always on (WebKitWebContext.cpp setSandboxEnabled(true)). The image has no bubblewrap, so
    WebKit runs `<bwrap> --args <fd> -- <command>` (BubblewrapLauncher.cpp). rni-no-sandbox closes
    the fds meant for bwrap and execs <command>. That is what a WebKit built with
    ENABLE_BUBBLEWRAP_SANDBOX=OFF does (meta-webkit's usual configuration, and the M5 cross build).
    In short, the web process runs UNSANDBOXED, the same as before this drop.

Taken from the IMAGE (never bundled): glibc 2.43 (libc, libm, libresolv, ld-linux) and the GPU
stack: libEGL.so.1, libgbm.so.1 (libmali), libdrm.so.2, libGL.so.1. Every gbm_/drm/egl symbol the
bundle imports was checked against the image's libgbm/libmali/libdrm/libEGL exports: none missing.

Not in this drop:
  - EME/Widevine: Debian's WebKit has no Thunder/OpenCDM.
  - GStreamer plugins: the gstreamer core libs are bundled because libWPEWebKit NEEDs them, but no
    plugins ship, so <video> and <audio> will not play.
Source of WebKit: Debian sid libwpewebkit-2.0-1 2.54.2-1 (arm64), see DEBIAN-VERSIONS.txt.
