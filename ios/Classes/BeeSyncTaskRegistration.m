#import "BeeSyncTaskRegistration.h"

NSString *_Nullable BeeSyncRegisterTask(NSString *identifier,
                                        void (^launchHandler)(__kindof BGTask *task)) {
  @try {
    BOOL ok = [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:identifier
                                                                    usingQueue:nil
                                                                 launchHandler:launchHandler];
    return ok ? nil : @"BGTaskScheduler refused the registration";
  } @catch (NSException *exception) {
    return exception.reason ?: exception.name;
  }
}
