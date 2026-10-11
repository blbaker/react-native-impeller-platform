#!/usr/bin/env bash
# SC-35: build the custom Impeller SDK (SC-32 patch) for windows-x64 with MSVC,
# driven from WSL through cmd.exe, and unpack it into
# engine/third_party/impeller-sdk-custom-win (same .stamp as the linux build).
#   bash tools/impeller-sdk-custom-build-win.sh [dest]
# Env: RNI_SDK_WIN_WORK  Windows checkout dir (default C:\sc35, ~15 GB on C:)
#      RNI_SDK_WIN_VS    Visual Studio / Build Tools 2022 dir (default C:\Devel\VSBuildTools)
set -euo pipefail
cd "$(dirname "$0")/.."
SHA="$(tr -d ' \n' < engine/IMPELLER_SHA)"
DEST="${1:-engine/third_party/impeller-sdk-custom-win}"
WIN_WORK="${RNI_SDK_WIN_WORK:-C:\\sc35}"
VS="${RNI_SDK_WIN_VS:-C:\\Devel\\VSBuildTools}"
CMD=/mnt/c/Windows/System32/cmd.exe
WSL_WORK="$(wslpath -u "$WIN_WORK")"
PATCHES=(engine/impeller-sdk-patches/*.patch)
PATCH_SUM="$(cat "${PATCHES[@]}" | sha256sum | cut -c1-64)"
say() { echo "[impeller-sdk-custom-win] $*"; }

mkdir -p "$WSL_WORK"
cat "${PATCHES[@]}" > "$WSL_WORK/rni.patch"
cat > "$WSL_WORK/gclient.txt" <<'EOF'
solutions = [{
  "name": ".", "url": "https://github.com/flutter/flutter.git", "deps_file": "DEPS",
  "managed": False, "custom_deps": {}, "safesync_url": "",
  "custom_vars": {"download_android_deps": False, "download_fuchsia_deps": False,
                  "download_jdk": False, "download_esbuild": False},
}]
EOF
# CIPD's clang package carries fuchsia runtime symlinks, and creating symlinks
# needs Developer Mode or admin (we change neither). This turns that DEPS
# entry off in the scratch checkout and installs it from the same CIPD version, minus
# the symlinks, which the windows-x64 build never reads.
cat > "$WSL_WORK/fetch_clang.py" <<'EOF'
import os, re, subprocess, sys, zipfile
w = sys.argv[1]
dest = os.path.join(w, "flutter", "engine", "src", "flutter", "buildtools", "windows-x64", "clang")
deps_path = os.path.join(w, "flutter", "DEPS")
deps = open(deps_path, encoding="utf-8").read()
ver = re.search(r"'clang_version': '([^']+)'", deps).group(1)
key = "'engine/src/flutter/buildtools/windows-x64/clang': {"
i = deps.index(key)
j = deps.find("'condition': 'download_windows_deps'", i)
if 0 <= j - i < 400:
    deps = deps[:j] + "'condition': 'False'" + deps[j + len("'condition': 'download_windows_deps'"):]
    open(deps_path, "w", encoding="utf-8", newline="").write(deps)
zp = os.path.join(w, "clang.zip")
if os.path.exists(os.path.join(dest, "bin", "clang-cl.exe")):
    sys.exit(0)
subprocess.check_call(["cipd.bat", "pkg-fetch", "fuchsia/third_party/clang/windows-amd64",
                       "-version", ver, "-out", zp], cwd=w)
z = zipfile.ZipFile(zp)
skipped = 0
for i in z.infolist():
    if (i.external_attr >> 16) & 0o170000 == 0o120000 or i.filename.startswith(".cipdpkg"):
        skipped += 1
        continue
    z.extract(i, dest)
print("clang", ver, "installed, symlinks skipped:", skipped)
EOF
# Without "Debugging Tools for Windows" (an admin SDK install) gn stops in
# vs_toolchain.py copy_dlls. dbghelp.dll is only copied beside test binaries
# for stack symbolization and is not part of the SDK zip, so make it optional.
cat > "$WSL_WORK/prep_vs.py" <<'EOF'
import os, sys
p = os.path.join(sys.argv[1], "flutter", "engine", "src", "build", "vs_toolchain.py")
s = open(p, encoding="utf-8").read()
old = "debug_files = [('dbghelp.dll', False),"
if old in s:
    open(p, "w", encoding="utf-8", newline="").write(s.replace(old, "debug_files = [('dbghelp.dll', True),"))
    print("vs_toolchain.py: dbghelp.dll optional")
EOF
# The batch file does the Windows-side work; exit codes 11..18 name the step.
sed 's/$/\r/' > "$WSL_WORK/build.bat" <<EOF
@echo off
setlocal
set W=$WIN_WORK
set SHA=$SHA
set DEPOT_TOOLS_WIN_TOOLCHAIN=0
set GYP_MSVS_OVERRIDE_PATH=$VS
set vs2022_install=$VS
set GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1
rem depot_tools' git.bat shadows git: every git call needs CALL or the batch ends there.
set PATH=%W%\\depot_tools;%PATH%
cd /d %W%
if not exist depot_tools\\.git call git clone -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git depot_tools || exit /b 11
if not exist flutter\\.git (call git init -q flutter && call git -C flutter remote add origin https://github.com/flutter/flutter.git)
call git -C flutter config core.longpaths true
set HEAD=
for /f %%h in ('git -C flutter rev-parse HEAD 2^>nul') do set HEAD=%%h
if not "%HEAD%"=="%SHA%" (call git -C flutter fetch -q --depth 1 origin %SHA% && call git -C flutter checkout -q --force FETCH_HEAD && del /q synced.txt 2>nul || exit /b 12)
copy /y gclient.txt flutter\\.gclient >nul
python fetch_clang.py %W% > %W%\\clang.log 2>&1 || exit /b 18
if not exist synced.txt (
  cd flutter
  call gclient sync --no-history -D -j 16 > %W%\\sync.log 2>&1 || exit /b 13
  cd ..
  echo %SHA%> synced.txt
)
call git -C flutter checkout -q -- engine/src/flutter/impeller/toolkit/interop engine/src/flutter/impeller/entity/contents/filters || exit /b 14
call git -C flutter apply --ignore-whitespace %W%\\rni.patch || exit /b 15
python prep_vs.py %W% > %W%\\prep_vs.log 2>&1 || exit /b 19
cd /d %W%\\flutter\\engine\\src
if not exist out\\rni_host_debug\\build.ninja (python flutter\\tools\\gn --target-dir rni_host_debug --runtime-mode debug --prebuilt-dart-sdk --no-lto --no-rbe --no-goma > %W%\\gn.log 2>&1 || exit /b 16)
call ninja -C out\\rni_host_debug flutter/impeller/toolkit/interop:sdk > %W%\\build.log 2>&1 || exit /b 17
echo BUILD_OK
EOF

say "cmd.exe build (logs in $WSL_WORK)"
t0=$(date +%s)
set +e
(cd /mnt/c && "$CMD" /c "$WIN_WORK\\build.bat") > "$WSL_WORK/driver.log" 2>&1
rc=$?
set -e
# cmd.exe /c does not always hand a batch `exit /b` code back to WSL.
[ $rc -ne 0 ] || tr -d '\r' < "$WSL_WORK/driver.log" | grep -qx BUILD_OK || rc=99
secs=$(( $(date +%s) - t0 ))
if [ $rc -ne 0 ]; then
  say "FAIL rc=$rc (11 depot_tools 12 fetch 13 sync 14/15 patch 16 gn 17 ninja 18 clang 19 vs_toolchain 99 no BUILD_OK)"
  for f in driver clang sync gn build; do [ -f "$WSL_WORK/$f.log" ] && { echo "--- $f.log"; grep -a -m3 -A6 -E 'FAILED|[Ee]rror' "$WSL_WORK/$f.log" | tail -20; }; done
  exit 1
fi
ZIP="$(ls "$WSL_WORK"/flutter/engine/src/out/rni_host_debug/zip_archives/*/impeller_sdk.zip | head -1)"
[ -f "$ZIP" ] || { echo "no SDK zip under $WSL_WORK/.../zip_archives" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
TMP="$(mktemp -d "$(dirname "$DEST")/.sdk-custom-win.XXXXXX")"
# Same subset as tools/sdk-fetch-win.sh: the 400 MB static impeller.lib is never linked.
python3 - "$ZIP" "$TMP" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
for n in z.namelist():
    if n.endswith("/") or n.endswith("lib/impeller.lib"):
        continue
    z.extract(n, sys.argv[2])
PY
printf 'sha=%s\npatch_sha256=%s\nbuild_seconds=%s\n' "$SHA" "$PATCH_SUM" "$secs" > "$TMP/.stamp"

# Probe on Windows: the linux gate's CPU-only layout probe, built with cl.exe
# against the import lib, run beside impeller.dll. The gate judges .probe.
say "probe with cl.exe"
P="$WSL_WORK/probe"; rm -rf "$P"; mkdir -p "$P/include"
cp tools/impeller-sdk-probe.c "$P/"; cp "$TMP"/include/impeller.h "$P/include/"
cp "$TMP"/lib/impeller.dll "$TMP"/lib/impeller.dll.lib "$P/"
cp /usr/share/fonts/truetype/freefont/FreeSans.ttf "$P/"
sed 's/$/\r/' > "$P/probe.bat" <<BAT
@echo off
call "$VS\\VC\\Auxiliary\\Build\\vcvars64.bat" >nul || exit /b 21
cd /d $WIN_WORK\\probe
cl /nologo /std:c11 /O1 /Iinclude impeller-sdk-probe.c impeller.dll.lib /Fe:probe.exe > cl.log 2>&1 || exit /b 22
probe.exe FreeSans.ttf > probe.txt 2> probe.err || exit /b 23
BAT
(cd /mnt/c && "$CMD" /c "$WIN_WORK\\probe\\probe.bat") > "$P/driver.log" 2>&1 \
  || { tail -5 "$P/driver.log" "$P/cl.log" "$P/probe.err" 2>/dev/null; rm -rf "$TMP"; exit 1; }
tr -d '\r' < "$P/probe.txt" > "$TMP/.probe"
grep -q PROBE_DONE "$TMP/.probe" || { cat "$TMP/.probe"; rm -rf "$TMP"; exit 1; }
paste -sd' ' "$TMP/.probe" | fold -s -w 160
chmod 755 "$TMP"; rm -rf "$DEST"; mv "$TMP" "$DEST"
say "built in ${secs}s -> $DEST"
