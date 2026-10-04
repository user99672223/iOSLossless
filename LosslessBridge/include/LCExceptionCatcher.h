/* Objective-C exception boundary for Swift callers.
 *
 * AVFoundation reports an invalid capture configuration (unsupported frame
 * duration, colour space, multichannel audio mode, output settings, ...) by
 * raising an NSException. Swift cannot catch those, so an uncaught one kills
 * the process. Running the risky statements inside LCCatchObjCException turns
 * the exception into a returned string that the app can log and recover from.
 */
#ifndef LC_EXCEPTION_CATCHER_H
#define LC_EXCEPTION_CATCHER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside @try/@catch. Returns nil when the block completed
/// normally, otherwise "<exception name>: <reason>".
FOUNDATION_EXPORT NSString * _Nullable LCCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END

#endif /* LC_EXCEPTION_CATCHER_H */
