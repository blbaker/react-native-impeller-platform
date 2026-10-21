// tools/ci-unpresented-damage.sh compiles this against engine/host/
// UnpresentedDamage.h (or a mutant copy) and runs it. CPU only, simulated
// clock: the windowed gate (ci-idle-commit-paint.sh) can only show these
// orderings when runner timing happens to produce them; this replays each one
// exactly.
//
// The loop is modelled the way main.cpp drives Check(): it checks every 1 ms
// while parked, a requested frame is in flight for 33 ms, then it is either
// lost (the loop checks again at once, as the raster thread's wake makes it)
// or presented.
#include <cstdio>
#include <utility>
#include <vector>

#include "UnpresentedDamage.h"

namespace {

constexpr int64_t kMs = 1000;
int failures = 0;

void Expect(bool ok, const char* arm, const char* what, long long got, long long want) {
  if (!ok) {
    ++failures;
    std::printf("  FAIL %s: %s got=%lld want=%lld\n", arm, what, got, want);
  }
}

struct Sim {
  rni::UnpresentedDamage ud;
  int64_t now = 1'000'000 * kMs;
  uint64_t scene = 2;
  uint64_t shown = 2;

  // A frame for `scene` was just lost. Park-and-check every 1 ms until the
  // loop asks again; returns {retry, ms waited}.
  std::pair<int, int> ReAsk() {
    const int64_t lostAt = now;
    for (int i = 0; i < 5000; ++i) {
      const auto d = ud.Check(scene, shown, /*inFlight=*/false, now);
      if (d.request) return {d.retry, (int)((now - lostAt) / kMs)};
      now += kMs;
    }
    return {-1, 5000};
  }
  // The requested frame is in flight for 33 ms (the loop may check meanwhile).
  void InFlight() {
    for (int i = 0; i < 33; ++i) {
      (void)ud.Check(scene, shown, /*inFlight=*/true, now);
      now += kMs;
    }
  }
};

// One commit whose own frame and the next two re-asked frames are lost, and the
// third re-ask presents (ICP_LOSE_FRAMES=3).
void SwapWithThreeLosses(Sim& s, const char* arm, int swap, bool caughtUpCheck) {
  s.now += 1400 * kMs;  // swaps ~1.4 s apart, inside a 1 s park + losses
  ++s.scene;            // JS commit
  s.InFlight();         // the commit's own frame: lost
  for (int k = 1; k <= 3; ++k) {
    const auto [retry, waited] = s.ReAsk();
    char what[96];
    std::snprintf(what, sizeof what, "swap %d re-ask %d retry", swap, k);
    Expect(retry == k, arm, what, retry, k);
    std::snprintf(what, sizeof what, "swap %d re-ask %d since_lost_ms", swap, k);
    Expect(waited <= 1, arm, what, waited, 0);
    s.InFlight();
  }
  s.shown = s.scene;  // the third re-ask presented
  if (caughtUpCheck) {
    // The park timed out before the next commit: one check sees caught-up.
    s.now += 1000 * kMs;
    (void)s.ud.Check(s.scene, s.shown, false, s.now);
  }
}

// A: the next commit lands while the loop is still parked after the present,
// so no check ever sees the screen caught up. Every commit's losses must still
// start the schedule from retry 1 (the PR #35 darwin failure).
void ArmCommitInsidePark() {
  Sim s;
  for (int swap = 1; swap <= 4; ++swap) SwapWithThreeLosses(s, "A commit-inside-park", swap, false);
}

// B: a check does see the screen caught up between commits (the timing on the
// PR #33 green run). Same expectation; non-regression.
void ArmCaughtUpBetween() {
  Sim s;
  for (int swap = 1; swap <= 4; ++swap) SwapWithThreeLosses(s, "B caught-up-between", swap, true);
}

// C: nothing ever presents. Re-asks must back off 0, 0, 25, 50 ... 1000 ms so a
// draw that keeps failing cannot spin a core. The schedule is written out here,
// not read from BackoffMs, so a backoff mutant cannot agree with itself.
void ArmNothingPresents() {
  Sim s;
  s.scene = 5;
  s.shown = 4;
  const std::vector<int> want = {0, 0, 0, 25, 50, 100, 200, 400, 800, 1000, 1000, 1000};
  for (size_t i = 0; i < want.size(); ++i) {
    const auto [retry, waited] = s.ReAsk();  // each frame is lost the moment it is asked
    char what[96];
    std::snprintf(what, sizeof what, "attempt %zu retry", i + 1);
    Expect(retry == (int)i + 1, "C nothing-presents", what, retry, (long long)i + 1);
    std::snprintf(what, sizeof what, "attempt %zu wait_ms", i + 1);
    Expect(waited >= want[i] - 1 && waited <= want[i] + 1, "C nothing-presents", what, waited,
           want[i]);
  }
}

// D: a frame presents while a long backoff deadline is pending, and a new
// commit lands before any check sees the screen caught up. The new commit's
// first loss must be re-asked at once, not after the old run's deadline.
void ArmPresentDuringBackoff() {
  Sim s;
  s.scene = 10;
  s.shown = 9;
  for (int i = 0; i < 7; ++i) (void)s.ReAsk();  // 7 failures: next deadline +400 ms
  s.now += 10 * kMs;
  s.shown = 10;  // the next try presented...
  s.scene = 11;  // ...and a commit landed before the loop looked
  s.InFlight();  // the commit's frame: lost
  const auto [retry, waited] = s.ReAsk();
  Expect(retry == 1, "D present-during-backoff", "first re-ask retry", retry, 1);
  Expect(waited <= 1, "D present-during-backoff", "first re-ask since_lost_ms", waited, 0);
}

}  // namespace

int main() {
  ArmCommitInsidePark();
  ArmCaughtUpBetween();
  ArmNothingPresents();
  ArmPresentDuringBackoff();
  if (failures) {
    std::printf("UNPRESENTED_DAMAGE_GATE_FAIL (%d checks failed)\n", failures);
    return 1;
  }
  std::printf("  OK A: commit inside the park: every swap re-asks 1,2,3 at 0 ms\n");
  std::printf("  OK B: caught-up check between swaps: same\n");
  std::printf("  OK C: nothing presents: backoff 0,0,0,25,50..1000 ms\n");
  std::printf("  OK D: present during a pending backoff: new loss re-asked at 0 ms\n");
  std::printf("UNPRESENTED_DAMAGE_GATE_PASS\n");
  return 0;
}
