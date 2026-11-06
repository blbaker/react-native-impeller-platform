# Cross toolchain: x86_64 linux host -> aarch64-linux-gnu (RK3588).
# clang + lld from the host, headers and libraries from the bookworm arm64
# sysroot that tools/arm64-sysroot.sh exports. Used by
# tools/engine-build-linux-arm64.sh for Hermes, GLFW and the engine.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if(NOT RNI_ARM64_SYSROOT)
  if(DEFINED ENV{RNI_ARM64_SYSROOT})
    set(RNI_ARM64_SYSROOT "$ENV{RNI_ARM64_SYSROOT}")
  else()
    get_filename_component(RNI_ARM64_SYSROOT
      "${CMAKE_CURRENT_LIST_DIR}/../third_party/sysroot-linux-arm64" ABSOLUTE)
  endif()
endif()
# try_compile projects re-read this file; pass the sysroot through to them.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES RNI_ARM64_SYSROOT)
set(CMAKE_SYSROOT "${RNI_ARM64_SYSROOT}")

set(_triple aarch64-linux-gnu)
set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_ASM_COMPILER clang)
set(CMAKE_C_COMPILER_TARGET ${_triple})
set(CMAKE_CXX_COMPILER_TARGET ${_triple})
set(CMAKE_ASM_COMPILER_TARGET ${_triple})
# ⛔ POINT CLANG AT THE GCC INSTALL UNDER usr/, NOT THE MERGED-/usr SYMLINK.
# bookworm's sysroot has lib -> usr/lib, and clang found GCC at
# <sysroot>/lib/gcc/aarch64-linux-gnu/12. Its libstdc++ include dir is then
# <sysroot>/lib/gcc/.../12/../../../../include/c++/12, which ninja normalises
# LEXICALLY to <sysroot>/include/c++/12: a path that does not exist. Every
# object's depfile named it, so ninja saw every object dirty and rebuilt all of
# Hermes (358 steps) and the engine (481) on EVERY run, about 6 minutes for a
# no-op. --gcc-toolchain=<sysroot>/usr makes the same walk land on
# <sysroot>/usr/include/c++/12. Re-read on every configure, so existing build
# trees pick it up.
set(CMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN "${RNI_ARM64_SYSROOT}/usr")
set(CMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN "${RNI_ARM64_SYSROOT}/usr")
set(CMAKE_ASM_COMPILER_EXTERNAL_TOOLCHAIN "${RNI_ARM64_SYSROOT}/usr")
find_program(_rni_llvm_ar NAMES llvm-ar llvm-ar-18 PATHS /usr/lib/llvm-18/bin REQUIRED)
find_program(_rni_llvm_ranlib NAMES llvm-ranlib llvm-ranlib-18 PATHS /usr/lib/llvm-18/bin REQUIRED)
find_program(_rni_llvm_strip NAMES llvm-strip llvm-strip-18 PATHS /usr/lib/llvm-18/bin REQUIRED)
set(CMAKE_AR "${_rni_llvm_ar}" CACHE FILEPATH "")
set(CMAKE_RANLIB "${_rni_llvm_ranlib}" CACHE FILEPATH "")
set(CMAKE_STRIP "${_rni_llvm_strip}" CACHE FILEPATH "")
# Cortex-A76/A55 (RK3588) are ARMv8.2-A; armv8-a keeps the binary portable to
# any aarch64 board. -fuse-ld=lld: the host's GNU ld cannot link aarch64.
set(CMAKE_C_FLAGS_INIT "-march=armv8-a")
set(CMAKE_CXX_FLAGS_INIT "-march=armv8-a")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld")

set(CMAKE_FIND_ROOT_PATH "${RNI_ARM64_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_LIBRARY_ARCHITECTURE ${_triple})

# pkg-config must read the sysroot's .pc files, never the host's.
set(ENV{PKG_CONFIG_DIR} "")
set(ENV{PKG_CONFIG_LIBDIR} "${RNI_ARM64_SYSROOT}/usr/lib/${_triple}/pkgconfig:${RNI_ARM64_SYSROOT}/usr/share/pkgconfig")
set(ENV{PKG_CONFIG_SYSROOT_DIR} "${RNI_ARM64_SYSROOT}")
