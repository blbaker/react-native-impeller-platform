// The JS half of ExpoFetchModule (ExpoFetch.cpp): the NativeRequest and
// NativeResponse SharedObjects expo/fetch drives (expo/src/winter/fetch/
// NativeRequest.ts is the contract). ES5 for the same reason as kExpoCoreJs:
// Hermes compiles it at runtime and app code subclasses NativeResponse
// (`class FetchResponse extends NativeResponse`).
//
// Response state lives in a WeakMap keyed by the instance, because
// FetchResponse.clone() makes objects with Object.create (no constructor).
#pragma once

namespace rni {

inline constexpr const char* kExpoFetchJs = R"JS(
(function (m, expo, host) {
  'use strict';
  var g = globalThis;
  var states = new WeakMap();
  var pending = new Map();
  var nextId = 1;
  var CHUNK = 65536;

  function stateOf(res) {
    var s = states.get(res);
    if (!s) {
      s = { status: 0, statusText: '', url: '', redirected: false, headers: [],
            body: null, used: false, cancelled: false, finalized: false };
      states.set(res, s);
    }
    return s;
  }
  function abortError() {
    var e = new Error('The operation was aborted.');
    e.name = 'AbortError';
    return e;
  }
  function finalize(res, s) {
    if (s.finalized) return;
    s.finalized = true;
    res.emit('readyForJSFinalization');
  }

  function NativeResponse() {
    expo.SharedObject.call(this);
    stateOf(this);
  }
  NativeResponse.prototype = Object.create(expo.SharedObject.prototype, {
    constructor: { value: NativeResponse, writable: true, configurable: true },
  });
  Object.setPrototypeOf(NativeResponse, expo.SharedObject);
  function getter(name, fn) {
    Object.defineProperty(NativeResponse.prototype, name, {
      get: function () { return fn(stateOf(this)); }, configurable: true,
    });
  }
  getter('bodyUsed', function (s) { return s.used; });
  getter('_rawHeaders', function (s) { return s.headers.slice(); });
  getter('status', function (s) { return s.status; });
  getter('statusText', function (s) { return s.statusText; });
  getter('url', function (s) { return s.url; });
  getter('redirected', function (s) { return s.redirected; });

  function takeBody(res, s) {
    if (s.cancelled) return Promise.reject(abortError());
    if (s.used) return Promise.reject(new TypeError('Response body is already used'));
    s.used = true;
    var body = s.body || new ArrayBuffer(0);
    s.body = null;
    finalize(res, s);
    return Promise.resolve(body);
  }
  NativeResponse.prototype.arrayBuffer = function () {
    return takeBody(this, stateOf(this));
  };
  NativeResponse.prototype.text = function () {
    return takeBody(this, stateOf(this)).then(function (b) { return host.utf8(b); });
  };
  // The whole body is already here: resolve null ("streaming started"), then
  // on a later task (as native events arrive) 64 KB didReceiveResponseData
  // chunks and didComplete.
  NativeResponse.prototype.startStreaming = function () {
    var self = this;
    var s = stateOf(this);
    if (s.cancelled) return Promise.reject(abortError());
    if (s.used) return Promise.reject(new TypeError('Response body is already used'));
    s.used = true;
    var bytes = new Uint8Array(s.body || new ArrayBuffer(0));
    s.body = null;
    setTimeout(function () {
      for (var off = 0; off < bytes.length && !s.cancelled; off += CHUNK) {
        self.emit('didReceiveResponseData', bytes.slice(off, Math.min(bytes.length, off + CHUNK)));
      }
      if (s.cancelled) self.emit('didFailWithError', 'The operation was aborted.');
      else self.emit('didComplete');
      finalize(self, s);
    }, 0);
    return Promise.resolve(null);
  };
  NativeResponse.prototype.cancelStreaming = function (reason) {
    stateOf(this).cancelled = true;
  };

  function NativeRequest(response) {
    expo.SharedObject.call(this);
    this.__response = response;
    this.__id = 0;
  }
  NativeRequest.prototype = Object.create(expo.SharedObject.prototype, {
    constructor: { value: NativeRequest, writable: true, configurable: true },
  });
  Object.setPrototypeOf(NativeRequest, expo.SharedObject);

  NativeRequest.prototype.start = function (url, init, body) {
    var self = this;
    init = init || {};
    return new Promise(function (resolve, reject) {
      var id = nextId++;
      self.__id = id;
      pending.set(id, { req: self, resolve: resolve, reject: reject });
      var buf = null;
      if (body != null) {
        var u8 = body instanceof Uint8Array ? body : new Uint8Array(body);
        buf = u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength);
      }
      try {
        host.start(id, String(url), init.method || 'GET', init.headers || [],
                   init.redirect || 'follow', buf);
      } catch (e) {
        pending.delete(id);
        reject(e);
      }
    });
  };
  NativeRequest.prototype.cancel = function () {
    var res = this.__response;
    if (res) stateOf(res).cancelled = true;
    var p = pending.get(this.__id);
    if (!p) return;
    pending.delete(this.__id);
    host.cancel(this.__id);
    p.reject(abortError());
    if (res) finalize(res, stateOf(res));
  };

  Object.defineProperty(g, '__rniExpoFetchDone', {
    value: function (id, ok, v) {
      var p = pending.get(id);
      if (!p) return;
      pending.delete(id);
      var res = p.req.__response;
      if (!ok) {
        p.reject(new Error(String(v)));
        if (res) finalize(res, stateOf(res));
        return;
      }
      var s = stateOf(res);
      s.status = v.status; s.statusText = v.statusText; s.url = v.url;
      s.redirected = v.redirected; s.headers = v.headers; s.body = v.body;
      p.resolve(res);
    },
  });

  m.NativeRequest = NativeRequest;
  m.NativeResponse = NativeResponse;
  m.unstable_createBlobData = function (data) {
    var u8 = data instanceof Uint8Array ? data : new Uint8Array(data);
    return Promise.resolve(host.createBlob(
        u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength)));
  };
})
)JS";

}  // namespace rni
