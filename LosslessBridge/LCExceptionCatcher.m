#import "LCExceptionCatcher.h"

NSString *LCCatchObjCException(void (NS_NOESCAPE ^block)(void))
{
    @try {
        block();
    } @catch (NSException *e) {
        NSString *name = e.name ?: @"NSException";
        NSString *reason = e.reason ?: @"(no reason)";
        return [NSString stringWithFormat:@"%@: %@", name, reason];
    }
    return nil;
}
