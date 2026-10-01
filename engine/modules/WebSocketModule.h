// WebSocketModule -- the TurboModule behind RN's WebSocket class.
//
// WHY IT EXISTS (parity item 12): every __DEV__ bundle reaches
// TurboModuleRegistry.getEnforcing('WebSocketModule') during InitializeCore
// (setUpReactDevTools, HMRClient), so its absence made dev bundles throw an
// Invariant Violation before the first render: scene_nodes=0, blank window.
// It is also the transport Metro's Fast Refresh (HMR) uses, and plain app
// code gets a working `new WebSocket(...)` from it.
//
// TRANSPORT: boost.beast over boost.asio, header-only, same dependency the
// Networking module already uses -- one TU for linux, darwin and windows.
// ws:// only, exactly like Networking is http:// only: a wss:// URL fails
// with an explicit `websocketFailed` message, never a silent hang. (Metro's
// dev server is plain ws://.)
//
// THREADING: each socket owns one io_context run on its own thread; all
// socket I/O happens there. JS calls (send/close/ping) POST onto that
// io_context, so the stream is only ever touched by one thread. Events reach
// JS through TurboModule::emitDeviceEvent (the RN-standard path RN's
// NativeEventEmitter listens on), one OBJECT payload per event, matching
// RCTWebSocketModule: {id, data, type}, {id, protocol}, {id, code, reason},
// {id, message}.
#pragma once

#include <FBReactNativeSpecJSI.h>

#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

namespace rni {

namespace jsi = facebook::jsi;

struct WsConnection;  // defined in the .cpp (beast types stay out of headers)

class WebSocketModule
    : public facebook::react::NativeWebSocketModuleCxxSpec<WebSocketModule> {
 public:
  explicit WebSocketModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
      : NativeWebSocketModuleCxxSpec(std::move(jsInvoker)) {}
  ~WebSocketModule() override;

  void connect(jsi::Runtime& rt, jsi::String url,
               std::optional<jsi::Array> protocols, jsi::Object options,
               double socketID);
  void send(jsi::Runtime& rt, jsi::String message, double forSocketID);
  void sendBinary(jsi::Runtime& rt, jsi::String base64String,
                  double forSocketID);
  void ping(jsi::Runtime& rt, double socketID);
  void close(jsi::Runtime& rt, double code, jsi::String reason,
             double socketID);
  void addListener(jsi::Runtime&, jsi::String) {}
  void removeListeners(jsi::Runtime&, double) {}

  // Called from socket threads.
  void emitOpen(int id, const std::string& protocol);
  void emitMessage(int id, const std::string& data, bool binary);
  void emitClosed(int id, int code, const std::string& reason);
  void emitFailed(int id, const std::string& message);

 private:
  std::shared_ptr<WsConnection> find(int id);
  void forget(int id);

  std::mutex mutex_;
  std::map<int, std::shared_ptr<WsConnection>> sockets_;
  // Set in the destructor so socket threads stop emitting into a dying module.
  std::shared_ptr<std::atomic<bool>> alive_ =
      std::make_shared<std::atomic<bool>>(true);
};

}  // namespace rni
