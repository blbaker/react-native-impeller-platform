# FP-52: the fuzz targets live inside rn-impeller (one binary, a target switch,
# like Skia's fuzz/FuzzMain.cpp `--type`), so they link the exact painter,
# descriptors and decoders the engine ships. libclang_rt.fuzzer_no_main gives
# LLVMFuzzerRunDriver without taking over main().
if(RNI_FUZZ)
  execute_process(COMMAND ${CMAKE_CXX_COMPILER} -print-runtime-dir
                  OUTPUT_VARIABLE _rt_dir OUTPUT_STRIP_TRAILING_WHITESPACE)
  find_file(RNI_FUZZER_NO_MAIN
            NAMES libclang_rt.fuzzer_no_main-x86_64.a libclang_rt.fuzzer_no_main.a
            PATHS "${_rt_dir}" NO_DEFAULT_PATH REQUIRED)
  target_sources(rn-impeller PRIVATE
    fuzz/FuzzMain.cpp
    fuzz/FuzzSvg.cpp
    fuzz/FuzzImage.cpp
    fuzz/FuzzFabric.cpp
    fuzz/FuzzProps.cpp
    fuzz/FuzzScene.cpp)
  target_link_libraries(rn-impeller PRIVATE "${RNI_FUZZER_NO_MAIN}")
  message(STATUS "RNI_FUZZ: ${RNI_FUZZER_NO_MAIN}")
endif()
