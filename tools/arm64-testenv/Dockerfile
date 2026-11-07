FROM --platform=linux/arm64 debian:bookworm
# Runtime test rootfs for the rn-impeller linux-arm64 package (stand-in for the
# RK3588 board userspace until a board is reachable). Mesa llvmpipe for GLES,
# weston (headless backend) for the Wayland path, Xvfb for the X11 path.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libegl1 libgles2 libgl1-mesa-dri libgbm1 libegl-mesa0 \
      libwayland-client0 libwayland-cursor0 libwayland-egl1 libxkbcommon0 libdecor-0-0 \
      weston xvfb xauth libx11-6 libxcursor1 libxi6 libxrandr2 libxinerama1 libx11-xcb1 \
      fontconfig fonts-dejavu-core libfreetype6 libfontconfig1 \
      libstdc++6 libatomic1 ca-certificates file binutils python3 procps \
    && rm -rf /var/lib/apt/lists/*
