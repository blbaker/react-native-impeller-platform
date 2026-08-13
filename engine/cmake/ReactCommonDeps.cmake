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
