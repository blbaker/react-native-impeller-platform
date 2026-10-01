// WebSocketModule -- see the header for the why. ws:// only (no TLS here).
#include "modules/WebSocketModule.h"

#include <boost/asio/connect.hpp>
#include <boost/asio/io_context.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/post.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/websocket.hpp>

#include <cstdio>
#include <deque>
#include <thread>
#include <vector>

namespace rni {

namespace asio = boost::asio;
namespace beast = boost::beast;
namespace websocket = beast::websocket;
using tcp = asio::ip::tcp;

namespace {

struct WsUrl {
  bool ok{false};
  std::string error, host, port, target;
};

WsUrl parseWsUrl(const std::string& url) {
  WsUrl u;
  const size_t se = url.find("://");
  if (se == std::string::npos) {
    u.error = "Unsupported WebSocket URL (no scheme): " + url;
    return u;
  }
  std::string scheme = url.substr(0, se);
  for (auto& c : scheme) c = (char)tolower((unsigned char)c);
  if (scheme == "wss") {
    u.error = "wss:// is not supported by this engine yet (no TLS): " + url;
    return u;
  }
  if (scheme != "ws") {
    u.error = "Unsupported WebSocket URL scheme '" + scheme + "'";
    return u;
  }
  std::string rest = url.substr(se + 3);
  const size_t slash = rest.find('/');
  std::string hostport = slash == std::string::npos ? rest : rest.substr(0, slash);
  u.target = slash == std::string::npos ? "/" : rest.substr(slash);
  const size_t colon = hostport.rfind(':');
  if (colon != std::string::npos && hostport.find(']') == std::string::npos) {
    u.host = hostport.substr(0, colon);
    u.port = hostport.substr(colon + 1);
  } else {
    u.host = hostport;
    u.port = "80";
  }
  if (u.host.empty()) {
    u.error = "WebSocket URL has no host: " + url;
    return u;
  }
  u.ok = true;
  return u;
}

std::string base64Decode(const std::string& in) {
  static const std::string tbl =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  int val = 0, bits = -8;
  for (unsigned char c : in) {
    const size_t p = tbl.find((char)c);
    if (p == std::string::npos) continue;  // '=', whitespace
    val = (val << 6) + (int)p;
    bits += 6;
    if (bits >= 0) {
      out.push_back(char((val >> bits) & 0xFF));
      bits -= 8;
    }
  }
  return out;
}

std::string base64Encode(const std::string& in) {
  static const char* tbl =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  int val = 0, bits = -6;
  for (unsigned char c : in) {
    val = (val << 8) + c;
    bits += 8;
    while (bits >= 0) {
      out.push_back(tbl[(val >> bits) & 0x3F]);
      bits -= 6;
    }
  }
  if (bits > -6) out.push_back(tbl[((val << 8) >> (bits + 8)) & 0x3F]);
  while (out.size() % 4) out.push_back('=');
  return out;
}

}  // namespace

// One connection: its own io_context + thread. Every stream operation runs on
// that thread; JS-thread calls post() onto the io_context.
struct WsConnection : std::enable_shared_from_this<WsConnection> {
  int id{0};
  WebSocketModule* module{nullptr};
  std::shared_ptr<std::atomic<bool>> alive;
  asio::io_context ioc;
  tcp::resolver resolver{ioc};
  websocket::stream<beast::tcp_stream> ws{ioc};
  beast::flat_buffer buffer;
  struct Out {
    std::string data;
    bool binary;
  };
  std::deque<Out> outbox;
  bool writing{false};
  bool open{false};
  bool closing{false};
  bool finished{false};
  std::thread thread;

  bool live() const { return alive && alive->load(); }

  void finish() {
    if (finished) return;
    finished = true;
    ioc.stop();
  }

  void fail(const std::string& message) {
    if (finished) return;
    if (live()) module->emitFailed(id, message);
    finish();
  }

