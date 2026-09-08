// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause
// Test-only injected driver. Never link this file into the application.
#import <AppKit/AppKit.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <CoreGraphics/CGEvent.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *workspace, *dataRoot, *mode, *markerID;
static NSInteger phase;
static NSDate *started;
static NSTimer *timer;
static NSDocument *refusingDocument;
static BOOL loggedUnexpectedModal;
static IMP originalTerminate;
static IMP originalSetDelegate;
static BOOL deferredQuitRequested;
static void describeViews(NSView *view, NSMutableArray<NSString *> *labels);

static NSString *canonical(NSString *path) {
    return path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
}

static void event(NSString *message) {
    NSString *path = [workspace stringByAppendingPathComponent:@"driver-events.txt"];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if(fd < 0) _exit(97);
    NSData *line = [[NSString stringWithFormat:@"%d %@ %@\n", getpid(), mode, message] dataUsingEncoding:NSUTF8StringEncoding];
    (void)write(fd, line.bytes, line.length);
    close(fd);
}

static void require(BOOL condition, NSString *message) {
    if(!condition) { event([@"FAIL " stringByAppendingString:message]); _exit(97); }
}

static void recordTerminationState(NSString *stage) {
    NSUInteger sheets = 0;
    for(NSWindow *window in NSApp.windows) if(window.attachedSheet != nil) {
        sheets++;
        NSWindow *sheet = window.attachedSheet;
        NSMutableArray<NSString *> *labels = [NSMutableArray array];
        describeViews(sheet.contentView, labels);
        event([NSString stringWithFormat:@"ATTACHED_SHEET class=%@ title=%@ identifier=%@ labels=%@",
               NSStringFromClass(sheet.class), sheet.title, sheet.identifier ?: @"none",
               [labels componentsJoinedByString:@" | "]]);
    }
    if(sheets) event([NSString stringWithFormat:@"READ_ONLY_INPUT_PERMISSION IOHID=%d CGListenGranted=%d",
                     (int)IOHIDCheckAccess(kIOHIDRequestTypeListenEvent), CGPreflightListenEventAccess()]);
    event([NSString stringWithFormat:@"%@ documents=%lu sheets=%lu modal=%@", stage,
           (unsigned long)NSDocumentController.sharedDocumentController.documents.count,
           (unsigned long)sheets, NSApp.modalWindow ?
           [NSString stringWithFormat:@"%@:%@:%@", NSStringFromClass(NSApp.modalWindow.class),
            NSApp.modalWindow.title, NSApp.modalWindow.identifier ?: @"no-identifier"] : @"none"]);
}

static void recordTermination(id application, SEL selector, id sender) {
    event(@"APPLICATION_TERMINATE_ENTER");
    recordTerminationState(@"TERMINATE_ENTRY_STATE");
    ((void (*)(id, SEL, id))originalTerminate)(application, selector, sender);
    event(@"APPLICATION_TERMINATE_RETURNED");
    recordTerminationState(@"TERMINATE_RETURN_STATE");
}

static void afterRunLoopDelay(NSTimeInterval delay, void (^operation)(void)) {
    // A real document controller can keep terminate: inside a nested AppKit
    // event loop. A main-queue block cannot reenter that queue; a separate timer
    // can deliver the deferred answer in both the ordinary and modal loops.
    NSTimer *replyTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *unused) {
        (void)unused;
        operation();
    }];
    [NSRunLoop.mainRunLoop addTimer:replyTimer forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:replyTimer forMode:NSModalPanelRunLoopMode];
}

static NSApplicationTerminateReply deferredTermination(id delegate, SEL selector, NSApplication *application) {
    (void)delegate; (void)selector;
    if(!deferredQuitRequested && ([mode isEqualToString:@"confirm"] || [mode isEqualToString:@"cancel-quit"])) {
        deferredQuitRequested = YES;
        event(@"DEFERRED_QUIT_REQUESTED");
        afterRunLoopDelay(0.4, ^{
            BOOL allow = [mode isEqualToString:@"confirm"];
            event(allow ? @"DEFERRED_QUIT_ACCEPTED" : @"DEFERRED_QUIT_CANCELLED");
            [application replyToApplicationShouldTerminate:allow];
            if(!allow) {
                afterRunLoopDelay(1.0, ^{
                    event(@"CANCELLED_APP_STILL_RUNNING");
                    event(@"ORDINARY_QUIT_AFTER_CANCEL");
                    [application terminate:nil];
                });
            }
        });
        return NSTerminateLater;
    }
    return NSTerminateNow;
}

