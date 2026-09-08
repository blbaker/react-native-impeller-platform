#include "modules/NetworkingModule.h"

#include <boost/asio/connect.hpp>
#include <boost/asio/io_context.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/read.hpp>
#include <boost/asio/read_until.hpp>
#include <boost/asio/streambuf.hpp>
#include <boost/asio/write.hpp>
#ifdef RNI_WITH_TLS
#include <boost/asio/ssl.hpp>
#endif

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <istream>
#include <ostream>
#include <sstream>
#include <thread>
#include <vector>

namespace rni {

namespace asio = boost::asio;
using tcp = asio::ip::tcp;

namespace {

std::string toLower(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return s;
}

std::string trim(const std::string& s) {
  size_t b = s.find_first_not_of(" \t\r\n");
  if (b == std::string::npos) return "";
  size_t e = s.find_last_not_of(" \t\r\n");
  return s.substr(b, e - b + 1);
}

// ⛔ THE RESPONSE MUST BE ENCODED THE WAY THE CALLER ASKED, AND `fetch` ASKS
// FOR BASE64 ON THIS ENGINE. XMLHttpRequest.js maps responseType 'arraybuffer'
// to a NATIVE responseType of 'base64', then decodes with base64-js. RN's
// fetch polyfill picks 'blob' when BlobModule is available and falls back to
// 'arraybuffer' when it is not — and this engine vends no BlobModule, so EVERY
// fetch() on this platform arrives here asking for base64.
//
// Returning raw text regardless looks completely correct in a curl-shaped test
// and in --test-http, and then every real fetch() dies inside base64-js with
// "Invalid string. Length must be a multiple of 4" — an error naming neither
// networking nor this module. Measured, not theorised: that is exactly how the
// first P10 run failed with the native half already green.
std::string base64Encode(const std::string& in) {
  static constexpr char kTable[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((in.size() + 2) / 3) * 4);
  size_t i = 0;
  while (i + 2 < in.size()) {
    uint32_t n = (static_cast<unsigned char>(in[i]) << 16) |
                 (static_cast<unsigned char>(in[i + 1]) << 8) |
                 static_cast<unsigned char>(in[i + 2]);
    out += kTable[(n >> 18) & 63];
    out += kTable[(n >> 12) & 63];
    out += kTable[(n >> 6) & 63];
    out += kTable[n & 63];
    i += 3;
  }
  // The tail is where a hand-rolled encoder goes wrong, and the padding is not
  // cosmetic: base64-js REQUIRES length % 4 == 0 and throws otherwise.
  if (i + 1 == in.size()) {
    uint32_t n = static_cast<unsigned char>(in[i]) << 16;
    out += kTable[(n >> 18) & 63];
    out += kTable[(n >> 12) & 63];
    out += '=';
    out += '=';
  } else if (i + 2 == in.size()) {
    uint32_t n = (static_cast<unsigned char>(in[i]) << 16) |
                 (static_cast<unsigned char>(in[i + 1]) << 8);
    out += kTable[(n >> 18) & 63];
    out += kTable[(n >> 12) & 63];
    out += kTable[(n >> 6) & 63];
    out += '=';
  }
  return out;
}

// ⛔ CHUNKED IS NOT OPTIONAL, BECAUSE THE SERVER PICKS IT, NOT US.
// HTTP/1.1 lets a server answer with Transfer-Encoding: chunked whenever it
// does not know the body length up front — which Node's http module does by
// DEFAULT for any response written without an explicit Content-Length. Asking
// for `Accept-Encoding: identity` does not prevent it: that negotiates
// CONTENT coding (gzip), not TRANSFER framing.
//
// Handing the raw stream to JS then delivers the chunk-size line as the body.
// Measured, not theorised: the P10 fixture received "13\r\n" — 0x13 being the
// hex length of the 19-byte token it expected — while status, headers and the
// error path were all already green. The engine's own --test-http missed it
// because that server sets Content-Length, which is exactly the trap of
// testing only against a server you wrote yourself.
std::string decodeChunked(const std::string& in, bool* ok) {
  std::string out;
  size_t pos = 0;
  *ok = true;
  while (pos < in.size()) {
    size_t lineEnd = in.find("\r\n", pos);
    if (lineEnd == std::string::npos) { *ok = false; break; }
    // The size line may carry chunk extensions after a ';'.
    std::string sizeLine = in.substr(pos, lineEnd - pos);
    size_t semi = sizeLine.find(';');
    if (semi != std::string::npos) sizeLine = sizeLine.substr(0, semi);
    sizeLine = trim(sizeLine);
    if (sizeLine.empty()) { *ok = false; break; }

    size_t chunkSize = 0;
    try {
      chunkSize = static_cast<size_t>(std::stoul(sizeLine, nullptr, 16));
    } catch (const std::exception&) { *ok = false; break; }

    pos = lineEnd + 2;
    if (chunkSize == 0) break;  // terminal chunk; trailers ignored
    if (pos + chunkSize > in.size()) { *ok = false; break; }
    out.append(in, pos, chunkSize);
    pos += chunkSize;
    // Each chunk is followed by its own CRLF.
    if (in.compare(pos, 2, "\r\n") == 0) pos += 2;
  }
  return out;
}

}  // namespace

// ---------------------------------------------------------------------------
// URL parsing
// ---------------------------------------------------------------------------

ParsedUrl parseUrl(const std::string& url) {
  ParsedUrl out;

  size_t schemeEnd = url.find("://");
  if (schemeEnd == std::string::npos) {
    out.error = "Unsupported URL (no scheme): " + url;
    return out;
  }
  out.scheme = toLower(url.substr(0, schemeEnd));

  // https is carried by asio::ssl over the same socket the http path uses.
  // When the engine is built without TLS the scheme is REFUSED with an error
  // naming the limitation, rather than silently downgraded to plaintext — a
  // downgrade would put a bearer token on the wire in clear text, which is a
  // credential leak wearing a success message.
  if (out.scheme != "http" && out.scheme != "https") {
    out.error = "Unsupported URL scheme '" + out.scheme + "'";
    return out;
  }
#ifndef RNI_WITH_TLS
  if (out.scheme == "https") {
    out.error =
        "https is not supported by this engine build (no TLS linked). "
        "Use http:// or build with TLS support.";
    return out;
  }
#endif

  std::string rest = url.substr(schemeEnd + 3);
  size_t pathStart = rest.find('/');
  std::string authority =
      pathStart == std::string::npos ? rest : rest.substr(0, pathStart);
  out.target = pathStart == std::string::npos ? "/" : rest.substr(pathStart);
  if (out.target.empty()) out.target = "/";

  // Strip userinfo if present; we do not implement basic-auth-in-URL.
  size_t at = authority.find('@');
  if (at != std::string::npos) authority = authority.substr(at + 1);

  size_t colon = authority.rfind(':');
  // rfind(':') would also match inside an IPv6 literal; a ']' after it means
  // the colon belongs to the address, not to a port.
  // ⛔ THE DEFAULT PORT IS SCHEME-DEPENDENT. Defaulting to 80 for an https URL
  // sends a TLS ClientHello at a plaintext port: the peer either refuses or
  // replies with an HTTP error page that the handshake reads as garbage, and
  // the failure names neither the port nor the scheme.
  const std::string defaultPort = (out.scheme == "https") ? "443" : "80";
  if (colon != std::string::npos && authority.find(']', colon) == std::string::npos) {
    out.host = authority.substr(0, colon);
    out.port = authority.substr(colon + 1);
  } else {
    out.host = authority;
    out.port = defaultPort;
  }

  // Bare IPv6 literals arrive bracketed; asio's resolver wants them bare.
  if (out.host.size() >= 2 && out.host.front() == '[' && out.host.back() == ']') {
    out.host = out.host.substr(1, out.host.size() - 2);
  }

  if (out.host.empty()) {
    out.error = "URL has no host: " + url;
    return out;
  }
  if (out.port.empty()) out.port = defaultPort;

  out.valid = true;
  return out;
}

// ---------------------------------------------------------------------------
// The transport
// ---------------------------------------------------------------------------

// The HTTP exchange, written once against ANY synchronous asio stream.
// `tcp::socket` and `ssl::stream<tcp::socket&>` both satisfy it, so the wire
// format has exactly one implementation and plaintext and TLS cannot drift
// apart in framing, header handling or chunk decoding.
template <typename Stream>
HttpResponse httpExchange(Stream& stream,
                          const std::string& method,
                          const ParsedUrl& url,
                          const std::map<std::string, std::string>& headers,
                          const std::string& body) {
  HttpResponse res;

  // -- request --
  std::ostringstream req;
  req << method << " " << url.target << " HTTP/1.1\r\n";
  req << "Host: " << url.host;
  // The default port is omitted from Host, and which port is "default"
  // depends on the scheme. Sending "Host: h:443" on https is legal but
  // differs from what every other client sends, and vhost routing and
  // certificate/SNI matching are both sensitive to it.
  const std::string defaultPort = (url.scheme == "https") ? "443" : "80";
  if (url.port != defaultPort) req << ":" << url.port;
  req << "\r\n";

  bool sawUserAgent = false, sawAccept = false, sawContentLength = false;
  for (const auto& [k, v] : headers) {
    std::string lk = toLower(k);
    if (lk == "host") continue;  // ours wins; a duplicate Host is a 400
    if (lk == "connection") continue;
    if (lk == "user-agent") sawUserAgent = true;
    if (lk == "accept") sawAccept = true;
    if (lk == "content-length") sawContentLength = true;
    req << k << ": " << v << "\r\n";
  }
  if (!sawUserAgent) req << "User-Agent: react-native-impeller\r\n";
  if (!sawAccept) req << "Accept: */*\r\n";
  // Content-Length is emitted whenever there is a body, and also for
  // bodyless POST/PUT — a POST with neither Content-Length nor
  // Transfer-Encoding makes some servers wait for a body that never comes.
  std::string m = toLower(method);
  if (!sawContentLength && (!body.empty() || m == "post" || m == "put" || m == "patch")) {
    req << "Content-Length: " << body.size() << "\r\n";
  }
  // Identity + close: chunked and keep-alive both need a framing layer this
  // module does not have, and asking for them would produce a body we then
  // mis-read. Asking for exactly what we can parse is honest.
  req << "Accept-Encoding: identity\r\n";
  req << "Connection: close\r\n\r\n";
  req << body;

  std::string requestStr = req.str();
  asio::write(stream, asio::buffer(requestStr));

  // -- status line --
  asio::streambuf buf;
  asio::read_until(stream, buf, "\r\n");
  std::istream is(&buf);
  std::string httpVersion;
  is >> httpVersion >> res.status;
  std::getline(is, res.statusText);
  res.statusText = trim(res.statusText);
  if (httpVersion.rfind("HTTP/", 0) != 0) {
    res.error = "Malformed HTTP response from " + url.host;
    return res;
  }

  // -- headers --
  asio::read_until(stream, buf, "\r\n\r\n");
  std::string line;
  while (std::getline(is, line) && line != "\r") {
    size_t colon = line.find(':');
    if (colon == std::string::npos) continue;
    res.headers[trim(line.substr(0, colon))] = trim(line.substr(colon + 1));
  }

  // -- body: everything until the server closes (Connection: close) --
  std::ostringstream bodyOut;
  if (buf.size() > 0) bodyOut << &buf;
  boost::system::error_code ec;
  while (asio::read(stream, buf, asio::transfer_at_least(1), ec)) {
    bodyOut << &buf;
    if (ec) break;
  }
  // ⛔ A TLS PEER THAT CLOSES WITHOUT close_notify RAISES ssl::error::stream_truncated,
  // NOT eof. Treating that as a read failure would fail perfectly good responses
  // from the many servers that just close the TCP connection — and it would fail
  // them AFTER the body had already been read in full.
  const bool benignEof = !ec || ec == asio::error::eof ||
                         ec == asio::error::connection_reset
#ifdef RNI_WITH_TLS
                         || ec == asio::ssl::error::stream_truncated
#endif
      ;
  if (!benignEof) {
    res.error = "Read failed: " + ec.message();
    return res;
  }
  res.body = bodyOut.str();

  // Decode the transfer framing the SERVER chose. Case-insensitive: header
  // names and values are not normalised on the wire.
  for (const auto& [k, v] : res.headers) {
    if (toLower(k) == "transfer-encoding" &&
        toLower(v).find("chunked") != std::string::npos) {
      bool decoded = false;
      std::string decodedBody = decodeChunked(res.body, &decoded);
      if (!decoded) {
        res.error = "Malformed chunked response from " + url.host;
        return res;
      }
      res.body = decodedBody;
      break;
    }
  }
  res.ok = true;
  return res;
}

HttpResponse performRequest(const std::string& method,
                            const ParsedUrl& url,
                            const std::map<std::string, std::string>& headers,
                            const std::string& body,
                            double timeoutMs) {
  HttpResponse res;
  if (!url.valid) {
    res.error = url.error;
    return res;
  }

  try {
    asio::io_context io;
    tcp::resolver resolver(io);
    auto endpoints = resolver.resolve(url.host, url.port);

    tcp::socket socket(io);

    // ⛔ CONNECT MUST BE BOUNDED, AND SO_*TIMEO DOES NOT BOUND IT.
    // The socket options below apply to read/write, not to connect(). And
    // `fetch()` passes timeout: 0 by default — meaning "no timeout" — so a
    // blocking asio::connect to a host that neither accepts nor refuses waits
    // indefinitely, on a thread nothing can interrupt. That is an app hang,
    // not a failed request, and it is exactly what a happy-path test never
    // sees. Measured: the P10 dead-port probe left one request in flight past
    // a 15s settle, because a blackholed port does not refuse.
    //
    // So connect asynchronously and run the io_context for a bounded slice.
    // The cap applies even when the caller asked for no timeout: "wait
    // forever" is never the right answer for a TCP connect.
    const auto connectBudget = std::chrono::milliseconds(
        timeoutMs > 0 ? static_cast<long long>(timeoutMs) : 10000);
    boost::system::error_code connectEc = asio::error::would_block;
    asio::async_connect(socket, endpoints,
                        [&connectEc](const boost::system::error_code& ec,
                                     const tcp::endpoint&) { connectEc = ec; });
    io.run_for(connectBudget);
    if (connectEc == asio::error::would_block) {
      // The handler never ran: the deadline expired first. Cancel so the
      // socket does not complete against a dead io_context after we return.
      socket.close();
      res.error = "Connection to " + url.host + ":" + url.port +
                  " timed out after " +
                  std::to_string(connectBudget.count()) + "ms";
      return res;
    }
    if (connectEc) {
      res.error = "Connection to " + url.host + ":" + url.port +
                  " failed: " + connectEc.message();
      return res;
    }
    // run_for leaves the context stopped; the blocking calls below need it
    // usable again.
    io.restart();

    // A dead peer must not hang the worker forever. These are the SO_*TIMEO
    // socket options rather than an asio deadline_timer, because the calls
    // below are synchronous — a timer would need an async rewrite of the whole
    // function to have any effect.
    if (timeoutMs > 0) {
      auto secs = static_cast<int>(timeoutMs / 1000.0);
      auto usecs = static_cast<int>(timeoutMs * 1000.0) % 1000000;
      if (secs == 0 && usecs == 0) usecs = 1000;
#ifndef _WIN32
      struct timeval tv {};
      tv.tv_sec = secs;
      tv.tv_usec = usecs;
      ::setsockopt(socket.native_handle(), SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
      ::setsockopt(socket.native_handle(), SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#else
      DWORD ms = static_cast<DWORD>(timeoutMs);
      ::setsockopt(socket.native_handle(), SOL_SOCKET, SO_RCVTIMEO,
                   reinterpret_cast<const char*>(&ms), sizeof(ms));
      ::setsockopt(socket.native_handle(), SOL_SOCKET, SO_SNDTIMEO,
                   reinterpret_cast<const char*>(&ms), sizeof(ms));
#endif
    }

    // -- dispatch: plaintext reuses the socket, TLS wraps it --
    // The wire format lives in httpExchange() and is shared. Only the
    // handshake and the trust decision are scheme-specific.
    if (url.scheme == "https") {
#ifdef RNI_WITH_TLS
      asio::ssl::context ctx(asio::ssl::context::tls_client);

      // ⛔ VERIFICATION IS NOT ON BY DEFAULT. asio's default is verify_none:
      // a self-signed or actively forged certificate is ACCEPTED and the
      // request succeeds, which is worse than no TLS because it looks secure.
      ctx.set_verify_mode(asio::ssl::verify_peer);
      ctx.set_options(asio::ssl::context::default_workarounds |
                      asio::ssl::context::no_sslv2 |
                      asio::ssl::context::no_sslv3 |
                      asio::ssl::context::no_tlsv1 |
                      asio::ssl::context::no_tlsv1_1);

      // The trust store. Without this there is nothing to verify AGAINST and
      // every request fails "unable to get local issuer certificate" -- which
      // reads as a server problem rather than a client misconfiguration.
      boost::system::error_code storeEc;
      ctx.set_default_verify_paths(storeEc);
      if (storeEc) {
        res.error = "TLS trust store unavailable: " + storeEc.message();
        return res;
      }

      asio::ssl::stream<tcp::socket&> tls(socket, ctx);

      // ⛔ TWO SEPARATE THINGS BOTH NEED THE HOSTNAME.
      // 1. SNI, or a vhosting server sends the wrong certificate (or refuses).
      //    SSL_set_tlsext_host_name is a macro, so it needs the raw handle.
      // 2. Hostname verification. verify_peer alone proves the chain is
      //    trusted, NOT that the certificate was issued for THIS host -- a
      //    valid certificate for any other domain would otherwise pass.
      if (!SSL_set_tlsext_host_name(tls.native_handle(), url.host.c_str())) {
        res.error = "TLS SNI setup failed for " + url.host;
        return res;
      }
      tls.set_verify_callback(asio::ssl::host_name_verification(url.host));

      boost::system::error_code hsEc;
      tls.handshake(asio::ssl::stream_base::client, hsEc);
      if (hsEc) {
        // Name the certificate result explicitly. "handshake failed" sends a
        // developer looking at the network; a rejected certificate is a trust
        // problem and the two have nothing in common.
        long vr = SSL_get_verify_result(tls.native_handle());
        std::string detail = hsEc.message();
        if (vr != X509_V_OK) {
          detail += " (certificate rejected: ";
          detail += X509_verify_cert_error_string(vr);
          detail += ")";
        }
        res.error = "TLS handshake with " + url.host + " failed: " + detail;
        return res;
      }

      res = httpExchange(tls, method, url, headers, body);

      // Best-effort close_notify. A peer that has already gone away makes this
      // fail, and that is not a request failure -- the response is complete.
      boost::system::error_code shutEc;
      tls.shutdown(shutEc);
      return res;
#else
      res.error =
          "https is not supported by this engine build (no TLS linked). "
          "Use http:// or build with TLS support.";
      return res;
#endif
    }

    return httpExchange(socket, method, url, headers, body);
  } catch (const std::exception& e) {
    res.error = std::string("Request failed: ") + e.what();
    return res;
  }
}

// ---------------------------------------------------------------------------
// TurboModule surface
// ---------------------------------------------------------------------------

NetworkingModule::~NetworkingModule() {
  // A worker calls emitDeviceEvent on `this`. Dying with one in flight is a
  // use-after-free, so wait — bounded, because a stuck socket must not wedge
  // teardown forever.
  for (int i = 0; i < 500 && inFlight_.load() > 0; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
}

void NetworkingModule::emitResponse(double requestId,
                                    int status,
                                    const std::map<std::string, std::string>& headers,
                                    const std::string& url) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (aborted_.count(requestId)) return;
  }
  // ⛔ ONE ARRAY ARGUMENT, NOT SPREAD ARGUMENTS. RCTNetworkingEventDefinitions
  // types every event as `[[a, b, c]]` and XMLHttpRequest.js does
  // `args => this.__didReceiveResponse(...args)` — it spreads on the JS side.
  // Emitting three separate arguments delivers `requestId` as `args` and the
  // handler silently receives undefined for everything. Nothing throws.
  emitDeviceEvent("didReceiveNetworkResponse",
                  [requestId, status, headers, url](jsi::Runtime& rt,
                                                    std::vector<jsi::Value>& args) {
                    auto arr = jsi::Array(rt, 4);
                    arr.setValueAtIndex(rt, 0, jsi::Value(requestId));
                    arr.setValueAtIndex(rt, 1, jsi::Value(static_cast<double>(status)));
                    jsi::Object h(rt);
                    for (const auto& [k, v] : headers) {
                      h.setProperty(rt, k.c_str(),
                                    jsi::String::createFromUtf8(rt, v));
                    }
                    arr.setValueAtIndex(rt, 2, std::move(h));
                    arr.setValueAtIndex(rt, 3, jsi::String::createFromUtf8(rt, url));
                    args.emplace_back(std::move(arr));
                  });
}

void NetworkingModule::emitData(double requestId, const std::string& body) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (aborted_.count(requestId)) return;
  }
  emitDeviceEvent("didReceiveNetworkData",
                  [requestId, body](jsi::Runtime& rt, std::vector<jsi::Value>& args) {
                    auto arr = jsi::Array(rt, 2);
                    arr.setValueAtIndex(rt, 0, jsi::Value(requestId));
                    arr.setValueAtIndex(rt, 1, jsi::String::createFromUtf8(rt, body));
                    args.emplace_back(std::move(arr));
                  });
}