  // Fully ASYNC connect: resolve -> connect (15 s timeout) -> handshake.
  // A synchronous connect ignores tcp_stream's expiry, and on some hosts
  // (measured: WSL) a connect to a closed local port is never refused, it
  // just hangs -- React DevTools' ws://localhost:8097 probe then pinned the
  // socket thread forever and teardown could not join it.
  void start(WsUrl url, std::vector<std::string> protocols,
             std::map<std::string, std::string> headers) {
    auto self = shared_from_this();
    std::string proto;
    for (size_t i = 0; i < protocols.size(); ++i) {
      proto += (i ? ", " : "") + protocols[i];
    }
    ws.set_option(websocket::stream_base::decorator(
        [headers, proto](websocket::request_type& req) {
          req.set(beast::http::field::user_agent, "react-native-impeller");
          if (!proto.empty())
            req.set(beast::http::field::sec_websocket_protocol, proto);
          for (const auto& [k, v] : headers) req.set(k, v);
        }));
    const std::string hostHeader =
        url.port == "80" ? url.host : url.host + ":" + url.port;
    resolver.async_resolve(
        url.host, url.port,
        [self, hostHeader, target = url.target](
            beast::error_code ec, tcp::resolver::results_type results) {
          if (ec) return self->fail("resolve: " + ec.message());
          beast::get_lowest_layer(self->ws).expires_after(std::chrono::seconds(15));
          beast::get_lowest_layer(self->ws).async_connect(
              results, [self, hostHeader, target](beast::error_code ec2,
                                                  tcp::endpoint) {
                if (ec2) return self->fail("connect: " + ec2.message());
                beast::get_lowest_layer(self->ws).expires_never();
                self->ws.set_option(websocket::stream_base::timeout::suggested(
                    beast::role_type::client));
                auto res = std::make_shared<websocket::response_type>();
                self->ws.async_handshake(
                    *res, hostHeader, target,
                    [self, res](beast::error_code ec3) {
                      if (ec3) return self->fail("handshake: " + ec3.message());
                      std::string chosen;
                      if (auto it = res->find(beast::http::field::sec_websocket_protocol);
                          it != res->end()) {
                        chosen = std::string(it->value());
                      }
                      self->open = true;
                      if (self->live()) self->module->emitOpen(self->id, chosen);
                      self->readNext();
                      self->flush();
                    });
              });
        });
    thread = std::thread([self]() {
      try {
        self->ioc.run();
      } catch (const std::exception& e) {
        self->fail(e.what());
      }
    });
  }

  void readNext() {
    auto self = shared_from_this();
    ws.async_read(buffer, [self](beast::error_code ec, std::size_t) {
      if (ec == websocket::error::closed) {
        const auto& r = self->ws.reason();
        if (self->live())
          self->module->emitClosed(self->id, r.code ? (int)r.code : 1000,
                                   std::string(r.reason.c_str()));
        self->finish();
        return;
      }
      if (ec) {
        if (self->closing) {
          if (self->live()) self->module->emitClosed(self->id, 1000, "");
          self->finish();
        } else {
          self->fail(ec.message());
        }
        return;
      }
      const std::string data = beast::buffers_to_string(self->buffer.data());
      self->buffer.consume(self->buffer.size());
      if (self->live())
        self->module->emitMessage(self->id, data, !self->ws.got_text());
      self->readNext();
    });
  }

  void flush() {
    if (writing || outbox.empty() || !open || finished) return;
    writing = true;
    auto self = shared_from_this();
    ws.binary(outbox.front().binary);
    ws.async_write(asio::buffer(outbox.front().data),
                   [self](beast::error_code ec, std::size_t) {
                     self->writing = false;
                     if (ec) {
                       self->fail(ec.message());
                       return;
                     }
                     self->outbox.pop_front();
                     self->flush();
                   });
  }

  void post(std::function<void()> fn) { asio::post(ioc, std::move(fn)); }
};

WebSocketModule::~WebSocketModule() {
  alive_->store(false);
  std::map<int, std::shared_ptr<WsConnection>> all;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    all.swap(sockets_);
  }
  for (auto& [id, c] : all) {
    c->post([c]() {
      beast::error_code ec;
      beast::get_lowest_layer(c->ws).socket().close(ec);
      c->finish();
    });
    c->ioc.stop();
    if (c->thread.joinable()) c->thread.join();
  }
}

std::shared_ptr<WsConnection> WebSocketModule::find(int id) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = sockets_.find(id);
  return it == sockets_.end() ? nullptr : it->second;
}

void WebSocketModule::forget(int id) {
  std::shared_ptr<WsConnection> c;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sockets_.find(id);
    if (it == sockets_.end()) return;
    c = it->second;
    sockets_.erase(it);
  }
  // Called on the JS thread after a terminal event; the socket thread has
  // stopped (finish() stopped its io_context) or is about to.
  if (c->thread.joinable()) c->thread.detach();
}

void WebSocketModule::connect(jsi::Runtime& rt, jsi::String url,
                              std::optional<jsi::Array> protocols,
                              jsi::Object options, double socketID) {
  const int id = (int)socketID;
  const std::string u = url.utf8(rt);
  std::vector<std::string> protos;
  if (protocols) {
    for (size_t i = 0; i < protocols->size(rt); ++i) {
      auto v = protocols->getValueAtIndex(rt, i);
      if (v.isString()) protos.push_back(v.getString(rt).utf8(rt));
    }
  }
  std::map<std::string, std::string> headers;
  if (options.hasProperty(rt, "headers")) {
    auto hv = options.getProperty(rt, "headers");
    if (hv.isObject()) {
      auto h = hv.getObject(rt);
      auto names = h.getPropertyNames(rt);
      for (size_t i = 0; i < names.size(rt); ++i) {
        auto k = names.getValueAtIndex(rt, i).getString(rt).utf8(rt);
        auto v = h.getProperty(rt, k.c_str());
        if (v.isString()) headers[k] = v.getString(rt).utf8(rt);
      }
    }
  }
  std::printf("rn-impeller: websocket connect id=%d url=%s\n", id, u.c_str());
  std::fflush(stdout);
  WsUrl parsed = parseWsUrl(u);
  if (!parsed.ok) {
    emitFailed(id, parsed.error);
    return;
  }
  auto c = std::make_shared<WsConnection>();
  c->id = id;
  c->module = this;
  c->alive = alive_;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    sockets_[id] = c;
  }
  c->start(parsed, protos, headers);
}

