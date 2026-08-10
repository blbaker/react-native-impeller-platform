# =============================================================================
# CompileFlags.cmake — one translation of this project's GCC/Clang compile flags
# into their MSVC equivalents.
#
# It exists BEFORE the Windows port (P5), not after, because the alternative is
# an `if(MSVC)` block copy-pasted onto every ReactCommon target — and on
# skia-platform exactly that shape failed one target at a time (`/Wno-sign-compare`
# → cl D8021) while the others sat waiting to fail identically. A "keep in sync"
# comment is a defect report, not a design.
#
# NOTHING HERE SILENCES AN ERROR. If a second compiler rejects code the first
# accepted, that is a portability finding to read, not suppress.
# =============================================================================

# rni_compile_flags(<target> [VISIBILITY <vis>]
#                   [EXCEPTIONS] [RTTI] [FRAME_POINTER]
#                   [NO_DEPRECATED] [NO_SIGN_COMPARE]
#                   [FORCE_INCLUDE <file>...])
function(rni_compile_flags target)
  cmake_parse_arguments(A
    "EXCEPTIONS;RTTI;FRAME_POINTER;NO_DEPRECATED;NO_SIGN_COMPARE"
    "VISIBILITY"
    "FORCE_INCLUDE"
    ${ARGN})
  if(NOT A_VISIBILITY)
    set(A_VISIBILITY PRIVATE)
  endif()

  set(_opts "")
  if(MSVC)
    if(A_EXCEPTIONS)
      list(APPEND _opts /EHsc)
    endif()
    if(A_RTTI)
      list(APPEND _opts /GR)
    endif()
    if(A_FRAME_POINTER)
      list(APPEND _opts /Oy-)
    endif()
    if(A_NO_DEPRECATED)
      list(APPEND _opts /wd4996)
    endif()
    # MSVC splits GCC's -Wsign-compare into two warnings.
    if(A_NO_SIGN_COMPARE)
      list(APPEND _opts /wd4018 /wd4389)
    endif()
    foreach(_f IN LISTS A_FORCE_INCLUDE)
      list(APPEND _opts "/FI${_f}")   # one token, no space
    endforeach()
  else()
    if(A_EXCEPTIONS)
      list(APPEND _opts -fexceptions)
    endif()
    if(A_RTTI)
      list(APPEND _opts -frtti)
    endif()
    if(A_FRAME_POINTER)
      list(APPEND _opts -fno-omit-frame-pointer)
    endif()
    if(A_NO_DEPRECATED)
      list(APPEND _opts -Wno-deprecated-declarations)
    endif()
    if(A_NO_SIGN_COMPARE)
      list(APPEND _opts -Wno-sign-compare)
    endif()
    # SHELL: stops CMake de-duplicating a repeated `-include`; without it the
    # second occurrence loses its flag and clang sees a bare source path.
    foreach(_f IN LISTS A_FORCE_INCLUDE)
      list(APPEND _opts "SHELL:-include ${_f}")
    endforeach()
  endif()

  target_compile_options(${target} ${A_VISIBILITY} ${_opts})
endfunction()
