// Non-Linux builds: no web view backend yet (darwin is a separate decision:
// CEF texture model vs WKWebView hole model). Every call fails with the reason.
#include "webview/WebViewHost.h"

namespace rni {
namespace {

class NoWebViewHost final : public WebViewHost {
 public:
  bool Supported(std::string* why) override {
    if (why) *why = "no web view backend on this platform yet";
    return false;
  }
  int64_t Create(std::shared_ptr<TextureRegistry>, int, int, double, const std::string&,
                 std::string* error) override {
    Supported(error);
    return 0;
  }
  void Load(int64_t, const std::string&, const Headers&) override {}
  void Resize(int64_t, int, int, double) override {}
  void Nav(int64_t, const std::string&) override {}
  void Inject(int64_t, const std::string&) override {}
  void UserScript(int64_t, const std::string&, bool) override {}
  bool Destroy(int64_t) override { return false; }
  void ClearData() override {}
  void SetEventListener(EventListener) override {}
  std::string StatusJson() override { return "{}"; }
  bool IsWebView(int64_t) override { return false; }
  void Pointer(int64_t, const char*, int, double, double, uint32_t, int) override {}
  void Touch(int64_t, const char*, double, double, uint32_t) override {}
  void Scroll(int64_t, double, double, double, double, uint32_t) override {}
  void Key(int64_t, bool, uint32_t, uint32_t, uint32_t) override {}
  void Focus(int64_t, bool) override {}
  void Text(int64_t, const std::string&) override {}
};

}  // namespace

bool WebViewLog() { return false; }

WebViewHost& WebViewHost::Instance() {
  static auto* host = new NoWebViewHost();
  return *host;
}

}  // namespace rni
