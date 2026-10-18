#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    NSInteger deletedDocs;
    NSInteger deletedCaches;
} AntibanResult;

/// Порт cleanAntibanAndTelemetry + continuous loop из proxyapp.
/// Умеет резолвить контейнер FreeFire через MCMActivateContainerPath
/// (entitlement com.apple.private.MobileContainerManager.allowed).
@interface AntibanCleaner : NSObject

+ (instancetype)shared;

/// Разовая чистка — возвращает результат синхронно на background queue.
- (AntibanResult)cleanOnce;

/// Запускает цикл чистки каждые 10 сек (как в proxyapp).
/// Вызывается когда game detected (при старте матча).
- (void)startLoop;

/// Останавливает цикл. Вызывается когда game пропала (выход из матча).
- (void)stopLoop;

@property (nonatomic, readonly) BOOL isLoopRunning;
@property (nonatomic, readonly) AntibanResult lastResult;

@end

NS_ASSUME_NONNULL_END