void NetworkingModule::emitComplete(double requestId,
                                    const std::string& error,
                                    bool timedOut) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (aborted_.count(requestId)) return;
  }
  emitDeviceEvent("didCompleteNetworkResponse",
                  [requestId, error, timedOut](jsi::Runtime& rt,
                                               std::vector<jsi::Value>& args) {
                    auto arr = jsi::Array(rt, 3);
                    arr.setValueAtIndex(rt, 0, jsi::Value(requestId));
                    // XHR treats '' as success and any string as the error
                    // message; null would be read as a missing argument.
                    arr.setValueAtIndex(rt, 1, jsi::String::createFromUtf8(rt, error));
                    arr.setValueAtIndex(rt, 2, jsi::Value(timedOut));
                    args.emplace_back(std::move(arr));
                  });
}

void NetworkingModule::sendRequest(jsi::Runtime& rt,
                                   jsi::Object query,
                                   jsi::Function callback) {
  auto getString = [&](const char* key) -> std::string {
    auto v = query.getProperty(rt, key);
    return v.isString() ? v.asString(rt).utf8(rt) : std::string();
  };

  std::string method = getString("method");
  if (method.empty()) method = "GET";
  std::string url = getString("url");

  std::map<std::string, std::string> headers;
  {
    auto v = query.getProperty(rt, "headers");
    if (v.isObject()) {
      auto obj = v.asObject(rt);
      auto names = obj.getPropertyNames(rt);
      for (size_t i = 0; i < names.size(rt); ++i) {
        auto name = names.getValueAtIndex(rt, i).asString(rt).utf8(rt);
        auto hv = obj.getProperty(rt, name.c_str());
        if (hv.isString()) headers[name] = hv.asString(rt).utf8(rt);
      }
    }
  }

  // The body arrives as `{string: "..."}` for text, and as {formData}/{blob}/
  // {base64} for the shapes this v1 does not implement. Reading only `string`
  // and reporting the rest as an error beats silently sending an empty body.
  std::string body;
  std::string bodyError;
  {
    auto v = query.getProperty(rt, "data");
    if (v.isObject()) {
      auto obj = v.asObject(rt);
      auto s = obj.getProperty(rt, "string");
      if (s.isString()) {
        body = s.asString(rt).utf8(rt);
      } else {
        for (const char* unsupported : {"formData", "blob", "base64", "uri"}) {
          if (!obj.getProperty(rt, unsupported).isUndefined()) {
            bodyError = std::string("Request body type '") + unsupported +
                        "' is not supported by this engine build";
            break;
          }
        }
      }
    }
  }

  double timeoutMs = 0;
  {
    auto v = query.getProperty(rt, "timeout");
    if (v.isNumber()) timeoutMs = v.asNumber();
  }

  // 'text' | 'base64' | 'blob'. See base64Encode's comment: fetch() on this
  // engine always asks for base64, because no BlobModule is vended.
  std::string responseType = getString("responseType");
  if (responseType.empty()) responseType = "text";

  // Allocate + hand back the id BEFORE anything async. See the header comment:
  // an event for an id JS has not stored yet is dropped.
  double requestId = nextRequestId_.fetch_add(1);
  callback.call(rt, jsi::Value(requestId));

  auto parsed = parseUrl(url);

  inFlight_.fetch_add(1);
  if (activity_) activity_->inFlight.fetch_add(1);
  std::thread([this, requestId, method, parsed, headers, body, bodyError,
               timeoutMs, url, responseType]() {
    // One exit point for the counters, so a path that returns early cannot
    // leave inFlight pinned above zero — which would hang every headless run
    // for the full settle timeout rather than failing anything.
    auto done = [this]() {
      if (activity_) {
        activity_->completed.fetch_add(1);
        activity_->inFlight.fetch_sub(1);
      }
      inFlight_.fetch_sub(1);
    };

    if (!bodyError.empty()) {
      emitComplete(requestId, bodyError, false);
      done();
      return;
    }
    auto res = performRequest(method, parsed, headers, body, timeoutMs);
    if (!res.ok) {
      emitComplete(requestId, res.error, false);
    } else {
      emitResponse(requestId, res.status, res.headers, url);
      // 'blob' is not implemented (no BlobModule); base64 is the closest
      // honest answer and is what XHR can still decode, rather than handing
      // back text that will fail to parse.
      if (responseType == "base64" || responseType == "blob") {
        emitData(requestId, base64Encode(res.body));
      } else {
        emitData(requestId, res.body);
      }
      emitComplete(requestId, "", false);
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      aborted_.erase(requestId);
    }
    done();
  }).detach();
}

