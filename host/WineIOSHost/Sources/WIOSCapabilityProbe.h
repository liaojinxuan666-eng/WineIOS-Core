#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WIOSCapabilityProbe : NSObject
+ (void)runSafeProbes;
+ (void)runJITExecutionProbe;
@end

NS_ASSUME_NONNULL_END