static void installDelegateHook(id application, SEL selector, id delegate) {
    if(delegate && [delegate respondsToSelector:@selector(resetAllSettingsAndQuit:)]) {
        Class delegateClass = [delegate class];
        Method existing = class_getInstanceMethod(delegateClass, @selector(applicationShouldTerminate:));
        if(existing == NULL) {
            require(class_addMethod(delegateClass, @selector(applicationShouldTerminate:),
                                    (IMP)deferredTermination, "Q@:@"), @"cannot install test deferred-quit hook");
        } else {
            require(method_getImplementation(existing) == (IMP)deferredTermination,
                    @"test deferred-quit hook must not replace an existing delegate method");
        }
        // AppKit may cache optional delegate selectors in setDelegate:. Install
        // the test method before that setter, not after DidFinishLaunching.
        event(@"DEFERRED_QUIT_HOOK_BEFORE_DELEGATE_ASSIGNMENT");
    }
    ((void (*)(id, SEL, id))originalSetDelegate)(application, selector, delegate);
}

static NSButton *findButton(NSView *view, NSString *identifier) {
    if([view isKindOfClass:NSButton.class] && [view.identifier isEqualToString:identifier]) return (NSButton *)view;
    for(NSView *child in view.subviews) {
        NSButton *found = findButton(child, identifier);
        if(found) return found;
    }
    return nil;
}

static BOOL hasSetupAssistant(NSView *view) {
    for(NSResponder *responder = view; responder; responder = responder.nextResponder) {
        if([NSStringFromClass(responder.class) containsString:@"SetupAssistant"]) return YES;
    }
    for(NSView *child in view.subviews) if(hasSetupAssistant(child)) return YES;
    return NO;
}

static void describeViews(NSView *view, NSMutableArray<NSString *> *labels) {
    if([view isKindOfClass:NSTextField.class]) {
        NSString *value = ((NSTextField *)view).stringValue;
        if(value.length) [labels addObject:value];
    }
    if([view isKindOfClass:NSButton.class]) [labels addObject:((NSButton *)view).title];
    for(NSView *child in view.subviews) describeViews(child, labels);
}

@interface OEResetRefusingDocument : NSDocument
@end
@implementation OEResetRefusingDocument
- (BOOL)isDocumentEdited { return YES; }
- (void)canCloseDocumentWithDelegate:(id)delegate shouldCloseSelector:(SEL)selector contextInfo:(void *)contextInfo {
    event(@"DOCUMENT_CLOSE_CANCELLED");
    ((void (*)(id, SEL, NSDocument *, BOOL, void *))objc_msgSend)(delegate, selector, self, NO, contextInfo);
}
@end

