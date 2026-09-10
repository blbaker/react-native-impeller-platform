// ENG-04 shape B — ONE narrow native file primitive, not a Storage API.
//
// ⛔ WHAT THIS DELIBERATELY IS NOT.
//
// The ledger row asked for a Storage TurboModule with getItem/setItem/
// removeItem. This is not that, on purpose, and the reasoning is recorded here
// because the next person to want persistence will land on this file.
//
// Storage has nothing to do with Impeller. Impeller is the renderer. The row
// was in the ENGINE ledger for a structural reason instead: JS on this platform
// cannot reach a syscall, and the engine binary is currently the only place
// native code can live (ModuleRegistry.h: a consumer-authored native module is
// "v2 DX"). That justification generalises to SQLite, keychain, file picker,
// clipboard, camera, biometrics -- each arriving as "the engine is the only
// place this can live", each wanting its own hand-written API surface, until
// the renderer is the dumping ground for anything needing a syscall.
//
// So the engine vends a PRIMITIVE and JS composes the API on top:
//
//     native  AppStorage.readFile / writeFile / deleteFile / listFiles
//     JS      the AsyncStorage-shaped getItem/setItem/removeItem shim
//
// Same division as Alert.impeller.js, which is the established pattern in this
// repo for exactly this class of problem. The engine owns the capability; the
// shape of the API stays in JS where it can change without a native release.
// A future need for structured data or encryption is then a JS change, not
// another ENG row against a key-value surface frozen in C++.
//
// ⛔ THE PATH CONFINEMENT IS THE WHOLE SECURITY MODEL, AND IT IS ENFORCED ON
// THE RESOLVED PATH, NOT THE INPUT STRING.
//
// A native file primitive reachable from JS is an arbitrary-file-write
// primitive unless something stops it. Rejecting ".." in the input is NOT
// something: symlinks, absolute paths, percent-encoding and "a/../../b" all
// defeat a substring check, and the check LOOKS like it works because the
// obvious hostile input is blocked. So every path is joined to the container,
// lexically normalised, and then re-checked for containment AFTER
// normalisation. A key that escapes is rejected with no file touched.
//
// Keys are further restricted to a conservative character set. That is not
// belt-and-braces for the containment check -- it is what makes the container
// listable and the on-disk layout predictable, since every key is exactly one
// flat file with no nesting.
#pragma once

#include <ReactCommon/TurboModule.h>

#include <filesystem>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace rni {

namespace jsi = facebook::jsi;
namespace react = facebook::react;

// Where the container lives. Resolved ONCE by the host and handed in, rather
// than read from the environment inside the module: the module must not be able
// to relocate its own sandbox, and a test must be able to point it somewhere
// disposable without setting process-wide state.
struct AppStorageConfig {
  std::filesystem::path container;
};

class AppStorageModule : public react::TurboModule {
 public:
  AppStorageModule(std::shared_ptr<react::CallInvoker> jsInvoker,
                   std::shared_ptr<AppStorageConfig> config)
      : react::TurboModule("AppStorage", std::move(jsInvoker)),
        config_(std::move(config)) {
    methodMap_["readFile"] = MethodMetadata{1, readFileHost};
    methodMap_["writeFile"] = MethodMetadata{2, writeFileHost};
    methodMap_["deleteFile"] = MethodMetadata{1, deleteFileHost};
    methodMap_["listFiles"] = MethodMetadata{0, listFilesHost};
  }

  // ⚠️ SYNCHRONOUS, AND THAT IS A DECISION RATHER THAN A SHORTCUT.
  //
  // The JS shim above this presents an async (Promise-returning) API because
  // that is what every RN storage consumer expects, and async is the shape you
  // cannot retrofit later without breaking callers. But the NATIVE half is
  // synchronous: these are small flat files under a local container, the calls
  // are made from the JS thread, and a thread pool here would add a queue, a
  // completion hop and a lifetime problem to save microseconds. If a caller
  // ever needs to move megabytes, that is a new primitive with its own row --
  // not a reason to make this one async up front.
  //
  // Resolve a key to a real path inside the container, or return false. The
  // OUT parameter is only written on success, so a rejected key cannot leave a
  // half-resolved path behind for a caller that forgot to check.
  bool resolve(const std::string& key, std::filesystem::path& out) const {
    // ⛔ THE CAP IS 251, NOT 255, AND THE FOUR BYTES ARE NOT PADDING.
    //
    // writeFile is atomic via a "<key>.tmp" sibling, so the longest filename
    // this module ever creates is the key plus four characters. A 255-cap here
    // accepts a key whose TEMP file is 259 bytes, which exceeds the 255-byte
    // limit on ext4/APFS/NTFS: the ofstream fails, writeFile returns false,
    // and the caller sees a storage failure for a key the primitive told it
    // was acceptable. Found by the gate's must-accept arm, not by the
    // rejection arm -- a confinement gate that only checks that bad keys are
    // refused passes perfectly on a primitive that refuses everything.
    static constexpr size_t kTmpSuffix = 4;  // ".tmp"
    static constexpr size_t kMaxFilename = 255;
    if (key.empty() || key.size() > kMaxFilename - kTmpSuffix) return false;
    // Conservative allowlist. Anything outside it is rejected rather than
    // sanitised: silently rewriting a key means two different keys can collide
    // on one file, and the caller is never told.
    for (unsigned char c : key) {
      const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                      (c >= '0' && c <= '9') || c == '.' || c == '-' ||
                      c == '_';
      if (!ok) return false;
    }
    // "." and ".." are each individually made of allowed characters, so the
    // allowlist above does not catch them. Named explicitly.
    if (key == "." || key == "..") return false;

    std::error_code ec;
    const auto base = config_->container.lexically_normal();
    const auto candidate = (base / key).lexically_normal();

    // Containment re-checked AFTER normalisation. This is the check that
    // actually holds; the allowlist is hygiene.
    const auto baseStr = base.generic_string();
    const auto candStr = candidate.generic_string();
    if (candStr.size() <= baseStr.size()) return false;
    if (candStr.compare(0, baseStr.size(), baseStr) != 0) return false;
    // Guard against a sibling directory whose name merely starts with the
    // container's name (/data/app vs /data/appEVIL): require a separator at
    // the boundary rather than a bare prefix match.
    if (candStr[baseStr.size()] != '/') return false;
    // One flat file per key: no nesting, so the container stays listable.
    if (candidate.parent_path().lexically_normal() != base) return false;

    (void)ec;
    out = candidate;
    return true;
  }

