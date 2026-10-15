#pragma once

// FP-52: libFuzzer targets compiled into rn-impeller when RNI_FUZZ is on
// (engine/cmake/Fuzz.cmake). Each returns 0 like LLVMFuzzerTestOneInput; a
// crash, sanitizer report or leak is the finding. Run one with
// `tools/fuzz-run.sh <target> <seconds>`.

#include <cstddef>
#include <cstdint>

namespace rni::fuzz {

int SvgPath(const uint8_t* data, size_t size);      // svg/SvgPath `d` parser
int SvgDash(const uint8_t* data, size_t size);      // svg/SvgDash pattern + path
int ImageDecode(const uint8_t* data, size_t size);  // fabric/ImageDecode DecodeBytes
int Props(const uint8_t* data, size_t size);        // JSON -> descriptor props -> SceneGraph
int Scene(const uint8_t* data, size_t size);        // mutation lists -> SceneGraph -> record

// `rn-impeller --fuzz <target> [libFuzzer flags and corpus dirs]`, or any argv
// with RNI_FUZZ_TARGET set (libFuzzer's -merge/-fork children).
bool Requested(int argc, char** argv);
int Main(int argc, char** argv);

}  // namespace rni::fuzz