static BOOL fixtureTrash(id self, SEL selector, NSURL *url, NSURL **result, NSError **error) {
    (void)self; (void)selector;
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSString *token = args.count == 6 ? args[4] : @"";
    NSString *name = url.lastPathComponent;
    NSDictionary *identity = [NSDictionary dictionaryWithContentsOfFile:[dataRoot stringByAppendingPathComponent:@".openemu-data-folder.plist"]];
    BOOL safe = [canonical(url.URLByDeletingLastPathComponent.path) isEqualToString:dataRoot] &&
        [[NSUUID alloc] initWithUUIDString:token] != nil && [name hasSuffix:token] &&
        ([name hasPrefix:@"OpenEmu Removed Data - "] || [name hasPrefix:@".openemu-removal-staging-"]) &&
        [identity[@"identifier"] isEqualToString:markerID];
    if(!safe) {
        if(error) *error = [NSError errorWithDomain:@"OpenEmu.RemovalRegression" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Fixture Trash rejected an unexpected path"}];
        return NO;
    }
    NSURL *destination = [NSURL fileURLWithPath:[[workspace stringByAppendingPathComponent:@"Fixture Trash"] stringByAppendingPathComponent:name]];
    BOOL success = [NSFileManager.defaultManager moveItemAtURL:url toURL:destination error:error];
    if(success) {
        if(result) *result = destination;
        event(@"WORKER_TRASHED_PRIVATE_FIXTURE");
    }
    return success;
}

static void tick(void) {
    if([started timeIntervalSinceNow] < -45) { event(@"FAIL driver timeout"); _exit(97); }
    if([mode isEqualToString:@"relaunch"]) {
        for(NSWindow *window in NSApp.windows) if(window.isVisible && hasSetupAssistant(window.contentView)) {
            event(@"FIRST_RUN_ASSISTANT_VISIBLE");
            [timer invalidate];
            [NSApp terminate:nil];
            return;
        }
        return;
    }
    NSWindow *modal = NSApp.modalWindow;
    if(phase == 3 && modal && !loggedUnexpectedModal &&
       ![modal.identifier isEqualToString:@"OEDataRemovalConfirmation"]) {
        loggedUnexpectedModal = YES;
        NSMutableArray<NSString *> *labels = [NSMutableArray array];
        describeViews(modal.contentView, labels);
        event([@"UNEXPECTED_PRIVATE_TEST_MODAL " stringByAppendingString:[labels componentsJoinedByString:@" | "]]);
    }
    if(phase == 1 && [modal.identifier isEqualToString:@"OEDataRemovalChooser"]) {
        for(NSString *category in @[@"preferences", @"controls", @"accounts", @"library", @"emulationData", @"bios", @"screenshots", @"plugins", @"shaders", @"caches", @"other"]) {
            NSButton *box = findButton(modal.contentView, [@"OEDataRemovalCategory." stringByAppendingString:category]);
            require(box != nil, @"category checkbox missing");
            BOOL selected = [@[@"preferences", @"controls", @"accounts"] containsObject:category];
            if((box.state == NSControlStateValueOn) != selected) [box performClick:nil];
        }
        phase = 2;
        event(@"CHOOSER_CONTINUE");
        NSButton *button = findButton(modal.contentView, @"OEDataRemovalContinue");
        require(button.isEnabled, @"chooser continue unavailable");
        [button performClick:nil];
    } else if(phase == 2 && [modal.identifier isEqualToString:@"OEDataRemovalConfirmation"]) {
        phase = 3;
        BOOL cancel = [mode isEqualToString:@"cancel"];
        event(cancel ? @"CONFIRMATION_CANCELLED" : @"RESET_CONFIRMED");
        NSButton *button = findButton(modal.contentView, cancel ? @"OEDataRemovalCancel" : @"OEDataRemovalContinue");
        require(button.isEnabled, @"confirmation action unavailable");
        [button performClick:nil];
    } else if(phase == 0 && !modal && [started timeIntervalSinceNow] < -2 &&
              [NSFileManager.defaultManager fileExistsAtPath:[dataRoot stringByAppendingPathComponent:@"Game Library/Library.storedata"]]) {
        require([NSApp.delegate respondsToSelector:@selector(resetAllSettingsAndQuit:)], @"actual reset action missing");
        NSString *controllerName = NSStringFromClass(NSDocumentController.sharedDocumentController.class);
        require([controllerName isEqualToString:@"GameDocumentController"] || [controllerName hasSuffix:@".GameDocumentController"],
                @"the app must install GameDocumentController before document operations");
        require([(id)NSApp.delegate valueForKey:@"documentController"] == NSDocumentController.sharedDocumentController,
                @"the delegate must retain the already-installed shared game document controller");
        event(@"GAME_DOCUMENT_CONTROLLER_VERIFIED");
        if([mode isEqualToString:@"cancel-close"]) {
            refusingDocument = [[OEResetRefusingDocument alloc] init];
            [NSDocumentController.sharedDocumentController addDocument:refusingDocument];
        }
        event(@"CALLING_ACTUAL_RESET_ACTION");
        phase = 1;
        // Return from this timer callback before entering the nested modal loop;
        // the same timer must remain able to drive the dialog buttons there.
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp sendAction:@selector(resetAllSettingsAndQuit:) to:NSApp.delegate from:nil];
            event(@"ACTUAL_RESET_ACTION_RETURNED");
            if([mode isEqualToString:@"cancel"] || [mode isEqualToString:@"cancel-close"]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    require(NSApp.modalWindow == nil, @"cancellation left a modal dialog");
                    [timer invalidate];
                    if(refusingDocument) [NSDocumentController.sharedDocumentController removeDocument:refusingDocument];
                    event(@"CANCELLED_APP_STILL_RUNNING");
                    // The coordinator checks unchanged files while this owned
                    // test app remains alive, then stops only its child process.
                });
            }
        });
    }
}

