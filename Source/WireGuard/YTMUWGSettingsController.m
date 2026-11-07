#import "YTMUWGSettingsController.h"
#import "YTMUWGCore.h"
#import <objc/message.h>

@interface NSBundle (YTMusicUltimate)
@property (class, nonatomic, readonly) NSBundle *ytmu_defaultBundle;
@end

// Localized string with an English fallback for languages without the key.
#define WGLOC(key, fallback) [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil]

typedef NS_ENUM(NSInteger, WGSection) { WGSectionTunnel, WGSectionProfile, WGSectionChecks, WGSectionAdvanced, WGSectionResult, WGSectionCount };
typedef NS_ENUM(NSInteger, WGCheckRow) { WGCheckCountry, WGCheckConnection, WGCheckScan, WGCheckCopy, WGCheckCount };

@interface YTMUWGSettingsController ()
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UISwitch *forceSwitch;
@property (nonatomic, copy) NSDictionary *profile;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *checks;
@property (nonatomic, copy) NSString *resultText;
@property (nonatomic, copy) NSArray<NSString *> *scanLines;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic) BOOL busy;
@end

@implementation YTMUWGSettingsController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = WGLOC(@"WG_TITLE", @"App-local WireGuard");
    self.checks = [NSMutableDictionary dictionary];
    self.enabledSwitch = [UISwitch new];
    [self.enabledSwitch addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
    self.forceSwitch = [UISwitch new];
    [self.forceSwitch addTarget:self action:@selector(toggleForce:) forControlEvents:UIControlEventValueChanged];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 48;
    [self reloadState];
}

- (void)reloadState {
    self.profile = YTMUWGStoredProfileSummary();
    self.enabledSwitch.on = YTMUWGSettingEnabled();
    self.forceSwitch.on = YTMUWGSettingForceNativeStack();
    [self.tableView reloadData];
}

#pragma mark - Text

- (NSString *)stateLine {
    YTMUWGState state = YTMUWGCurrentState();
    NSString *text;
    switch (state) {
        case YTMUWGStateOff: text = WGLOC(@"WG_STATE_OFF", @"Off in this launch"); break;
        case YTMUWGStateUnsupported: text = WGLOC(@"WG_STATE_UNSUPPORTED", @"Requires iOS 17 or later"); break;
        case YTMUWGStateWaitingProfile: text = WGLOC(@"WG_STATE_WAITING", @"Waiting for Keychain (unlock the device)"); break;
        case YTMUWGStateStarting: text = WGLOC(@"WG_STATE_STARTING", @"Starting"); break;
        case YTMUWGStateRunning: text = WGLOC(@"WG_STATE_RUNNING", @"Running"); break;
        case YTMUWGStateFailed: text = WGLOC(@"WG_STATE_FAILED", @"Failed — app traffic is blocked, not sent directly"); break;
    }
    if (state == YTMUWGStateRunning) {
        NSDictionary *status = YTMUWGEngineStatus();
        long long age = [status[@"handshakeAgeSec"] longLongValue];
        NSString *handshake = age < 0 ? WGLOC(@"WG_HANDSHAKE_NONE", @"no handshake yet")
                                      : [NSString stringWithFormat:WGLOC(@"WG_HANDSHAKE_AGO", @"handshake %lld s ago"), age];
        text = [NSString stringWithFormat:@"%@ · %@", text, handshake];
    }
    if (YTMUWGSettingEnabled() != YTMUWGActiveThisLaunch() && state != YTMUWGStateUnsupported)
        text = [text stringByAppendingFormat:@"\n%@", WGLOC(@"WG_RESTART_NEEDED", @"Restart the app to apply the change")];
    return text;
}

