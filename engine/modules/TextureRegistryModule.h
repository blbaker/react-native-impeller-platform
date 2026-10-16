// FP-42: "ImpellerTextureRegistry" TurboModule. JS registers a test producer
// and gets its id for <ImpellerTextureView textureId>; real producers (video,
// camera) register from native code through the same TextureRegistry.
//   isSupported() -> true
//   registerTestProducer(fps, width, height, maxFrames?) -> id (number);
//     maxFrames > 0: the producer stops after that many frames (stays registered)
//   unregister(id) -> bool (false: no such id)
//   markFrameAvailable(id) -> undefined
#pragma once

#include <ReactCommon/TurboModule.h>

#include <cmath>
#include <memory>

#include "scenegraph/TextureRegistry.h"

namespace rni {

namespace jsi = facebook::jsi;
namespace react = facebook::react;

class TextureRegistryModule : public react::TurboModule {
 public:
  TextureRegistryModule(std::shared_ptr<react::CallInvoker> jsInvoker,
                        std::shared_ptr<TextureRegistry> registry)
      : react::TurboModule("ImpellerTextureRegistry", std::move(jsInvoker)),
        registry_(std::move(registry)) {
    methodMap_["isSupported"] = MethodMetadata{0, isSupportedHost};
    methodMap_["registerTestProducer"] = MethodMetadata{4, registerTestProducerHost};
    methodMap_["unregister"] = MethodMetadata{1, unregisterHost};
    methodMap_["markFrameAvailable"] = MethodMetadata{1, markHost};
  }

 private:
  static TextureRegistryModule& self(react::TurboModule& tm) {
    return static_cast<TextureRegistryModule&>(tm);
  }
  static int64_t idArg(jsi::Runtime& rt, const jsi::Value* args, size_t count, const char* fn) {
    if (count < 1 || !args[0].isNumber() || args[0].asNumber() < 1 ||
        std::floor(args[0].asNumber()) != args[0].asNumber()) {
      throw jsi::JSError(rt, std::string("ImpellerTextureRegistry.") + fn +
                                 ": expected a texture id (positive integer)");
    }
    return (int64_t)args[0].asNumber();
  }

  static jsi::Value isSupportedHost(jsi::Runtime&, react::TurboModule&, const jsi::Value*,
                                    size_t) {
    return jsi::Value(true);
  }

  static jsi::Value registerTestProducerHost(jsi::Runtime& rt, react::TurboModule& tm,
                                             const jsi::Value* args, size_t count) {
    if (count < 3 || !args[0].isNumber() || !args[1].isNumber() || !args[2].isNumber()) {
      throw jsi::JSError(rt, "ImpellerTextureRegistry.registerTestProducer: expected "
                             "(number fps, number width, number height)");
    }
    const double fps = args[0].asNumber(), w = args[1].asNumber(), h = args[2].asNumber();
    if (!(fps > 0 && fps <= 240) || !(w >= 2 && w <= 4096) || !(h >= 2 && h <= 4096)) {
      throw jsi::JSError(rt, "ImpellerTextureRegistry.registerTestProducer: fps in (0, 240], "
                             "width/height in [2, 4096]");
    }
    double maxFrames = 0;
    if (count >= 4 && !args[3].isUndefined()) {
      if (!args[3].isNumber() || args[3].asNumber() < 0) {
        throw jsi::JSError(rt, "ImpellerTextureRegistry.registerTestProducer: maxFrames >= 0");
      }
      maxFrames = std::floor(args[3].asNumber());
    }
    auto& me = self(tm);
    const int64_t id = me.registry_->NextId();
    me.registry_->Register(MakeTestPatternTexture(me.registry_.get(), id, fps, (int)w, (int)h,
                                                  (uint64_t)maxFrames));
    return jsi::Value((double)id);
  }

  static jsi::Value unregisterHost(jsi::Runtime& rt, react::TurboModule& tm,
                                   const jsi::Value* args, size_t count) {
    return jsi::Value(self(tm).registry_->Unregister(idArg(rt, args, count, "unregister")));
  }

  static jsi::Value markHost(jsi::Runtime& rt, react::TurboModule& tm, const jsi::Value* args,
                             size_t count) {
    self(tm).registry_->MarkFrameAvailable(idArg(rt, args, count, "markFrameAvailable"));
    return jsi::Value::undefined();
  }

  std::shared_ptr<TextureRegistry> registry_;
};

}  // namespace rni
