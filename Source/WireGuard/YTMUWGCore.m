#import "YTMUWGCore.h"
#import "YTMUWGBridge.h"
#import <Network/Network.h>
#import <Security/Security.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <netinet/in.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <sys/socket.h>
#import <sys/utsname.h>
#import <unistd.h>

NSString *const YTMUWGVersion = @"1.0";

static NSString *const kDefaultsKey = @"YTMUWireGuard";
static NSString *const kKeychainService = @"YTMusicUltimate.WireGuard";
static NSString *const kKeychainAccount = @"profile";

#pragma mark - State

static atomic_int gState = YTMUWGStateOff;
static BOOL gActive;              // hooks installed in this launch
static int gPort = -1;            // local proxy port (fixed for the launch)
static int gListenerFD = -1;      // reserved socket handed to Go on start
static char gUser[33], gPass[33]; // per-launch random proxy credentials
static dispatch_queue_t gQueue;

static atomic_uint gConfigsProxied, gSessionsProxied, gBackgroundConfigs, gSharedReplaced;
static atomic_uint gProxyFailures, gBlockedRequests, gHTTP3Cleared, gDataURLFetches;
static atomic_uint gRebinds;
static BOOL gFFmpegProxy;

YTMUWGState YTMUWGCurrentState(void) { return (YTMUWGState)atomic_load(&gState); }
BOOL YTMUWGActiveThisLaunch(void) { return gActive; }

NSString *YTMUWGStateDescription(YTMUWGState state) {
    switch (state) {
        case YTMUWGStateOff: return @"off";
        case YTMUWGStateUnsupported: return @"unsupported (iOS 17+ required)";
        case YTMUWGStateWaitingProfile: return @"waiting for profile (Keychain locked)";
        case YTMUWGStateStarting: return @"starting";
        case YTMUWGStateRunning: return @"running";
        case YTMUWGStateFailed: return @"failed (traffic blocked)";
    }
    return @"unknown";
}

#pragma mark - Settings

#ifdef YTMUWG_TESTING
static NSString *TestEnv(NSString *name) { return NSProcessInfo.processInfo.environment[name]; }
#endif

static NSDictionary *SettingsDict(void) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kDefaultsKey];
    return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

static void SetSetting(NSString *key, id value) {
    NSMutableDictionary *d = [SettingsDict() mutableCopy];
    d[key] = value;
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:kDefaultsKey];
}

BOOL YTMUWGSettingEnabled(void) {
#ifdef YTMUWG_TESTING
    if (TestEnv(@"YTMUWG_TEST_ENABLED")) return [TestEnv(@"YTMUWG_TEST_ENABLED") boolValue];
#endif
    return [SettingsDict()[@"enabled"] boolValue];
}
void YTMUWGSetSettingEnabled(BOOL enabled) { SetSetting(@"enabled", @(enabled)); }

BOOL YTMUWGSettingForceNativeStack(void) {
#ifdef YTMUWG_TESTING
    if (TestEnv(@"YTMUWG_TEST_FORCE_STACK")) return [TestEnv(@"YTMUWG_TEST_FORCE_STACK") boolValue];
#endif
    return [SettingsDict()[@"forceNativeStack"] boolValue];
}
void YTMUWGSetSettingForceNativeStack(BOOL enabled) { SetSetting(@"forceNativeStack", @(enabled)); }

static BOOL YTMUMasterEnabled(void) {
#ifdef YTMUWG_TESTING
    return YES;
#endif
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    id v = [d isKindOfClass:NSDictionary.class] ? d[@"YTMUltimateIsEnabled"] : nil;
    return v ? [v boolValue] : YES;
}

NSString *YTMUWGAppVersion(void) {
#ifdef YTMUWG_TESTING
    if (TestEnv(@"YTMUWG_TEST_APP_VERSION")) return TestEnv(@"YTMUWG_TEST_APP_VERSION");
#endif
    id v = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [v isKindOfClass:NSString.class] ? v : @"?";
}

#pragma mark - iOS 17 proxy API (resolved at runtime; the repo builds with the iOS 16.5 SDK)

