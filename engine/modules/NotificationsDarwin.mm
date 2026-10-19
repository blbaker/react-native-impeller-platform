// macOS notifications through UNUserNotificationCenter.
//
// ⛔ THE BUNDLE CHECK COMES BEFORE ANY UserNotifications CALL.
// +[UNUserNotificationCenter currentNotificationCenter] raises an Objective-C
// exception ("bundleProxyForCurrentProcess is nil") in a process that is not
// running from an app bundle, which is how the bare engine binary runs from
// its npm package. An uncaught exception there kills the app. So a process
// with no CFBundleIdentifier answers "unavailable" and never touches the
// center; an app that ships the engine inside its .app gets real
// notifications.
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

#include "modules/Notifications.h"

#include <string>
#include <utility>

using rni::notifications::Press;
using rni::notifications::PressSink;

static std::string Utf8(NSString* s) {
  const char* c = s.UTF8String;
  return c ? std::string(c) : std::string();
}

// Never nil: a nil value in the userInfo literal below would raise.
static NSString* NS(const std::string& s) {
  NSString* out = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
  return out ?: @"";
}

@interface RNINotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
- (instancetype)initWithSink:(PressSink)sink;
@end

@implementation RNINotificationDelegate {
  PressSink _onPress;
}

- (instancetype)initWithSink:(PressSink)sink {
  if ((self = [super init])) _onPress = std::move(sink);
  return self;
}

// macOS hides a notification from the frontmost app unless the delegate asks
// for it. A desktop app is usually frontmost when it shows one.
- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       willPresentNotification:(UNNotification*)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
  completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList |
                    UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
    didReceiveNotificationResponse:(UNNotificationResponse*)response
             withCompletionHandler:(void (^)(void))completionHandler {
  NSDictionary* info = response.notification.request.content.userInfo;
  id rid = info[@"rniId"];
  id data = info[@"rniData"];
  // Only the default action (a click on the body) is a press, and only for a
  // notification this engine created (it carries rniId).
  if ([response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier] &&
      [rid isKindOfClass:[NSString class]] && _onPress) {
    _onPress(Press{Utf8(rid), [data isKindOfClass:[NSString class]] ? Utf8(data) : "null", "default"});
  }
  completionHandler();
}

@end

namespace rni::notifications {

namespace {

std::string Describe(NSError* error) {
  return Utf8(error.localizedDescription) + " (" + Utf8(error.domain) + " " +
         std::to_string((long)error.code) + ")";
}

class DarwinBackend : public Backend {
 public:
  explicit DarwinBackend(PressSink onPress) {
    if (NSBundle.mainBundle.bundleIdentifier.length == 0) {
      unavailable_ =
          "macOS notifications need the engine to run inside an app bundle with a "
          "CFBundleIdentifier; this process has none";
      return;
    }
    center_ = UNUserNotificationCenter.currentNotificationCenter;
    // The center holds its delegate weakly; this backend keeps it alive.
    delegate_ = [[RNINotificationDelegate alloc] initWithSink:std::move(onPress)];
    center_.delegate = delegate_;
  }

  void requestPermission(Done done) override {
    if (center_ == nil) {
      done({"unavailable", unavailable_});
      return;
    }
    [center_ requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                           completionHandler:^(BOOL granted, NSError* error) {
                             if (error != nil) {
                               done({"error", Describe(error)});
                             } else {
                               done({granted ? "granted" : "denied", ""});
                             }
                           }];
  }

  void show(const Request& request, Done done) override {
    if (center_ == nil) {
      done({"unavailable", unavailable_});
      return;
    }
    UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
    content.title = NS(request.title);
    content.body = NS(request.body);
    content.sound = UNNotificationSound.defaultSound;
    content.userInfo = @{@"rniId" : NS(request.id), @"rniData" : NS(request.data)};
    // The same identifier replaces a delivered notification, which is the
    // "same id replaces" contract in Notifications.h.
    UNNotificationRequest* req = [UNNotificationRequest requestWithIdentifier:NS(request.id)
                                                                      content:content
                                                                      trigger:nil];
    [center_ addNotificationRequest:req
              withCompletionHandler:^(NSError* error) {
                if (error == nil) {
                  done({"shown", ""});
                } else if ([error.domain isEqualToString:UNErrorDomain] &&
                           error.code == UNErrorCodeNotificationsNotAllowed) {
                  done({"denied", "the user has not allowed notifications for this app"});
                } else {
                  done({"error", Describe(error)});
                }
              }];
  }

 private:
  std::string unavailable_;
  UNUserNotificationCenter* center_ = nil;
  RNINotificationDelegate* delegate_ = nil;
};

}  // namespace

std::unique_ptr<Backend> CreateBackend(PressSink onPress) {
  return std::make_unique<DarwinBackend>(std::move(onPress));
}

}  // namespace rni::notifications
