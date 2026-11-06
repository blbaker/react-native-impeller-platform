#!/usr/bin/env python3
"""Checks for tools/ci-webview-osk.sh. Stdlib only.

  webview_osk_check.py <engine.log>

The log is cut at each `OSK_DRIVE tap <name>` line, so every rule reads only
what happened after that tap. Rules run in tap order and a tap the driver never
reached fails as that step, so a stalled run names the broken arm. Prints
WEBVIEW_OSK_FAIL: <arm>: <why>, exits 1 on the first broken rule.
"""
import json
import re
import sys

log = open(sys.argv[1], errors="replace").read()
CYCLES = 5
TAPS = ["text", "password", "blank", "text-again", "key-t", "key-e", "key-s", "key-t2"]
for i in range(1, CYCLES + 1):
    TAPS += ["done-%d" % i] + (["phys-key"] if i == CYCLES else []) + ["refocus-%d" % i]
TAPS += ["rn-chrome"]
TEXT = "focused=true isPassword=false purpose=free-form"
PASSWORD = "focused=true isPassword=true purpose=password"
BLUR = "focused=false isPassword=false purpose=null"


def bad(arm, msg):
    print("WEBVIEW_OSK_FAIL: %s: %s" % (arm, msg), file=sys.stderr)
    sys.exit(1)


cuts = [(m.start(), m.group(1)) for m in re.finditer(r"^OSK_DRIVE tap (\S+)", log, re.M)]
if not cuts:
    bad("drive", "no tap at all (the page never reported 'stage ready')")
seg = {name: log[start:cuts[i + 1][0] if i + 1 < len(cuts) else len(log)] for i, (start, name) in enumerate(cuts)}


def need(arm, tap, pattern, what):
    if tap not in seg:
        bad(arm, "the driver never reached the '%s' tap (an earlier step stalled)" % tap)
    if not re.search(pattern, seg[tap], re.M):
        bad(arm, "no %s after the '%s' tap (/%s/)" % (what, tap, pattern))


def focus(s):
    return re.findall(r"WVAPP editableFocus (focused=\S+ isPassword=\S+ purpose=\S+)$", s, re.M)


def focus_is(arm, tap, want):
    need(arm, tap, r"WVAPP editableFocus ", "editableFocus")
    got = focus(seg[tap])
    if got != want:
        bad(arm, "the '%s' tap gave %s, want %s" % (tap, got, want))


if focus(log[:cuts[0][0]]):
    bad("focus-load", "editableFocus before any tap: %s" % focus(log[:cuts[0][0]]))
# Tap 1: focus, then sendText 'abc' as ONE input method commit (no key events),
# sendKey Backspace as a real key, the read-back, non-ASCII, an unknown key name.
focus_is("focus-text", "text", [TEXT])
need("commit", "text", r'WVPAGE beforeinput t \S+ "abc"$', "single beforeinput carrying \"abc\"")
if re.search(r"WVPAGE keydown t [abc]$", seg["text"], re.M):
    bad("commit", "sendText produced key events (keysym mapping), want an input method commit")
need("backspace", "text", r"WVPAGE keydown t Backspace$", "keydown Backspace from sendKey")
need("value", "text", r'WVAPP title "read:ab"$', "value 'ab' read back via injectJavaScript + navState")
need("non-ascii", "text", r'WVAPP title "read:ab\u00e9\u6f22"$', "value 'ab\u00e9\u6f22' from sendText")
need("unknown-key", "text", r"WVAPP sendKey-unknown threw .*unknown key 'NoSuchKey'", "throw for sendKey('NoSuchKey')")
# Tap 2: straight from the text field to the password field.
need("focus-password", "password", r"WVAPP editableFocus ", "editableFocus")
pw = focus(seg["password"])
if pw[-1] != PASSWORD or any(f not in (BLUR, PASSWORD) for f in pw):
    bad("focus-password", "the 'password' tap gave %s, want [...%s]" % (pw, PASSWORD))
