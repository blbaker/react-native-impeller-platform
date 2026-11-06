// ENG-51: https on Windows through WinHTTP. See HttpsWinHttp.cpp.
#pragma once

#include <map>
#include <string>

#include "modules/NetworkingModule.h"

namespace rni {

// One blocking https request. Schannel does the TLS, and the chain and the
// host name are verified against the Windows certificate store. Same contract
// as performRequest, which calls it for every https URL on Windows.
HttpResponse performHttpsWinHttp(const std::string& method, const ParsedUrl& url,
                                 const std::map<std::string, std::string>& headers,
                                 const std::string& body, double timeoutMs);

}  // namespace rni