- (NSArray<NSArray<NSString *> *> *)profileRows {
    if (!self.profile) return @[];
    NSDictionary *p = self.profile;
    NSString *extra = [NSString stringWithFormat:@"MTU %@ · Keepalive %@ · PSK %@", p[@"mtu"],
                       [p[@"keepalive"] integerValue] ? p[@"keepalive"] : @"-",
                       [p[@"presharedKey"] boolValue] ? WGLOC(@"WG_YES", @"yes") : WGLOC(@"WG_NO", @"no")];
    NSString *endpoint = p[@"endpoint"] ?: @"-";
    if ([p[@"endpointHostname"] boolValue])
        endpoint = [endpoint stringByAppendingFormat:@"\n%@", WGLOC(@"WG_ENDPOINT_DNS", @"Host name: looked up once by the device's DNS to reach the server")];
    return @[
        @[WGLOC(@"WG_ADDRESS", @"Address"), [p[@"addresses"] componentsJoinedByString:@", "] ?: @"-"],
        @[@"DNS", [[p[@"dns"] componentsJoinedByString:@", "] ?: @"-" stringByAppendingFormat:@"\n%@", WGLOC(@"WG_DNS_TUNNEL", @"Queried through the tunnel")]],
        @[WGLOC(@"WG_ENDPOINT", @"Endpoint"), endpoint],
        @[WGLOC(@"WG_OPTIONS", @"Options"), extra],
    ];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return WGSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case WGSectionTunnel: return 2;
        case WGSectionProfile: return (NSInteger)self.profileRows.count + 2 + (self.profile ? 1 : 0);
        case WGSectionChecks: return WGCheckCount;
        case WGSectionAdvanced: return 1;
        case WGSectionResult: return self.resultText.length ? 1 : 0;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case WGSectionTunnel: return WGLOC(@"WG_SECTION_TUNNEL", @"Tunnel");
        case WGSectionProfile: return WGLOC(@"WG_SECTION_PROFILE", @"WireGuard profile");
        case WGSectionChecks: return WGLOC(@"WG_SECTION_CHECKS", @"Checks");
        case WGSectionAdvanced: return WGLOC(@"WG_SECTION_ADVANCED", @"Advanced");
        case WGSectionResult: return self.resultText.length ? WGLOC(@"WG_SECTION_RESULT", @"Result") : nil;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case WGSectionTunnel:
            return WGLOC(@"WG_FOOTER_TUNNEL", @"No system VPN or network extension is used. YouTube Music's own requests and music streams go through WireGuard inside this app; if the tunnel fails, requests fail instead of going direct. Restart the app after changing this. Requires iOS 17.");
        case WGSectionProfile:
            return WGLOC(@"WG_FOOTER_PROFILE", @"Standard WireGuard .conf with one [Peer] and AllowedIPs 0.0.0.0/0. The private key is stored only in this device's Keychain and is never shown or copied into diagnostics.");
        case WGSectionChecks:
            return WGLOC(@"WG_FOOTER_CHECKS", @"A successful country check does not mean music will play. Also test playback, next track and lock-screen playback, then copy the diagnostics right after any playback error.");
        case WGSectionAdvanced:
            return WGLOC(@"WG_FOOTER_ADVANCED", @"For YouTube Music versions not verified yet: force the music loader's networkStackType to 0 (URLSession). Leave off unless the diagnostics show Envoy loader tasks.");
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSInteger row = indexPath.row;

    if (indexPath.section == WGSectionTunnel) {
        if (row == 0) {
            cell.textLabel.text = WGLOC(@"WG_ENABLE", @"Use WireGuard in this app");
            cell.accessoryView = self.enabledSwitch;
            self.enabledSwitch.enabled = YTMUWGIsSupportedOS();
        } else {
            cell.textLabel.text = WGLOC(@"WG_STATUS", @"Status");
            cell.detailTextLabel.text = [self stateLine];
        }
    } else if (indexPath.section == WGSectionProfile) {
        NSArray *rows = self.profileRows;
        if (row < (NSInteger)rows.count) {
            cell.textLabel.text = rows[row][0];
            cell.detailTextLabel.text = rows[row][1];
        } else {
            NSInteger action = row - (NSInteger)rows.count;
            NSArray *titles = @[self.profile ? WGLOC(@"WG_REIMPORT_FILE", @"Replace from .conf file") : WGLOC(@"WG_IMPORT_FILE", @"Import .conf file"),
                                WGLOC(@"WG_IMPORT_PASTEBOARD", @"Import from clipboard"),
                                WGLOC(@"WG_DELETE_PROFILE", @"Delete profile")];
            cell.textLabel.text = titles[action];
            cell.textLabel.textColor = action == 2 ? UIColor.systemRedColor : UIColor.systemBlueColor;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (indexPath.section == WGSectionChecks) {
        NSArray *titles = @[WGLOC(@"WG_CHECK_COUNTRY", @"Check country and exit IP"),
                            WGLOC(@"WG_CHECK_CONNECTION", @"Run connection diagnostics (DNS · HTTPS · 206)"),
                            WGLOC(@"WG_CHECK_SCAN", @"Scan transport classes of this version"),
                            WGLOC(@"WG_CHECK_COPY", @"Copy diagnostics")];
        cell.textLabel.text = titles[row];
        cell.textLabel.textColor = self.busy && row < WGCheckCopy ? UIColor.secondaryLabelColor : UIColor.systemBlueColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (indexPath.section == WGSectionAdvanced) {
        cell.textLabel.text = WGLOC(@"WG_FORCE_STACK", @"Force URLSession music loader (unverified versions)");
        cell.accessoryView = self.forceSwitch;
    } else {
        cell.textLabel.text = self.resultText;
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == WGSectionProfile) {
        NSInteger action = indexPath.row - (NSInteger)self.profileRows.count;
        if (action == 0) [self pickFile];
        else if (action == 1) [self importText:UIPasteboard.generalPasteboard.string fromPasteboard:YES];
        else if (action == 2) [self confirmDelete];
    } else if (indexPath.section == WGSectionChecks) {
        if (indexPath.row == WGCheckCopy) [self copyDiagnostics];
        else if (self.busy) return;
        else if (indexPath.row == WGCheckCountry) [self runCountryCheck];
        else if (indexPath.row == WGCheckConnection) [self runConnectionChecks];
        else if (indexPath.row == WGCheckScan) [self runScan];
    }
}

#pragma mark - Settings actions

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:WGLOC(@"WG_OK", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)offerRestart {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:WGLOC(@"WG_RESTART_TITLE", @"Restart required")
        message:WGLOC(@"WG_RESTART_MESSAGE", @"Fully close and reopen YouTube Music to apply this setting.") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:WGLOC(@"WG_LATER", @"Later") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:WGLOC(@"WG_CLOSE_NOW", @"Close app now") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SEL suspend = NSSelectorFromString(@"suspend");
        if ([UIApplication.sharedApplication respondsToSelector:suspend])
            ((void (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, suspend);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleEnabled:(UISwitch *)sender {
    if (sender.on && !YTMUWGIsSupportedOS()) {
        sender.on = NO;
        [self alert:WGLOC(@"WG_UNSUPPORTED_TITLE", @"Not supported") message:WGLOC(@"WG_STATE_UNSUPPORTED", @"Requires iOS 17 or later")];
        return;
    }
    if (sender.on && !YTMUWGHasProfile()) {
        sender.on = NO;
        [self alert:WGLOC(@"WG_NO_PROFILE_TITLE", @"No profile") message:WGLOC(@"WG_NO_PROFILE", @"Import a WireGuard .conf file first.")];
        return;
    }
    YTMUWGSetSettingEnabled(sender.on);
    [self reloadState];
    [self offerRestart];
}

- (void)toggleForce:(UISwitch *)sender {
    YTMUWGSetSettingForceNativeStack(sender.on);
    [self offerRestart];
}

#pragma mark - Profile import

- (void)pickFile {
    // public.data/public.item cover .conf files, which have no registered type.
    // initWithDocumentTypes:inMode: works on every iOS version the tweak supports.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.data", @"public.text", @"public.item"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    NSData *data = size.unsignedLongLongValue <= 65536 ? [NSData dataWithContentsOfURL:url options:0 error:nil] : nil;
    if (scoped) [url stopAccessingSecurityScopedResource];
    // The picker's imported copy lives in this app's tmp/Inbox; remove it so the
    // private key exists only in the Keychain.
    if ([url.path hasPrefix:NSTemporaryDirectory()] || [url.path containsString:@"/tmp/"] || [url.path containsString:@"-Inbox/"])
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    [self importText:text fromPasteboard:NO];
}

- (void)importText:(NSString *)text fromPasteboard:(BOOL)fromPasteboard {
    if (!text.length || text.length > 65536) {
        [self alert:WGLOC(@"WG_IMPORT_FAILED", @"Could not import") message:WGLOC(@"WG_IMPORT_HINT", @"Choose a standard WireGuard .conf file (64 KB or smaller).")];
        return;
    }
    NSString *reason = nil;
    if (!YTMUWGImportProfile(text, &reason)) {
        [self alert:WGLOC(@"WG_IMPORT_FAILED", @"Could not import")
            message:[NSString stringWithFormat:@"%@\n\n%@", WGLOC(@"WG_IMPORT_HINT", @"Choose a standard WireGuard .conf file (64 KB or smaller)."), reason ?: @""]];
        return;
    }
    // Do not leave the private key on the clipboard. Only touch the pasteboard
    // when the profile came from it (reading it would otherwise prompt).
    if (fromPasteboard) UIPasteboard.generalPasteboard.string = @"";
    [self reloadState];
    if (!YTMUWGSettingEnabled() && YTMUWGIsSupportedOS()) {
        YTMUWGSetSettingEnabled(YES);
        [self reloadState];
    }
    [self offerRestart];
}

- (void)confirmDelete {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:WGLOC(@"WG_DELETE_PROFILE", @"Delete profile")
        message:WGLOC(@"WG_DELETE_MESSAGE", @"The profile is removed from the Keychain and the tunnel is turned off after restart.") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:WGLOC(@"WG_CANCEL", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:WGLOC(@"WG_DELETE", @"Delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSString *reason = nil;
        if (!YTMUWGDeleteProfile(&reason)) [self alert:WGLOC(@"WG_DELETE_FAILED", @"Could not delete") message:reason ?: @""];
        [self reloadState];
        [self offerRestart];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Checks

- (void)setBusy:(BOOL)busy text:(NSString *)text {
    self.busy = busy;
    if (text) self.resultText = text;
    [self.tableView reloadData];
}

- (BOOL)requireActive {
    if (YTMUWGActiveThisLaunch()) return YES;
    [self alert:WGLOC(@"WG_NOT_ACTIVE_TITLE", @"Tunnel is not active")
        message:WGLOC(@"WG_NOT_ACTIVE", @"Turn it on, then fully close and reopen the app. Turn off any system VPN before checking.")];
    return NO;
}

- (void)fetch:(NSString *)urlString range:(NSString *)range completion:(void (^)(NSHTTPURLResponse *response, NSData *data, NSError *error, NSTimeInterval seconds))completion {
    if (!self.session) self.session = YTMUWGTunnelSession(nil);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    if (range) [request setValue:range forHTTPHeaderField:@"Range"];
    NSDate *start = [NSDate date];
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSTimeInterval seconds = -start.timeIntervalSinceNow;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil, data, error, seconds);
        });
    }] resume];
}

static NSString *ErrorText(NSError *error) {
    return error ? [NSString stringWithFormat:@"%@ %ld", error.domain, (long)error.code] : @"";
}

- (void)runCountryCheck {
    if (![self requireActive]) return;
    [self setBusy:YES text:WGLOC(@"WG_CHECKING", @"Checking through the tunnel…")];
    [self fetch:@"https://www.cloudflare.com/cdn-cgi/trace" range:nil completion:^(NSHTTPURLResponse *response, NSData *data, NSError *error, NSTimeInterval seconds) {
        NSString *ip = nil, *loc = nil;
        NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"ip="]) ip = [line substringFromIndex:3];
            if ([line hasPrefix:@"loc="]) loc = [line substringFromIndex:4];
        }
        NSString *text;
        if (error || response.statusCode != 200 || !ip.length || !loc.length) {
            text = [NSString stringWithFormat:@"%@\n%@ HTTP %ld", WGLOC(@"WG_COUNTRY_FAILED", @"Country check failed."), ErrorText(error), (long)response.statusCode];
            self.checks[@"country"] = [NSString stringWithFormat:@"failed %@ HTTP %ld", ErrorText(error), (long)response.statusCode];
        } else {
            text = [NSString stringWithFormat:WGLOC(@"WG_COUNTRY_RESULT", @"Country: %@\nExit IP: %@\n\nThis only proves the tunnel works. Now play a song, skip to the next one and try lock-screen playback."), loc, ip];
            self.checks[@"country"] = [NSString stringWithFormat:@"%@ exit %@ (%.1f s)", loc, ip, seconds];
        }
        [self setBusy:NO text:text];
    }];
}

