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
    // ENG-10 GPU sprite compositing. registerSprite uploads an atlas entry
    // ONCE; drawSprites (per frame) only references entries by textureId.
    methodMap_["registerSprite"] = MethodMetadata{4, registerSpriteHost};
    methodMap_["drawSprites"] = MethodMetadata{2, drawSpritesHost};
    // ENG-21. Per-<world> sampler: 'nearest' or 'linear'.
    methodMap_["setSampling"] = MethodMetadata{2, setSamplingHost};
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

  // ENG-10. Args: (textureId: string, rgba: ArrayBuffer, w: number, h: number)
  // rgba is STRAIGHT (non-premultiplied) RGBA8, top-to-bottom -- the same
  // layout as canvas ImageData and setPixels. Same strict-throw contract.
  //
  // ⛔ PREMULTIPLIED HERE, ONCE. Impeller samples textures as premultiplied
  // alpha; uploading straight alpha makes every semi-transparent texel too
  // bright (a 50%-alpha grey shadow composites as if it were twice as light).
  // setPixels never hit this because world buffers are opaque. Doing it at
  // registration costs one pass per atlas entry, never per frame.
  static jsi::Value registerSpriteHost(jsi::Runtime& rt, react::TurboModule& tm,
                                       const jsi::Value* args, size_t count) {
    if (count < 4 || !args[0].isString() || !args[1].isObject() ||
        !args[2].isNumber() || !args[3].isNumber()) {
      throw jsi::JSError(
          rt, "WorldRaster.registerSprite: expected (string textureId, "
              "ArrayBuffer rgba, number w, number h)");
    }
    auto& me = self(tm);
    const auto textureId = args[0].asString(rt).utf8(rt);
    const double w = args[2].asNumber();
    const double h = args[3].asNumber();
    jsi::Object obj = args[1].asObject(rt);
    if (!obj.isArrayBuffer(rt)) {
      throw jsi::JSError(
          rt, "WorldRaster.registerSprite: rgba must be an ArrayBuffer");
    }
    jsi::ArrayBuffer buffer = obj.getArrayBuffer(rt);
    const size_t byteLength = buffer.size(rt);
    if (w <= 0 || h <= 0) {
      throw jsi::JSError(
          rt, "WorldRaster.registerSprite: w and h must be > 0");
    }
    const double expected = w * h * 4.0;
    if (expected != static_cast<double>(byteLength)) {
      throw jsi::JSError(
          rt, "WorldRaster.registerSprite: byteLength (" +
                  std::to_string(byteLength) + ") != w*h*4 (" +
                  std::to_string(expected) + ") for textureId '" + textureId +
                  "'");
    }
    const uint8_t* data = buffer.data(rt);
    std::vector<uint8_t> pixels(data, data + byteLength);
    for (size_t i = 0; i + 3 < pixels.size(); i += 4) {
      const unsigned a = pixels[i + 3];
      if (a == 255) continue;
      pixels[i] = (uint8_t)((pixels[i] * a + 127) / 255);
      pixels[i + 1] = (uint8_t)((pixels[i + 1] * a + 127) / 255);
      pixels[i + 2] = (uint8_t)((pixels[i + 2] * a + 127) / 255);
    }
    me.store_->registerSprite(textureId, std::move(pixels), w, h);
    return jsi::Value::undefined();
  }

  // ENG-10. Args: (id: string, sprites: Array<{textureId, x, y, w, h, alpha?}>)
  // Replaces the whole list painted over <world name=id>, back-to-front.
  //
  // ⛔ AN UNREGISTERED textureId THROWS. A silently skipped sprite is the
  // "nothing painted, no signal" failure the setPixels contract forbids --
  // the caller drew before registering, and that must surface at the call.
  static jsi::Value drawSpritesHost(jsi::Runtime& rt, react::TurboModule& tm,
                                    const jsi::Value* args, size_t count) {
    if (count < 2 || !args[0].isString() || !args[1].isObject() ||
        !args[1].asObject(rt).isArray(rt)) {
      throw jsi::JSError(
          rt, "WorldRaster.drawSprites: expected (string id, Array sprites)");
    }
    auto& me = self(tm);
    const auto id = args[0].asString(rt).utf8(rt);
    jsi::Array arr = args[1].asObject(rt).asArray(rt);
    const size_t n = arr.size(rt);
    std::vector<WorldSprite> sprites;
    sprites.reserve(n);
    auto num = [&](const jsi::Object& o, const char* key, size_t i,
                   bool optional, double dflt) -> double {
      jsi::Value v = o.getProperty(rt, key);
      if (v.isNumber()) return v.asNumber();
      if (optional && v.isUndefined()) return dflt;
      throw jsi::JSError(rt, "WorldRaster.drawSprites: sprites[" +
                                 std::to_string(i) + "]." + key +
                                 " must be a number");
    };
    for (size_t i = 0; i < n; ++i) {
      jsi::Value item = arr.getValueAtIndex(rt, i);
      if (!item.isObject()) {
        throw jsi::JSError(rt, "WorldRaster.drawSprites: sprites[" +
                                   std::to_string(i) + "] must be an object");
      }
      jsi::Object o = item.asObject(rt);
      jsi::Value tid = o.getProperty(rt, "textureId");
      if (!tid.isString()) {
        throw jsi::JSError(rt, "WorldRaster.drawSprites: sprites[" +
                                   std::to_string(i) +
                                   "].textureId must be a string");
      }
      WorldSprite s;
      s.textureId = tid.asString(rt).utf8(rt);
      s.x = (float)num(o, "x", i, false, 0);
      s.y = (float)num(o, "y", i, false, 0);
      s.w = (float)num(o, "w", i, false, 0);
      s.h = (float)num(o, "h", i, false, 0);
      const double a = num(o, "alpha", i, true, 1.0);
      s.alpha = (float)(a < 0 ? 0 : (a > 1 ? 1 : a));
      if (me.store_->getSprite(s.textureId) == nullptr) {
        throw jsi::JSError(rt, "WorldRaster.drawSprites: sprites[" +
                                   std::to_string(i) + "].textureId '" +
                                   s.textureId +
                                   "' was never registered (call "
                                   "registerSprite first)");
      }
      sprites.push_back(std::move(s));
    }
    me.store_->setSprites(id, std::move(sprites));
    return jsi::Value::undefined();
  }

  // ENG-21. Args: (id: string, mode: 'nearest' | 'linear')
  // Sets how the <world name=id> samples its setPixels terrain and every
  // sprite drawn on it. Any other mode THROWS: a typo ('nearst') silently
  // falling back to linear is the blurry-art bug this exists to fix.
  static jsi::Value setSamplingHost(jsi::Runtime& rt, react::TurboModule& tm,
                                    const jsi::Value* args, size_t count) {
    if (count < 2 || !args[0].isString() || !args[1].isString()) {
      throw jsi::JSError(
          rt, "WorldRaster.setSampling: expected (string id, string mode)");
    }
    auto& me = self(tm);
    const auto id = args[0].asString(rt).utf8(rt);
    const auto mode = args[1].asString(rt).utf8(rt);
    bool nearest = false;
    if (mode == "nearest") {
      nearest = true;
    } else if (mode != "linear") {
      throw jsi::JSError(rt, "WorldRaster.setSampling: mode must be "
                             "'nearest' or 'linear', got '" + mode + "'");
    }
    me.store_->setSampling(id, nearest);
    return jsi::Value::undefined();
  }

  std::shared_ptr<WorldRasterStore> store_;
};

}  // namespace rni
