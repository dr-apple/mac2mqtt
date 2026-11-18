// Now-Playing-Helfer für mac2mqttd.
// Seit macOS 15.4 liefert MediaRemote nur noch Apple-Plattformprozessen echte Daten.
// mac2mqttd startet daher /usr/bin/perl, lädt diese Bibliothek und ruft mac2mqtt_np_stream() auf.
// Ausgabe: eine JSON-Zeile pro Änderung (und alle 10 s als Lebenszeichen), z. B.
//   {"playing":true,"rate":1,"pid":123}
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <signal.h>
#include "Mac2MQTTNowPlaying.h"

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetPid)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetPlaying)(dispatch_queue_t, void (^)(Boolean));

void mac2mqtt_np_stream(void) {
    signal(SIGPIPE, SIG_DFL);   // mac2mqttd beendet -> Pipe zu -> Helfer endet
    void *fw = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    MRGetInfo getInfo = fw ? (MRGetInfo)dlsym(fw, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    MRGetPid getPid = fw ? (MRGetPid)dlsym(fw, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL;
    MRGetPlaying getPlaying = fw ? (MRGetPlaying)dlsym(fw, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
    if (!getInfo || !getPlaying) { printf("{\"error\":\"mediaremote\"}\n"); fflush(stdout); return; }

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    NSString *last = nil; NSDate *lastWrite = [NSDate distantPast];
    for (;;) {
        @autoreleasepool {
            dispatch_semaphore_t s = dispatch_semaphore_create(0);
            __block double rate = -1; __block BOOL hasInfo = NO; __block int pid = -1; __block int playing = -1;
            getInfo(q, ^(CFDictionaryRef d) {
                NSDictionary *n = (__bridge NSDictionary *)d;
                if (n) { hasInfo = YES; id r = n[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]; if (r) rate = [r doubleValue]; }
                dispatch_semaphore_signal(s);
            });
            dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
            getPlaying(q, ^(Boolean b) { playing = b ? 1 : 0; dispatch_semaphore_signal(s); });
            dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
            if (getPid) {
                getPid(q, ^(int p) { pid = p; dispatch_semaphore_signal(s); });
                dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
            }
            // Rate ist am verlässlichsten; ohne Rate gilt der „isPlaying“-Wert der Now-Playing-App.
            BOOL isPlaying = hasInfo && rate >= 0 ? (rate > 0.01) : (playing == 1);
            NSString *line = [NSString stringWithFormat:@"{\"playing\":%@,\"rate\":%g,\"pid\":%d,\"info\":%@}",
                              isPlaying ? @"true" : @"false", rate, pid, hasInfo ? @"true" : @"false"];
            if (![line isEqualToString:last] || [[NSDate date] timeIntervalSinceDate:lastWrite] > 10) {
                if (printf("%s\n", line.UTF8String) < 0 || fflush(stdout) != 0) return;
                last = line; lastWrite = [NSDate date];
            }
        }
        usleep(500 * 1000);
    }
}