typedef void *(*CreateSocksFn)(void *endpoint);
typedef void (*SetUserPassFn)(void *config, const char *user, const char *pass);
typedef void (*SetFailoverFn)(void *config, bool allowed);
typedef bool (*GetFailoverFn)(void *config);
static CreateSocksFn pCreateSocks;
static SetUserPassFn pSetUserPass;
static SetFailoverFn pSetFailover;
static GetFailoverFn pGetFailover;
static SEL sSetProxyConfigurations, sProxyConfigurations;

BOOL YTMUWGIsSupportedOS(void) {
    static BOOL supported;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#if TARGET_OS_OSX
        NSOperatingSystemVersion minimum = {14, 0, 0};
#else
        NSOperatingSystemVersion minimum = {17, 0, 0};
#endif
        // NSProcessInfo instead of @available: no compiler-rt dependency.
        if ([NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:minimum]) {
            dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY);
            pCreateSocks = (CreateSocksFn)dlsym(RTLD_DEFAULT, "nw_proxy_config_create_socksv5");
            pSetUserPass = (SetUserPassFn)dlsym(RTLD_DEFAULT, "nw_proxy_config_set_username_and_password");
            pSetFailover = (SetFailoverFn)dlsym(RTLD_DEFAULT, "nw_proxy_config_set_failover_allowed");
            pGetFailover = (GetFailoverFn)dlsym(RTLD_DEFAULT, "nw_proxy_config_get_failover_allowed");
            sSetProxyConfigurations = NSSelectorFromString(@"setProxyConfigurations:");
            sProxyConfigurations = NSSelectorFromString(@"proxyConfigurations");
            supported = pCreateSocks && pSetUserPass && pSetFailover && pGetFailover &&
                [NSURLSessionConfiguration instancesRespondToSelector:sSetProxyConfigurations] &&
                [NSURLSessionConfiguration instancesRespondToSelector:sProxyConfigurations];
        }
    });
    return supported;
}

#pragma mark - Fail-closed protocol

// Used only if a configuration cannot be given the tunnel proxy. Every web
// request on that configuration fails instead of being sent directly.
@interface YTMUWGBlockedURLProtocol : NSURLProtocol
@end
@implementation YTMUWGBlockedURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *scheme = request.URL.scheme.lowercaseString;
    return [@[@"http", @"https", @"ws", @"wss"] containsObject:scheme ?: @""];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    atomic_fetch_add(&gBlockedRequests, 1);
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
}
- (void)stopLoading {}
@end

static void BlockConfiguration(NSURLSessionConfiguration *config) {
    atomic_fetch_add(&gProxyFailures, 1);
    NSArray *classes = config.protocolClasses ?: @[];
    if (![classes containsObject:YTMUWGBlockedURLProtocol.class])
        config.protocolClasses = [@[YTMUWGBlockedURLProtocol.class] arrayByAddingObjectsFromArray:classes];
}

static void ApplyProxy(NSURLSessionConfiguration *config) {
    if (!gActive || ![config isKindOfClass:NSURLSessionConfiguration.class]) return;
    @try {
        char port[8];
        snprintf(port, sizeof(port), "%d", gPort);
        nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", port);
        id proxy = endpoint ? (__bridge_transfer id)pCreateSocks((__bridge void *)endpoint) : nil;
        if (!proxy) {
            BlockConfiguration(config);
            return;
        }
        pSetUserPass((__bridge void *)proxy, gUser, gPass);
        pSetFailover((__bridge void *)proxy, false);
        config.connectionProxyDictionary = nil;
        ((void (*)(id, SEL, id))objc_msgSend)(config, sSetProxyConfigurations, @[proxy]);
        atomic_fetch_add(&gConfigsProxied, 1);
    } @catch (NSException *exception) {
        BlockConfiguration(config);
    }
}

#pragma mark - Hooks

static IMP ReplaceMethod(Class cls, SEL sel, IMP replacement) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    // class_addMethod first so an inherited implementation is not modified for
    // unrelated superclasses.
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method)))
        original = method_setImplementation(class_getInstanceMethod(cls, sel), replacement);
    return original;
}

