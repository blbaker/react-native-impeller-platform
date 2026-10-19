// iOS host phase (Task 3.1): the engine as an Objective-C object an iOS app
// owns, the same relationship Flutter's FlutterEngine has with a
// FlutterViewController. Objective-C only, so an app never includes C++.
//
// Lifecycle (the same contract as the Android renderer's): create once,
// attach/detach to a view any number of times, destroy once.
//   RNIEngine* e = [[RNIEngine alloc] initWithBundlePath:path appName:@"App"];
//   [e attachToView:metalView];   // first attach boots JS and starts the surface
//   [e detach];                   // stops frames; the JS runtime stays up
//   [e destroy];                  // tears everything down; the object is spent
//
// The view must be backed by a CAMetalLayer (+layerClass), e.g. RNIMetalLayerView
// from host/MetalSurfaceIOS.h. All methods: main thread.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RNIEngine : NSObject

// Reads the bundle (JS source or Hermes bytecode) now; nil when it cannot.
- (nullable instancetype)initWithBundlePath:(NSString*)bundlePath appName:(NSString*)appName;
- (instancetype)init NS_UNAVAILABLE;

// First call: creates the Metal context, boots EngineSession (ReactHost +
// FabricHost + SceneGraph), evaluates the bundle, starts the surface and waits
// for JS to go idle, then paints every vsync. Later calls re-attach frames.
// Returns NO (and logs why) when the view cannot host a Metal surface.
- (BOOL)attachToView:(UIView*)view;
- (void)detach;
- (void)destroy;

// Frames presented since the first attach.
@property(nonatomic, readonly) NSUInteger presentedFrames;
// Runs once, on the main thread, after the first frame with content presents.
@property(nonatomic, copy, nullable) void (^onFirstFrame)(void);

@end

NS_ASSUME_NONNULL_END
