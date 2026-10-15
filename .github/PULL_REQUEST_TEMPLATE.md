## Summary

<!-- What does this change, and why. -->

## Acceptance criteria

<!-- List each acceptance criterion from the ticket/issue and how you
     verified it. One line each: criterion -> how you checked it. -->

-
-

## How this was tested

<!-- Gates run, mutation-verify scripts run, screenshots for visual changes.
     Paste exit codes, not just "it passed". -->

## What I was unsure about

<!-- Call out anything a reviewer should look at closely. An empty section
     here reads as "I checked everything", which is rarely true. -->

## Checklist

- [ ] Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
- [ ] `tools/ci-all.sh` (or the gates this change touches) passes locally
- [ ] Any new `tools/ci-*.sh` ships a matching `tools/mutation-verify-*.sh`
- [ ] Touched files stay at or under 300 lines, or the oversized file was
      split rather than grown further
- [ ] No secrets, personal paths, or internal hostnames in the diff
