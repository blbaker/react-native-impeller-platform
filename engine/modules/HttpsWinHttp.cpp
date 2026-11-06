// ENG-51: https on Windows through WinHTTP.
//
// The Windows engine links no OpenSSL (engine/cmake/ReactCommonDeps.cmake), so
// the asio::ssl path in NetworkingModule.cpp does not exist there and every
// https fetch used to fail. WinHTTP ships with Windows: Schannel does the TLS,
// and the chain and the host name are checked against the Windows certificate
// store, the same trust decision curl.exe and the browsers make on that PC.
// Plain http stays on the asio path.
//
// Kept to what the asio path does, so the two platforms answer alike: direct
// connection (no proxy), no redirect following, no cookie jar, TLS 1.2 or
// newer, an identity body, at most 10 s to connect when the caller set no
// timeout.
#include "modules/HttpsWinHttp.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
// folly/portability/Windows.h (reached through NetworkingModule.h) #undefs the
// IN/OUT parameter markers that winhttp.h still uses in its declarations.
#ifndef IN
#define IN
#endif
#ifndef OUT
#define OUT
#endif
#include <winhttp.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <memory>

// Defined by newer Windows SDKs only. The value is the documented flag.
#ifndef WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3
#define WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3 0x00002000
#endif

namespace rni {

namespace {

// Same cap as the asio connect when fetch passes timeout 0 ("none").
constexpr int kConnectCapMs = 10000;

struct HandleCloser {
  void operator()(void* h) const {
    if (h != nullptr) WinHttpCloseHandle(h);
  }
};
using Handle = std::unique_ptr<void, HandleCloser>;

std::wstring Widen(const std::string& s) {
  if (s.empty()) return {};
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring out((size_t)n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n);
  return out;
}

std::string Narrow(const std::wstring& s) {
  if (s.empty()) return {};
  const int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0,
                                    nullptr, nullptr);
  std::string out((size_t)n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n, nullptr, nullptr);
  return out;
}

std::string Lower(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return s;
}

std::string Trim(const std::string& s) {
  const size_t b = s.find_first_not_of(" \t\r\n");
  if (b == std::string::npos) return "";
  return s.substr(b, s.find_last_not_of(" \t\r\n") - b + 1);
}

std::string Describe(DWORD code) {
  wchar_t* buf = nullptr;
  const DWORD n = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_HMODULE |
          FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
      GetModuleHandleW(L"winhttp.dll"), code, 0, reinterpret_cast<LPWSTR>(&buf), 0, nullptr);
  std::string text = n > 0 && buf != nullptr ? Trim(Narrow(std::wstring(buf, n))) : "";
  if (buf != nullptr) LocalFree(buf);
  return (text.empty() ? "error" : text) + " (WinHTTP " + std::to_string(code) + ")";
}

// The reasons Schannel gave for refusing the server's certificate, from the
// WINHTTP_CALLBACK_STATUS_SECURE_FAILURE flags. Empty when the failure was
// not about the certificate.
std::string CertificateReasons(DWORD flags) {
  struct Reason {
    DWORD flag;
    const char* text;
  };
  const Reason reasons[] = {
      {WINHTTP_CALLBACK_STATUS_FLAG_INVALID_CA, "issuer not trusted"},
      {WINHTTP_CALLBACK_STATUS_FLAG_CERT_CN_INVALID, "host name mismatch"},
      {WINHTTP_CALLBACK_STATUS_FLAG_CERT_DATE_INVALID, "expired or not yet valid"},
      {WINHTTP_CALLBACK_STATUS_FLAG_CERT_REVOKED, "revoked"},
      {WINHTTP_CALLBACK_STATUS_FLAG_CERT_REV_FAILED, "revocation check failed"},
      {WINHTTP_CALLBACK_STATUS_FLAG_INVALID_CERT, "invalid certificate"},
  };
  std::string out;
  for (const Reason& r : reasons) {
    if ((flags & r.flag) == 0) continue;
    if (!out.empty()) out += ", ";
    out += r.text;
  }
  return out;
}

void CALLBACK OnSecureFailure(HINTERNET, DWORD_PTR context, DWORD status, LPVOID info,
                              DWORD infoLength) {
  if (status != WINHTTP_CALLBACK_STATUS_SECURE_FAILURE || context == 0 || info == nullptr ||
      infoLength < sizeof(DWORD)) {
    return;
  }
  *reinterpret_cast<DWORD*>(context) = *static_cast<const DWORD*>(info);
}

