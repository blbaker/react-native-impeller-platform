# FP-03: sanitizer builds, modelled on Flutter's GN `is_asan` / `is_ubsan`
# (engine/src/build/config/sanitizers). Directory-scoped so every TU this project
# COMPILES (ours, ReactCommon, folly, glog, fmt) is instrumented; the prebuilt
# libimpeller.so / libhermesvm.so are linked as they are.
#   cmake -B engine/build-asan -DCMAKE_CXX_COMPILER=clang++ -DRNI_SANITIZE=address,undefined
set(RNI_SANITIZE "" CACHE STRING "Comma list passed to -fsanitize= (e.g. address,undefined)")
if(RNI_SANITIZE)
  # Clang only, as in Flutter's sanitizer builds: GCC's libubsan ignores
  # UBSAN_OPTIONS=log_path, so gates that swallow stderr would lose UB reports.
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    message(FATAL_ERROR "RNI_SANITIZE needs clang (-DCMAKE_CXX_COMPILER=clang++)")
  endif()
  # -g1: line tables for symbolized reports without full debug info size.
  add_compile_options(-fsanitize=${RNI_SANITIZE} -fno-omit-frame-pointer -g1)
  add_link_options(-fsanitize=${RNI_SANITIZE})
  add_compile_definitions(RNI_SANITIZE_BUILD="${RNI_SANITIZE}")
  message(STATUS "RNI_SANITIZE=${RNI_SANITIZE}")
endif()


# FP-52: libFuzzer targets. Coverage instrumentation (fuzzer-no-link) goes on every
# TU like the sanitizers above; engine/cmake/Fuzz.cmake adds the fuzz/ sources and
# links libFuzzer without its main, so rn-impeller keeps its own main and
# `rn-impeller --fuzz <target> [libFuzzer flags]` runs one target.
option(RNI_FUZZ "Build the libFuzzer targets into rn-impeller (--fuzz); needs clang + RNI_SANITIZE" OFF)
if(RNI_FUZZ)
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang" OR NOT RNI_SANITIZE)
    message(FATAL_ERROR "RNI_FUZZ needs clang and RNI_SANITIZE (e.g. address,undefined)")
  endif()
  add_compile_options(-fsanitize=fuzzer-no-link)
  add_compile_definitions(RNI_FUZZ=1)
endif()