void NetworkingModule::abortRequest(jsi::Runtime&, double requestId) {
  std::lock_guard<std::mutex> lock(mutex_);
  aborted_[requestId] = true;
}

void NetworkingModule::clearCookies(jsi::Runtime& rt, jsi::Function callback) {
  // No cookie jar exists, so nothing was cleared. `false` is what RN's own
  // implementations return when there was nothing to clear; returning true
  // would claim work that did not happen.
  callback.call(rt, jsi::Value(false));
}

// ---------------------------------------------------------------------------
// Self-tests — the gateable half
// ---------------------------------------------------------------------------

int runUrlSelfTest() {
  struct Case {
    const char* url;
    bool valid;
    const char* host;
    const char* port;
    const char* target;
  };
  const Case cases[] = {
      {"http://127.0.0.1:8080/api/x?y=1", true, "127.0.0.1", "8080", "/api/x?y=1"},
      {"http://example.com/", true, "example.com", "80", "/"},
      {"http://example.com", true, "example.com", "80", "/"},
      {"http://user:pw@example.com:81/p", true, "example.com", "81", "/p"},
      {"http://[::1]:9000/p", true, "::1", "9000", "/p"},
      // https now PARSES, and defaults to 443 rather than 80. Before TLS this
      // row asserted `false` -- the assertion inverting is the point: it is
      // what proves the build actually links TLS rather than merely claiming to.
#ifdef RNI_WITH_TLS
      {"https://example.com/", true, "example.com", "443", "/"},
      {"https://example.com:8443/p", true, "example.com", "8443", "/p"},
#else
      {"https://example.com/", false, "", "", ""},
#endif
      {"ftp://example.com/", false, "", "", ""},
      {"/relative/path", false, "", "", ""},
      {"http:///nohost", false, "", "", ""},
  };

  int failures = 0;
  for (const auto& c : cases) {
    auto p = parseUrl(c.url);
    bool ok = (p.valid == c.valid);
    if (ok && c.valid) {
      ok = (p.host == c.host && p.port == c.port && p.target == c.target);
    }
    if (!ok) ++failures;
    std::printf("  %-38s valid=%-5s host=%-12s port=%-5s target=%-14s %s\n",
                c.url, p.valid ? "true" : "false", p.host.c_str(),
                p.port.c_str(), p.target.c_str(), ok ? "ok" : "FAIL");
  }
  std::printf("url-selftest: %s (%d failure%s)\n", failures ? "FAIL" : "PASS",
              failures, failures == 1 ? "" : "s");
  return failures ? 1 : 0;
}

