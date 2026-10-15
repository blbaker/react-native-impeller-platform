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
| [research/flutter-impeller-parity.pdf](research/flutter-impeller-parity.pdf) | Spec + appendices as one linked PDF (citations are GitHub permalinks) |
| [DECISIONS.md](DECISIONS.md) | Baker's directives verbatim and every decision made on his behalf |
| [PASSES.md](PASSES.md) | The work plan: FP-00..FP-56, each with its gate and mutants; markers show status |
| [PROGRESS.md](PROGRESS.md) | Generated ledger: every pass attempt, time, model, commit, session summary |
| [PR.md](PR.md) | Generated pull-request description (synced to the draft PR) |
| [STATE.md](STATE.md) | Hand-off notes between pass sessions (gotchas, numbers) |
| [BLOCKERS.md](BLOCKERS.md) | Blocked passes: exact error, diagnosis, triage decision |
| [RULES.md](RULES.md) | The protocol every pass session follows |
| `evidence/` | Before/after images and charts posted for pixel- or timing-changing passes |
| `sessions/` | Raw loop log + each session's final report, copied from `.loop-logs/` |
| `ARCHITECTURE.md` | Written by FP-56: the as-built architecture, every claim pointing at our code |

Regenerate the PDF: `python3 tools/flutter-parity-compile.py` (needs `~/.local/state/rni-tool/scripts/md2pdf.py`).
Re-audit citations: `python3 tools/flutter-parity-cite-audit.py audit docs/eng/flutter-parity/SPEC.md docs/eng/flutter-parity/research/0*.md`.