static id (*origDefault)(id, SEL);
static id (*origEphemeral)(id, SEL);
static id (*origBackground)(id, SEL, id);
static id (*origSession)(id, SEL, id);
static id (*origSessionDelegate)(id, SEL, id, id, id);
static id (*origShared)(id, SEL);
static void (*origSetHTTP3)(id, SEL, BOOL);
static BOOL (*origGetHTTP3)(id, SEL);
static id (*origDataURL)(id, SEL, id);
static id (*origDataURLOptions)(id, SEL, id, NSUInteger, NSError **);

static id HookDefault(id self, SEL _cmd) {
    NSURLSessionConfiguration *c = origDefault(self, _cmd);
    ApplyProxy(c);
    return c;
}
static id HookEphemeral(id self, SEL _cmd) {
    NSURLSessionConfiguration *c = origEphemeral(self, _cmd);
    ApplyProxy(c);
    return c;
}
static id HookBackground(id self, SEL _cmd, id identifier) {
    NSURLSessionConfiguration *c = origBackground(self, _cmd, identifier);
    atomic_fetch_add(&gBackgroundConfigs, 1);
    ApplyProxy(c);
    return c;
}
// The session constructors re-apply the proxy to a copy, so later changes to a
// configuration object by the app cannot remove it.
static id HookSession(id self, SEL _cmd, NSURLSessionConfiguration *config) {
    NSURLSessionConfiguration *copy = [config copy];
    ApplyProxy(copy);
    atomic_fetch_add(&gSessionsProxied, 1);
    return origSession(self, _cmd, copy);
}
static id HookSessionDelegate(id self, SEL _cmd, NSURLSessionConfiguration *config, id delegate, id queue) {
    NSURLSessionConfiguration *copy = [config copy];
    ApplyProxy(copy);
    atomic_fetch_add(&gSessionsProxied, 1);
    return origSessionDelegate(self, _cmd, copy, delegate, queue);
}
static id HookShared(id self, SEL _cmd) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
        atomic_fetch_add(&gSharedReplaced, 1);
    });
    return session;
}
// The local SOCKS5 proxy carries TCP only; never ask URLSession to assume QUIC.
static void HookSetHTTP3(id self, SEL _cmd, BOOL value) {
    if (value) atomic_fetch_add(&gHTTP3Cleared, 1);
    origSetHTTP3(self, _cmd, NO);
}
static BOOL HookGetHTTP3(id self, SEL _cmd) { return NO; }

static BOOL IsWebURL(id url) {
    if (![url isKindOfClass:NSURL.class]) return NO;
    NSString *scheme = [url scheme].lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

// -[NSData dataWithContentsOfURL:] loads web URLs on a private Foundation path.
// YTMusicUltimate uses it for HLS manifests and cover art, so route it through
// a tunnelled session instead.
static NSData *TunnelFetch(NSURL *url, NSError **outError) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
        c.timeoutIntervalForRequest = 30;
        c.timeoutIntervalForResource = 120;
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 4;
        session = [NSURLSession sessionWithConfiguration:c delegate:nil delegateQueue:queue];
    });
    atomic_fetch_add(&gDataURLFetches, 1);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *result;
    __block NSError *failure;
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (!error && status >= 200 && status < 300) result = data ?: [NSData data];
        else failure = error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil];
        dispatch_semaphore_signal(done);
    }] resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 125 * NSEC_PER_SEC)))
        failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
    if (!result && outError) *outError = failure;
    return result;
}

static id MutableIfNeeded(id cls, NSData *data) {
    if (!data) return nil;
    return [cls isSubclassOfClass:NSMutableData.class] ? [data mutableCopy] : data;
}
static id HookDataURL(id self, SEL _cmd, id url) {
    if (!IsWebURL(url)) return origDataURL(self, _cmd, url);
    return MutableIfNeeded(self, TunnelFetch(url, NULL));
}
static id HookDataURLOptions(id self, SEL _cmd, id url, NSUInteger options, NSError **error) {
    if (!IsWebURL(url)) return origDataURLOptions(self, _cmd, url, options, error);
    return MutableIfNeeded(self, TunnelFetch(url, error));
}

