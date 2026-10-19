// The slice of sd-bus (libsystemd) the Linux notification backend uses,
// resolved with dlopen at first use.
//
// WHY DLOPEN AND NOT A LINK DEPENDENCY
// Linking -lsystemd would add a DT_NEEDED entry to the shipped engine, so a
// distro without libsystemd.so.0 (or a container without it) could not start
// the engine at all, for a feature most apps never call. Loaded at runtime, a
// missing library is one "unavailable" answer from Notifications and nothing
// else. It also means the build needs no libsystemd-dev headers: the
// declarations below are the stable public ABI from sd-bus.h (systemd >= 237
// for sd_bus_match_signal).
#pragma once

#include <dlfcn.h>

#include <cstdint>
#include <string>
#include <type_traits>

namespace rni::notifications::sdbus {

struct sd_bus;
struct sd_bus_message;
struct sd_bus_slot;
struct sd_bus_error {
  const char* name;
  const char* message;
  int need_free;
};
using sd_bus_message_handler_t = int (*)(sd_bus_message*, void*, sd_bus_error*);

struct Api {
  int (*open_user)(sd_bus**) = nullptr;
  sd_bus* (*flush_close_unref)(sd_bus*) = nullptr;
  int (*call_method)(sd_bus*, const char*, const char*, const char*,
                     const char*, sd_bus_error*, sd_bus_message**,
                     const char*, ...) = nullptr;
  int (*message_read)(sd_bus_message*, const char*, ...) = nullptr;
  sd_bus_message* (*message_unref)(sd_bus_message*) = nullptr;
  void (*error_free)(sd_bus_error*) = nullptr;
  int (*match_signal)(sd_bus*, sd_bus_slot**, const char*, const char*,
                      const char*, const char*, sd_bus_message_handler_t,
                      void*) = nullptr;
  int (*process)(sd_bus*, sd_bus_message**) = nullptr;
  int (*get_fd)(sd_bus*) = nullptr;
  int (*get_events)(sd_bus*) = nullptr;
  int (*get_timeout)(sd_bus*, uint64_t*) = nullptr;
  // Optional (systemd >= 240). Without it calls use sd-bus's 25 s default.
  int (*set_method_call_timeout)(sd_bus*, uint64_t) = nullptr;

  bool ok = false;
  std::string error;  // why ok is false
};

// Loads once; later calls return the same table. Never unloaded: sd-bus
// objects may outlive any single caller.
inline const Api& Load() {
  static const Api api = [] {
    Api a;
    void* lib = dlopen("libsystemd.so.0", RTLD_NOW | RTLD_LOCAL);
    if (lib == nullptr) {
      const char* why = dlerror();
      a.error = std::string("libsystemd.so.0 could not be loaded (") +
                (why ? why : "unknown error") + ")";
      return a;
    }
    bool missing = false;
    auto sym = [&](auto& fn, const char* name, bool required) {
      fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(dlsym(lib, name));
      if (fn == nullptr && required) {
        missing = true;
        if (a.error.empty()) a.error = std::string("libsystemd lacks ") + name;
      }
    };
    sym(a.open_user, "sd_bus_open_user", true);
    sym(a.flush_close_unref, "sd_bus_flush_close_unref", true);
    sym(a.call_method, "sd_bus_call_method", true);
    sym(a.message_read, "sd_bus_message_read", true);
    sym(a.message_unref, "sd_bus_message_unref", true);
    sym(a.error_free, "sd_bus_error_free", true);
    sym(a.match_signal, "sd_bus_match_signal", true);
    sym(a.process, "sd_bus_process", true);
    sym(a.get_fd, "sd_bus_get_fd", true);
    sym(a.get_events, "sd_bus_get_events", true);
    sym(a.get_timeout, "sd_bus_get_timeout", true);
    sym(a.set_method_call_timeout, "sd_bus_set_method_call_timeout", false);
    a.ok = !missing;
    return a;
  }();
  return api;
}

}  // namespace rni::notifications::sdbus
