// IsletMediaRemote: reads the system's Now Playing item (any app: browsers, Podcasts, TV, VLC…) for Islet.
//
// Since macOS 15.4, mediaremoted only answers "get" requests from Apple-signed processes, so Islet can't read
// MediaRemote itself (its change signals and its commands still work in-process). Instead, NowPlayingFeature's
// `MediaRemoteBridge` runs, once per change:
//
//     /usr/bin/perl -e '<DynaLoader loader>' <path to this dylib>
//
// perl (an Apple platform binary, without library validation) loads this library and calls `islet_mr_read`, which
// writes ONE binary property list to stdout and exits the process: ≈ 10–30 ms and ≈ 5 MB, freed right away.
// Nothing stays resident.
//
// Output keys (each one optional):
//   playing  bool    MRMediaRemoteGetNowPlayingApplicationIsPlaying
//   pid      int     pid of the now playing process (0 when nothing is playing)
//   bundle   string  bundle id of the now playing client (com.google.Chrome, com.apple.podcasts…)
//   parent   string  parent app bundle id, for web content and helper processes (com.apple.Safari for WebKit)
//   name     string  client display name
//   info     dict    the kMRMediaRemoteNowPlayingInfo* entries that are property-list types (artwork bytes included,
//                    unless their kMRMediaRemoteNowPlayingInfoArtworkIdentifier equals $ISLET_MR_SKIP_ARTWORK: Islet
//                    already has that image)
//
// It is a .h only so SwiftPM ignores it (a .m would make NowPlayingFeature a mixed-language target). Built by
// scripts/bundle.sh into Contents/Helpers/libIsletMediaRemote.dylib:
//
//     clang -x objective-c -dynamiclib -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 \
//           -framework Foundation -o libIsletMediaRemote.dylib IsletMediaRemote.h

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef void (*IsletMRGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*IsletMRGetBool)(dispatch_queue_t, void (^)(Boolean));
typedef void (*IsletMRGetPID)(dispatch_queue_t, void (^)(int));
typedef void (*IsletMRGetClient)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*IsletMRClientString)(id);

/// Keeps property-list types only (the info dictionary may hold other objects, which would fail serialization).
static id IsletPlistSafe(id value, int depth) {
    if (value == nil || depth > 4) return nil;
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] ||
        [value isKindOfClass:NSData.class] || [value isKindOfClass:NSDate.class]) {
        return value;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *array = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            id safe = IsletPlistSafe(item, depth + 1);
            if (safe) [array addObject:safe];
        }
        return array;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
            (void)stop;
            id safe = IsletPlistSafe(object, depth + 1);
            if (safe && [key isKindOfClass:NSString.class]) dictionary[key] = safe;
        }];
        return dictionary;
    }
    return nil;
}

static void IsletSetString(NSMutableDictionary *out, NSString *key, IsletMRClientString getter, id client) {
    if (!getter || !client) return;
    NSString *value = (__bridge NSString *)getter(client);
    if ([value isKindOfClass:NSString.class] && value.length > 0) out[key] = [value copy];
}

/// Entry point, called by perl through DynaLoader::dl_install_xsub (the XSUB arguments are ignored). Never returns.
__attribute__((visibility("default")))
void islet_mr_read(void) {
    @autoreleasepool {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        const char *skip = getenv("ISLET_MR_SKIP_ARTWORK");
        NSString *knownArtwork = skip && skip[0] ? @(skip) : nil;

        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW | RTLD_LOCAL);
        IsletMRGetInfo getInfo = mr ? (IsletMRGetInfo)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo") : NULL;
        IsletMRGetBool getPlaying = mr ? (IsletMRGetBool)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
        IsletMRGetPID getPID = mr ? (IsletMRGetPID)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL;
        IsletMRGetClient getClient = mr ? (IsletMRGetClient)dlsym(mr, "MRMediaRemoteGetNowPlayingClient") : NULL;
        IsletMRClientString bundleOf = mr ? (IsletMRClientString)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier") : NULL;
        IsletMRClientString parentOf = mr ? (IsletMRClientString)dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier") : NULL;
        IsletMRClientString nameOf = mr ? (IsletMRClientString)dlsym(mr, "MRNowPlayingClientGetDisplayName") : NULL;

        // The four requests run concurrently; their replies land on one serial queue, which owns `out`.
        dispatch_queue_t queue = dispatch_queue_create("app.islet.mediaremote", DISPATCH_QUEUE_SERIAL);
        dispatch_group_t group = dispatch_group_create();
        if (getInfo) {
            dispatch_group_enter(group);
            getInfo(queue, ^(CFDictionaryRef info) {
                NSMutableDictionary *safe = info ? IsletPlistSafe((__bridge id)info, 0) : nil;
                if (![safe isKindOfClass:NSMutableDictionary.class]) safe = nil;
                if (knownArtwork && [safe[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] isEqual:knownArtwork]) {
                    [safe removeObjectForKey:@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                }
                if (safe.count > 0) out[@"info"] = safe;
                dispatch_group_leave(group);
            });
        }
        if (getPlaying) {
            dispatch_group_enter(group);
            getPlaying(queue, ^(Boolean playing) {
                out[@"playing"] = @(playing != 0);
                dispatch_group_leave(group);
            });
        }
        if (getPID) {
            dispatch_group_enter(group);
            getPID(queue, ^(int pid) {
                out[@"pid"] = @(pid);
                dispatch_group_leave(group);
            });
        }
        if (getClient) {
            dispatch_group_enter(group);
            getClient(queue, ^(id client) {
                IsletSetString(out, @"bundle", bundleOf, client);
                IsletSetString(out, @"parent", parentOf, client);
                IsletSetString(out, @"name", nameOf, client);
                dispatch_group_leave(group);
            });
        }
        // Islet kills the process after 5 s anyway (the rest is perl's cold start); a missing reply only drops its keys.
        dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));

        __block NSData *data = nil;
        dispatch_sync(queue, ^{
            data = [NSPropertyListSerialization dataWithPropertyList:out
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:NULL];
        });
        if (data.length > 0) fwrite(data.bytes, 1, data.length, stdout);
        fflush(stdout);
    }
    // Skip perl's teardown: the XSUB never touched perl's stack, and there is nothing left to do.
    _exit(0);
}
