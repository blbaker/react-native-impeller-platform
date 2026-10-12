// ExponentConstants: the native half of expo-constants (SC-44).
//
// expo-constants reads requireOptionalNativeModule('ExponentConstants') at
// import and warns "No native ExponentConstants module found" without it;
// Constants.expoConfig then stays null. The values follow a BARE app on iOS
// (EXConstantsService): executionEnvironment 'bare', appOwnership null (bare
// iOS sends nil), no Expo Go, no updates.
//
// manifest = the app config (app.json's `expo` object), found from the bundle:
//   RNI_EXPO_APP_CONFIG=<file>         explicit app.config / app.json
//   http(s) bundle (expo start)        GET <origin>/ with expo-platform: ios,
//                                      extra.expoClient (app config + hostUri);
//                                      the dev server rejects platform impeller
//   file:// bundle                     app.config (expo's embedded form) or
//                                      app.json in the bundle dir or up to two
//                                      parents
// Absent everywhere = no `manifest` key (Constants.expoConfig null, as iOS
// with no embedded config).
#include "modules/ExpoHost.h"

#include <folly/json.h>
#include <jsi/JSIDynamic.h>

#include <cstdlib>
#include <fstream>
#include <sstream>

#if !defined(_WIN32)
#include <unistd.h>
#endif

#include "modules/NetworkingModule.h"

namespace rni {

namespace jsi = facebook::jsi;
namespace fs = std::filesystem;

namespace {

bool parseObject(const std::string& text, folly::dynamic& out) {
  try {
    out = folly::parseJson(text);
  } catch (const std::exception&) {
    return false;
  }
  return out.isObject();
}

// app.json holds {"expo": {...}}; app.config (and a bare config) is the object.
bool configFromFile(const fs::path& p, folly::dynamic& out) {
  std::ifstream in(p, std::ios::binary);
  if (!in) return false;
  std::ostringstream ss;
  ss << in.rdbuf();
  folly::dynamic d;
  if (!parseObject(ss.str(), d)) return false;
  auto expo = d.find("expo");
  out = (expo != d.items().end() && expo->second.isObject()) ? expo->second : d;
  return true;
}

bool configFromDevServer(const std::string& bundleUrl, folly::dynamic& out) {
  const size_t se = bundleUrl.find("://");
  if (se == std::string::npos) return false;
  const size_t slash = bundleUrl.find('/', se + 3);
  const std::string origin = bundleUrl.substr(0, slash);
  auto url = parseUrl(origin + "/");
  if (!url.valid) return false;
  auto res = performRequest(
      "GET", url,
      {{"expo-platform", "ios"}, {"Accept", "application/expo+json,application/json"}}, "",
      5000);
  if (!res.ok || res.status != 200) return false;
  folly::dynamic d;
  if (!parseObject(res.body, d)) return false;
  // Expo Updates protocol manifest (SDK 46+), or a legacy app-config manifest.
  if (auto extra = d.get_ptr("extra"); extra && extra->isObject()) {
    if (auto client = extra->get_ptr("expoClient"); client && client->isObject()) {
      out = *client;
      return true;
    }
  }
  if (d.count("slug") || d.count("name")) {
    out = d;
    return true;
  }
  return false;
}

bool configFromBundleDir(const std::string& bundleUrl, folly::dynamic& out) {
  if (bundleUrl.rfind("file://", 0) != 0) return false;
  std::error_code ec;
  fs::path dir = fs::absolute(fs::path(bundleUrl.substr(7)), ec).parent_path();
  for (int up = 0; up < 3 && !dir.empty(); ++up) {
    for (const char* name : {"app.config", "app.json"}) {
      if (fs::is_regular_file(dir / name, ec) && configFromFile(dir / name, out)) return true;
    }
    if (dir == dir.parent_path()) break;
    dir = dir.parent_path();
  }
  return false;
}

std::string deviceName() {
#if defined(_WIN32)
  const char* n = std::getenv("COMPUTERNAME");
  return n ? n : "";
#else
  char buf[256] = {0};
  if (gethostname(buf, sizeof(buf) - 1) != 0) return "";
  return buf;
#endif
}

folly::dynamic buildConstants(const std::string& bundleUrl) {
  folly::dynamic c = folly::dynamic::object;
  c["executionEnvironment"] = "bare";
  c["appOwnership"] = nullptr;
  c["isHeadless"] = false;
  c["debugMode"] = bundleUrl.find("dev=true") != std::string::npos;
  c["sessionId"] = expoUuidv4();
  c["statusBarHeight"] = 0;
  c["systemFonts"] = folly::dynamic::array;
  c["platform"] = folly::dynamic::object;
  c["deviceName"] = deviceName();
  c["expoVersion"] = nullptr;
  c["linkingUri"] = "";

  folly::dynamic manifest;
  const char* env = std::getenv("RNI_EXPO_APP_CONFIG");
  bool found = false;
  if (env != nullptr && *env != '\0') {
    found = configFromFile(env, manifest);
  } else if (bundleUrl.rfind("http://", 0) == 0 || bundleUrl.rfind("https://", 0) == 0) {
    found = configFromDevServer(bundleUrl, manifest);
  } else {
    found = configFromBundleDir(bundleUrl, manifest);
  }
  if (found) c["manifest"] = manifest;
  return c;
}

const char* kConstantsJs = R"JS(
(function (m, expo, host) {
  'use strict';
  var c = host.constants();
  Object.keys(c).forEach(function (k) { m[k] = c[k]; });
  m.getWebViewUserAgentAsync = function () { return Promise.resolve(null); };
})
)JS";

}  // namespace

void registerExpoConstants(ExpoModuleRegistry& registry,
                           std::shared_ptr<ExpoHostConfig> config) {
  ExpoModuleDef def;
  def.js = kConstantsJs;
  def.installHost = [config](jsi::Runtime& rt, jsi::Object& host,
                             std::shared_ptr<facebook::react::CallInvoker>) {
    host.setProperty(
        rt, "constants",
        jsi::Function::createFromHostFunction(
            rt, jsi::PropNameID::forAscii(rt, "constants"), 0,
            [config](jsi::Runtime& rt, const jsi::Value&, const jsi::Value*,
                     size_t) -> jsi::Value {
              const std::string url = config->bundleUrl ? *config->bundleUrl : "";
              return jsi::valueFromDynamic(rt, buildConstants(url));
            }));
  };
  registry.add("ExponentConstants", std::move(def));
}

}  // namespace rni
