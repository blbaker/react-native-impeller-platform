# Contributing

Thanks for looking at this project. It's a from-scratch out-of-tree React
Native platform rendered through Flutter's Impeller engine, and it's still
pre-release, so expect some rough edges.

## Before you start

Read [AGENTS.md](AGENTS.md) and
[docs/engineering-standards.md](docs/engineering-standards.md). They apply
whether you're a person or an AI agent making the change. AGENTS.md has the
setup and command reference, the standards doc has the rules changes are held
to (pragmatic, minimal diffs, root-cause fixes, test first).

## Building from a clean clone

You need Node 20+, CMake, and a C++ compiler toolchain for your platform.

```bash
git clone https://github.com/blbaker/react-native-impeller-platform.git
cd react-native-impeller-platform
```

GLFW is fetched, not committed, so it has to run before the engine build or
CMake fails with "GLFW not found":

```bash
bash tools/glfw-fetch.sh
```

Then build the engine for your platform:

```bash
# Linux
bash tools/engine-build.sh linux x64

# macOS (Apple Silicon)
bash tools/engine-build.sh darwin arm64

# Windows (from a shell with cmd.exe on PATH)
bash tools/engine-build.sh win32 x64
```

The first build compiles Hermes from source and fetches the pinned Impeller
SDK; expect it to take a while. It stages the result under
`packages-engine/engine-<platform>-<arch>/bin/`.

### Platform notes

- **Linux**: renders through Mesa's software rasterizer (`llvmpipe`) in a
  headless/CI environment. There's no GPU requirement to run the gates.
- **macOS**: renders through ANGLE over Metal. Windowed gates need a real
  display; headless gates run anywhere.
- **Windows**: renders through ANGLE over Direct3D 11. The build script shells
  out to `cmd.exe`/MSVC, so it needs to run somewhere that can reach it (WSL
  with the Windows toolchain on `PATH` works).

## Running the gates

```bash
bash tools/ci-all.sh          # the core gate chain
bash tools/ci-<name>.sh       # one gate, e.g. tools/ci-headless.sh
```

Each gate renders a small fixture app and compares the output pixel-by-pixel
against an oracle. If you touch engine or package code, rebuild before
re-running a gate. Gates read the already-staged binary, they don't rebuild
it for you.

### Mutation-verify: proving a gate can actually fail

Every `tools/ci-*.sh` gate has a matching `tools/mutation-verify-*.sh`. It
re-introduces the exact defect the gate exists to catch and checks that the
gate goes red for that reason, then confirms it goes green again once the
defect is reverted. A gate nobody has watched fail is not a proof of
anything. Run the mutation-verify script for any gate you add or change:

```bash
bash tools/mutation-verify-<name>.sh
```

If you add a new `tools/ci-*.sh`, add its `tools/mutation-verify-*.sh` in the
same PR.

### Repo hygiene standards

```bash
node --test tools/standards/*.test.mjs
```

This checks things like file size on new files, conventional commit subjects
on your branch, and that new CI gates ship a mutation-verify script. See
[docs/engineering-standards.md](docs/engineering-standards.md) for the full
rule set this mechanizes a subset of.

## Branching and commits

- Branch names: `feat/<short-description>`, `fix/<short-description>`,
  `refactor/...`, `docs/...`, `ci/...`, `chore/...`.
- One change per branch. A fix you spot along the way goes in its own branch.
- Commit subjects follow [Conventional Commits](https://www.conventionalcommits.org/):
  `feat: add resize handling for the GLFW surface`, `fix: correct caret
  offset after a paste`.
- Keep new files at or under 300 lines. If a file you're editing is already
  bigger, split off only the part your change touches rather than rewriting
  it.

## Opening a pull request

Use the PR template. It asks for the acceptance criteria you were given and
how you checked each one, the exit codes of the gates you ran, and anything
you were unsure about. A visual change needs a screenshot in the PR.

PRs are squash-merged against `main`. CI runs the same gate chain
(`tools/ci-all.sh`) plus the workflow policy check and `actionlint` on any
workflow file changes.

## Using an AI agent

If you're using Claude Code, Codex, or a similar coding agent, point it at
[`AGENTS.md`](AGENTS.md) first ([`CLAUDE.md`](CLAUDE.md) at the repo root just points there).
It has the build commands, the repo layout, and the standing rules, most
importantly, that an agent should never push to `main`, merge a PR,
force-push, or touch the publish guard in `.github/workflows/release.yml`.
Those stay human actions.

## Release process

Versions are managed by [Release Please](https://github.com/googleapis/release-please)
based on your commits' conventional-commit types. You don't bump version
numbers by hand.

### Publishing to npm

Publishing uses [npm trusted publishing](https://docs.npmjs.com/trusted-publishers):
the repo stores no npm token. A version tag runs `.github/workflows/release.yml`,
which runs the gates, does a `npm publish --dry-run` of every package, and then,
only when the repository variable `RNI_PUBLISH_ENABLED` is `true`, runs
`npm stage publish` for each package with a short-lived OIDC credential. Staged
versions are not public. A maintainer approves each one with 2FA on npmjs.com
(Staged Packages tab) or with `npm stage approve <id>`. Approve the three engine
packages before `react-native-impeller-platform`, because it pins them exactly.

One-time setup, done by a maintainer with npm 11.15.0 or later and 2FA on:

1. Each package has to exist on npm before a trusted publisher can be added.
   For a name that doesn't exist yet, `npm stage publish` creates it with
   npm's `0.0.0-stage` placeholder. Run it once in each package directory and
   reject the staged version with `npm stage reject <id>`.
2. Add the trusted publisher for each of the four packages:

   ```bash
   for p in react-native-impeller-platform \
            @blbaker/react-native-impeller-platform-engine-darwin-arm64 \
            @blbaker/react-native-impeller-platform-engine-linux-x64 \
            @blbaker/react-native-impeller-platform-engine-win32-x64; do
     npm trust github "$p" --repo blbaker/react-native-impeller-platform \
       --file release.yml --env npm-publish --allow-stage-publish --yes
     sleep 2
   done
   ```

   A new trusted publisher expires if it isn't used within 2 days, so add it
   right before the first tagged release.
3. On npmjs.com, set each package's Settings → Publishing access to "Require
   two-factor authentication and disallow tokens".

`tools/ci-workflows.sh` enforces the workflow side: a real publish needs the
guard variable, `id-token: write` on the publishing job only, and no npm token.

The engine binaries are built by `.github/workflows/engines.yml`, on a Linux
runner for `linux-x64` and a macOS runner for `darwin-arm64`. The release job
unpacks those builds and runs `tools/ci-release-meta.sh` with
`RNI_REQUIRE_ENGINE_BINARIES=1`. That check fails unless every engine package
holds a binary for its own OS and CPU, with its exec bit set, that `npm pack`
would actually ship. Windows has no CI build yet, so until it does, a release
stops at that check and names `engine-win32-x64`.