static void InstallSessionHooks(void) {
    Class configMeta = object_getClass(NSURLSessionConfiguration.class);
    Class sessionMeta = object_getClass(NSURLSession.class);
    origDefault = (void *)ReplaceMethod(configMeta, @selector(defaultSessionConfiguration), (IMP)HookDefault);
    origEphemeral = (void *)ReplaceMethod(configMeta, @selector(ephemeralSessionConfiguration), (IMP)HookEphemeral);
    origBackground = (void *)ReplaceMethod(configMeta, @selector(backgroundSessionConfigurationWithIdentifier:), (IMP)HookBackground);
    origSession = (void *)ReplaceMethod(sessionMeta, @selector(sessionWithConfiguration:), (IMP)HookSession);
    origSessionDelegate = (void *)ReplaceMethod(sessionMeta, @selector(sessionWithConfiguration:delegate:delegateQueue:), (IMP)HookSessionDelegate);
    origShared = (void *)ReplaceMethod(sessionMeta, @selector(sharedSession), (IMP)HookShared);

    SEL setHTTP3 = NSSelectorFromString(@"setAssumesHTTP3Capable:");
    SEL getHTTP3 = NSSelectorFromString(@"assumesHTTP3Capable");
    Method m = class_getInstanceMethod(NSMutableURLRequest.class, setHTTP3);
    if (m && method_getNumberOfArguments(m) == 3)
        origSetHTTP3 = (void *)ReplaceMethod(NSMutableURLRequest.class, setHTTP3, (IMP)HookSetHTTP3);
    m = class_getInstanceMethod(NSURLRequest.class, getHTTP3);
    if (m && method_getNumberOfArguments(m) == 2)
        origGetHTTP3 = (void *)ReplaceMethod(NSURLRequest.class, getHTTP3, (IMP)HookGetHTTP3);

    Class dataMeta = object_getClass(NSData.class);
    origDataURL = (void *)ReplaceMethod(dataMeta, @selector(dataWithContentsOfURL:), (IMP)HookDataURL);
    origDataURLOptions = (void *)ReplaceMethod(dataMeta, @selector(dataWithContentsOfURL:options:error:), (IMP)HookDataURLOptions);
}

NSDictionary *YTMUWGProxyCounters(void) {
    return @{
        @"configs": @(atomic_load(&gConfigsProxied)),
        @"sessions": @(atomic_load(&gSessionsProxied)),
        @"backgroundConfigs": @(atomic_load(&gBackgroundConfigs)),
        @"sharedReplaced": @(atomic_load(&gSharedReplaced)),
        @"proxyFailures": @(atomic_load(&gProxyFailures)),
        @"blockedRequests": @(atomic_load(&gBlockedRequests)),
        @"http3Cleared": @(atomic_load(&gHTTP3Cleared)),
        @"dataURLFetches": @(atomic_load(&gDataURLFetches)),
        @"ffmpegProxy": @(gFFmpegProxy),
        @"rebinds": @(atomic_load(&gRebinds)),
    };
}

#pragma mark - Keychain

static NSMutableDictionary *KeychainQuery(void) {
    return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: kKeychainService,
              (__bridge id)kSecAttrAccount: kKeychainAccount} mutableCopy];
}

