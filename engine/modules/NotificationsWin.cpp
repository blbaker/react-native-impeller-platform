// Windows notifications: WinRT toast notifications for an unpackaged desktop
// app, through the raw ABI headers in the Windows SDK and WRL (no C++/WinRT,
// no Windows App SDK, no extra DLL to ship).
//
// ⛔ AN UNPACKAGED APP NEEDS A REGISTERED AppUserModelID OR TOASTS VANISH.
// CreateToastNotifierWithId(id) followed by Show() returns S_OK for any id,
// but Windows only displays the toast when the id is known to the shell. A
// packaged (MSIX) app has one from its manifest; an exe has none. The usual
// fix is a Start-menu shortcut carrying the id. This file uses the lighter,
// documented alternative: HKCU\Software\Classes\AppUserModelId\<id> with a
// DisplayName, written on first use (per user, no admin rights), plus
// SetCurrentProcessExplicitAppUserModelID so the toasts group under this app.
#include "modules/Notifications.h"

#include <windows.h>
#include <roapi.h>
#include <shobjidl_core.h>
#include <windows.data.xml.dom.h>
#include <windows.ui.notifications.h>
#include <wrl/client.h>
#include <wrl/event.h>
#include <wrl/wrappers/corewrappers.h>

#include <cstdio>
#include <cwctype>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

namespace rni::notifications {

namespace {

using ABI::Windows::Data::Xml::Dom::IXmlDocument;
using ABI::Windows::Data::Xml::Dom::IXmlDocumentIO;
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;
namespace wun = ABI::Windows::UI::Notifications;
using ActivatedHandler =
    ABI::Windows::Foundation::ITypedEventHandler<wun::ToastNotification*, IInspectable*>;

std::wstring Wide(const std::string& s) {
  if (s.empty()) return {};
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring out(n > 0 ? n : 0, L'\0');
  if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n);
  return out;
}

std::wstring XmlEscape(const std::wstring& s) {
  std::wstring out;
  for (wchar_t c : s) {
    switch (c) {
      case L'&': out += L"&amp;"; break;
      case L'<': out += L"&lt;"; break;
      case L'>': out += L"&gt;"; break;
      case L'"': out += L"&quot;"; break;
      case L'\'': out += L"&apos;"; break;
      default: out += c;
    }
  }
  return out;
}

std::string Hr(const char* what, HRESULT hr) {
  char buf[96];
  std::snprintf(buf, sizeof(buf), "%s failed (HRESULT 0x%08lX)", what, (unsigned long)hr);
  return buf;
}

// Shared with the Activated callbacks, which Windows may run after the backend
// is gone; they hold it weakly.
struct State {
  std::mutex mu;
  PressSink onPress;
  std::unordered_map<std::string, std::string> data;  // id -> data JSON
  std::unordered_map<std::string, ComPtr<wun::IToastNotification>> live;
};

class WinBackend : public Backend {
 public:
  explicit WinBackend(PressSink onPress) : state_(std::make_shared<State>()) {
    state_->onPress = std::move(onPress);
    std::wstring name = Wide(AppDisplayName());
    std::wstring id = L"ReactNativeImpeller.";
    for (wchar_t c : name) id += (iswalnum(c) || c == L'.' || c == L'-') ? c : L'_';
    displayName_ = name;
    appId_ = id;
    worker_ = std::thread([this] { run(); });
  }

  ~WinBackend() override {
    {
      std::lock_guard<std::mutex> lock(mu_);
      stop_ = true;
    }
    wake_.notify_one();
    worker_.join();
  }

  void requestPermission(Done done) override {
    post([this, done = std::move(done)] {
      if (!ensure()) return done({"unavailable", unavailable_});
      done(setting());
    });
  }

  void show(const Request& request, Done done) override {
    post([this, request, done = std::move(done)] { showNow(request, done); });
  }

 private:
  void post(std::function<void()> task) {
    {
      std::lock_guard<std::mutex> lock(mu_);
      tasks_.push_back(std::move(task));
    }
    wake_.notify_one();
  }

