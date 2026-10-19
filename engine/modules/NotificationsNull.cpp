// The backend for hosts with no notification implementation (iOS and Android
// builds of the engine). Every call answers "unavailable"; nothing is shown.
#include "modules/Notifications.h"

namespace rni::notifications {

namespace {

constexpr const char* kReason =
    "this engine build has no notification backend for its platform";

class NullBackend : public Backend {
 public:
  void requestPermission(Done done) override { done({"unavailable", kReason}); }
  void show(const Request&, Done done) override {
    done({"unavailable", kReason});
  }
};

}  // namespace

std::unique_ptr<Backend> CreateBackend(PressSink) {
  return std::make_unique<NullBackend>();
}

}  // namespace rni::notifications
