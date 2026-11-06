// Row 3: "ImpellerVideo" TurboModule. JS creates a player
// for a uri and gets back its texture id, which <ImpellerTextureView textureId>
// paints (package/src/video wraps this as expo-video's useVideoPlayer /
// VideoView). Players are owned here and released with the module.
//   isSupported() -> bool            backend() -> "ffmpeg" | "none"
//   create(uri) -> id                throws with the reason when it cannot
//   play(id) pause(id) seek(id, seconds) setRate(id, rate) setLoop(id, bool)
//   getStatus(id) -> {status, error, currentTime, duration, playing, rate, loop,
//                     ended, width, height, framesShown, framesDropped,
//                     audio ("none" | "on" | "muted" | "error: ..."), audioFrames}
//   release(id) -> bool              (false: no such player)
#pragma once

#include <ReactCommon/TurboModule.h>

#include <cmath>
#include <map>
#include <memory>
#include <mutex>
#include <string>

#include "scenegraph/TextureRegistry.h"
#include "video/VideoPlayer.h"

namespace rni {

class VideoModule : public facebook::react::TurboModule {
 public:
  VideoModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
              std::shared_ptr<TextureRegistry> registry)
      : facebook::react::TurboModule("ImpellerVideo", std::move(jsInvoker)),
        registry_(std::move(registry)) {
    methodMap_["isSupported"] = MethodMetadata{0, isSupportedHost};
    methodMap_["backend"] = MethodMetadata{0, backendHost};
    methodMap_["create"] = MethodMetadata{1, createHost};
    methodMap_["play"] = MethodMetadata{1, playHost};
    methodMap_["pause"] = MethodMetadata{1, pauseHost};
    methodMap_["seek"] = MethodMetadata{2, seekHost};
    methodMap_["setRate"] = MethodMetadata{2, setRateHost};
    methodMap_["setLoop"] = MethodMetadata{2, setLoopHost};
    methodMap_["getStatus"] = MethodMetadata{1, statusHost};
    methodMap_["release"] = MethodMetadata{1, releaseHost};
  }

  ~VideoModule() override {
    std::map<int64_t, std::shared_ptr<VideoPlayer>> players;
    {
      std::lock_guard<std::mutex> lock(mu_);
      players.swap(players_);
    }
    for (auto& [id, p] : players) registry_->Unregister(id);  // stops the decode thread
  }

 private:
  using Runtime = facebook::jsi::Runtime;
  using Value = facebook::jsi::Value;
  using TM = facebook::react::TurboModule;

  static VideoModule& self(TM& tm) { return static_cast<VideoModule&>(tm); }

  static int64_t idArg(Runtime& rt, const Value* args, size_t count, const char* fn) {
    if (count < 1 || !args[0].isNumber() || args[0].asNumber() < 1 ||
        std::floor(args[0].asNumber()) != args[0].asNumber()) {
      throw facebook::jsi::JSError(rt, std::string("ImpellerVideo.") + fn +
                                           ": expected a player id (positive integer)");
    }
    return (int64_t)args[0].asNumber();
  }

  std::shared_ptr<VideoPlayer> get(Runtime& rt, const Value* args, size_t count, const char* fn) {
    const int64_t id = idArg(rt, args, count, fn);
    std::lock_guard<std::mutex> lock(mu_);
    auto it = players_.find(id);
    if (it == players_.end()) {
      throw facebook::jsi::JSError(rt, std::string("ImpellerVideo.") + fn + ": no player " +
                                           std::to_string(id) + " (released?)");
    }
    return it->second;
  }

  static double numArg(Runtime& rt, const Value* args, size_t count, const char* fn) {
    if (count < 2 || !args[1].isNumber() || !std::isfinite(args[1].asNumber())) {
      throw facebook::jsi::JSError(rt, std::string("ImpellerVideo.") + fn +
                                           ": expected (id, finite number)");
    }
    return args[1].asNumber();
  }

