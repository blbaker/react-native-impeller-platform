#!/usr/bin/env python3
"""Runs INSIDE the arm64 debian:sid container (make-tarball.sh). Stages a
self-contained WPE WebKit runtime + rni-webhelper for the board image under
/out/stage, laid out to unpack next to rn-impeller (/opt/rn-impeller-<sha>/):

  bin/rni-webhelper                               RUNPATH $ORIGIN/../rni-wpe/lib
  rni-wpe/lib/*.so.*                              RUNPATH $ORIGIN
  rni-wpe/lib/gio/modules/libgiognutls.so         RUNPATH $ORIGIN/../..
  rni-wpe/libexec/wpe-webkit-2.0/WPE*Process      RUNPATH $ORIGIN/../../lib
  rni-wpe/libexec/rni-no-sandbox, rni-wpe/b       bubblewrap stand-in

Kept on the IMAGE (never bundled): glibc, and the GPU stack (libmali provides
libEGL/libGLESv2/libgbm; libdrm stays with it). README-tarball.txt says why
three compiled-in paths are repointed at /opt/rni-wpe.
"""
import os, re, shutil, subprocess, sys

ML = "/usr/lib/aarch64-linux-gnu"
PKG = ML + "/wpe-webkit-2.0"
ST = "/out/stage"
KEEP_ON_IMAGE = re.compile(
    r"^(ld-linux-aarch64\.so\.1|libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|"
    r"libresolv\.so\.2|libutil\.so\.1|libanl\.so\.1|libmvec\.so\.1|"
    r"libEGL\.so\.1|libGLESv2\.so\.2|libGLX.*|libGL\.so\.1|libGLdispatch\.so\.0|libgbm\.so\.1|libdrm\.so\.2)$")
# libEGL/libGLESv2 via glvnd pull libGLdispatch; on the image they are libmali's.

def sh(*a):
    return subprocess.run(a, check=True, capture_output=True, text=True).stdout

def ldd(path):
    out = {}
    for line in sh("ldd", path).splitlines():
        m = re.match(r"\s*(\S+) => (\S+) \(", line)
        if m:
            out[m.group(1)] = m.group(2)
        elif "not found" in line:
            sys.exit("STAGE_FAIL: %s: %s" % (path, line.strip()))
    return out

roots = {
    "/out/rni-webhelper": "bin/rni-webhelper",
    "/out/rni-no-sandbox": "rni-wpe/libexec/rni-no-sandbox",
    PKG + "/WPEWebProcess": "rni-wpe/libexec/wpe-webkit-2.0/WPEWebProcess",
    PKG + "/WPENetworkProcess": "rni-wpe/libexec/wpe-webkit-2.0/WPENetworkProcess",
    PKG + "/WPEGPUProcess": "rni-wpe/libexec/wpe-webkit-2.0/WPEGPUProcess",
    PKG + "/injected-bundle/libWPEInjectedBundle.so": "rni-wpe/libexec/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so",
    ML + "/gio/modules/libgiognutls.so": "rni-wpe/lib/gio/modules/libgiognutls.so",
}
rpath = {
    "bin": "$ORIGIN/../rni-wpe/lib",
    "rni-wpe/libexec": "$ORIGIN/../lib",
    "rni-wpe/libexec/wpe-webkit-2.0": "$ORIGIN/../../lib",
    "rni-wpe/libexec/wpe-webkit-2.0/injected-bundle": "$ORIGIN/../../../lib",
    "rni-wpe/lib/gio/modules": "$ORIGIN/../..",
    "rni-wpe/lib": "$ORIGIN",
}

libs, kept = {}, set()
for src in roots:
    for so, p in ldd(src).items():
        if KEEP_ON_IMAGE.match(so):
            kept.add(so)
        else:
            libs[so] = p

shutil.rmtree(ST, ignore_errors=True)
for src, rel in roots.items():
    dst = os.path.join(ST, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
for so, p in sorted(libs.items()):
    shutil.copy2(os.path.realpath(p), os.path.join(ST, "rni-wpe/lib", so))

for d, _, files in os.walk(ST):
    reldir = os.path.relpath(d, ST)
    if reldir not in rpath:
        continue
    for f in files:
        fp = os.path.join(d, f)
        if sh("file", "-b", fp).startswith("ELF"):
            subprocess.run(["patchelf", "--set-rpath", rpath[reldir], fp], check=True)

# WebKit launches its processes from the compiled-in PKGLIBEXECDIR and loads the
# injected bundle from PKGLIBDIR (ProcessExecutablePathGLib.cpp: no runtime override
# outside DEVELOPER_MODE). Repoint that one string, SAME LENGTH, so tail-merged and
# concatenated literals stay intact: extra slashes are legal path padding.
def patch_same_len(path, old, head, tail):
    new = head + b"/" * (len(old) - len(head) - len(tail)) + tail
    assert len(new) == len(old) and new.endswith(tail), new
    data = bytearray(open(path, "rb").read())
    hits = [m.start() for m in re.finditer(re.escape(old), data)]
    for h in hits:
        s = data.rfind(b"\0", 0, h) + 1
        e = data.find(b"\0", h)
        print("PATCH_STRING %s @%#x %r" % (os.path.basename(path), h, bytes(data[s:e])))
        data[h:h + len(old)] = new
    open(path, "wb").write(data)
    print("PATCHED %d occurrence(s) -> %s" % (len(hits), new.decode()))
    if not hits:
        sys.exit("STAGE_FAIL: %r not found in %s" % (old, path))

# 1. WebKit's PKGLIBEXECDIR/PKGLIBDIR (process binaries + injected bundle).
WK = os.path.join(ST, "rni-wpe/lib/libWPEWebKit-2.0.so.1")
patch_same_len(WK, PKG.encode(), b"/opt/rni-wpe/libexec", b"/wpe-webkit-2.0")
# 1b. BWRAP_EXECUTABLE: the sandbox is always on in the 2022 API; point it at the stand-in.
patch_same_len(WK, b"/usr/bin/bwrap", b"/opt/rni-wpe/b", b"")
os.symlink("libexec/rni-no-sandbox", os.path.join(ST, "rni-wpe/b"))
# 2. GIO_MODULE_DIR, so libsoup finds the bundled TLS backend with no env var.
patch_same_len(os.path.join(ST, "rni-wpe/lib/libgio-2.0.so.0"), (ML + "/gio/modules").encode(),
               b"/opt/rni-wpe/lib/gio", b"/modules")

# Leftover absolute Debian paths that matter at run time.
left = sh("sh", "-c", "grep -l -a -r '/usr/lib/aarch64-linux-gnu/wpe-webkit-2.0' %s || true" % ST).split()
print("LEFTOVER_PKGLIBEXECDIR_FILES", left)

print("KEPT_ON_IMAGE", " ".join(sorted(kept)))
print("BUNDLED %d libs" % len(libs))
for so in sorted(libs):
    print("  ", so)
print(sh("du", "-sh", ST).strip())
uid = int(os.environ.get("HOST_UID", "0"))
for d, ds, fs in os.walk(ST):
    for n in ds + fs:
        os.lchown(os.path.join(d, n), uid, uid)
os.lchown(ST, uid, uid)
