# sed rules for tools/enginesession-normalize.sh. One rule per run-varying
# field, each found by diffing two real tools/ci-all.sh runs on an
# unmodified tree -- see that script's header for the full explanation.

# Timing with the unit glued to the number ("63ms", "1.2s"): wall-clock,
# never asserted on by any gate's PASS condition.
s/[0-9]+(\.[0-9]+)?(us|ms|s)\b/<T>/g

# The same, with a space before the unit, as prose lines write it
# (ci-first-present.sh's "heard N ms after JS start").
s/[0-9]+(\.[0-9]+)? (us|ms|s)\b/<T>/g

# Named *_ms= fields (first_present_ms=, js_ms=, boot_wait_ms=): the same
# per-run timing, spelled as a field instead of a unit suffix.
s/([a-z_]*_ms)=[0-9]+/\1=<T>/g

# ci-canvas.sh's own benchmark throughput numbers.
s/ms_per_frame=[0-9.]+/ms_per_frame=<T>/g
s/fps=[0-9.]+/fps=<T>/g

# Ephemeral TCP ports an OS-assigned loopback test server binds to a
# different number every run (ci-p10.sh's Networking gate,
# ci-linkresolve.sh's throwaway registry).
s/port=[0-9]+/port=<PORT>/g

# mktemp-created scratch directories: a fresh random name every run, by
# design (pack-and-consume.sh, ci-p4.sh, ci-linkresolve.sh) -- AND the
# absolute parent of that directory, which is wherever $TMPDIR points on
# the machine/runner that ran it, not engine behavior. Anchored to the two
# known literal labels these lines use so the greedy path match can't
# swallow the label itself.
s#screenshot=[^ ]*/tmp\.[A-Za-z0-9]+#screenshot=<SCRATCH_DIR>#g
s#package [^ ]*/tmp\.[A-Za-z0-9]+#package <SCRATCH_DIR>#g
# Fallback for any other bare "tmp.<random>" this repo's gates print with
# no path in front of it.
s#tmp\.[A-Za-z0-9]+#tmp.<RAND>#g

# ci-animate.sh's pixel-changed count between two time-separated captures
# of a live animation: how far the animation progressed by the moment each
# screenshot landed, which depends on real-world scheduling/load, not on
# engine behavior -- the gate's own PASS rule is only "> 100", never an
# exact count (measured: 12800 and 5120 px both passing, same tree, back
# to back runs).
s/[0-9]+ px changed/<N> px changed/g
s/(animating|static)=[0-9]+px/\1=<N>px/g
