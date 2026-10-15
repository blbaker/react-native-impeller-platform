#!/usr/bin/env python3
"""FP-20 grep gate: no GL symbol above the GL backend.

usage:
  gl_symbol_scan.py scan [ROOT]   every tracked engine/ source outside the GL
                                  backend files, comments and strings stripped;
                                  prints each hit, exit 1 when there is one
  gl_symbol_scan.py self-test     the scanner sees a planted call and ignores
                                  comments, strings and GL-named files

A GL symbol is a GL entry point (gl[A-Z]...), a GL_ constant or GL type, a
GL-only interop call (ImpellerTextureCreateWithOpenGLTextureHandleNew,
ImpellerSurfaceCreateWrappedFBONew, ImpellerContextCreateOpenGLESNew) or a GL
backend internal (GlNamePool, WrapNewGlName, scenegraph_gl). GL backend files
are the ones named for GL: a basename containing "GL", "Gl" or "Gles"
(engine/host/*GL*/*Gl*/*Gles*, base/GlValidation, scenegraph/*Gl.cpp
including SupersampleBackendGl.cpp, the GL supersample backend). Third-party
code and engine/spike experiments are not the engine.
"""
import os
import re
import subprocess
import sys

SYMBOL = re.compile(
    r"\b(gl[A-Z]\w*|GL_[A-Z0-9_]+|GL(?:uint|int|enum|sizei|boolean|float|sync|char|void|bitfield|ubyte)\b"
    r"|ImpellerTextureCreateWithOpenGLTextureHandleNew|ImpellerSurfaceCreateWrappedFBONew"
    r"|ImpellerContextCreateOpenGLESNew|GlNamePool|WrapNewGlName|scenegraph_gl)")
GL_FILE = re.compile(r"(GL|Gl|Gles)")
SOURCE = re.compile(r"\.(c|cc|cpp|h|hpp|mm|m)$")


def strip(text):
    # Block comments keep their newlines so hit line numbers stay right.
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def is_gl_file(path):
    return bool(GL_FILE.search(os.path.basename(path)))


def scan_text(path, text):
    hits = []
    if is_gl_file(path):
        return hits
    for i, line in enumerate(strip(text).split("\n"), 1):
        found = sorted(set(m.group(1) for m in SYMBOL.finditer(line)))
        if found:
            hits.append(f"{path}:{i}: {','.join(found)}")
    return hits


def engine_files(root):
    cmd = ["git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "engine"]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.split()
    return [f for f in out if SOURCE.search(f) and "/third_party/" not in f
            and not f.startswith("engine/spike/")]


def scan(root):
    files = engine_files(root)
    hits, gl_files, gl_hits = [], 0, 0
    for f in files:
        with open(os.path.join(root, f), errors="replace") as fh:
            text = fh.read()
        if is_gl_file(f):
            gl_files += 1
            gl_hits += sum(1 for line in strip(text).split("\n") if SYMBOL.search(line))
            continue
        hits += scan_text(f, text)
    for h in hits:
        print(h)
    print(f"scanned={len(files)} gl_backend_files={gl_files} gl_backend_symbol_lines={gl_hits} "
          f"violations={len(hits)}")
    return 1 if hits else 0


def self_test():
    planted = "void f() {\n  // glFinish(); in a comment\n  const char* s = \"glFlush\";\n  glFinish();\n}\n"
    assert scan_text("engine/scenegraph/Planted.cpp", planted) == [
        "engine/scenegraph/Planted.cpp:4: glFinish"], scan_text("engine/scenegraph/Planted.cpp", planted)
    assert scan_text("engine/scenegraph/PlantedGl.cpp", planted) == []
    adopt = "t = ImpellerTextureCreateWithOpenGLTextureHandleNew(c, &d, n);\nGLuint x; GL_RGBA8;\n"
    hits = scan_text("engine/host/main.cpp", adopt)
    assert len(hits) == 2 and "ImpellerTextureCreateWithOpenGLTextureHandleNew" in hits[0], hits
    block = "/* glFinish();\n glFlush(); */\nint ok;\n"
    assert scan_text("engine/x.cpp", block) == []
    print("self_test=ok")
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "scan"
    if cmd == "self-test":
        sys.exit(self_test())
    sys.exit(scan(sys.argv[2] if len(sys.argv) > 2 else "."))