  static Value isSupportedHost(Runtime&, TM&, const Value*, size_t) {
    return Value(VideoSupported());
  }
  static Value backendHost(Runtime& rt, TM&, const Value*, size_t) {
    return facebook::jsi::String::createFromUtf8(rt, VideoBackendName());
  }
  static Value createHost(Runtime& rt, TM& tm, const Value* args, size_t count) {
    if (count < 1 || !args[0].isString()) {
      throw facebook::jsi::JSError(rt, "ImpellerVideo.create: expected (string uri)");
    }
    auto& me = self(tm);
    const std::string uri = args[0].asString(rt).utf8(rt);
    int64_t id = 0;
    std::string error;
    auto p = CreateVideoPlayer(me.registry_.get(), uri, &id, &error);
    if (!p) throw facebook::jsi::JSError(rt, "ImpellerVideo.create: " + error);
    std::lock_guard<std::mutex> lock(me.mu_);
    me.players_[id] = std::move(p);
    return Value((double)id);
  }
  static Value playHost(Runtime& rt, TM& tm, const Value* a, size_t n) {
    self(tm).get(rt, a, n, "play")->Play();
    return Value::undefined();
  }
  static Value pauseHost(Runtime& rt, TM& tm, const Value* a, size_t n) {
    self(tm).get(rt, a, n, "pause")->Pause();
    return Value::undefined();
  }
  static Value seekHost(Runtime& rt, TM& tm, const Value* a, size_t n) {
    auto p = self(tm).get(rt, a, n, "seek");
    p->Seek(numArg(rt, a, n, "seek"));
    return Value::undefined();
  }
  static Value setRateHost(Runtime& rt, TM& tm, const Value* a, size_t n) {
    auto p = self(tm).get(rt, a, n, "setRate");
    p->SetRate(numArg(rt, a, n, "setRate"));
    return Value::undefined();
  }
  static Value setLoopHost(Runtime& rt, TM& tm, const Value* a, size_t n) {
    auto p = self(tm).get(rt, a, n, "setLoop");
    if (n < 2 || !a[1].isBool()) {
      throw facebook::jsi::JSError(rt, "ImpellerVideo.setLoop: expected (id, boolean)");
    }
    p->SetLoop(a[1].getBool());
    return Value::undefined();
  }
  static Value statusHost(Runtime& rt, TM& tm, const Value* a, size_t n) {
    const VideoStatus s = self(tm).get(rt, a, n, "getStatus")->Status();
    facebook::jsi::Object o(rt);
    o.setProperty(rt, "status", facebook::jsi::String::createFromUtf8(rt, s.status));
    o.setProperty(rt, "error", facebook::jsi::String::createFromUtf8(rt, s.error));
    o.setProperty(rt, "currentTime", s.currentTime);
    o.setProperty(rt, "duration", s.duration);
    o.setProperty(rt, "playing", s.playing);
    o.setProperty(rt, "rate", s.rate);
    o.setProperty(rt, "loop", s.loop);
    o.setProperty(rt, "ended", s.ended);
    o.setProperty(rt, "width", s.width);
    o.setProperty(rt, "height", s.height);
    o.setProperty(rt, "framesShown", (double)s.framesShown);
    o.setProperty(rt, "framesDropped", (double)s.framesDropped);
    o.setProperty(rt, "audio", facebook::jsi::String::createFromUtf8(rt, s.audio));
    o.setProperty(rt, "audioFrames", (double)s.audioFrames);
    return o;
  }
  static Value releaseHost(Runtime& rt, TM& tm, const Value* a, size_t n) {
    auto& me = self(tm);
    const int64_t id = idArg(rt, a, n, "release");
    std::shared_ptr<VideoPlayer> p;
    {
      std::lock_guard<std::mutex> lock(me.mu_);
      auto it = me.players_.find(id);
      if (it == me.players_.end()) return Value(false);
      p = std::move(it->second);
      me.players_.erase(it);
    }
    me.registry_->Unregister(id);  // joins the decode thread
    return Value(true);
  }

  std::shared_ptr<TextureRegistry> registry_;
  std::mutex mu_;
  std::map<int64_t, std::shared_ptr<VideoPlayer>> players_;
};

}  // namespace rni
