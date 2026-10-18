---
title: Contributing & releasing
---

# Contributing & releasing

This page covers working on the repository itself. If you just want to use
the published package in an app, you don't need any of this; see
[Getting started](./getting-started).

Read [AGENTS.md](https://github.com/blbaker/react-native-impeller-platform/blob/main/AGENTS.md)
and [docs/engineering-standards.md](https://github.com/blbaker/react-native-impeller-platform/blob/main/docs/engineering-standards.md)
first. Both apply whether the change comes from a person or an AI agent.

## Building from a clean clone

You need Node 20+, CMake, and a C++ compiler toolchain for your platform.

```bash
git clone https://github.com/blbaker/react-native-impeller-platform.git
cd react-native-impeller-platform
```

See [Building the engine from source](./guides/building-the-engine-from-source)
for the GLFW fetch step, the per-OS build commands, and platform notes.

## Running the gates

```bash
bash tools/ci-all.sh          # the core gate chain
bash tools/ci-<name>.sh       # one gate, e.g. tools/ci-headless.sh
```

Each gate renders a small fixture app and compares it pixel by pixel
against an oracle. Rebuild before re-running a gate if you've touched
engine or package code; gates read the already-staged binary rather than
rebuilding it for you.

### Mutation-verify: proving a gate can actually fail

Every `tools/ci-*.sh` gate has a matching `tools/mutation-verify-*.sh`. It
re-introduces the exact defect the gate exists to catch, confirms the gate
goes red for that reason, then confirms it goes green again once the defect
is reverted. A gate nobody has watched fail isn't proof of anything.

```bash
bash tools/mutation-verify-<name>.sh
```

A new `tools/ci-*.sh` ships its matching `mutation-verify` script in the
same pull request.

### Repo hygiene standards

```bash
node --test tools/standards/*.test.mjs
```

This checks file size on new files, conventional-commit subjects on your
branch, that every new CI gate ships a mutation-verify script, and that the
diff holds no secrets, personal paths, or internal-only terms.

## Branching and commits

- Branch names: `feat/<short-description>`, `fix/...`, `refactor/...`,
  `docs/...`, `ci/...`, `chore/...`.
- One change per branch. A fix noticed along the way goes in its own branch.
- Commit subjects follow [Conventional Commits](https://www.conventionalcommits.org/).
- Keep new files at or under 300 lines. If a file you're editing is already
  bigger, split off only the part your change touches.

## Opening a pull request

PRs are squash-merged against `main`. CI runs the same gate chain
(`tools/ci-all.sh`) plus a workflow policy check and `actionlint` on any
workflow file changes. A visual change needs a real screenshot in the PR,
not just a description of it.

## Release process

Versions are managed by [Release Please](https://github.com/googleapis/release-please)
from your commits' conventional-commit types; you don't bump version numbers
by hand.

Publishing uses [npm trusted publishing](https://docs.npmjs.com/trusted-publishers):
the repository stores no npm token. A version tag runs the release
workflow, which runs the gates, does a `npm publish --dry-run` for every
package, and then, only when the repository variable `RNI_PUBLISH_ENABLED`
is `true`, stages each package with `npm stage publish`. A maintainer
approves each staged version with 2FA on npmjs.com or
`npm stage approve <id>`. The three engine packages are approved before
`react-native-impeller-platform`, since it pins them exactly.

Engine binaries are built per OS by a separate workflow: a Linux runner for
`linux-x64`, a macOS runner for `darwin-arm64`, and a Windows runner for
`win32-x64`. Before any real publish step runs, `tools/ci-release-meta.sh`
checks, with `RNI_REQUIRE_ENGINE_BINARIES=1`, that every engine package
actually holds a binary for its own OS and CPU, with its exec bit set, that
`npm pack` would ship. That check exists because `packages-engine/*/bin` is
left out of git; without it, a tag could publish an engine package holding
only a `README.md`.

A separate policy gate, `tools/ci-workflows.sh`, checks the workflow files
themselves rather than trusting review alone: a real publish must stay
reachable only from a version tag, must run after the gates in the same
workflow, must stay behind the one guard variable, and the OIDC token used
for trusted publishing must be scoped to the publishing job only, never
granted at the top of the file. Every action reference is pinned to a
version tag.

## Using an AI agent

If you're using Claude Code, Codex, or a similar coding agent, point it at
[`AGENTS.md`](https://github.com/blbaker/react-native-impeller-platform/blob/main/AGENTS.md)
first. It has the build commands, the repo layout, and the standing rule
that an agent never pushes to `main`, merges a PR, force-pushes, or touches
the publish guard in `.github/workflows/release.yml`. Those stay human
decisions.
