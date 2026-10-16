# Flutter-parity rendering engine: documentation index

Goal (Baker, 2026-10-14): "an enterprise grade, bulletproof rendering engine for RN" that uses
Impeller the way Flutter does, "strictly but in a RN way". Branch `feat/flutter-parity`.

| File | What it is |
|---|---|
| [SPEC.md](SPEC.md) | The design: Flutter's architecture mapped to RN, backend matrix, ranked gaps, roadmap. Start here. |
| [research/01-frame-pipeline-threading.md](research/01-frame-pipeline-threading.md) | Appendix A: threads, vsync, pipeline, rasterizer, resize, RN mapping |
| [research/02-impeller-internals.md](research/02-impeller-internals.md) | Appendix B: AA, paths, clips, text atlas, images, filters, shaders, backend switch |
| [research/03-embedding-platform.md](research/03-embedding-platform.md) | Appendix C: per-OS embedding, present, resize, background, context loss, IO, textures, platform views |
| [research/04-quality-reliability.md](research/04-quality-reliability.md) | Appendix D: tests, goldens, validation layers, fuzzing, sanitizers, tracing, frame timing, CI |
| [research/METHOD.md](research/METHOD.md) | How the research was done and audited (sources, pins, citation audit) |
| [DIAGRAMS.md](DIAGRAMS.md) | Visual docs: target thread model, backend per OS, how a change lands (Mermaid, renders on GitHub) |
| [DECISIONS.md](DECISIONS.md) | Baker's directives verbatim and every decision made on his behalf |

This directory also held a layer of internal process tracking for the
automation loop that built this engine: per-pass work plans, generated
progress ledgers and PR descriptions, session hand-off notes, the loop's own
operating rules, an as-built architecture snapshot, and raw per-session logs.
That layer isn't part of this public copy — it's a record of how the work was
run, not design documentation a contributor needs, and most of it names
machines and infrastructure that don't exist outside the original setup. The
files listed in the table above are the real design record and are unaffected.

Re-audit citations: `python3 tools/flutter-parity-cite-audit.py audit docs/eng/flutter-parity/SPEC.md docs/eng/flutter-parity/research/0*.md`.