static NSString *ReadProfile(OSStatus *outStatus) {
#ifdef YTMUWG_TESTING
    NSString *path = TestEnv(@"YTMUWG_TEST_PROFILE");
    if (path) return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
#endif
    NSMutableDictionary *query = KeychainQuery();
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (outStatus) *outStatus = status;
    if (status != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

BOOL YTMUWGHasProfile(void) { return ReadProfile(NULL).length > 0; }

static NSDictionary *JSONFromGo(char *raw) {
    if (!raw) return nil;
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
    YTMUWGFree(raw);
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

NSDictionary *YTMUWGInspectProfile(NSString *text, NSString **reason) {
    NSDictionary *summary = JSONFromGo(YTMUWGInspect((char *)text.UTF8String));
    if (![summary[@"ok"] boolValue]) {
        if (reason) *reason = [summary[@"error"] isKindOfClass:NSString.class] ? summary[@"error"] : @"invalid profile";
        return nil;
    }
    return summary;
}

NSDictionary *YTMUWGStoredProfileSummary(void) {
    NSString *text = ReadProfile(NULL);
    return text ? YTMUWGInspectProfile(text, NULL) : nil;
}

BOOL YTMUWGImportProfile(NSString *text, NSString **reason) {
    if (!YTMUWGInspectProfile(text, reason)) return NO;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *query = KeychainQuery();
    NSDictionary *attributes = @{(__bridge id)kSecValueData: data,
                                 (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        [query addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
    if (status != errSecSuccess) {
        if (reason) *reason = [NSString stringWithFormat:@"Keychain error %d", (int)status];
        return NO;
    }
    return YES;
}

BOOL YTMUWGDeleteProfile(NSString **reason) {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)KeychainQuery());
    if (status != errSecSuccess && status != errSecItemNotFound) {
        if (reason) *reason = [NSString stringWithFormat:@"Keychain error %d", (int)status];
        return NO;
    }
    YTMUWGSetSettingEnabled(NO);
    return YES;
}

#pragma mark - Engine

NSDictionary *YTMUWGEngineStatus(void) {
    if (!gActive) return @{@"running": @NO};
    return JSONFromGo(YTMUWGStatus()) ?: @{@"running": @NO};
}

static void StartEngine(void) {
    dispatch_async(gQueue, ^{
        YTMUWGState state = YTMUWGCurrentState();
        if (state == YTMUWGStateRunning || state == YTMUWGStateFailed) return;
        OSStatus status = errSecSuccess;
        NSString *profile = ReadProfile(&status);
        if (!profile.length) {
            // Locked Keychain (e.g. background launch before first unlock):
            // keep blocking traffic and retry when the app becomes active.
            atomic_store(&gState, YTMUWGStateWaitingProfile);
            return;
        }
        atomic_store(&gState, YTMUWGStateStarting);
        int fd = gListenerFD;
        gListenerFD = -1; // ownership moves to Go
        int port = YTMUWGStart((char *)profile.UTF8String, gUser, gPass, fd, gPort);
        atomic_store(&gState, port == gPort ? YTMUWGStateRunning : YTMUWGStateFailed);
    });
}

void YTMUWGRequestRebind(NSString *reason) {
    if (!gActive) return;
    dispatch_async(gQueue, ^{
        YTMUWGState state = YTMUWGCurrentState();
        if (state == YTMUWGStateWaitingProfile) {
            StartEngine();
        } else if (state == YTMUWGStateRunning) {
            YTMUWGRebind();
            atomic_fetch_add(&gRebinds, 1);
        }
    });
}

void YTMUWGLookupInTunnel(NSString *host, void (^completion)(NSDictionary *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = gActive ? JSONFromGo(YTMUWGLookup((char *)host.UTF8String)) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result ?: @{@"ok": @NO, @"error": @"tunnel not active"}); });
    });
}

NSURLSession *YTMUWGTunnelSession(id<NSURLSessionDelegate> delegate) {
    if (!gActive) return nil;
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    c.timeoutIntervalForRequest = 15;
    c.timeoutIntervalForResource = 25;
    c.URLCache = nil;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    ApplyProxy(c); // explicit, independent of the class-method hooks
    return [NSURLSession sessionWithConfiguration:c delegate:delegate delegateQueue:nil];
}

static BOOL ReserveListener(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {0};
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t len = sizeof(addr);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) || listen(fd, 256) ||
        getsockname(fd, (struct sockaddr *)&addr, &len)) {
        close(fd);
        return NO;
    }
    gListenerFD = fd;
    gPort = ntohs(addr.sin_port);
    return YES;
}

static void RandomHex(char out[33]) {
    uint8_t bytes[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) arc4random_buf(bytes, sizeof(bytes));
    for (int i = 0; i < 16; i++) snprintf(out + i * 2, 3, "%02x", bytes[i]);
}