int runHttpSelfTest() {
  int failures = 0;

  // A one-shot loopback server. It records the request it saw so the test can
  // assert the CLIENT sent the right thing, not merely that bytes moved.
  struct Seen {
    std::string requestLine;
    std::string headerBlock;
    std::string body;
  };

  auto serveOnce = [](unsigned short& outPort, Seen& seen,
                      const std::string& responseBody) {
    auto io = std::make_shared<asio::io_context>();
    auto acceptor = std::make_shared<tcp::acceptor>(
        *io, tcp::endpoint(asio::ip::make_address("127.0.0.1"), 0));
    outPort = acceptor->local_endpoint().port();
    return std::thread([io, acceptor, &seen, responseBody]() {
      try {
        tcp::socket sock(*io);
        acceptor->accept(sock);

        asio::streambuf buf;
        boost::system::error_code ec;
        asio::read_until(sock, buf, "\r\n\r\n", ec);
        std::istream in(&buf);
        std::getline(in, seen.requestLine);
        std::string line;
        size_t contentLength = 0;
        while (std::getline(in, line) && line != "\r") {
          seen.headerBlock += line + "\n";
          std::string lower = toLower(line);
          if (lower.rfind("content-length:", 0) == 0) {
            contentLength = static_cast<size_t>(std::stoul(trim(line.substr(15))));
          }
        }
        std::ostringstream got;
        if (buf.size() > 0) got << &buf;
        seen.body = got.str();
        while (seen.body.size() < contentLength) {
          asio::read(sock, buf, asio::transfer_at_least(1), ec);
          std::ostringstream more;
          more << &buf;
          seen.body += more.str();
          if (ec) break;
        }

        std::ostringstream resp;
        resp << "HTTP/1.1 200 OK\r\n"
             << "Content-Type: text/plain\r\n"
             << "X-Probe: impeller\r\n"
             << "Content-Length: " << responseBody.size() << "\r\n"
             << "Connection: close\r\n\r\n"
             << responseBody;
        std::string out = resp.str();
        asio::write(sock, asio::buffer(out), ec);
        sock.shutdown(tcp::socket::shutdown_both, ec);
      } catch (const std::exception& e) {
        std::printf("  server error: %s\n", e.what());
      }
    });
  };

  auto check = [&](const char* what, bool ok) {
    std::printf("  %-46s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) ++failures;
  };

  // -- GET --
  {
    unsigned short port = 0;
    Seen seen;
    auto server = serveOnce(port, seen, "hello-get");
    auto url = parseUrl("http://127.0.0.1:" + std::to_string(port) + "/ping?a=1");
    auto res = performRequest("GET", url, {{"X-Client", "hostapp"}}, "", 5000);
    server.join();

    check("GET completed", res.ok);
    check("GET status is 200", res.status == 200);
    check("GET body is the server's body", res.body == "hello-get");
    check("GET response headers parsed",
          res.headers.count("X-Probe") && res.headers["X-Probe"] == "impeller");
    check("GET request line carries path+query",
          seen.requestLine.find("GET /ping?a=1 HTTP/1.1") != std::string::npos);
    check("GET custom request header reached the server",
          seen.headerBlock.find("X-Client: hostapp") != std::string::npos);
  }

  // -- POST with headers and a body --
  {
    unsigned short port = 0;
    Seen seen;
    auto server = serveOnce(port, seen, "hello-post");
    auto url = parseUrl("http://127.0.0.1:" + std::to_string(port) + "/submit");
    const std::string postBody = R"({"sets":3})";
    auto res = performRequest("POST", url,
                              {{"Content-Type", "application/json"},
                               {"X-Auth", "token123"}},
                              postBody, 5000);
    server.join();

    check("POST completed", res.ok);
    check("POST status is 200", res.status == 200);
    check("POST body is the server's body", res.body == "hello-post");
    check("POST request line is POST",
          seen.requestLine.find("POST /submit HTTP/1.1") != std::string::npos);
    check("POST Content-Type reached the server",
          seen.headerBlock.find("Content-Type: application/json") != std::string::npos);
    check("POST custom auth header reached the server",
          seen.headerBlock.find("X-Auth: token123") != std::string::npos);
    // Derived from the body, never hardcoded. A literal here was wrong on the
    // first run (11 for a 10-byte body) and would have been "fixed" by editing
    // the number to match whatever shipped — which tests nothing.
    check("POST Content-Length equals the real body length",
          toLower(seen.headerBlock)
                  .find("content-length: " + std::to_string(postBody.size())) !=
              std::string::npos);
    check("POST body reached the server", seen.body == postBody);
  }

  // -- https: refused when TLS is absent, verified when TLS is present --
  {
#ifdef RNI_WITH_TLS
    // The NEGATIVE CONTROL. A hostname that resolves but presents a
    // certificate for a different name must be REJECTED. Without this arm a
    // TLS stack with verification disabled passes every other assertion here,
    // which is exactly the failure mode this test exists to catch.
    //
    // Uses a documented-invalid-certificate endpoint rather than a live the company
    // host. Skipped when the network is unreachable so the suite stays
    // hermetic; a network failure is not a verification failure and must not
    // be reported as one.
    auto badUrl = parseUrl("https://self-signed.badssl.com/");
    check("https URL parses once TLS is linked", badUrl.valid);
    check("https defaults to port 443", badUrl.port == "443");
    auto bad = performRequest("GET", badUrl, {}, "", 8000);
    const bool unreachable =
        !bad.ok && bad.error.find("certificate") == std::string::npos &&
        (bad.error.find("resolve") != std::string::npos ||
         bad.error.find("timed out") != std::string::npos ||
         bad.error.find("Connection") != std::string::npos);
    if (unreachable) {
      std::printf("  SKIP (no network): bad-cert arm — %s\n", bad.error.c_str());
    } else {
      check("a bad certificate is REJECTED, not accepted", !bad.ok);
      check("the bad-cert error names the certificate, not the network",
            bad.error.find("certificate") != std::string::npos ||
                bad.error.find("TLS handshake") != std::string::npos);
    }

    // SECOND NEGATIVE CONTROL, and it is NOT redundant with the first.
    // self-signed.badssl.com fails on CHAIN trust, so verify_peer alone
    // rejects it -- deleting the hostname check leaves that arm passing.
    // Measured: mutation testing removed host_name_verification() and the
    // suite stayed green. wrong.host.badssl.com serves a PUBLICLY TRUSTED
    // certificate issued for a DIFFERENT name, so the chain verifies and only
    // the hostname check can reject it. This arm is the one that dies when
    // that callback goes missing.
    auto wrongUrl = parseUrl("https://wrong.host.badssl.com/");
    auto wrong = performRequest("GET", wrongUrl, {}, "", 8000);
    const bool wrongUnreachable =
        !wrong.ok && wrong.error.find("certificate") == std::string::npos &&
        wrong.error.find("handshake") == std::string::npos &&
        (wrong.error.find("resolve") != std::string::npos ||
         wrong.error.find("timed out") != std::string::npos ||
         wrong.error.find("Connection") != std::string::npos);
    if (wrongUnreachable) {
      std::printf("  SKIP (no network): wrong-host arm — %s\n",
                  wrong.error.c_str());
    } else {
      check("a cert for the WRONG HOSTNAME is rejected", !wrong.ok);
    }
#else
    auto url = parseUrl("https://example.com/");
    auto res = performRequest("GET", url, {}, "", 5000);
    check("https is refused rather than attempted", !res.ok);
    check("https error names the TLS limitation",
          res.error.find("TLS") != std::string::npos);
#endif
  }

  // -- a closed port must fail fast, not hang --
  {
    unsigned short port = 0;
    Seen seen;
    auto server = serveOnce(port, seen, "x");
    // Take the port, then close the acceptor by letting the thread finish
    // against our own connect, so the NEXT connect on that port is refused.
    {
      auto url = parseUrl("http://127.0.0.1:" + std::to_string(port) + "/");
      performRequest("GET", url, {}, "", 2000);
    }
    server.join();
    auto url = parseUrl("http://127.0.0.1:" + std::to_string(port) + "/");
    auto res = performRequest("GET", url, {}, "", 2000);
    check("connection to a closed port reports an error", !res.ok);
    check("closed-port error is non-empty", !res.error.empty());
  }

  // -- CHUNKED framing, which the SERVER chooses and we do not control -----
  // The self-test server above sets Content-Length, so it can never produce
  // this — and that gap is precisely how a chunk-size line reached JS as the
  // response body. Node sends chunked by DEFAULT for any response written
  // without an explicit length, so this is the common case in the real gate,
  // not an exotic one. Raw sockets here rather than the helper, because the
  // helper cannot emit the framing under test.
  {
    auto io = std::make_shared<asio::io_context>();
    auto acceptor = std::make_shared<tcp::acceptor>(
        *io, tcp::endpoint(asio::ip::make_address("127.0.0.1"), 0));
    unsigned short port = acceptor->local_endpoint().port();
    std::thread server([io, acceptor]() {
      try {
        tcp::socket sock(*io);
        acceptor->accept(sock);
        asio::streambuf buf;
        boost::system::error_code ec;
        asio::read_until(sock, buf, "\r\n\r\n", ec);
        // 5 + 7 + 0: a multi-chunk body, so a decoder that returns only the
        // first chunk fails here rather than passing by luck.
        std::string resp =
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: text/plain\r\n"
            "Transfer-Encoding: chunked\r\n"
            "Connection: close\r\n\r\n"
            "5\r\nhello\r\n"
            "7\r\n, world\r\n"
            "0\r\n\r\n";
        asio::write(sock, asio::buffer(resp), ec);
        sock.shutdown(tcp::socket::shutdown_both, ec);
      } catch (const std::exception&) {}
    });

    auto url = parseUrl("http://127.0.0.1:" + std::to_string(port) + "/chunked");
    auto res = performRequest("GET", url, {}, "", 5000);
    server.join();

    check("chunked response completes", res.ok);
    check("chunked body is DE-CHUNKED, not the raw stream",
          res.body == "hello, world");
    if (res.body != "hello, world") {
      std::printf("      got '%s' want 'hello, world'\n", res.body.c_str());
    }
    // The specific corruption that reached JS: the chunk-size line surfacing
    // as the body.
    check("chunk-size line does not leak into the body",
          res.body.find("\r\n") == std::string::npos);
  }

  // -- a BLACKHOLED address must time out, not hang forever ----------------
  // Distinct from the closed port above, and this is the case that actually
  // hangs: a refused connection returns instantly, while an address that
  // silently drops packets returns nothing at all. `fetch()` sends timeout: 0
  // ("no timeout"), so an unbounded connect here is an app hang rather than a
  // failed request. 192.0.2.0/24 is TEST-NET-1 (RFC 5737) and is guaranteed
  // not to be routed to a real host.
  {
    auto url = parseUrl("http://192.0.2.1:81/blackhole");
    auto start = std::chrono::steady_clock::now();
    auto res = performRequest("GET", url, {}, "", 1200);
    auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                         std::chrono::steady_clock::now() - start)
                         .count();
    check("blackholed address fails rather than succeeding", !res.ok);
    // The bound is what is being tested. Without it this returns only when the
    // OS gives up (~2 minutes) or never.
    check("blackholed connect respects the timeout budget", elapsedMs < 5000);
    if (elapsedMs >= 5000) {
      std::printf("      took %lldms\n", static_cast<long long>(elapsedMs));
    }
  }

  // -- base64 encoding, including the tails base64-js rejects --------------
  // fetch() on this engine ALWAYS asks for base64 (no BlobModule -> XHR
  // requests 'arraybuffer' -> native 'base64'), so a wrong encoder breaks
  // every real request while the raw-text path above stays green. Vectors are
  // RFC 4648's, and each length class exercises a different padding tail.
  {
    struct B64 { const char* in; const char* want; };
    const B64 vectors[] = {
        {"", ""},
        {"f", "Zg=="},
        {"fo", "Zm8="},
        {"foo", "Zm9v"},
        {"foob", "Zm9vYg=="},
        {"fooba", "Zm9vYmE="},
        {"foobar", "Zm9vYmFy"},
        {"impeller-get-9f3a2c", "aW1wZWxsZXItZ2V0LTlmM2EyYw=="},
    };
    for (const auto& v : vectors) {
      std::string got = base64Encode(v.in);
      check((std::string("base64('") + v.in + "')").c_str(), got == v.want);
      if (got != v.want) {
        std::printf("      got '%s' want '%s'\n", got.c_str(), v.want);
      }
    }
    // The property base64-js actually enforces, checked over every length so a
    // future edit to the tail cannot reintroduce "Length must be a multiple
    // of 4" — the error that broke the first P10 run.
    bool allPadded = true;
    std::string s;
    for (int i = 0; i < 40; ++i) {
      if (base64Encode(s).size() % 4 != 0) allPadded = false;
      s += static_cast<char>('a' + (i % 26));
    }
    check("every base64 output length is a multiple of 4", allPadded);
  }

  std::printf("http-selftest: %s (%d failure%s)\n", failures ? "FAIL" : "PASS",
              failures, failures == 1 ? "" : "s");
  return failures ? 1 : 0;
}

}  // namespace rni
