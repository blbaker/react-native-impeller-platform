# AGENTS.md

Instructions for AI coding agents working in this repo. `CLAUDE.md` points
here.

## Setup

- Node 20+ (see `engines.node` in `package/package.json`). Run
  `node --version` before you start.
- A clean clone does not build with `tools/engine-build.sh` alone: GLFW is
  fetched, not committed. Run `bash tools/glfw-fetch.sh` first, or CMake
  fails with "GLFW not found".
- `npm install` inside `engine/rn` for the pinned React Native checkout the
  engine links against. `tools/engine-build.sh` does this for you.

## Layout

- `engine/`: the C++ Impeller host (scene graph, Fabric mounting, native
  modules, platform surfaces).
- `package/`: the `react-native-impeller-platform` JS package.
- `packages-engine/engine-<platform>-<arch>/`: prebuilt engine binaries,
  one package per platform, versioned in lockstep with `package/`.
- `tools/`: build scripts and CI gates. `ci-*.sh` is a gate;
  `mutation-verify-*.sh` proves that gate can actually fail.
- `fixtures/`: small RN apps the gates render and compare pixel by pixel.

## Commands

- `bash tools/engine-build.sh linux x64` (or `darwin arm64` / `win32 x64`):
  build the engine for one platform.
- `bash tools/ci-all.sh`: the core gate chain (headless render, engine
  package, pack-and-consume, mount, conformance, module seam).
- `bash tools/ci-<name>.sh`: an individual gate.
- `bash tools/mutation-verify-<name>.sh`: prove a gate's mutants get caught.
- `node --test tools/standards/*.test.mjs`: the repo-hygiene standards
  suite (see below).

## Engineering standards

Read `docs/engineering-standards.md` before writing or changing any code.
It covers the rules this repo is held to: pragmatic solutions, YAGNI,
surgical edits, root-cause fixes, and test-first development.

`node --test tools/standards/*.test.mjs` runs a deterministic suite that
checks a subset of those rules mechanically (file size on new files,
conventional commit subjects on the branch, every new `ci-*.sh` ships a
`mutation-verify-*.sh`, no secrets or personal paths in the diff). Run it
before you hand off a branch.

## Rules

- Add no dependency a task does not need.
- Never add a git remote, push to `main`, merge a PR, force-push, or change
  repository settings. Those are the maintainer's calls.
- Never weaken or bypass the publish guard in
  `.github/workflows/release.yml` (`RNI_PUBLISH_ENABLED`) or the policy
  gate in `tools/ci-workflows.sh`.
- Branch name by type: `feat/`, `fix/`, `refactor/`, `docs/`, `ci/`,
  `chore/`.
- Commit subjects follow [Conventional Commits](https://www.conventionalcommits.org/).
