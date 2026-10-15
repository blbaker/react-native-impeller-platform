#include "modules/ImageLoaderModule.h"

#include <ReactCommon/TurboModuleUtils.h>

#include <map>

#include "fabric/ImageStore.h"

namespace rni {

namespace react = facebook::react;

void InstallImageFetcher(std::shared_ptr<NetworkActivity> activity) {
  image::SetFetcher(
      [](const std::string& uri, const image::Headers& headers) {
        image::FetchResult out;
        ParsedUrl url = parseUrl(uri);
        if (!url.valid) {
          out.error = url.error;
          return out;
        }
        std::map<std::string, std::string> h(headers.begin(), headers.end());
        HttpResponse res = performRequest("GET", url, h, "", 15000);
        out.status = res.status;
        out.headers.assign(res.headers.begin(), res.headers.end());
        if (!res.ok) {
          out.error = res.error;
        } else if (res.status < 200 || res.status > 299) {
          out.error = "HTTP " + std::to_string(res.status) + " for " + uri;
        } else {
          out.ok = true;
          out.body = std::move(res.body);
        }
        return out;
      },
      [activity] { activity->inFlight.fetch_add(1); },
      [activity] {
        activity->completed.fetch_add(1);
        activity->inFlight.fetch_sub(1);
      });
}

jsi::Value ImageLoaderModule::load(jsi::Runtime& rt, std::string uri,
                                   std::vector<std::pair<std::string, std::string>> headers,
                                   Shape shape) {
  auto jsInvoker = jsInvoker_;
  return react::createPromiseAsJSIValue(
      rt, [jsInvoker, uri = std::move(uri), headers = std::move(headers), shape](
              jsi::Runtime&, std::shared_ptr<react::Promise> promise) {
        // The worker MOVES the promise into the JS-thread hop, so its last
        // reference (jsi::Function members) is dropped on the JS thread.
        auto holder = std::make_shared<std::shared_ptr<react::Promise>>(std::move(promise));
        image::LoadAsync(uri, headers, [jsInvoker, holder, shape](const image::LoadResult& r) {
          auto p = std::move(*holder);
          if (!p) return;
          const int w = r.image ? r.image->srcWidth : 0, h = r.image ? r.image->srcHeight : 0;
          const std::string error = r.error;
          jsInvoker->invokeAsync([p = std::move(p), w, h, error, shape,
                                  ok = (bool)r.image](jsi::Runtime& rt2) {
            if (!ok) {
              p->reject(error);
              return;
            }
            if (shape == Shape::Bool) {
              p->resolve(jsi::Value(true));
            } else if (shape == Shape::Pair) {
              jsi::Array a(rt2, 2);
              a.setValueAtIndex(rt2, 0, jsi::Value((double)w));
              a.setValueAtIndex(rt2, 1, jsi::Value((double)h));
              p->resolve(std::move(a));
            } else {
              jsi::Object o(rt2);
              o.setProperty(rt2, "width", (double)w);
              o.setProperty(rt2, "height", (double)h);
              p->resolve(std::move(o));
            }
          });
        });
      });
}

jsi::Value ImageLoaderModule::getSize(jsi::Runtime& rt, jsi::String uri) {
  return load(rt, uri.utf8(rt), {}, Shape::Pair);
}

jsi::Value ImageLoaderModule::getSizeWithHeaders(jsi::Runtime& rt, jsi::String uri,
                                                 jsi::Object headers) {
  std::vector<std::pair<std::string, std::string>> h;
  jsi::Array names = headers.getPropertyNames(rt);
  for (size_t i = 0; i < names.size(rt); ++i) {
    jsi::String name = names.getValueAtIndex(rt, i).getString(rt);
    jsi::Value v = headers.getProperty(rt, name);
    if (v.isString()) h.emplace_back(name.utf8(rt), v.getString(rt).utf8(rt));
  }
  return load(rt, uri.utf8(rt), std::move(h), Shape::Object);
}

jsi::Value ImageLoaderModule::prefetchImage(jsi::Runtime& rt, jsi::String uri) {
  return load(rt, uri.utf8(rt), {}, Shape::Bool);
}

jsi::Value ImageLoaderModule::prefetchImageWithMetadata(jsi::Runtime& rt, jsi::String uri,
                                                        jsi::String, double) {
  return load(rt, uri.utf8(rt), {}, Shape::Bool);
}

jsi::Value ImageLoaderModule::queryCache(jsi::Runtime& rt, jsi::Array uris) {
  jsi::Object out(rt);
  for (size_t i = 0; i < uris.size(rt); ++i) {
    jsi::Value v = uris.getValueAtIndex(rt, i);
    if (!v.isString()) continue;
    const std::string uri = v.getString(rt).utf8(rt);
    if (image::IsCached(uri)) out.setProperty(rt, uri.c_str(), "memory");
  }
  return react::createPromiseAsJSIValue(
      rt, [out = std::make_shared<jsi::Object>(std::move(out))](
              jsi::Runtime& rt2, std::shared_ptr<react::Promise> promise) {
        promise->resolve(jsi::Value(rt2, *out));
      });
}

}  // namespace rni