void WebSocketModule::send(jsi::Runtime& rt, jsi::String message,
                           double forSocketID) {
  auto c = find((int)forSocketID);
  if (!c) return;
  std::string data = message.utf8(rt);
  c->post([c, data = std::move(data)]() mutable {
    c->outbox.push_back({std::move(data), false});
    c->flush();
  });
}

void WebSocketModule::sendBinary(jsi::Runtime& rt, jsi::String base64String,
                                 double forSocketID) {
  auto c = find((int)forSocketID);
  if (!c) return;
  std::string data = base64Decode(base64String.utf8(rt));
  c->post([c, data = std::move(data)]() mutable {
    c->outbox.push_back({std::move(data), true});
    c->flush();
  });
}

void WebSocketModule::ping(jsi::Runtime&, double socketID) {
  auto c = find((int)socketID);
  if (!c) return;
  c->post([c]() {
    if (!c->open || c->finished) return;
    c->ws.async_ping({}, [](beast::error_code) {});
  });
}

void WebSocketModule::close(jsi::Runtime& rt, double code, jsi::String reason,
                            double socketID) {
  auto c = find((int)socketID);
  if (!c) return;
  std::string why = reason.utf8(rt);
  const int cc = (int)code;
  c->post([c, cc, why]() {
    if (c->finished || c->closing) return;
    c->closing = true;
    if (!c->open) {
      c->finish();
      return;
    }
    websocket::close_reason r;
    r.code = (websocket::close_code)(cc > 0 ? cc : 1000);
    r.reason = why;
    c->ws.async_close(r, [c](beast::error_code) {
      // The pending async_read completes with `closed` and emits the event.
    });
  });
}

void WebSocketModule::emitOpen(int id, const std::string& protocol) {
  std::printf("rn-impeller: websocket open id=%d\n", id);
  std::fflush(stdout);
  emitDeviceEvent("websocketOpen", [id, protocol](jsi::Runtime& rt,
                                                  std::vector<jsi::Value>& args) {
    jsi::Object o(rt);
    o.setProperty(rt, "id", id);
    o.setProperty(rt, "protocol", jsi::String::createFromUtf8(rt, protocol));
    args.emplace_back(std::move(o));
  });
}

void WebSocketModule::emitMessage(int id, const std::string& data, bool binary) {
  const std::string payload = binary ? base64Encode(data) : data;
  emitDeviceEvent("websocketMessage", [id, payload, binary](
                                          jsi::Runtime& rt,
                                          std::vector<jsi::Value>& args) {
    jsi::Object o(rt);
    o.setProperty(rt, "id", id);
    o.setProperty(rt, "type",
                  jsi::String::createFromAscii(rt, binary ? "binary" : "text"));
    o.setProperty(rt, "data", jsi::String::createFromUtf8(rt, payload));
    args.emplace_back(std::move(o));
  });
}

void WebSocketModule::emitClosed(int id, int code, const std::string& reason) {
  std::printf("rn-impeller: websocket closed id=%d code=%d\n", id, code);
  std::fflush(stdout);
  emitDeviceEvent("websocketClosed", [this, alive = alive_, id, code, reason](
                                         jsi::Runtime& rt,
                                         std::vector<jsi::Value>& args) {
    if (alive->load()) forget(id);
    jsi::Object o(rt);
    o.setProperty(rt, "id", id);
    o.setProperty(rt, "code", code);
    o.setProperty(rt, "reason", jsi::String::createFromUtf8(rt, reason));
    args.emplace_back(std::move(o));
  });
}

void WebSocketModule::emitFailed(int id, const std::string& message) {
  std::printf("rn-impeller: websocket failed id=%d message=%s\n", id,
              message.c_str());
  std::fflush(stdout);
  emitDeviceEvent("websocketFailed", [this, alive = alive_, id, message](
                                         jsi::Runtime& rt,
                                         std::vector<jsi::Value>& args) {
    if (alive->load()) forget(id);
    jsi::Object o(rt);
    o.setProperty(rt, "id", id);
    o.setProperty(rt, "message", jsi::String::createFromUtf8(rt, message));
    args.emplace_back(std::move(o));
  });
}

}  // namespace rni
