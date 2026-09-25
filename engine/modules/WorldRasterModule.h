// ENG-09 — WorldRasterModule.
//
// ONE narrow native primitive, same shape as AppStorageModule (see that
// file's header comment for the general argument against the engine
// growing bespoke feature APIs). This module vends exactly two methods:
//
//     isSupported()                 -> bool, always true once the engine
//                                       binary has this module at all
//     setPixels(id, rgba, w, h)     -> writes into WorldRasterStore
//
// setPixels is intentionally synchronous and intentionally STRICT: a
// byteLength that does not equal w*h*4 THROWS rather than silently
// no-opping or truncating. A silent no-op here is worse than a throw --
// the caller would see nothing painted and have no signal that its own
// buffer math was wrong, versus an immediate, loud, attributable JS
// exception at the call site that built the mismatched buffer.
#pragma once

#include <ReactCommon/TurboModule.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "modules/WorldRasterStore.h"

namespace rni {

namespace jsi = facebook::jsi;
namespace react = facebook::react;

class WorldRasterModule : public react::TurboModule {
 public:
  WorldRasterModule(std::shared_ptr<react::CallInvoker> jsInvoker,
                    std::shared_ptr<WorldRasterStore> store)
      : react::TurboModule("WorldRaster", std::move(jsInvoker)),
        store_(std::move(store)) {
    methodMap_["isSupported"] = MethodMetadata{0, isSupportedHost};
    methodMap_["setPixels"] = MethodMetadata{4, setPixelsHost};
  }

 private:
  static WorldRasterModule& self(react::TurboModule& tm) {
    return static_cast<WorldRasterModule&>(tm);
  }

  static jsi::Value isSupportedHost(jsi::Runtime&, react::TurboModule&,
                                    const jsi::Value*, size_t) {
    return jsi::Value(true);
  }

  // Args: (id: string, rgba: ArrayBuffer, w: number, h: number)
  //
  // ⛔ THE THROW IS THE CONTRACT. A mismatched byteLength means the JS side
  // built the wrong buffer for the dimensions it is claiming -- a bug that
  // must surface at the call site, not three frames later as "the world
  // texture looks wrong" with nothing in the log to point at why.
  static jsi::Value setPixelsHost(jsi::Runtime& rt, react::TurboModule& tm,
                                  const jsi::Value* args, size_t count) {
    if (count < 4 || !args[0].isString() || !args[1].isObject() ||
        !args[2].isNumber() || !args[3].isNumber()) {
      throw jsi::JSError(
          rt, "WorldRaster.setPixels: expected (string id, ArrayBuffer "
              "rgba, number w, number h)");
    }
    auto& me = self(tm);
    const auto id = args[0].asString(rt).utf8(rt);
    const double w = args[2].asNumber();
    const double h = args[3].asNumber();

    jsi::Object obj = args[1].asObject(rt);
    if (!obj.isArrayBuffer(rt)) {
      throw jsi::JSError(rt,
                          "WorldRaster.setPixels: rgba must be an ArrayBuffer");
    }
    jsi::ArrayBuffer buffer = obj.getArrayBuffer(rt);
    const size_t byteLength = buffer.size(rt);

    if (w < 0 || h < 0) {
      throw jsi::JSError(rt,
                          "WorldRaster.setPixels: w and h must be >= 0");
    }
    // Computed in double first so a huge w*h that would overflow size_t is
    // caught by the comparison rather than wrapping into a small number
    // that happens to match a small, WRONG byteLength.
    const double expected = w * h * 4.0;
    if (expected != static_cast<double>(byteLength)) {
      throw jsi::JSError(
          rt, "WorldRaster.setPixels: byteLength (" +
                  std::to_string(byteLength) + ") != w*h*4 (" +
                  std::to_string(expected) + ") for id '" + id + "'");
    }

    const uint8_t* data = buffer.data(rt);
    std::vector<uint8_t> pixels(data, data + byteLength);
    me.store_->setPixels(id, std::move(pixels), w, h);
    return jsi::Value::undefined();
  }

  std::shared_ptr<WorldRasterStore> store_;
};

}  // namespace rni
