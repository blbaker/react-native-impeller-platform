# =============================================================================
# ReactCommonDeps.cmake — third-party C++ deps ReactCommon (RN 0.86.2) needs.
#
# Everything is FetchContent'd; nothing is installed on the host. Versions match
# RN 0.86.2's gradle/libs.versions.toml where it pins one.
#
# folly is NOT built with folly's own CMake. We mirror what
# ReactAndroid/src/main/jni/third-party/folly/CMakeLists.txt does: compile the
# small folly_runtime source list with -DFOLLY_NO_CONFIG. Desktop-Linux deltas
# vs the Android flags: FOLLY_MOBILE=0, FOLLY_USE_LIBCPP=0 (libstdc++).
#
# Provenance: this list and the glog shim below were derived and debugged on
# skia-platform against the same RN version. Re-deriving them would be paying
# twice for the same information.
# =============================================================================

include(FetchContent)

# --- boost (headers only) ----------------------------------------------------
# Plain source archive, exposed as an INTERFACE include dir. The boostorg
# superproject CMake pulls 100+ submodules for headers we already have here.
FetchContent_Declare(
  boost_src
  URL https://archives.boost.io/release/1.83.0/source/boost_1_83_0.tar.gz
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(boost_src)
add_library(rc_boost INTERFACE)
target_include_directories(rc_boost SYSTEM INTERFACE "${boost_src_SOURCE_DIR}")

# --- OpenSSL (TLS for the Networking TurboModule) ----------------------------
# ⛔ PREFER THE SYSTEM OpenSSL, BUILD FROM SOURCE ONLY AS A FALLBACK.
# A source build costs ~46s and, more importantly, pins a CA story: OpenSSL
# built from a tarball has NO default trust store, so certificate verification
# silently has nothing to verify against and every https:// request fails with
# "unable to get local issuer certificate". Where the platform ships OpenSSL it
# also ships a populated store, and set_default_verify_paths() finds it.
#
# `asio::ssl` is a header-only wrapper over libssl/libcrypto — the boost we
# already vendor (1.83.0, headers only) provides it, so no new boost machinery
# is needed. Only the libraries are new.
# ⛔ ON DARWIN THE SYSTEM OpenSSL IS HOMEBREW'S, AND LINKING IT *SHARED* SHIPS A
# BINARY THAT ONLY RUNS ON THIS MACHINE.
# macOS has no OpenSSL in /usr/lib (Apple removed it in 10.15 — only the private
# libssl.0.9.8 stub remains), so find_package resolves to the brew Cellar and the
# executable records ABSOLUTE install names:
#     /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib
#     /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib
# Measured 2026-09-08 on the macOS tester, first darwin build after TLS landed:
# the relocatability gate below rejected the staged Mach-O for exactly these two
# paths. That gate is right and must not be relaxed — an npm consumer without
# Homebrew (or on Intel, where the prefix is /usr/local) gets `Library not
# loaded` at exec, which on arm64 is an unexplained `Abort trap: 6`.
#
# Static archives dodge it: brew ships libssl.a/libcrypto.a alongside the dylibs,
# they leave no install name to rewrite, and OPENSSL_USE_STATIC_LIBS is
# FindOpenSSL's documented switch for exactly this. Linux keeps the shared link —
# there the libraries ARE in a system path, the gate permits them, and static
# linking would only bloat the binary.
#
# ⚠️ THE TRUST STORE IS THE THING TO VERIFY AFTER THIS CHANGE, NOT THE LINK.
# A statically linked brew OpenSSL still compiles in brew's OPENSSLDIR, so
# set_default_verify_paths() points at /opt/homebrew/etc/openssl@3/certs — which
# a consumer machine need not have. NetworkingModule.cpp already error-checks
# that call, so the failure is loud rather than a silent verify_none; the
# negative-control arm of the networking probe is what proves the chain actually
# verifies on this host. Prove it there, do not assume it here.
if(APPLE)
  set(OPENSSL_USE_STATIC_LIBS TRUE)
endif()
# ⛔ OPENSSL_SSL_LIBRARY IS A *CACHE* ENTRY, SO FLIPPING THE FLAG ABOVE CHANGES
# NOTHING IN AN EXISTING BUILD DIRECTORY.
# FindOpenSSL only searches when its result variables are unset; on a re-configure
# they are already cached from the previous run, so it returns the SHARED dylibs
# it found last time and reports success. Measured 2026-09-08: the static fix was
# delivered and rebuilt on the macOS tester, ninja said "no work to do", and the
# relocatability gate failed with the IDENTICAL two brew paths — a correct fix
# that looks like a fix that does not work. That is the worst shape of stale
# state, and it would have been diagnosed as "the cmake change is wrong".
#
# Re-resolve whenever the cached library disagrees with the static/shared mode we
# are asking for. Cheap (a find_library, not a compile) and it means neither a
# human nor a peer has to know to delete engine/build.
if(DEFINED OPENSSL_SSL_LIBRARY AND OPENSSL_USE_STATIC_LIBS)
  get_filename_component(_rc_ssl_ext "${OPENSSL_SSL_LIBRARY}" EXT)
  if(NOT _rc_ssl_ext STREQUAL "${CMAKE_STATIC_LIBRARY_SUFFIX}")
    message(STATUS "rc_ssl: cached ${OPENSSL_SSL_LIBRARY} is not static; re-resolving")
    unset(OPENSSL_SSL_LIBRARY CACHE)
    unset(OPENSSL_CRYPTO_LIBRARY CACHE)
    unset(OPENSSL_INCLUDE_DIR CACHE)
    unset(OPENSSL_LIBRARIES CACHE)
  endif()
endif()
# ⛔ WINDOWS NEVER PICKS UP AN OpenSSL FROM THE BUILD MACHINE.
# A GitHub Windows runner has a shared OpenSSL 3 installed. find_package found
# it, the engine linked libssl-3-x64.dll and libcrypto-3-x64.dll, and those
# ship in no package, so the import-table check in engine-build-win-stage.sh
# failed the build. On a user's machine that engine would die before main().
# Windows builds without TLS (the branch below), the same on every machine,
# until shipping OpenSSL and a CA story for Windows is a deliberate decision.
# iOS: find_package would resolve the Mac's own (Homebrew, macOS-arch) OpenSSL
# for an iOS target; iOS builds without TLS for now, like Android.
if(NOT ANDROID AND NOT WIN32 AND NOT IOS)
  find_package(OpenSSL QUIET)
endif()
if(OpenSSL_FOUND)
  message(STATUS "rc_ssl: using system OpenSSL ${OPENSSL_VERSION} (static=${OPENSSL_USE_STATIC_LIBS})")
  add_library(rc_ssl INTERFACE)
  target_link_libraries(rc_ssl INTERFACE OpenSSL::SSL OpenSSL::Crypto)
  target_compile_definitions(rc_ssl INTERFACE RNI_WITH_TLS=1)
elseif(WIN32 OR ANDROID OR IOS)
  # The source fallback below is a Unix config+make build cmd.exe cannot run
  # (and on android the NDK cross config is not wired; SC-41 probes need no TLS).
  # Build without TLS: NetworkingModule refuses https:// with a clear error.
  message(STATUS "rc_ssl: ${CMAKE_SYSTEM_NAME} without OpenSSL; building WITHOUT TLS (http only)")
  add_library(rc_ssl INTERFACE)
else()
  message(STATUS "rc_ssl: no system OpenSSL; building from source")
  FetchContent_Declare(openssl_src
    URL https://github.com/openssl/openssl/releases/download/openssl-3.2.1/openssl-3.2.1.tar.gz
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_MakeAvailable(openssl_src)
  include(ExternalProject)
  ExternalProject_Add(openssl_build
    SOURCE_DIR "${openssl_src_SOURCE_DIR}"
    CONFIGURE_COMMAND "${openssl_src_SOURCE_DIR}/config"
                      --prefix=<INSTALL_DIR> --openssldir=<INSTALL_DIR>
                      no-shared no-tests no-docs
    BUILD_COMMAND ${CMAKE_COMMAND} -E env make -j4 build_libs
    INSTALL_COMMAND ${CMAKE_COMMAND} -E env make install_dev
    BUILD_BYPRODUCTS <INSTALL_DIR>/lib/libssl.a <INSTALL_DIR>/lib64/libssl.a
                     <INSTALL_DIR>/lib/libcrypto.a <INSTALL_DIR>/lib64/libcrypto.a)
  ExternalProject_Get_Property(openssl_build INSTALL_DIR)
  # Built OpenSSL puts libs in lib/ or lib64/ depending on platform; probe both.
  add_library(rc_ssl INTERFACE)
  add_dependencies(rc_ssl openssl_build)
  file(MAKE_DIRECTORY "${INSTALL_DIR}/include")
  target_include_directories(rc_ssl SYSTEM INTERFACE "${INSTALL_DIR}/include")
  target_link_libraries(rc_ssl INTERFACE
    "-L${INSTALL_DIR}/lib" "-L${INSTALL_DIR}/lib64" ssl crypto ${CMAKE_DL_LIBS})
  target_compile_definitions(rc_ssl INTERFACE RNI_WITH_TLS=1)
endif()

# --- fmt ---------------------------------------------------------------------
FetchContent_Declare(fmt
  GIT_REPOSITORY https://github.com/fmtlib/fmt.git
  GIT_TAG 12.1.0 GIT_SHALLOW TRUE)
set(FMT_INSTALL OFF CACHE BOOL "" FORCE)
set(FMT_TEST OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(fmt)

# --- double-conversion -------------------------------------------------------
FetchContent_Declare(double-conversion
  GIT_REPOSITORY https://github.com/google/double-conversion.git
  GIT_TAG v3.3.0 GIT_SHALLOW TRUE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(double-conversion)

# --- glog --------------------------------------------------------------------
FetchContent_Declare(glog
  GIT_REPOSITORY https://github.com/google/glog.git
  GIT_TAG v0.6.0 GIT_SHALLOW TRUE)
set(WITH_GFLAGS OFF CACHE BOOL "" FORCE)
set(WITH_GTEST OFF CACHE BOOL "" FORCE)
set(WITH_UNWIND OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(glog)

# glog exports its raw src/ tree on the include path, and that tree's top-level
# demangle.h SHADOWS libiberty's <demangle.h>, which folly/Demangle.cpp probes
# with __has_include. Stage only the public glog/*.h into a shim dir and export
# that instead.
set(GLOG_SHIM "${CMAKE_BINARY_DIR}/glog-shim")
file(MAKE_DIRECTORY "${GLOG_SHIM}/glog")
foreach(hdr export.h logging.h raw_logging.h stl_logging.h vlog_is_on.h)
  file(COPY_FILE "${glog_BINARY_DIR}/glog/${hdr}" "${GLOG_SHIM}/glog/${hdr}" ONLY_IF_DIFFERENT)
endforeach()
foreach(hdr log_severity.h platform.h)
  file(COPY_FILE "${glog_SOURCE_DIR}/src/glog/${hdr}" "${GLOG_SHIM}/glog/${hdr}" ONLY_IF_DIFFERENT)
endforeach()
set_target_properties(glog PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "$<BUILD_INTERFACE:${GLOG_SHIM}>")

# --- fast_float (header-only, required by folly 2024.11+) --------------------
FetchContent_Declare(fast_float
  GIT_REPOSITORY https://github.com/fastfloat/fast_float.git
  GIT_TAG v8.0.0 GIT_SHALLOW TRUE)
FetchContent_MakeAvailable(fast_float)

# --- folly (minimal FOLLY_NO_CONFIG runtime) ---------------------------------
FetchContent_Declare(folly_src
  URL https://github.com/facebook/folly/archive/v2024.11.18.00.tar.gz
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_Populate(folly_src)

set(FOLLY_DIR "${folly_src_SOURCE_DIR}")
add_library(folly_runtime STATIC
  ${FOLLY_DIR}/folly/Conv.cpp
  ${FOLLY_DIR}/folly/Demangle.cpp
  ${FOLLY_DIR}/folly/FileUtil.cpp
  ${FOLLY_DIR}/folly/Format.cpp
  ${FOLLY_DIR}/folly/ScopeGuard.cpp
  ${FOLLY_DIR}/folly/SharedMutex.cpp
  ${FOLLY_DIR}/folly/String.cpp
  ${FOLLY_DIR}/folly/Unicode.cpp
  ${FOLLY_DIR}/folly/concurrency/CacheLocality.cpp
  ${FOLLY_DIR}/folly/container/detail/F14Table.cpp
  ${FOLLY_DIR}/folly/detail/FileUtilDetail.cpp
  ${FOLLY_DIR}/folly/detail/Futex.cpp
  ${FOLLY_DIR}/folly/detail/SplitStringSimd.cpp
  ${FOLLY_DIR}/folly/detail/StaticSingletonManager.cpp
  ${FOLLY_DIR}/folly/detail/UniqueInstance.cpp
  ${FOLLY_DIR}/folly/hash/SpookyHashV2.cpp
  ${FOLLY_DIR}/folly/json/dynamic.cpp
  ${FOLLY_DIR}/folly/json/json_pointer.cpp
  ${FOLLY_DIR}/folly/json/json.cpp
  ${FOLLY_DIR}/folly/lang/CString.cpp
  ${FOLLY_DIR}/folly/lang/Exception.cpp
  ${FOLLY_DIR}/folly/lang/SafeAssert.cpp
  ${FOLLY_DIR}/folly/lang/ToAscii.cpp
  ${FOLLY_DIR}/folly/memory/ReentrantAllocator.cpp
  ${FOLLY_DIR}/folly/memory/detail/MallocImpl.cpp
  ${FOLLY_DIR}/folly/net/NetOps.cpp
  ${FOLLY_DIR}/folly/portability/SysUio.cpp
  ${FOLLY_DIR}/folly/synchronization/SanitizeThread.cpp
  ${FOLLY_DIR}/folly/synchronization/ParkingLot.cpp
  ${FOLLY_DIR}/folly/system/AtFork.cpp
  ${FOLLY_DIR}/folly/system/ThreadId.cpp
  # Windows-only arms (P5). Each is wrapped in `#ifdef _WIN32` upstream, so
  # adding them unconditionally would compile to nothing on Linux while still
  # churning the working platform's build.
  $<$<BOOL:${WIN32}>:${FOLLY_DIR}/folly/portability/SysMman.cpp>
  $<$<BOOL:${WIN32}>:${FOLLY_DIR}/folly/portability/Fcntl.cpp>
  $<$<BOOL:${WIN32}>:${FOLLY_DIR}/folly/portability/Unistd.cpp>
  $<$<BOOL:${WIN32}>:${FOLLY_DIR}/folly/portability/SysStat.cpp>
  $<$<BOOL:${WIN32}>:${FOLLY_DIR}/folly/portability/SysTime.cpp>
  $<$<BOOL:${WIN32}>:${FOLLY_DIR}/folly/portability/Stdlib.cpp>
  $<$<BOOL:${WIN32}>:${FOLLY_DIR}/folly/portability/Sockets.cpp>
  $<$<BOOL:${WIN32}>:${FOLLY_DIR}/folly/net/detail/SocketFileDescriptorMap.cpp>
)
rni_compile_flags(folly_runtime EXCEPTIONS RTTI FRAME_POINTER NO_SIGN_COMPARE)
target_compile_definitions(folly_runtime PUBLIC
  FOLLY_NO_CONFIG=1
  FOLLY_HAVE_CLOCK_GETTIME=1
  FOLLY_USE_LIBCPP=0
  FOLLY_CFG_NO_COROUTINES=1
  FOLLY_MOBILE=0
  FOLLY_HAVE_RECVMMSG=1
  FOLLY_HAVE_PTHREAD=1
)
set_property(TARGET folly_runtime PROPERTY POSITION_INDEPENDENT_CODE ON)
target_include_directories(folly_runtime SYSTEM PUBLIC "${FOLLY_DIR}")
target_link_libraries(folly_runtime PUBLIC
  rc_boost glog::glog double-conversion fmt::fmt FastFloat::fast_float)

# folly's PORTABILITY layer is the Winsock dependency, not anything we call.
# On Linux, socket()/poll()/ioctl() live in libc and cost nothing to link. On
# Windows those same functions are folly::portability::sockets shims over
# ws2_32, so NetOps/Sockets/Fcntl/Unistd.cpp pull 28 __imp_* symbols even though
# this engine opens no sockets — folly compiles the portability TUs
# unconditionally.
#
# Declared on folly_runtime rather than the executable BECAUSE THAT IS WHERE THE
# DEPENDENCY IS: as a PUBLIC link on the owning target it propagates to every
# future consumer, instead of being re-diagnosed the first time something other
# than rn-impeller links folly.
if(WIN32)
  target_link_libraries(folly_runtime PUBLIC ws2_32)
endif()
