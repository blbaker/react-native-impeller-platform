# linux-arm64 web view environment. ONE arm64 Debian sid image is
# both:
#   - the multiarch arm64 SYSROOT the WPE WebKit 2.54 cross build compiles
#     against (tools/webview-arm64/wpe-cross-build.sh exports it), and
#   - the qemu-aarch64 RUNTIME the gate (tools/ci-webview-arm64.sh) runs the
#     arm64 rn-impeller + rni-webhelper in: headless Weston kiosk-shell, Mesa
#     llvmpipe, and the rni-touch-inject Weston module for wl_touch taps.
# Same image for both = the libraries WebKit was linked against are the ones it
# loads. sid, not bookworm: it carries the wpewebkit 2.54 source, so build-dep
# pulls the same dependency set the x64 image (wpe-ocdm:sid) was built from.
FROM --platform=linux/arm64 debian:sid
ENV DEBIAN_FRONTEND=noninteractive
RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources \
 && apt-get -o Acquire::Retries=3 update \
 && apt-get -o Acquire::Retries=3 build-dep -y --no-install-recommends wpewebkit \
 && apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
      g++ cmake ninja-build pkg-config file binutils python3 procps ca-certificates \
      gstreamer1.0-libav gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
      gstreamer1.0-plugins-bad libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
      libegl1 libgles2 libegl-mesa0 libgl1-mesa-dri libgbm1 libegl-dev libgles-dev libdrm-dev \
      libwayland-client0 libwayland-cursor0 libwayland-egl1 libxkbcommon0 libdecor-0-0 \
      weston libwayland-dev wayland-protocols \
      fontconfig fonts-dejavu-core libfreetype6 libfontconfig1 libnspr4 \
 && apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
      "$(apt-cache search --names-only '^libweston-[0-9]+-dev$' | cut -d' ' -f1 | sort -V | tail -1)" \
 && rm -rf /var/lib/apt/lists/*