  // ⛔ ONE THREAD OWNS THE APARTMENT AND EVERY WinRT OBJECT IN IT.
  // Measured: with the objects created on the JS thread and released by
  // ReactHost teardown on the main thread, after the JS thread had exited,
  // the engine died with an access violation on every run. Here the objects
  // are created, used and released on this thread, and the apartment is left
  // only after the last one is gone.
  void run() {
    const HRESULT init = RoInitialize(RO_INIT_MULTITHREADED);
    for (;;) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(mu_);
        wake_.wait(lock, [this] { return stop_ || !tasks_.empty(); });
        if (stop_) break;  // queued calls are dropped unanswered at shutdown
        task = std::move(tasks_.front());
        tasks_.pop_front();
      }
      task();
    }
    {
      std::lock_guard<std::mutex> lock(state_->mu);
      state_->live.clear();
    }
    factory_.Reset();
    notifier_.Reset();
    if (SUCCEEDED(init)) RoUninitialize();
  }

  void showNow(const Request& request, const Done& done) {
    if (!ensure()) return done({"unavailable", unavailable_});
    // Show() returns S_OK even when Windows will discard the toast, so a
    // turned-off setting is reported here instead of a false "shown".
    if (Result allowed = setting(); allowed.status == "denied") return done(allowed);
    const std::wstring xml =
        L"<toast><visual><binding template=\"ToastGeneric\"><text>" +
        XmlEscape(Wide(request.title)) + L"</text><text>" + XmlEscape(Wide(request.body)) +
        L"</text></binding></visual></toast>";
    ComPtr<IInspectable> inspectable;
    HRESULT hr = RoActivateInstance(
        HStringReference(RuntimeClass_Windows_Data_Xml_Dom_XmlDocument).Get(), &inspectable);
    ComPtr<IXmlDocument> doc;
    ComPtr<IXmlDocumentIO> io;
    if (SUCCEEDED(hr)) hr = inspectable.As(&doc);
    if (SUCCEEDED(hr)) hr = doc.As(&io);
    if (SUCCEEDED(hr)) hr = io->LoadXml(HStringReference(xml.c_str(), (unsigned)xml.size()).Get());
    if (FAILED(hr)) return done({"error", Hr("building the toast XML", hr)});

    ComPtr<wun::IToastNotification> toast;
    hr = factory_->CreateToastNotification(doc.Get(), &toast);
    if (FAILED(hr)) return done({"error", Hr("CreateToastNotification", hr)});
    // The tag makes a second show() with the same id replace the first in
    // Action Center. Tags are capped at 64 characters; a longer id still
    // shows, it just does not replace.
    ComPtr<wun::IToastNotification2> tagged;
    const std::wstring tag = Wide(request.id);
    if (tag.size() <= 64 && SUCCEEDED(toast.As(&tagged))) {
      tagged->put_Tag(HStringReference(tag.c_str(), (unsigned)tag.size()).Get());
    }
    std::weak_ptr<State> weak = state_;
    const std::string id = request.id;
    EventRegistrationToken token{};
    hr = toast->add_Activated(
        Callback<ActivatedHandler>([weak, id](wun::IToastNotification*, IInspectable*) -> HRESULT {
          auto state = weak.lock();
          if (!state) return S_OK;
          std::string data;
          PressSink sink;
          {
            std::lock_guard<std::mutex> lock(state->mu);
            auto it = state->data.find(id);
            if (it == state->data.end()) return S_OK;  // replaced by a newer toast
            data = it->second;
            sink = state->onPress;
          }
          if (sink) sink(Press{id, data, "default"});
          return S_OK;
        }).Get(),
        &token);
    if (FAILED(hr)) return done({"error", Hr("ToastNotification::add_Activated", hr)});
    hr = notifier_->Show(toast.Get());
    if (FAILED(hr)) return done({"error", Hr("IToastNotifier::Show", hr)});
    {
      std::lock_guard<std::mutex> stateLock(state_->mu);
      state_->data[id] = request.data;
      // Held so Windows keeps delivering Activated for it while we run.
      state_->live[id] = toast;
    }
    done({"shown", ""});
  }

  // Windows has no prompt to show; the answer is the user's current setting.
  Result setting() {
    wun::NotificationSetting value = wun::NotificationSetting_Enabled;
    const HRESULT hr = notifier_->get_Setting(&value);
    if (FAILED(hr)) return {"error", Hr("IToastNotifier::get_Setting", hr)};
    switch (value) {
      case wun::NotificationSetting_Enabled: return {"granted", ""};
      case wun::NotificationSetting_DisabledForApplication:
        return {"denied", "notifications are turned off for this app in Windows Settings"};
      case wun::NotificationSetting_DisabledForUser:
        return {"denied", "notifications are turned off for this user"};
      case wun::NotificationSetting_DisabledByGroupPolicy:
        return {"denied", "notifications are turned off by group policy"};
      default: return {"denied", "notifications are turned off for this app"};
    }
  }

  // Worker thread only. Retries on every call until it succeeds once.
  bool ensure() {
    if (notifier_) return true;
    if (!registerAppId()) return false;
    SetCurrentProcessExplicitAppUserModelID(appId_.c_str());
    ComPtr<wun::IToastNotificationManagerStatics> manager;
    HRESULT hr = RoGetActivationFactory(
        HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotificationManager).Get(),
        IID_PPV_ARGS(&manager));
    if (FAILED(hr)) {
      unavailable_ = "toast notifications are not available on this Windows: " +
                     Hr("RoGetActivationFactory(ToastNotificationManager)", hr);
      return false;
    }
    hr = RoGetActivationFactory(
        HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotification).Get(),
        IID_PPV_ARGS(&factory_));
    if (SUCCEEDED(hr)) {
      hr = manager->CreateToastNotifierWithId(HStringReference(appId_.c_str(), (unsigned)appId_.size()).Get(), &notifier_);
    }
    if (FAILED(hr)) {
      unavailable_ = Hr("creating the toast notifier", hr);
      factory_.Reset();
      return false;
    }
    return true;
  }

  bool registerAppId() {
    const std::wstring key = L"Software\\Classes\\AppUserModelId\\" + appId_;
    HKEY hkey = nullptr;
    LSTATUS rc = RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, 0, KEY_SET_VALUE,
                                 nullptr, &hkey, nullptr);
    if (rc == ERROR_SUCCESS) {
      rc = RegSetValueExW(hkey, L"DisplayName", 0, REG_SZ,
                          reinterpret_cast<const BYTE*>(displayName_.c_str()),
                          (DWORD)((displayName_.size() + 1) * sizeof(wchar_t)));
      RegCloseKey(hkey);
    }
    if (rc != ERROR_SUCCESS) {
      unavailable_ = "could not register the app id for toasts (registry error " +
                     std::to_string((long)rc) + ")";
      return false;
    }
    return true;
  }

  std::mutex mu_;
  std::shared_ptr<State> state_;
  std::wstring displayName_;
  std::wstring appId_;
  std::string unavailable_;
  ComPtr<wun::IToastNotificationFactory> factory_;
  ComPtr<wun::IToastNotifier> notifier_;
  std::condition_variable wake_;
  std::deque<std::function<void()>> tasks_;
  bool stop_ = false;
  std::thread worker_;
};

}  // namespace

std::unique_ptr<Backend> CreateBackend(PressSink onPress) {
  return std::make_unique<WinBackend>(std::move(onPress));
}

}  // namespace rni::notifications