static void ObserveLifecycle(void) {
    // UIKit notification names as strings: this file is Foundation-only so the
    // same core also runs in the macOS test harness.
    // Rebind only after real backgrounding (iOS may have defuncted the sockets),
    // not after Control Center or a notification banner, to avoid needless
    // interruptions of a playing stream.
    static CFAbsoluteTime backgroundSince;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:@"UIApplicationDidEnterBackgroundNotification" object:nil queue:nil usingBlock:^(NSNotification *note) {
        backgroundSince = CFAbsoluteTimeGetCurrent();
    }];
    [center addObserverForName:@"UIApplicationWillEnterForegroundNotification" object:nil queue:nil usingBlock:^(NSNotification *note) {
        if (backgroundSince > 0 && CFAbsoluteTimeGetCurrent() - backgroundSince > 15) YTMUWGRequestRebind(@"foreground");
        backgroundSince = 0;
    }];
    for (NSString *name in @[@"UIApplicationDidBecomeActiveNotification", @"UIApplicationProtectedDataDidBecomeAvailable"]) {
        [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            // Starts the engine if the Keychain was locked at launch; no rebind.
            if (YTMUWGCurrentState() == YTMUWGStateWaitingProfile) YTMUWGRequestRebind(name);
        }];
    }
    static nw_path_monitor_t monitor;
    static NSString *lastSignature;
    monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(monitor, gQueue);
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        NSString *signature = [NSString stringWithFormat:@"%d%d%d%d", (int)nw_path_get_status(path),
            nw_path_uses_interface_type(path, nw_interface_type_wifi), nw_path_uses_interface_type(path, nw_interface_type_cellular),
            nw_path_uses_interface_type(path, nw_interface_type_wired)];
        // Wi-Fi <-> cellular: reopen the WireGuard UDP socket on the new path.
        if (lastSignature && ![signature isEqualToString:lastSignature] && nw_path_get_status(path) == nw_path_status_satisfied)
            YTMUWGRequestRebind(@"path");
        lastSignature = signature;
    });
    nw_path_monitor_start(monitor);
}

__attribute__((constructor)) static void YTMUWGInit(void) {
    @autoreleasepool {
        gQueue = dispatch_queue_create("ytmu.wireguard", DISPATCH_QUEUE_SERIAL);
        if (!YTMUWGSettingEnabled() || !YTMUMasterEnabled()) return;
        if (!YTMUWGIsSupportedOS()) {
            atomic_store(&gState, YTMUWGStateUnsupported);
            return;
        }
        RandomHex(gUser);
        RandomHex(gPass);
        // Reserve the loopback port synchronously: hooks may run before the Go
        // runtime of this image is initialized, and Go must never be entered
        // from a constructor (it would wait for its own initializer).
        if (!ReserveListener()) gPort = 1; // closed port: fail closed, never direct
        gActive = YES;
        atomic_store(&gState, YTMUWGStateStarting);
        InstallSessionHooks();
        YTMUWGInstallTransportPatches();
        // FFmpeg (YTMusicUltimate downloads) has its own HTTP stack; its tls
        // protocol honours http_proxy and tunnels HTTPS via authenticated CONNECT.
        char proxyURL[128];
        snprintf(proxyURL, sizeof(proxyURL), "http://%s:%s@127.0.0.1:%d", gUser, gPass, gPort);
        gFFmpegProxy = setenv("http_proxy", proxyURL, 1) == 0;
        unsetenv("no_proxy");
        ObserveLifecycle();
        StartEngine();
    }
}

#pragma mark - Diagnostics

NSString *YTMUWGHostCategory(NSString *host) {
    NSString *h = host.lowercaseString ?: @"";
    BOOL (^is)(NSString *) = ^BOOL(NSString *domain) { return [h isEqualToString:domain] || [h hasSuffix:[@"." stringByAppendingString:domain]]; };
    if (is(@"googlevideo.com") || is(@"gvt1.com") || is(@"c.youtube.com")) return @"media";
    if (is(@"youtube.com") || is(@"googleapis.com") || is(@"ytimg.com") || is(@"ggpht.com")) return @"api";
    return @"other";
}

NSString *YTMUWGRedactText(NSString *text) {
    char *raw = YTMUWGRedact((char *)(text ?: @"").UTF8String);
    if (!raw) return @"";
    NSString *out = [NSString stringWithUTF8String:raw] ?: @"";
    YTMUWGFree(raw);
    return out;
}

static NSString *DeviceModel(void) {
    struct utsname u;
    uname(&u);
    return [NSString stringWithUTF8String:u.machine] ?: @"?";
}

static NSString *N(id v) { return v ? [NSString stringWithFormat:@"%@", v] : @"-"; }