need("password-text", "password", r'WVAPP title "read:pw1"$', "password value 'pw1' from sendText")
# Tap 3: the page outside the fields; tap 4: Enter submits; tap 5: outside the web view.
focus_is("focus-blank", "blank", [BLUR])
focus_is("focus-text-again", "text-again", [TEXT])
need("enter", "text-again", r"WVPAGE keydown t Enter$", "keydown Enter from sendKey")
need("submit", "text-again", r'WVPAGE submit "ab\u00e9\u6f22"$', "form submit from Enter")
need("submit-title", "text-again", r'WVAPP title "submitted:ab\u00e9\u6f22"$', "the submit title in navState")
# Taps 5-8: the app's own keyboard. The keys are RN views OUTSIDE the web view, pressed
# with setKeepFocus(true): every press keeps the page focused (no blur, no editableFocus
# between keys), reaches the RN key's onPress, and its sendText lands in the field.
need("keep-set", "text-again", r"^rn-impeller: webview keep_focus id=\d+ on=1$", "setKeepFocus(true) reaching the engine")
typed = "ab\u00e9\u6f22"
for tap, ch in (("key-t", "t"), ("key-e", "e"), ("key-s", "s"), ("key-t2", "t")):
    typed += ch
    arm = "keep-" + tap
    need(arm, tap, r"^rn-impeller: webview_input keep_focus id=\d+ ", "kept focus on the press outside the web view")
    if focus(seg[tap]):
        bad(arm, "editableFocus between keys: %s" % focus(seg[tap]))
    if re.search(r"WVPAGE blur t$|WVAPP blurred while keeping focus$", seg[tap], re.M):
        bad(arm, "the field blurred on the '%s' press" % tap)
    if "no editable has input focus" in seg[tap]:
        bad(arm, "the helper got the text with no focused editable")
    need(arm, tap, r"WVAPP key %s$" % ch, "the RN key's onPress (the press must still reach the app)")
    need(arm, tap, r'WVPAGE beforeinput t \S+ "%s"$' % ch, "single beforeinput carrying \"%s\"" % ch)
    need(arm, tap, r'WVAPP title "read:%s"$' % typed, "value %r read back" % typed)
# Then 5 cycles of the console's Done key (an RN view outside, pressed while the flag
# is set, so the press keeps focus) -> setKeepFocus(false) -> a tap on the SAME field.
# The tap must report focus again: the console reopens its keyboard on that event. It
# can only, because clearing the flag blurred the view (a tap on a field that still
# has focus changes nothing WebKit reports). The blur's event may land after the next
# tap line, so each cycle reads the Done and refocus segments together.
for i in range(1, CYCLES + 1):
    done, refocus = "done-%d" % i, "refocus-%d" % i
    between = ["phys-key"] if i == CYCLES else []
    if refocus not in seg:
        bad(refocus, "the driver never reached the '%s' tap (an earlier step stalled)" % refocus)
    need(refocus, refocus, r"WVAPP editableFocus ", "editableFocus (the same field tapped after Done)")
    got = focus("".join(seg[t] for t in [done] + between + [refocus]))
    if got != [BLUR, TEXT]:
        bad(refocus, "Done then a tap on the same field gave %s, want %s" % (got, [BLUR, TEXT]))
    need(done, done, r"^rn-impeller: webview_input keep_focus id=\d+ ", "kept focus on the Done press (flag still set)")
    need(done, done, r"WVAPP key done$", "the Done key's onPress")
    need(done, done, r"^rn-impeller: webview keep_focus id=\d+ on=0 blur=1$",
         "setKeepFocus(false) reaching the engine and blurring the focused view")
    if re.search(r"WVAPP blurred while keeping focus$", seg[done], re.M):
        bad(done, "the field blurred before setKeepFocus(false)")
    if i < CYCLES:
        need(refocus, refocus, r"^rn-impeller: webview keep_focus id=\d+ on=1$", "setKeepFocus(true) again")
# Before the last tap, a physical key: the blurred page must not get it (the engine's
# focus was cleared with the blur), so it reaches RN's key handler instead.
if re.search(r"^rn-impeller: key_(event|char) .*webview=\d+$|WVPAGE keydown t x$", seg["phys-key"], re.M):
    bad("phys-key", "a physical key after Done still went to the page: the engine kept the blurred view focused")
need("phys-key", "phys-key", r"^rn-impeller: key_event type=down key=x ", "the physical key reaching RN")
# Tap 9, the negative control: with the flag cleared, a press outside blurs as before.
if re.search(r"webview_input keep_focus", seg.get("rn-chrome", "")):
    bad("keep-off", "focus kept on the 'rn-chrome' press after setKeepFocus(false)")
focus_is("focus-rn-chrome", "rn-chrome", [BLUR])
if [n for _, n in cuts] != TAPS or "OSK_DRIVE_OK" not in log:
    bad("drive", "taps %s, want %s and OSK_DRIVE_OK" % ([n for _, n in cuts], TAPS))

# The raw impellerWebViewEvent (what the console listens to) carries the same events.
raw = [json.loads(j) for j in re.findall(r"WVAPP raw editableFocus (\{.*\})$", log, re.M)]
as_line = ["focused=%s isPassword=%s purpose=%s" % (str(r["focused"]).lower(), str(r["isPassword"]).lower(),
                                                    "null" if r["purpose"] is None else r["purpose"]) for r in raw]
if as_line != focus(log):
    bad("raw-event", "impellerWebViewEvent editableFocus %s != onEditableFocus %s" % (as_line, focus(log)))
print("WEBVIEW_OSK_CHECK_OK focus_events=%d %s" % (len(raw), " | ".join(as_line)))
