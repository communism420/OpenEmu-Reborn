// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause
// Test-only injected driver. Never link this file into the application.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *workspace, *dataRoot;
static NSWindow *permissionSheet, *parentWindow;
static id permissionAlert;
static NSButton *recheckButton;
static NSTimer *timer;
static NSDate *started, *nextStep;
static NSUInteger begins, ends, completions, clicks;
static _Atomic(NSUInteger) accessReads, rescans;
static _Atomic(BOOL) granted;
static BOOL grantClicked;
static IMP originalBeginSheet, originalEndSheet;

static NSString *canonical(NSString *path) {
    // Foundation may shorten /private/tmp back to /tmp for display, whereas
    // the coordinator uses filesystem canonical paths. Keep this comparison
    // strict and consistent with Python's Path.resolve(). Both paths checked
    // here are pre-existing directories, not the deliberately missing Data.
    if(!path.isAbsolutePath) return nil;
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if(!resolved) return nil;
    NSString *result = [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
    free(resolved);
    return result;
}

static void event(NSString *message) {
    NSString *path = [workspace stringByAppendingPathComponent:@"permission-driver-events.txt"];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0600);
    if(fd < 0) _exit(97);
    NSData *line = [[message stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if(write(fd, line.bytes, line.length) != (ssize_t)line.length) _exit(97);
    close(fd);
}

static void require(BOOL condition, NSString *message) {
    if(!condition) { event([@"FAIL " stringByAppendingString:message]); _exit(97); }
}

static NSUInteger simulatedAccess(id object, SEL selector) {
    (void)object; (void)selector;
    atomic_fetch_add(&accessReads, 1);
    // OEDeviceAccessTypeGranted = 0; OEDeviceAccessTypeDenied = 1.
    return atomic_load(&granted) ? 0 : 1;
}

static BOOL forbiddenRequest(id object, SEL selector) {
    (void)object; (void)selector;
    require(NO, @"a denied/granted recheck must never request actual macOS permission");
    return NO;
}

static void simulatedRescan(id object, SEL selector) {
    (void)object; (void)selector;
    require(atomic_load(&granted), @"keyboard rescan requested while simulated access is denied");
    atomic_fetch_add(&rescans, 1);
    // Do not call IOKit: this test verifies the UI's reaction to a simulated
    // grant, not the machine's actual TCC state or keyboard delivery.
}

static void findButtons(NSView *view, NSMutableArray<NSButton *> *buttons) {
    if([view isKindOfClass:NSButton.class]) [buttons addObject:(NSButton *)view];
    for(NSView *child in view.subviews) findButtons(child, buttons);
}

static void recordBeginSheet(NSWindow *parent, SEL selector, NSWindow *sheet,
                             void (^completion)(NSModalResponse)) {
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    findButtons(sheet.contentView, buttons);
    NSString *title = [NSBundle.mainBundle localizedStringForKey:@"Check Again" value:nil table:nil];
    NSButton *candidate = nil;
    id alert = nil;
    for(NSButton *button in buttons) {
        if([button.title isEqualToString:title]) candidate = button;
        NSString *targetName = NSStringFromClass([button.target class]);
        if([targetName isEqualToString:@"OEAlert"] || [targetName hasSuffix:@".OEAlert"]) alert = button.target;
    }
    if(candidate) {
        ++begins;
        require(begins == 1, @"permission alert was presented again");
        require(alert != nil, @"sheet must belong to the actual OEAlert");
        require(candidate.target == NSApp.delegate &&
                candidate.action == NSSelectorFromString(@"recheckInputMonitoringPermission:"),
                @"Check Again must invoke the actual delegate recheck without dismissing OEAlert");
        permissionSheet = sheet;
        parentWindow = parent;
        permissionAlert = alert;
        recheckButton = candidate;
        event(@"ACTUAL_PERMISSION_ALERT_PRESENTED");
        ((void (*)(id, SEL, NSWindow *, void (^)(NSModalResponse)))originalBeginSheet)(parent, selector, sheet,
            ^(NSModalResponse response) {
                ++completions;
                require(grantClicked, @"denied recheck completed the permission sheet");
                require(completions == 1, @"permission completion ran more than once");
                require(response == NSAlertSecondButtonReturn, @"grant refresh returned an unexpected sheet result");
                event(@"GRANTED_SHEET_COMPLETED_ONCE");
                if(completion) completion(response);
            });
    } else {
        ((void (*)(id, SEL, NSWindow *, void (^)(NSModalResponse)))originalBeginSheet)(parent, selector, sheet, completion);
    }
}

static void recordEndSheet(NSWindow *parent, SEL selector, NSWindow *sheet, NSModalResponse response) {
    if(sheet == permissionSheet) {
        ++ends;
        require(grantClicked, @"denied recheck ended the permission sheet");
        require(ends == 1, @"permission sheet ended more than once");
    }
    ((void (*)(id, SEL, NSWindow *, NSModalResponse))originalEndSheet)(parent, selector, sheet, response);
}

static void requireSameDeniedSheet(void) {
    require(begins == 1 && ends == 0 && completions == 0, @"denied sheet was closed or recreated");
    require(permissionSheet.isVisible && parentWindow.attachedSheet == permissionSheet &&
            permissionSheet.sheetParent == parentWindow, @"original permission sheet is not still attached");
    require([permissionAlert valueForKey:@"window"] == permissionSheet &&
            recheckButton.window == permissionSheet, @"OEAlert/window/button identity changed");
    require(atomic_load(&rescans) == 0, @"denied recheck rescanned real keyboard devices");
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:[dataRoot stringByAppendingPathComponent:@"Settings.plist"]];
    require([settings[@"OEInputMonitoringAlertSuppressed"] boolValue], @"denied recheck cleared the user's suppression choice");
}

static void tick(void) {
    require([started timeIntervalSinceNow] > -25, @"permission UI driver timed out");
    if(!permissionSheet || !permissionSheet.isVisible) {
        if(!grantClicked) return;
    }
    if(nextStep && [nextStep timeIntervalSinceNow] > 0) return;
    if(!grantClicked) {
        requireSameDeniedSheet();
        require(recheckButton.isEnabled, @"Check Again must remain enabled");
        if(clicks < 5) {
            NSUInteger before = atomic_load(&accessReads);
            [recheckButton performClick:nil];
            ++clicks;
            require(atomic_load(&accessReads) > before, @"actual click did not recheck live permission");
            requireSameDeniedSheet();
            event([NSString stringWithFormat:@"DENIED_CLICK_%lu_SAME_ALERT", (unsigned long)clicks]);
            nextStep = [NSDate dateWithTimeIntervalSinceNow:0.35];
            return;
        }
        // The delay after the fifth click also catches asynchronously queued
        // close/reopen loops rather than only testing synchronous identity.
        atomic_store(&granted, YES);
        grantClicked = YES;
        NSUInteger before = atomic_load(&accessReads);
        [recheckButton performClick:nil];
        require(atomic_load(&accessReads) > before, @"grant click did not read the new status");
        require(atomic_load(&rescans) > 0, @"grant refresh did not request a keyboard rescan");
        event(@"SIMULATED_GRANT_RECHECKED");
        nextStep = [NSDate dateWithTimeIntervalSinceNow:0.8];
        return;
    }
    require(begins == 1 && ends == 1 && completions == 1, @"grant must end and complete exactly one original sheet");
    require(parentWindow.attachedSheet != permissionSheet && permissionSheet.sheetParent == nil,
            @"granted permission sheet remained attached");
    require(!permissionSheet.isVisible, @"granted permission sheet remained visible");
    [timer invalidate];
    event(@"PASS_ACTUAL_PERMISSION_SHEET_NO_FLICKER");
    [NSApp terminate:nil];
}

static void replaceMethod(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    require(method != NULL, [@"required test boundary missing: " stringByAppendingString:NSStringFromSelector(selector)]);
    method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void installPermissionRegressionDriver(void) {
    @autoreleasepool {
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        if(!environment[@"OE_PERMISSION_TEST_WORKSPACE"] ||
           ![args.firstObject.lastPathComponent isEqualToString:@"OpenEmu"]) return;
        workspace = canonical(environment[@"OE_PERMISSION_TEST_WORKSPACE"]);
        require([workspace hasPrefix:@"/private/tmp/openemu-input-ui-"], @"not a private permission-test workspace");
        dataRoot = [workspace stringByAppendingPathComponent:@"Data"];
        require([canonical(environment[@"CFFIXED_USER_HOME"] ?: @"") isEqualToString:
                 [workspace stringByAppendingPathComponent:@"Private Home"]], @"framework home is not private");
        NSUInteger index = [args indexOfObject:@"--data-folder"];
        require(index != NSNotFound && index + 1 < args.count && [args[index + 1] isEqualToString:dataRoot],
                @"launch must select only the private fixture");
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        require([@[@"org.openemu.OpenEmu", @"org.openemu.OpenEmu.debug"] containsObject:bundleID], @"unexpected application identity");
        require(![NSFileManager.defaultManager fileExistsAtPath:dataRoot], @"fixture must not exist before injected hooks");
        // If injection fails, this still-missing --data-folder makes startup
        // fail before HID, credentials, plugins or the real user's data load.
        Class manager = NSClassFromString(@"OEDeviceManager");
        require(manager != Nil, @"device manager class unavailable");
        replaceMethod(manager, NSSelectorFromString(@"accessType"), (IMP)simulatedAccess);
        replaceMethod(manager, NSSelectorFromString(@"requestAccess"), (IMP)forbiddenRequest);
        replaceMethod(manager, NSSelectorFromString(@"rescanKeyboardDevices"), (IMP)simulatedRescan);
        Method begin = class_getInstanceMethod(NSWindow.class, @selector(beginSheet:completionHandler:));
        Method end = class_getInstanceMethod(NSWindow.class, @selector(endSheet:returnCode:));
        require(begin && end, @"native sheet boundaries unavailable");
        originalBeginSheet = method_setImplementation(begin, (IMP)recordBeginSheet);
        originalEndSheet = method_setImplementation(end, (IMP)recordEndSheet);
        NSString *marker = environment[@"OE_PERMISSION_TEST_MARKER"];
        require([[NSUUID alloc] initWithUUIDString:marker] != nil, @"missing private fixture identity");
        require([NSFileManager.defaultManager createDirectoryAtPath:dataRoot withIntermediateDirectories:NO attributes:nil error:nil],
                @"cannot create private data folder after installing permission stubs");
        require([@{@"version": @1, @"identifier": marker} writeToFile:
                 [dataRoot stringByAppendingPathComponent:@".openemu-data-folder.plist"] atomically:YES], @"cannot create fixture identity");
        require([@{@"setupAssistantFinished": @YES, @"OEPermissionRegressionSentinel": marker} writeToFile:
                 [dataRoot stringByAppendingPathComponent:@"Settings.plist"] atomically:YES], @"cannot create fixture settings");
        NSData *sentinel = [@"synthetic-credential-sentinel-no-keychain-migration" dataUsingEncoding:NSUTF8StringEncoding];
        require([sentinel writeToFile:[dataRoot stringByAppendingPathComponent:@".oe_credentials"] atomically:YES],
                @"cannot prevent legacy Keychain migration in fixture");
        event(@"PERMISSION_STUBS_INSTALLED_BEFORE_PRIVATE_PROFILE_CREATION");
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
            usingBlock:^(NSNotification *note) { (void)note; event(@"APPLICATION_WILL_TERMINATE"); }];
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;
                started = NSDate.date;
                nextStep = [NSDate dateWithTimeIntervalSinceNow:0.8];
                timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *unused) { (void)unused; tick(); }];
                [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
                [NSRunLoop.mainRunLoop addTimer:timer forMode:NSModalPanelRunLoopMode];
                event(@"APPLICATION_DID_FINISH_LAUNCHING");
            }];
    }
}