NSString *YTMUWGDiagnosticsReport(NSDictionary<NSString *, NSString *> *checks) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSProcessInfo *info = NSProcessInfo.processInfo;
    [lines addObject:[NSString stringWithFormat:@"YTMU app-local WireGuard diagnostics v%@", YTMUWGVersion]];
    [lines addObject:[NSString stringWithFormat:@"app: YouTube Music %@ | OS %@ | %@", YTMUWGAppVersion(), info.operatingSystemVersionString, DeviceModel()]];
    [lines addObject:[NSString stringWithFormat:@"setting.enabled: %@ | active this launch: %@ | supported OS: %@",
        YTMUWGSettingEnabled() ? @"yes" : @"no", gActive ? @"yes" : @"no", YTMUWGIsSupportedOS() ? @"yes" : @"no"]];
    [lines addObject:[NSString stringWithFormat:@"state: %@", YTMUWGStateDescription(YTMUWGCurrentState())]];

    NSDictionary *st = YTMUWGEngineStatus();
    if ([st[@"running"] boolValue]) {
        long long age = [st[@"handshakeAgeSec"] longLongValue];
        [lines addObject:[NSString stringWithFormat:@"wireguard.handshake: %@ | wg rx %@ B tx %@ B | uptime %@ s",
            age < 0 ? @"none yet" : [NSString stringWithFormat:@"%lld s ago", age], N(st[@"wgRxBytes"]), N(st[@"wgTxBytes"]), N(st[@"uptimeSec"])]];
        NSDictionary *c = st[@"connections"], *cat = st[@"categories"], *b = st[@"proxyBytes"], *bind = st[@"bind"];
        [lines addObject:[NSString stringWithFormat:@"tunnel.connections: total %@ (hostname %@, ip %@) active %@ failed %@ dnsFailed %@",
            N(c[@"total"]), N(c[@"domainTargets"]), N(c[@"ipTargets"]), N(c[@"active"]), N(c[@"failed"]), N(c[@"dnsFailed"])]];
        [lines addObject:[NSString stringWithFormat:@"tunnel.by-protocol: socks5 %@ | http-connect(FFmpeg) %@ | auth rejected %@ | bad requests %@",
            N(c[@"socks"]), N(c[@"httpConnect"]), N(c[@"authRejected"]), N(c[@"badRequests"])]];
        [lines addObject:[NSString stringWithFormat:@"tunnel.destinations: media-cdn %@ | youtube-api %@ | other %@",
            N(cat[@"media"]), N(cat[@"api"]), N(cat[@"other"])]];
        [lines addObject:[NSString stringWithFormat:@"tunnel.bytes: up %@ down %@ | bind updates %@ failures %@ relistens %@ | endpoint resolved by device DNS: %@",
            N(b[@"up"]), N(b[@"down"]), N(bind[@"updates"]), N(bind[@"failures"]), N(bind[@"relistens"]), [st[@"endpointResolvedLocally"] boolValue] ? @"yes" : @"no"]];
    } else {
        [lines addObject:[NSString stringWithFormat:@"engine: not running %@", N(st[@"error"])]];
    }
    NSDictionary *p = YTMUWGProxyCounters();
    [lines addObject:[NSString stringWithFormat:@"proxy.applied: configs %@ sessions %@ background %@ sharedSession %@ | failures %@ blocked %@",
        p[@"configs"], p[@"sessions"], p[@"backgroundConfigs"], p[@"sharedReplaced"], p[@"proxyFailures"], p[@"blockedRequests"]]];
    [lines addObject:[NSString stringWithFormat:@"proxy.other: http3 requests cleared %@ | NSData URL loads tunnelled %@ | FFmpeg http_proxy %@ | rebinds %@",
        p[@"http3Cleared"], p[@"dataURLFetches"], [p[@"ffmpegProxy"] boolValue] ? @"set" : @"not set", p[@"rebinds"]]];
    [lines addObjectsFromArray:YTMUWGTransportReportLines()];
    for (NSString *key in [checks.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [lines addObject:[NSString stringWithFormat:@"check.%@: %@", key, checks[key]]];
    [lines addObject:@"note: a country/HTTPS check passing does not prove music playback; verify play, next track and lock-screen playback."];
    return YTMUWGRedactText([lines componentsJoinedByString:@"\n"]);
}