// Error text in the words the asio path uses, so callers (and the self-test's
// "no network" skip) read both platforms the same way.
std::string FailureText(const ParsedUrl& url, const char* step, DWORD code, DWORD secureFlags) {
  const std::string where = url.host + ":" + url.port;
  const std::string reasons = CertificateReasons(secureFlags);
  if (!reasons.empty()) {
    return "TLS handshake with " + url.host + " failed (certificate rejected: " + reasons + ")";
  }
  switch (code) {
    case ERROR_WINHTTP_SECURE_FAILURE:
    case ERROR_WINHTTP_SECURE_CHANNEL_ERROR:
      return "TLS handshake with " + url.host + " failed: " + Describe(code);
    case ERROR_WINHTTP_NAME_NOT_RESOLVED:
      return "Could not resolve " + url.host + ": " + Describe(code);
    case ERROR_WINHTTP_CANNOT_CONNECT:
      return "Connection to " + where + " failed: " + Describe(code);
    case ERROR_WINHTTP_TIMEOUT:
      return "Request to " + where + " timed out (" + step + "): " + Describe(code);
    default:
      return std::string("Request failed (") + step + "): " + Describe(code);
  }
}

std::wstring QueryHeader(HINTERNET request, DWORD info) {
  DWORD bytes = 0;
  WinHttpQueryHeaders(request, info, WINHTTP_HEADER_NAME_BY_INDEX, WINHTTP_NO_OUTPUT_BUFFER,
                      &bytes, WINHTTP_NO_HEADER_INDEX);
  if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || bytes == 0) return {};
  std::wstring out(bytes / sizeof(wchar_t), L'\0');
  if (!WinHttpQueryHeaders(request, info, WINHTTP_HEADER_NAME_BY_INDEX, out.data(), &bytes,
                           WINHTTP_NO_HEADER_INDEX)) {
    return {};
  }
  out.resize(bytes / sizeof(wchar_t));
  return out;
}

// The header block WinHTTP sends on top of its own. Host, Connection and
// Content-Length are WinHTTP's to write (a second copy is a malformed
// request); User-Agent goes to WinHttpOpen instead.
std::wstring RequestHeaders(const std::map<std::string, std::string>& headers,
                            std::string* userAgent) {
  std::string block;
  bool sawAccept = false;
  for (const auto& [k, v] : headers) {
    const std::string lk = Lower(k);
    if (lk == "host" || lk == "connection" || lk == "content-length") continue;
    // This module has no decoder, so the body must arrive as sent.
    if (lk == "accept-encoding") continue;
    if (lk == "user-agent") {
      *userAgent = v;
      continue;
    }
    if (lk == "accept") sawAccept = true;
    block += k + ": " + v + "\r\n";
  }
  if (!sawAccept) block += "Accept: */*\r\n";
  block += "Accept-Encoding: identity\r\n";
  return Widen(block);
}

}  // namespace

