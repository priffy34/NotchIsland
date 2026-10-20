// Тонкая обёртка над приватным MediaRemote.framework.
// adapter_stream — печатает JSON-строку при каждом изменении Now Playing (без поллинга).
// adapter_send   — отправляет команду (MR_CMD) текущему плееру.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void (^InfoBlock)(NSDictionary *);
typedef void (^BoolBlock)(Boolean);
typedef void (^ClientBlock)(id);

static void (*MRGetInfo)(dispatch_queue_t, InfoBlock);
static void (*MRGetIsPlaying)(dispatch_queue_t, BoolBlock);
static void (*MRGetClient)(dispatch_queue_t, ClientBlock);
static void (*MRRegister)(dispatch_queue_t);
static Boolean (*MRSend)(int, id);
static NSString *(*MRClientBundle)(id);
static void (*MRSetElapsed)(double);

static BOOL loadMR(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!h) return NO;
    MRGetInfo      = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    MRGetIsPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetClient    = dlsym(h, "MRMediaRemoteGetNowPlayingClient");
    MRRegister     = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    MRSend         = dlsym(h, "MRMediaRemoteSendCommand");
    MRClientBundle = dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    MRSetElapsed   = dlsym(h, "MRMediaRemoteSetElapsedTime");
    return MRGetInfo && MRGetIsPlaying && MRRegister && MRSend;
}

static id nz(id v) { return v ?: [NSNull null]; }

static void emit(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    MRGetInfo(q, ^(NSDictionary *info) {
        MRGetIsPlaying(q, ^(Boolean playing) {
            void (^finish)(NSString *) = ^(NSString *bundle) {
                NSString *p = @"kMRMediaRemoteNowPlayingInfo";
                NSNumber *elapsed = info[[p stringByAppendingString:@"ElapsedTime"]];
                NSNumber *rate = info[[p stringByAppendingString:@"PlaybackRate"]];
                NSDate *ts = info[[p stringByAppendingString:@"Timestamp"]];
                double r = rate ? rate.doubleValue : 1.0;
                if (playing && r <= 0) r = 1.0;
                double el = elapsed ? elapsed.doubleValue : 0;
                if (playing && ts) el += r * (-[ts timeIntervalSinceNow]);
                NSData *art = info[[p stringByAppendingString:@"ArtworkData"]];
                NSDictionary *out = @{
                    @"title":    nz(info[[p stringByAppendingString:@"Title"]]),
                    @"artist":   nz(info[[p stringByAppendingString:@"Artist"]]),
                    @"album":    nz(info[[p stringByAppendingString:@"Album"]]),
                    @"duration": nz(info[[p stringByAppendingString:@"Duration"]]),
                    @"elapsed":  @(el),
                    @"rate":     @(r),
                    @"playing":  [NSNumber numberWithBool:playing],
                    @"bundle":   nz(bundle),
                    @"artwork":  art ? [art base64EncodedStringWithOptions:0] : (id)[NSNull null],
                };
                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                if (json) {
                    fwrite(json.bytes, 1, json.length, stdout);
                    fputc('\n', stdout);
                    fflush(stdout);
                }
            };
            if (MRGetClient && MRClientBundle) {
                MRGetClient(q, ^(id client) {
                    finish(client ? MRClientBundle(client) : nil);
                });
            } else {
                finish(nil);
            }
        });
    });
}

static BOOL pending = NO;
static void schedule(void) {
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        pending = NO;
        emit();
    });
}

__attribute__((visibility("default")))
void adapter_stream(void *interp, void *cv) {
    @autoreleasepool {
        if (!loadMR()) { fputs("{}\n", stdout); fflush(stdout); return; }
        MRRegister(dispatch_get_main_queue());
        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ];
        for (NSString *n in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil
                usingBlock:^(NSNotification *x) { schedule(); }];
        }
        // Если родитель умер — выходим.
        [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) {
            if (getppid() == 1) exit(0);
        }];
        emit();
        CFRunLoopRun();
    }
}

__attribute__((visibility("default")))
void adapter_send(void *interp, void *cv) {
    @autoreleasepool {
        const char *c = getenv("MR_CMD");
        if (!c || !loadMR()) return;
        MRSend(atoi(c), nil);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    }
}

__attribute__((visibility("default")))
void adapter_seek(void *interp, void *cv) {
    @autoreleasepool {
        const char *c = getenv("MR_SEEK");
        if (!c || !loadMR() || !MRSetElapsed) return;
        MRSetElapsed(atof(c));
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    }
}
