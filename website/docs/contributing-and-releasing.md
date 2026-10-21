---
title: Contributing and releasing
---

# Contributing and releasing

If you want to use the published package in an app, you don't need any
of this. See [Get started](./getting-started) instead.

Read [AGENTS.md](https://github.com/blbaker/react-native-impeller-platform/blob/main/AGENTS.md)
and [docs/engineering-standards.md](https://github.com/blbaker/react-native-impeller-platform/blob/main/docs/engineering-standards.md)
first. Both apply whether the change comes from a person or an AI agent.

## Build from a clean clone

Building the engine requires Node 20 or later, CMake, and a C++ compiler
toolchain for your platform. To clone the repository, run the following
commands:

```bash
git clone https://github.com/blbaker/react-native-impeller-platform.git
cd react-native-impeller-platform
```

For more information about the GLFW fetch step, the per-OS build
commands, and platform notes, see
[Build the engine from source](./guides/building-the-engine-from-source).

## Run the gates

To run the core gate chain, or a single gate, run one of the following
commands:

```bash
bash tools/ci-all.sh          # the core gate chain
bash tools/ci-NAME.sh         # one gate, for example tools/ci-headless.sh
```

Replace `NAME` with the gate's name, for example `headless`.

Each gate renders a small fixture app and compares it pixel by pixel
against an oracle. Rebuild before you re-run a gate if you've touched
engine or package code. A gate reads the already-staged binary instead of
rebuilding it for you.

### Mutation-verify: how a gate proves it can fail

Every `tools/ci-*.sh` gate has a matching `tools/mutation-verify-*.sh`
script. It re-introduces the exact defect the gate exists to catch,
confirms the gate goes red for that reason, then confirms the gate goes
green again after you revert the defect.

To run a mutation-verify script, run the following command:

```bash
bash tools/mutation-verify-NAME.sh
```

Replace `NAME` with the matching gate's name. A new `tools/ci-*.sh` script
ships its matching mutation-verify script in the same pull request.

### Repo hygiene standards

To check repo hygiene standards, run the following command:

```bash
node --test tools/standards/*.test.mjs
```

This command checks file size on new files, conventional-commit subjects
on your branch, that every new CI gate ships a mutation-verify script,
and that the diff holds no secrets, personal paths, or internal-only
terms.

## Branch and commit conventions

The following conventions apply to branches and commits:

- Branch names: `feat/SHORT_DESCRIPTION`, `fix/...`, `refactor/...`,
  `docs/...`, `ci/...`, `chore/...`. Replace `SHORT_DESCRIPTION` with a
  short, hyphenated summary of the change.
- One change per branch. A fix you notice along the way goes in a
  separate branch.
- Commit subjects follow [Conventional Commits](https://www.conventionalcommits.org/).
- Keep new files at or under 300 lines. If a file you're editing is
  already bigger, split off only the part your change touches.

## Open a pull request

PRs are squash-merged against `main`. CI runs the same gate chain
(`tools/ci-all.sh`) plus a workflow policy check and `actionlint` on any
workflow file changes. A visual change needs a real screenshot in the PR
instead of a description of it.

## Release process

[Release Please](https://github.com/googleapis/release-please) manages
versions from your commits' conventional-commit types, so you don't bump
version numbers by hand.

Publishing uses [npm trusted publishing](https://docs.npmjs.com/trusted-publishers):
the repository stores no npm token. A version tag runs the release
workflow, which runs the gates, runs `npm publish --dry-run` for every
package, and then, only when the repository variable
`RNI_PUBLISH_ENABLED` is `true`, stages each package with
`npm stage publish`. A maintainer approves each staged version with 2FA
on npmjs.com, or with `npm stage approve STAGE_ID`. Replace `STAGE_ID`
with the ID that `npm stage publish` prints for that package. The
maintainer approves the three engine packages before
`react-native-impeller-platform`, since it pins them exactly.

A separate workflow builds engine binaries per OS: a Linux runner builds
`linux-x64`, a macOS runner builds `darwin-arm64`, and a Windows runner
builds `win32-x64`. Before any real publish step runs,
`tools/ci-release-meta.sh` checks, with `RNI_REQUIRE_ENGINE_BINARIES=1`,
that every engine package holds a binary for its OS and CPU,
with its exec bit set, the same binary that `npm pack` ships. That check
exists because `packages-engine/*/bin` is left out of git. Without the
check, a tag could publish an engine package holding only a `README.md`
file.

A separate policy gate, `tools/ci-workflows.sh`, checks the workflow
files. It confirms that a
real publish stays reachable only from a version tag, runs after the
gates in the same workflow, stays behind the one guard variable, and that
the OIDC token used for trusted publishing stays scoped to the publishing
job only, never granted at the top of the file. Every action reference
is pinned to a version tag.

## Use an AI agent

If you're using Claude Code, Codex, or a similar coding agent, point it
at [AGENTS.md](https://github.com/blbaker/react-native-impeller-platform/blob/main/AGENTS.md)
first. It has the build commands, the repository layout, and the
standing rule that an agent never pushes to `main`, merges a PR,
force-pushes, or touches the publish guard in
`.github/workflows/release.yml`. Those stay human decisions.