HttpResponse performHttpsWinHttp(const std::string& method, const ParsedUrl& url,
                                 const std::map<std::string, std::string>& headers,
                                 const std::string& body, double timeoutMs) {
  HttpResponse res;
  char* portEnd = nullptr;
  const long port = std::strtol(url.port.c_str(), &portEnd, 10);
  if (url.port.empty() || *portEnd != '\0' || port <= 0 || port > 65535) {
    res.error = "Invalid port '" + url.port + "' in https URL";
    return res;
  }

  std::string userAgent = "react-native-impeller";
  const std::wstring extraHeaders = RequestHeaders(headers, &userAgent);

  Handle session(WinHttpOpen(Widen(userAgent).c_str(), WINHTTP_ACCESS_TYPE_NO_PROXY,
                             WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0));
  if (!session) {
    res.error = FailureText(url, "open", GetLastError(), 0);
    return res;
  }
  // TLS 1.2 and 1.3, like the asio path's no_tlsv1/no_tlsv1_1. Windows 10
  // builds without TLS 1.3 in WinHTTP refuse the combined set; take 1.2 there.
  DWORD protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3;
  if (!WinHttpSetOption(session.get(), WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols,
                        sizeof(protocols))) {
    protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2;
    if (!WinHttpSetOption(session.get(), WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols,
                          sizeof(protocols))) {
      res.error = FailureText(url, "tls protocols", GetLastError(), 0);
      return res;
    }
  }
  // 0 = no limit, which is what fetch's timeout 0 means for the reads.
  const int budget = timeoutMs > 0 ? (int)timeoutMs : 0;
  const int connectBudget = timeoutMs > 0 ? (int)timeoutMs : kConnectCapMs;
  WinHttpSetTimeouts(session.get(), budget, connectBudget, budget, budget);

  Handle connection(WinHttpConnect(session.get(), Widen(url.host).c_str(), (INTERNET_PORT)port, 0));
  if (!connection) {
    res.error = FailureText(url, "connect", GetLastError(), 0);
    return res;
  }
  // The target goes out as the caller wrote it, as on the asio path.
  Handle request(WinHttpOpenRequest(connection.get(), Widen(method).c_str(),
                                    Widen(url.target).c_str(), nullptr, WINHTTP_NO_REFERER,
                                    WINHTTP_DEFAULT_ACCEPT_TYPES,
                                    WINHTTP_FLAG_SECURE | WINHTTP_FLAG_ESCAPE_DISABLE |
                                        WINHTTP_FLAG_ESCAPE_DISABLE_QUERY));
  if (!request) {
    res.error = FailureText(url, "open request", GetLastError(), 0);
    return res;
  }
  DWORD features = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES;
  WinHttpSetOption(request.get(), WINHTTP_OPTION_DISABLE_FEATURE, &features, sizeof(features));

  DWORD secureFlags = 0;
  WinHttpSetStatusCallback(request.get(), &OnSecureFailure, WINHTTP_CALLBACK_FLAG_SECURE_FAILURE,
                           0);
  const DWORD bodyLen = (DWORD)body.size();
  if (!WinHttpSendRequest(request.get(), extraHeaders.c_str(), (DWORD)-1L,
                          bodyLen > 0 ? const_cast<char*>(body.data()) : WINHTTP_NO_REQUEST_DATA,
                          bodyLen, bodyLen, reinterpret_cast<DWORD_PTR>(&secureFlags))) {
    res.error = FailureText(url, "send", GetLastError(), secureFlags);
    return res;
  }
  if (!WinHttpReceiveResponse(request.get(), nullptr)) {
    res.error = FailureText(url, "receive", GetLastError(), secureFlags);
    return res;
  }

  DWORD status = 0;
  DWORD statusLen = sizeof(status);
  if (!WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                           WINHTTP_HEADER_NAME_BY_INDEX, &status, &statusLen,
                           WINHTTP_NO_HEADER_INDEX)) {
    res.error = "Malformed HTTP response from " + url.host;
    return res;
  }
  res.status = (int)status;
  res.statusText = Trim(Narrow(QueryHeader(request.get(), WINHTTP_QUERY_STATUS_TEXT)));

  // Raw block: the status line, then one "Name: value" per line.
  const std::string raw = Narrow(QueryHeader(request.get(), WINHTTP_QUERY_RAW_HEADERS_CRLF));
  size_t at = raw.find("\r\n");
  while (at != std::string::npos && at + 2 < raw.size()) {
    const size_t next = raw.find("\r\n", at + 2);
    const std::string line = raw.substr(at + 2, next == std::string::npos ? std::string::npos
                                                                          : next - at - 2);
    const size_t colon = line.find(':');
    if (colon != std::string::npos) {
      res.headers[Trim(line.substr(0, colon))] = Trim(line.substr(colon + 1));
    }
    at = next;
  }

  // WinHTTP removes chunked framing itself; the body here is the payload.
  for (;;) {
    DWORD available = 0;
    if (!WinHttpQueryDataAvailable(request.get(), &available)) {
      res.error = "Read failed: " + Describe(GetLastError());
      return res;
    }
    if (available == 0) break;
    const size_t start = res.body.size();
    res.body.resize(start + available);
    DWORD got = 0;
    if (!WinHttpReadData(request.get(), res.body.data() + start, available, &got)) {
      res.error = "Read failed: " + Describe(GetLastError());
      return res;
    }
    res.body.resize(start + got);
    if (got == 0) break;
  }
  res.ok = true;
  return res;
}

}  // namespace rni
