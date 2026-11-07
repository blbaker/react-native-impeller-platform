# Cross toolchain for WPE WebKit 2.54 + rni-webhelper, x86_64 -> aarch64-linux-gnu.
# Used INSIDE the rni-wpe-cross:sid container (wpe-ocdm:sid + aarch64 binutils),
# where the arm64 Debian sid sysroot (exported from rni-webview-arm64:sid, the
# same image the gate runs in) is mounted at /sysroot. clang 21 + lld from the
# x64 image; every header and library comes from the sysroot.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(_triple aarch64-linux-gnu)
set(_sysroot /sysroot)
set(CMAKE_SYSROOT ${_sysroot})

set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_ASM_COMPILER clang)
set(CMAKE_C_COMPILER_TARGET ${_triple})
set(CMAKE_CXX_COMPILER_TARGET ${_triple})
set(CMAKE_ASM_COMPILER_TARGET ${_triple})
# ⛔ POINT CLANG AT THE GCC INSTALL UNDER usr/, NOT THE MERGED-/usr SYMLINK.
# The sid sysroot has lib -> usr/lib, so clang finds GCC at
# /sysroot/lib/gcc/aarch64-linux-gnu/16 and names libstdc++ headers as
# /sysroot/lib/gcc/.../16/../../../../include/c++/16/... in every depfile.
# ninja normalises that LEXICALLY to /sysroot/include/c++/16, which does not
# exist, so every C++ object stays dirty forever (a second ninja pass after a
# full build rebuilt ~2700 WebKit objects). --gcc-toolchain=/sysroot/usr makes
# the same walk land on /sysroot/usr/include/c++/16. Same fix as
# engine/cmake/toolchain-linux-arm64.cmake.
set(CMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN ${_sysroot}/usr)
set(CMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN ${_sysroot}/usr)
set(CMAKE_ASM_COMPILER_EXTERNAL_TOOLCHAIN ${_sysroot}/usr)
# The host's GNU ar has no aarch64 BFD: use the cross binutils.
set(CMAKE_AR /usr/bin/aarch64-linux-gnu-ar CACHE FILEPATH "")
set(CMAKE_RANLIB /usr/bin/aarch64-linux-gnu-ranlib CACHE FILEPATH "")
set(CMAKE_STRIP /usr/bin/aarch64-linux-gnu-strip CACHE FILEPATH "")
set(CMAKE_OBJCOPY /usr/bin/aarch64-linux-gnu-objcopy CACHE FILEPATH "")
# armv8-a: portable to any aarch64 board (RK3588 is v8.2-A).
set(CMAKE_C_FLAGS_INIT "-march=armv8-a")
set(CMAKE_CXX_FLAGS_INIT "-march=armv8-a")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld")

set(CMAKE_FIND_ROOT_PATH ${_sysroot})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)  # perl, ruby, gperf, unifdef, glib tools: host
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_LIBRARY_ARCHITECTURE ${_triple})

set(ENV{PKG_CONFIG_DIR} "")
set(ENV{PKG_CONFIG_PATH} "")
set(ENV{PKG_CONFIG_LIBDIR} "${_sysroot}/usr/lib/${_triple}/pkgconfig:${_sysroot}/usr/share/pkgconfig:/opt/rni-wpe/lib/pkgconfig")
set(ENV{PKG_CONFIG_SYSROOT_DIR} "${_sysroot}")
