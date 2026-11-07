#import <Foundation/Foundation.h>

// App-local WireGuard for YouTube Music.
//
// No system VPN, Network Extension, TUN interface or route change is used.
// wireguard-go + gVisor netstack run inside this process; an authenticated
// SOCKS5 server on 127.0.0.1 is applied to every NSURLSession configuration via
// nw_proxy_config (iOS 17+) with failover to direct connections disabled.

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YTMUWGState) {
    YTMUWGStateOff = 0,          // disabled in settings for this launch
    YTMUWGStateUnsupported,      // iOS < 17 or proxy API missing
    YTMUWGStateWaitingProfile,   // enabled; profile not readable yet (Keychain locked)
    YTMUWGStateStarting,
    YTMUWGStateRunning,
    YTMUWGStateFailed,           // engine failed; traffic is blocked, not sent direct
};

FOUNDATION_EXPORT NSString *const YTMUWGVersion;

// Settings (take effect on next launch).
BOOL YTMUWGSettingEnabled(void);
void YTMUWGSetSettingEnabled(BOOL enabled);
BOOL YTMUWGSettingForceNativeStack(void);
void YTMUWGSetSettingForceNativeStack(BOOL enabled);

BOOL YTMUWGIsSupportedOS(void);
YTMUWGState YTMUWGCurrentState(void);
BOOL YTMUWGActiveThisLaunch(void);
NSString *YTMUWGStateDescription(YTMUWGState state);

// Profile (Keychain, this device only). Summaries never contain keys.
BOOL YTMUWGHasProfile(void);
NSDictionary *_Nullable YTMUWGInspectProfile(NSString *text, NSString *_Nullable *_Nullable reason);
BOOL YTMUWGImportProfile(NSString *text, NSString *_Nullable *_Nullable reason);
BOOL YTMUWGDeleteProfile(NSString *_Nullable *_Nullable reason);
NSDictionary *_Nullable YTMUWGStoredProfileSummary(void);

// Engine.
NSDictionary *YTMUWGEngineStatus(void);
void YTMUWGLookupInTunnel(NSString *host, void (^completion)(NSDictionary *result));
void YTMUWGRequestRebind(NSString *reason);

// A session that goes through the tunnel (used by diagnostics). Returns nil
// when the tunnel is not active in this launch.
NSURLSession *_Nullable YTMUWGTunnelSession(id<NSURLSessionDelegate> _Nullable delegate);

// Counters of proxy application, for diagnostics.
NSDictionary *YTMUWGProxyCounters(void);

// Text helpers. Diagnostics are always passed through YTMUWGRedact.
NSString *YTMUWGRedactText(NSString *text);
NSString *YTMUWGDiagnosticsReport(NSDictionary<NSString *, NSString *> *_Nullable checks);

// Implemented in YTMUWGTransport.m.
void YTMUWGInstallTransportPatches(void);
NSArray<NSString *> *YTMUWGTransportReportLines(void);
NSArray<NSString *> *YTMUWGScanTransportClasses(void);

// Implemented in YTMUWGCore.m; used by YTMUWGTransport.m.
NSString *YTMUWGAppVersion(void);
NSString *YTMUWGHostCategory(NSString *_Nullable host);

NS_ASSUME_NONNULL_END
