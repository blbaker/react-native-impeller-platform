#pragma once
// FP-06: what gates need to stay frame-synchronous on a loaded box.
//   TimeScale()  RNI_TIME_SCALE (>= 1, default 1). Multiplies every test-hook WAIT CEILING
//                (JS drain after a synthetic event, boot drain), never a measured interval.
//                tools/ci-sanitize.sh and tools/ci-tsan.sh export 4.
//   Quit         --quit-on-term: SIGTERM/SIGINT end the windowed loop like a window close, so
//                an XTest gate can send real input, wait for the engine's own log line, then
//                ask for a clean exit (exit counters printed) instead of guessing a duration.
//   FrameDelay   RNI_TEST_FRAME_DELAY_MS: sleep that long at the top of every windowed loop
//                iteration. A deterministic slow box for mutation scripts.
// Model: Flutter's test harness waits on engine events (flutter_tester's
// WaitForFirstFrame / Animator frame callbacks), not on wall-clock sleeps.
namespace rni::testsync {

double TimeScale();
int ScaledMs(int ms);

void InstallQuitSignals();
bool QuitRequested();
void RequestQuit();  // as if SIGTERM arrived (test probes; needs --quit-on-term to end the loop)
int QuitSignal();  // 0 until a signal arrived

int FrameDelayMs();
void DelayFrame();

}  // namespace rni::testsync