 private:
  static AppStorageModule& self(react::TurboModule& tm) {
    return static_cast<AppStorageModule&>(tm);
  }

  // Missing file reads as NULL, not as an empty string. Those are different
  // facts -- "no value stored" versus "a stored empty value" -- and collapsing
  // them makes a removed key indistinguishable from one set to "". The JS shim
  // depends on this to implement removeItem-then-getItem correctly.
  static jsi::Value readFileHost(jsi::Runtime& rt, react::TurboModule& tm,
                                 const jsi::Value* args, size_t count) {
    if (count < 1 || !args[0].isString()) return jsi::Value::null();
    auto& me = self(tm);
    std::filesystem::path p;
    if (!me.resolve(args[0].asString(rt).utf8(rt), p)) return jsi::Value::null();
    std::ifstream in(p, std::ios::binary);
    if (!in) return jsi::Value::null();
    std::ostringstream buf;
    buf << in.rdbuf();
    return jsi::Value(jsi::String::createFromUtf8(rt, buf.str()));
  }

  // Returns a bool rather than throwing. A rejected key and a full disk are
  // both "the write did not happen", and the shim surfaces that as a rejected
  // Promise; a C++ throw across the JSI boundary here would be a crash in a
  // storage call, which is a worse failure than a false.
  static jsi::Value writeFileHost(jsi::Runtime& rt, react::TurboModule& tm,
                                  const jsi::Value* args, size_t count) {
    if (count < 2 || !args[0].isString() || !args[1].isString()) {
      return jsi::Value(false);
    }
    auto& me = self(tm);
    std::filesystem::path p;
    if (!me.resolve(args[0].asString(rt).utf8(rt), p)) return jsi::Value(false);

    std::error_code ec;
    std::filesystem::create_directories(me.config_->container, ec);

    // ⛔ WRITE TO A TEMP AND RENAME. A truncating write that is interrupted
    // (crash, power loss, full disk mid-write) leaves a file that EXISTS and is
    // CORRUPT, which every reader then treats as a real stored value. Rename
    // within the same directory is atomic on POSIX and on NTFS, so a reader
    // sees either the whole old value or the whole new one.
    const auto tmp = std::filesystem::path(p.string() + ".tmp");
    {
      std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
      if (!out) return jsi::Value(false);
      const auto body = args[1].asString(rt).utf8(rt);
      out.write(body.data(), (std::streamsize)body.size());
      out.flush();
      if (!out) {
        out.close();
        std::filesystem::remove(tmp, ec);
        return jsi::Value(false);
      }
    }
    std::filesystem::rename(tmp, p, ec);
    if (ec) {
      std::filesystem::remove(tmp, ec);
      return jsi::Value(false);
    }
    return jsi::Value(true);
  }

  // Deleting an absent key is SUCCESS, not failure: removeItem is idempotent in
  // every storage API JS will put on top of this, and reporting false would
  // make a shim retry or surface an error for a state the caller asked for.
  static jsi::Value deleteFileHost(jsi::Runtime& rt, react::TurboModule& tm,
                                   const jsi::Value* args, size_t count) {
    if (count < 1 || !args[0].isString()) return jsi::Value(false);
    auto& me = self(tm);
    std::filesystem::path p;
    if (!me.resolve(args[0].asString(rt).utf8(rt), p)) return jsi::Value(false);
    std::error_code ec;
    std::filesystem::remove(p, ec);
    return jsi::Value(!ec);
  }

  // Enumeration is what makes a real storage API implementable in JS --
  // getAllKeys, multiGet, clear all need it, and without it the shim would have
  // to keep its own index file that can drift from the directory.
  static jsi::Value listFilesHost(jsi::Runtime& rt, react::TurboModule& tm,
                                  const jsi::Value* args, size_t count) {
    (void)args;
    (void)count;
    auto& me = self(tm);
    std::vector<std::string> names;
    std::error_code ec;
    for (const auto& entry :
         std::filesystem::directory_iterator(me.config_->container, ec)) {
      if (ec) break;
      if (!entry.is_regular_file(ec)) continue;
      auto name = entry.path().filename().string();
      // Hide the atomic-write temporaries: a crash can leave one behind, and a
      // shim enumerating keys must not report ".tmp" leftovers as real keys.
      if (name.size() > 4 && name.compare(name.size() - 4, 4, ".tmp") == 0) {
        continue;
      }
      names.push_back(std::move(name));
    }
    auto out = jsi::Array(rt, names.size());
    for (size_t i = 0; i < names.size(); ++i) {
      out.setValueAtIndex(rt, i, jsi::String::createFromUtf8(rt, names[i]));
    }
    return jsi::Value(rt, out);
  }

  std::shared_ptr<AppStorageConfig> config_;
};

}  // namespace rni
