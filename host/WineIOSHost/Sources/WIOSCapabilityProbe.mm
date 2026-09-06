#import "WIOSCapabilityProbe.h"
#import "WIOSLog.h"

#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <unistd.h>

static void LogResult(NSString *key, BOOL passed, NSString *detail)
{
    NSString *value = passed ? @"PASS" : @"FAIL";
    if (detail.length) value = [value stringByAppendingFormat:@" (%@)", detail];
    [[WIOSLog shared] appendLevel:passed ? @"INFO" : @"ERROR" key:key value:value];
}

typedef struct {
    pthread_key_t key;
    BOOL passed;
} WIOSThreadProbeContext;

static void *WIOSThreadProbe(void *opaque)
{
    WIOSThreadProbeContext *context = static_cast<WIOSThreadProbeContext *>(opaque);
    BOOL initiallyEmpty = pthread_getspecific(context->key) == NULL;
    int marker = 2;
    int setResult = pthread_setspecific(context->key, &marker);
    context->passed = initiallyEmpty && setResult == 0 && pthread_getspecific(context->key) == &marker;
    return NULL;
}

@implementation WIOSCapabilityProbe

+ (void)runSafeProbes
{
    WIOSLog *log = [WIOSLog shared];

#if defined(__aarch64__)
    [log appendLevel:@"INFO" key:@"ARCH" value:@"arm64"];
#else
    [log appendLevel:@"ERROR" key:@"ARCH" value:@"unsupported"];
#endif

    [log appendLevel:@"INFO" key:@"OS_VERSION"
               value:[[NSProcessInfo processInfo] operatingSystemVersionString]];
    [log appendLevel:@"INFO" key:@"PAGE_SIZE"
               value:[NSString stringWithFormat:@"%ld", sysconf(_SC_PAGESIZE)]];
    [log appendLevel:@"INFO" key:@"PID"
               value:[NSString stringWithFormat:@"%d", getpid()]];

    pthread_key_t key;
    int keyResult = pthread_key_create(&key, NULL);
    if (keyResult == 0) {
        int mainMarker = 1;
        pthread_setspecific(key, &mainMarker);
        WIOSThreadProbeContext context = {key, NO};
        pthread_t thread;
        int createResult = pthread_create(&thread, NULL, WIOSThreadProbe, &context);
        int joinResult = createResult == 0 ? pthread_join(thread, NULL) : createResult;
        BOOL mainValueIntact = pthread_getspecific(key) == &mainMarker;
        LogResult(@"THREAD", createResult == 0 && joinResult == 0,
                  [NSString stringWithFormat:@"create=%d join=%d", createResult, joinResult]);
        LogResult(@"TLS", context.passed && mainValueIntact, @"pthread_key isolation");
        pthread_key_delete(key);
    } else {
        LogResult(@"THREAD", NO, [NSString stringWithFormat:@"pthread_key_create=%d", keyResult]);
        LogResult(@"TLS", NO, @"key unavailable");
    }

    NSURL *fileURL = [[log.fileURL URLByDeletingLastPathComponent]
        URLByAppendingPathComponent:@"file-probe.bin"];
    NSData *payload = [@"WIOS-FILE-PROBE" dataUsingEncoding:NSUTF8StringEncoding];
    BOOL wrote = [payload writeToURL:fileURL atomically:YES];
    NSData *readback = [NSData dataWithContentsOfURL:fileURL];
    BOOL removed = [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
    LogResult(@"FILE_IO", wrote && [payload isEqualToData:readback] && removed, @"sandbox roundtrip");

    size_t pageSize = (size_t)sysconf(_SC_PAGESIZE);
    errno = 0;
    void *page = mmap(NULL, pageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (page == MAP_FAILED) {
        LogResult(@"VM_BASIC", NO, [NSString stringWithFormat:@"mmap errno=%d", errno]);
    } else {
        memset(page, 0xA5, pageSize);
        int readOnly = mprotect(page, pageSize, PROT_READ);
        int readWrite = readOnly == 0 ? mprotect(page, pageSize, PROT_READ | PROT_WRITE) : -1;
        int release = munmap(page, pageSize);
        LogResult(@"VM_BASIC", readOnly == 0 && readWrite == 0 && release == 0,
                  [NSString stringWithFormat:@"ro=%d rw=%d unmap=%d", readOnly, readWrite, release]);
    }

#ifdef MAP_JIT
    errno = 0;
    void *jitPage = mmap(NULL, pageSize, PROT_READ | PROT_WRITE | PROT_EXEC,
                         MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (jitPage == MAP_FAILED) {
        [log appendLevel:@"WARN" key:@"MAP_JIT"
                   value:[NSString stringWithFormat:@"UNAVAILABLE (errno=%d: %s)", errno, strerror(errno)]];
    } else {
        [log appendLevel:@"INFO" key:@"MAP_JIT" value:@"AVAILABLE (execution not attempted)"];
        munmap(jitPage, pageSize);
    }
#else
    [log appendLevel:@"WARN" key:@"MAP_JIT" value:@"NOT_DEFINED_BY_SDK"];
#endif
}

+ (void)runJITExecutionProbe
{
    /*
     * pthread_jit_write_protect_np() is explicitly unavailable when compiling
     * against the iPhoneOS SDK. JIT is not part of the current Arcadia Wine
     * runtime bring-up gate, so keep the public probe entry point but do not
     * compile or execute a JIT test here.
     */
    [[WIOSLog shared] appendLevel:@"INFO"
                              key:@"JIT_EXEC"
                            value:@"SKIPPED (not required for current Wine runtime bring-up)"];
}

@end
