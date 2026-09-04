#import "WIOSLog.h"

@interface WIOSLog ()
@property(nonatomic, strong) NSFileHandle *handle;
@property(nonatomic, strong) NSURL *logURL;
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation WIOSLog

+ (instancetype)shared
{
    static WIOSLog *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[WIOSLog alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate
{
    self = [super init];
    if (!self) return nil;

    _queue = dispatch_queue_create("com.wineios.core.log", DISPATCH_QUEUE_SERIAL);
    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *directory = [documents URLByAppendingPathComponent:@"Logs" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    _logURL = [directory URLByAppendingPathComponent:@"wine-ios.log"];
    return self;
}

- (instancetype)init
{
    return [WIOSLog shared];
}

- (void)resetForNewSession
{
    dispatch_sync(self.queue, ^{
        [self.handle closeFile];
        self.handle = nil;
        [[NSData data] writeToURL:self.logURL atomically:YES];
        self.handle = [NSFileHandle fileHandleForWritingToURL:self.logURL error:nil];
    });
}

- (void)appendLevel:(NSString *)level key:(NSString *)key value:(NSString *)value
{
    dispatch_sync(self.queue, ^{
        if (!self.handle) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:self.logURL.path]) {
                [[NSData data] writeToURL:self.logURL atomically:YES];
            }
            self.handle = [NSFileHandle fileHandleForWritingToURL:self.logURL error:nil];
            [self.handle seekToEndOfFile];
        }

        NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                                  NSISO8601DateFormatWithFractionalSeconds;
        NSString *line = [NSString stringWithFormat:@"%@ [%@] %@=%@\n",
                          [formatter stringFromDate:[NSDate date]], level, key, value];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        [self.handle writeData:data];
        [self.handle synchronizeFile];
        NSLog(@"%@", [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
    });
}

- (NSString *)contents
{
    __block NSString *text = @"";
    dispatch_sync(self.queue, ^{
        NSData *data = [NSData dataWithContentsOfURL:self.logURL];
        text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
    });
    return text;
}

- (NSURL *)fileURL
{
    return self.logURL;
}

@end