- (void)runConnectionChecks {
    if (![self requireActive]) return;
    [self setBusy:YES text:WGLOC(@"WG_CHECKING", @"Checking through the tunnel…")];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    // Lookups use the profile's DNS servers through the tunnel (Go netstack).
    NSArray<NSString *> *hosts = @[@"music.youtube.com", @"youtubei.googleapis.com", @"redirector.googlevideo.com"];
    __block NSUInteger pending = hosts.count;
    for (NSString *host in hosts) {
        YTMUWGLookupInTunnel(host, ^(NSDictionary *result) {
            BOOL ok = [result[@"ok"] boolValue];
            [lines addObject:ok ? [NSString stringWithFormat:@"DNS (tunnel) %@: OK %@ addr, %@ ms", host, result[@"count"], result[@"ms"]]
                                : [NSString stringWithFormat:@"DNS (tunnel) %@: FAIL %@", host, result[@"error"] ?: @"failed"]];
            self.checks[[@"dns." stringByAppendingString:host]] = ok ? [NSString stringWithFormat:@"ok %@ addr %@ ms", result[@"count"], result[@"ms"]]
                                                                      : [NSString stringWithFormat:@"failed %@", result[@"error"]];
            if (--pending == 0) [self checkHTTPS:lines];
        });
    }
}

