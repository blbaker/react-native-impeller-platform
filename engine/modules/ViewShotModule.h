// FP-43: "RNViewShot", react-native-view-shot's native module surface
// (src/specs/NativeRNViewShot.ts):
//   captureRef(tag, options) -> Promise<string>
//   captureScreen(options)   -> Promise<string>
//   releaseCapture(uri)      -> void
// options: format 'png' | 'jpg' ('jpeg'), quality 0..1, result 'tmpfile' |
// 'base64' | 'data-uri', width/height (output pixels), fileName (tmpfile
// prefix). Anything else rejects. The capture itself runs off the JS thread
// (scenegraph/SnapshotController.h); the Promise settles on the JS thread.
#pragma once

#include <ReactCommon/TurboModule.h>
#include <ReactCommon/TurboModuleUtils.h>

#include <cstdio>
#include <memory>
#include <string>

#include "scenegraph/SnapshotController.h"

namespace rni {

class ViewShotModule : public facebook::react::TurboModule {
 public:
  ViewShotModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                 std::shared_ptr<SnapshotController> controller)
      : facebook::react::TurboModule("RNViewShot", std::move(jsInvoker)),
        controller_(std::move(controller)) {
    methodMap_["captureRef"] = MethodMetadata{2, captureRefHost};
    methodMap_["captureScreen"] = MethodMetadata{1, captureScreenHost};
    methodMap_["releaseCapture"] = MethodMetadata{1, releaseHost};
  }

 private:
  using Runtime = facebook::jsi::Runtime;
  using Value = facebook::jsi::Value;

  static ViewShotModule& self(facebook::react::TurboModule& tm) {
    return static_cast<ViewShotModule&>(tm);
  }

  // Empty = ok; else the rejection message.
  static std::string parseOptions(Runtime& rt, const Value& v, SnapshotOptions* o) {
    if (v.isUndefined() || v.isNull()) return "";
    if (!v.isObject()) return "options must be an object";
    auto obj = v.asObject(rt);
    auto str = [&](const char* k, std::string* out) {
      auto p = obj.getProperty(rt, k);
      if (p.isString()) *out = p.asString(rt).utf8(rt);
    };
    auto num = [&](const char* k, double* out) {
      auto p = obj.getProperty(rt, k);
      if (p.isNumber()) *out = p.asNumber();
    };
    str("format", &o->format);
    str("result", &o->result);
    str("fileName", &o->fileName);
    num("quality", &o->quality);
    num("width", &o->width);
    num("height", &o->height);
    if (o->format == "jpeg") o->format = "jpg";
    if (o->format != "png" && o->format != "jpg") {
      return "Unsupported format: " + o->format + " (this engine encodes png and jpg)";
    }
    if (o->result != "tmpfile" && o->result != "base64" && o->result != "data-uri") {
      return "Unsupported result: " + o->result + " (tmpfile, base64 or data-uri)";
    }
    if (!(o->quality >= 0 && o->quality <= 1)) return "quality must be in [0, 1]";
    if (!(o->width >= 0) || !(o->height >= 0)) return "width/height must be >= 0";
    return "";
  }

  Value capture(Runtime& rt, int tag, const Value& options) {
    SnapshotOptions o;
    std::string error = parseOptions(rt, options, &o);
    auto invoker = jsInvoker_;
    auto controller = controller_;
    return facebook::react::createPromiseAsJSIValue(
        rt, [invoker, controller, tag, o = std::move(o), error = std::move(error)](
                Runtime&, std::shared_ptr<facebook::react::Promise> promise) mutable {
          if (!error.empty()) {
            promise->reject(error);
            return;
          }
          // The hop moves the promise so its last reference drops on the JS thread.
          auto holder = std::make_shared<std::shared_ptr<facebook::react::Promise>>(
              std::move(promise));
          controller->Request(
              tag, std::move(o), [invoker, holder](SnapshotOutcome out) {
                auto p = std::move(*holder);
                if (!p) return;
                invoker->invokeAsync([p = std::move(p), out = std::move(out)](Runtime& rt2) {
                  std::printf("rn-impeller: snapshot_resolve id=%llu ok=%d thread=%s\n",
                              (unsigned long long)out.id, (int)out.ok,
                              SnapshotThreadLabel().c_str());
                  std::fflush(stdout);
                  if (out.ok) {
                    p->resolve(facebook::jsi::String::createFromUtf8(rt2, out.value));
                  } else {
                    p->reject(out.error);
                  }
                });
              });
        });
  }

  static Value captureRefHost(Runtime& rt, facebook::react::TurboModule& tm, const Value* args,
                              size_t count) {
    if (count < 1 || !args[0].isNumber() || args[0].asNumber() < 1) {
      throw facebook::jsi::JSError(rt, "RNViewShot.captureRef: expected a view tag (number)");
    }
    const Value none;
    return self(tm).capture(rt, (int)args[0].asNumber(), count >= 2 ? args[1] : none);
  }

  static Value captureScreenHost(Runtime& rt, facebook::react::TurboModule& tm,
                                 const Value* args, size_t count) {
    const Value none;
    return self(tm).capture(rt, 0, count >= 1 ? args[0] : none);
  }

  static Value releaseHost(Runtime& rt, facebook::react::TurboModule& tm, const Value* args,
                           size_t count) {
    if (count >= 1 && args[0].isString()) {
      self(tm).controller_->Release(args[0].asString(rt).utf8(rt));
    }
    return Value::undefined();
  }

  std::shared_ptr<SnapshotController> controller_;
};

}  // namespace rni
