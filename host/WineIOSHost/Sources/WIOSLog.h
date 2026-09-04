#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WIOSLog : NSObject

+ (instancetype)shared;
- (void)resetForNewSession;
- (void)appendLevel:(NSString *)level key:(NSString *)key value:(NSString *)value;
- (NSString *)contents;
- (NSURL *)fileURL;

@end

NS_ASSUME_NONNULL_END