- (void)checkHTTPS:(NSMutableArray<NSString *> *)lines {
    [self fetch:@"https://www.google.com/generate_204" range:nil completion:^(NSHTTPURLResponse *response, NSData *data, NSError *error, NSTimeInterval seconds) {
        BOOL ok = !error && response.statusCode == 204;
        [lines addObject:[NSString stringWithFormat:@"HTTPS www.google.com: %@ HTTP %ld %@ (%.1f s)", ok ? @"OK" : @"FAIL", (long)response.statusCode, ErrorText(error), seconds]];
        self.checks[@"https.generate_204"] = [NSString stringWithFormat:@"HTTP %ld %@ %.1fs", (long)response.statusCode, ErrorText(error), seconds];
        [self checkRange:@[@"https://www.gstatic.com/images/branding/googlelogo/2x/googlelogo_color_272x92dp.png",
                           @"https://raw.githubusercontent.com/dayanch96/YTMusicUltimate/main/LICENSE"] index:0 lines:lines];
    }];
}

// A byte-range request like the music loader's. A server that ignores Range
// (HTTP 200) is not counted as success; the next candidate is tried.
- (void)checkRange:(NSArray<NSString *> *)candidates index:(NSUInteger)index lines:(NSMutableArray<NSString *> *)lines {
    if (index >= candidates.count) {
        [lines addObject:@"HTTP 206: FAIL no candidate returned partial content"];
        self.checks[@"range206"] = @"no candidate returned 206";
        [self finishChecks:lines];
        return;
    }
    [self fetch:candidates[index] range:@"bytes=0-1023" completion:^(NSHTTPURLResponse *response, NSData *data, NSError *error, NSTimeInterval seconds) {
        NSString *contentRange = response.allHeaderFields[@"Content-Range"];
        NSString *host = [NSURL URLWithString:candidates[index]].host;
        if (!error && response.statusCode == 206 && data.length == 1024 && [contentRange hasPrefix:@"bytes 0-1023/"]) {
            [lines addObject:[NSString stringWithFormat:@"HTTP 206: OK %@ (%lu B, %.1f s)", host, (unsigned long)data.length, seconds]];
            self.checks[@"range206"] = [NSString stringWithFormat:@"206 ok host=%@ %.1fs", host, seconds];
            [self finishChecks:lines];
        } else {
            [lines addObject:[NSString stringWithFormat:@"HTTP 206: %@ HTTP %ld %@", host, (long)response.statusCode, ErrorText(error)]];
            [self checkRange:candidates index:index + 1 lines:lines];
        }
    }];
}

