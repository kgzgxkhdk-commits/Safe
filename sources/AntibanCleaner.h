#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    NSInteger deletedDocs;
    NSInteger deletedCaches;
} AntibanResult;

/// Watches game container directories with DISPATCH_SOURCE_TYPE_VNODE.
/// Fires an immediate clean pass the moment any file appears in a watched dir.
/// Start when game is detected, stop when game exits.
@interface AntibanCleaner : NSObject

+ (instancetype)shared;

/// One-shot immediate clean, returns result synchronously on background queue.
- (AntibanResult)cleanOnce;

/// Start fs-level watching. Fires on game process appear.
- (void)startWatching;

/// Stop watching + final clean pass. Fires on game process disappear.
- (void)stopWatching;

@property (nonatomic, readonly) BOOL         isWatching;
@property (nonatomic, readonly) AntibanResult lastResult;

@end

NS_ASSUME_NONNULL_END
