#import <BackgroundTasks/BackgroundTasks.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Registers a BGTaskScheduler launch handler. Returns nil on success, or the
/// reason registration was refused.
///
/// BGTaskScheduler raises an Objective-C exception when a handler is
/// registered after the app finished launching (add-to-app, or apps that
/// register plugins from a scene) or twice. Swift cannot catch those, so this
/// wrapper turns them into a returned message instead of a crash.
FOUNDATION_EXPORT NSString *_Nullable BeeSyncRegisterTask(NSString *identifier,
                                                         void (^launchHandler)(__kindof BGTask *task))
    API_AVAILABLE(ios(13.0));

NS_ASSUME_NONNULL_END