__attribute__((constructor)) static void installRegressionDriver(void) {
    @autoreleasepool {
        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        // DYLD_INSERT_LIBRARIES may reach crash reporters and other child tools.
        // They are outside this driver and must not be changed or terminated.
        if(![args.firstObject.lastPathComponent isEqualToString:@"OpenEmu"]) return;
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        NSString *configured = environment[@"OE_RESET_TEST_WORKSPACE"];
        if(!configured) return;
        workspace = canonical(configured);
        dataRoot = canonical(environment[@"OE_RESET_TEST_DATA_ROOT"] ?: @"");
        mode = environment[@"OE_RESET_TEST_MODE"] ?: @"";
        markerID = environment[@"OE_RESET_TEST_MARKER"] ?: @"";
        require([workspace hasPrefix:@"/private/tmp/openemu-reset-action-"] || [workspace hasPrefix:@"/tmp/openemu-reset-action-"], @"not a private test workspace");
        require([dataRoot hasPrefix:[workspace stringByAppendingString:@"/"]], @"data root outside private workspace");
        require([[NSUUID alloc] initWithUUIDString:markerID] != nil, @"missing fixture identity");
        if([args containsObject:@"--openemu-delete-data"]) {
            require(args.count == 6 && [canonical([args[2] stringByDeletingLastPathComponent]) isEqualToString:dataRoot], @"worker fixture root mismatch");
            NSString *logPath = [workspace stringByAppendingPathComponent:@"worker-stderr.log"];
            int workerLog = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
            require(workerLog >= 0, @"cannot open private worker log");
            require(dup2(workerLog, STDERR_FILENO) >= 0, @"cannot redirect private worker stderr");
            close(workerLog);
            Method method = class_getInstanceMethod(NSFileManager.class, @selector(trashItemAtURL:resultingItemURL:error:));
            require(method != NULL, @"Trash method unavailable");
            method_setImplementation(method, (IMP)fixtureTrash);
            event(@"WORKER_FIXTURE_TRASH_INSTALLED");
            return; // Never drive application UI in the worker.
        }
        NSUInteger index = [args indexOfObject:@"--data-folder"];
        require(index != NSNotFound && index + 1 < args.count && [canonical(args[index + 1]) isEqualToString:dataRoot], @"ordinary launch must use only explicit private data root");
        Method terminate = class_getInstanceMethod(NSApplication.class, @selector(terminate:));
        require(terminate != NULL, @"application termination method unavailable");
        originalTerminate = method_setImplementation(terminate, (IMP)recordTermination);
        Method setDelegate = class_getInstanceMethod(NSApplication.class, @selector(setDelegate:));
        require(setDelegate != NULL, @"application delegate setter unavailable");
        originalSetDelegate = method_setImplementation(setDelegate, (IMP)installDelegateHook);
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note;
            event(@"APPLICATION_WILL_TERMINATE");
        }];
        event(@"DRIVER_LOADED");
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            Method deferred = class_getInstanceMethod([NSApp.delegate class], @selector(applicationShouldTerminate:));
            require(deferred != NULL && method_getImplementation(deferred) == (IMP)deferredTermination,
                    @"test deferred-quit hook was not installed before delegate assignment");
            started = NSDate.date;
            timer = [NSTimer timerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *unused) { (void)unused; tick(); }];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSModalPanelRunLoopMode];
            event(@"APPLICATION_DID_FINISH_LAUNCHING");
        }];
    }
}