- (void)finishChecks:(NSMutableArray<NSString *> *)lines {
    [lines addObject:@""];
    [lines addObject:WGLOC(@"WG_CHECKS_NOTE", @"These checks do not prove music playback. Test real playback too.")];
    [self setBusy:NO text:[lines componentsJoinedByString:@"\n"]];
}

- (void)runScan {
    [self setBusy:YES text:WGLOC(@"WG_SCANNING", @"Scanning…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *lines = YTMUWGScanTransportClasses();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanLines = lines;
            [self setBusy:NO text:[lines componentsJoinedByString:@"\n\n"]];
        });
    });
}

- (void)copyDiagnostics {
    NSString *report = YTMUWGDiagnosticsReport(self.checks);
    if (self.scanLines.count)
        report = [report stringByAppendingFormat:@"\n%@", YTMUWGRedactText([self.scanLines componentsJoinedByString:@"\n"])];
    UIPasteboard.generalPasteboard.string = report;
    self.resultText = report;
    [self.tableView reloadData];
    [self alert:WGLOC(@"WG_COPIED_TITLE", @"Diagnostics copied")
        message:WGLOC(@"WG_COPIED", @"Only counters, HTTP status codes and error codes were copied. Keys, tokens, song URLs and full IP addresses are removed.")];
}

@end
