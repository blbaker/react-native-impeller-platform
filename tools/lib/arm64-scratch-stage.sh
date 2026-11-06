# arm64-scratch-stage.sh: build the linux-arm64 engine from the CURRENT source
# into a scratch package dir, staged and stripped exactly like
# tools/engine-build-linux.sh does, without touching
# packages-engine/engine-linux-arm64 (gates and other runs keep using it).
# Mutation scripts point RNI_ARM64_ENGINE_DIR at "<dir>/bin".
#   arm64_stage <dir> <log>      cmake --build + install --component engine + strip
#   arm64_same_as_staged <dir>   rn-impeller byte-identical to the staged package
# Needs a configured build tree (bash tools/engine-build.sh linux arm64 once).
ARM64_EB="${ARM64_EB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/engine/build-linux-arm64/engine}"
ARM64_PKGBIN="${ARM64_PKGBIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/packages-engine/engine-linux-arm64/bin}"
arm64_stage() {
  local dir="$1" log="$2" strip f
  [ -f "$ARM64_EB/build.ninja" ] || { echo "arm64_stage: no build tree at $ARM64_EB" >&2; return 1; }
  strip="$(grep -E '^CMAKE_STRIP:' "$ARM64_EB/CMakeCache.txt" | cut -d= -f2)"
  nice -n 10 cmake --build "$ARM64_EB" -j"${JOBS:-10}" --target rn-impeller > "$log" 2>&1 \
    || { grep -E 'error:|FAILED:' "$log" | head >&2; return 1; }
  DESTDIR= cmake --install "$ARM64_EB" --component engine --prefix "$dir" > /dev/null || return 1
  for f in "$dir"/bin/*; do "$strip" --strip-unneeded "$f" || return 1; done
  chmod 755 "$dir"/bin/*
}
arm64_same_as_staged() { cmp -s "$1/bin/rn-impeller" "$ARM64_PKGBIN/rn-impeller"; }
