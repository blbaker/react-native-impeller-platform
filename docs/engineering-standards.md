# Engineering standards

These rules apply to every change in this repo, human or AI-assisted. The
issue or PR description sets *what* to build; these rules set *how*. When they
conflict, be explicit about the tradeoff in the PR rather than silently
picking one.

## Pragmatic

Pick the simplest solution that meets the acceptance criteria today. Prefer a
plain function over a pattern, and a pattern over a framework. Code should be
understandable by a reviewer on the first read: match the style already
around you (names, file layout, error handling) rather than introducing your
own.

## YAGNI

Build what the issue asks for. No speculative features, no "while I'm here"
refactors bundled into an unrelated change, no configuration knobs nobody
requested. Add a dependency only when the task genuinely needs it, and say why
in the PR. Don't introduce an abstraction (a factory, a generic wrapper, a
base class) until there are at least two real callers; wait for a third
near-duplicate before extracting shared code.

## Minimal, surgical edits

Touch the fewest files and lines needed to meet the acceptance criteria.
Don't reformat, reorder imports, or tidy up code outside your change in the
same diff. That hides the actual change in noise and makes review slower,
not faster.

New files stay at or under 300 lines. If a file you're touching is already
bigger than that, split off only the part your change needs rather than
rewriting the whole file.

One change per branch. A fix you notice along the way that isn't part of this
change goes in its own branch or issue, not folded into this diff.

## Root cause

Find the cause before you fix it. Fix the cause, not the symptom. No empty
`catch` blocks, no `catch` that swallows the real error, no sleep or timer
added to paper over a race condition, no magic number tuned to make one test
pass. If partway through a change the plan turns out to be wrong, say so
rather than forcing it to work.

## Code quality

- Strict TypeScript where TypeScript is used: no `any`, prefer `unknown`,
  generics, or a real type.
- Prefer pure functions and immutable data. Keep logic testable without
  pulling in a rendering or native dependency where that's avoidable.
- Validate input at a boundary (a parsed bundle, a network response, a file on
  disk) rather than trusting it blindly.
- No secrets in code or config. Reference them by name (an env var, a
  GitHub Actions secret), never the value.
- No debug logging left behind, no commented-out code, no emoji in code or
  UI strings.
- Comments explain *why*, not *what*. Delete a comment that just repeats the
  line below it.

## Tests and proof

Write the failing test first, make it pass, then clean up. Tests check the
acceptance criteria, not implementation details that are free to change later.

A new guard or check (a CI gate, a validation function, a lint rule) needs a
positive control: seed a real violation, show the check catches it, remove
the violation, show the check passes. A check nobody has watched fail is
decoration, not a guard. See `tools/mutation-verify-*.sh` for the pattern
this repo already uses for the engine gates, and `tools/standards/` for the
same idea applied to repo-hygiene checks.

A new `tools/ci-*.sh` gate ships with a matching `tools/mutation-verify-*.sh`
in the same PR.

Before handing off, run the gates your change affects and paste their exit
codes in the PR. Call out any pre-existing failure you did not cause rather
than silently fixing it in an unrelated diff.

A visual change (anything affecting rendering, layout, or UI) needs a real
screenshot in the PR, not just a description of the change.

## Reviewable

- Conventional commit subjects: `feat: add resize handling for the GLFW
  surface`, `fix: correct caret offset after a paste`.
- The PR description lists each acceptance criterion and how it was checked.
- Say what you were unsure about. That's where the reviewer should look
  first.
- Never force-push a branch once it's been reviewed; push a new commit
  instead so review history stays intact.
