#!/usr/bin/env python3
"""EME arm driver for tools/ci-webview.sh: ask the ENGINE for 8 readbacks.

  webview_eme_series.py <engine-log> <workdir>

The engine runs with --screenshot <workdir>/<tag>-shot.ppm --screenshot-when-file
<workdir>/<tag>-shot.go --screenshot-series 8 (<tag> = the log's basename). Once the
page is playing (its clock 1 s past the 120 s start) or the player gave up, this
creates the when-file; the engine captures, removes it, and 2 s later it is created
again, until 8 captures are logged. The verdict is tools/webview_eme_check.py's,
on those engine readbacks (the same rules as the arm64 arm).
"""
import os
import re
import sys
import time

LOG, WORK = sys.argv[1], sys.argv[2]
TAG = os.path.basename(LOG)[:-4] if LOG.endswith(".log") else os.path.basename(LOG)
GO = os.path.join(WORK, TAG + "-shot.go")
N, GAP = 8, 2.0
READY = re.compile(r"WVEME (tick t=(12[1-9]|1[3-9][0-9]|[2-9][0-9][0-9])\.|fail )")


def text():
    try:
        return open(LOG, errors="replace").read()
    except OSError:
        return ""


def wait(pred, secs):
    end = time.time() + secs
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.2)
    return False


def shots():
    return len(re.findall(r"^rn-impeller: screenshot=", text(), re.M))


if not wait(lambda: READY.search(text()), 45):
    print("EME_SERIES_FAIL page never played or failed in 45 s", flush=True)
    sys.exit(1)
for k in range(N):
    if k:
        time.sleep(GAP)
    open(GO, "w").close()
    if not wait(lambda: shots() >= k + 1, 20):
        print("EME_SERIES_FAIL capture %d never logged" % k, flush=True)
        sys.exit(1)
print("EME_SERIES_OK %d engine captures" % N, flush=True)
