// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause
// Test-only injected driver. Never link this file into the application.
#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *workspace;
static NSString *dataRoot;
static NSDate *started;
static NSTimer *timer;
static BOOL exercised;
static Class firstInitializedController;

static NSString *canonical(NSString *path) {
    return path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
}

static void event(NSString *message) {
    int descriptor = open([[workspace stringByAppendingPathComponent:@"game-driver-events.txt"] fileSystemRepresentation],
                          O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0600);
    if(descriptor < 0) _exit(97);
    NSData *line = [[NSString stringWithFormat:@"%@\n", message] dataUsingEncoding:NSUTF8StringEncoding];
    (void)write(descriptor, line.bytes, line.length);
    close(descriptor);
}

static void require(BOOL condition, NSString *message) {
    if(!condition) { event([@"FAIL " stringByAppendingString:message]); _exit(97); }
}

static Class appClass(NSString *name) {
    return NSClassFromString([@"OpenEmu." stringByAppendingString:name]) ?: NSClassFromString(name);
}

@interface NSDocumentController (OEGameRegressionInitialization)
- (instancetype)initOEGameRegression;
@end

@implementation NSDocumentController (OEGameRegressionInitialization)
- (instancetype)initOEGameRegression {
    // Both selectors are in the init family, preserving ARC ownership while
    // transparently forwarding to the exchanged original implementation.
    self = [self initOEGameRegression];
    if(self && !firstInitializedController) {
        firstInitializedController = self.class;
        event([@"FIRST_DOCUMENT_CONTROLLER_INITIALIZED " stringByAppendingString:NSStringFromClass(self.class)]);
    }
    return self;
}
@end

static void verifyMissingGame(NSDocumentController *controller, NSManagedObjectContext *context,
                              NSString *extension, BOOL useROMSelector) {
    // Create real app-model Game/ROM objects only in the private test library.
    // The deliberately absent file + nil source returns fileDoesNotExist before
    // selecting or launching an emulator core, without any download or dialog.
    NSManagedObject *game = [NSEntityDescription insertNewObjectForEntityForName:@"Game" inManagedObjectContext:context];
    NSManagedObject *rom = [NSEntityDescription insertNewObjectForEntityForName:@"ROM" inManagedObjectContext:context];
    require([game isKindOfClass:appClass(@"OEDBGame")] && [rom isKindOfClass:appClass(@"OEDBRom")], @"fixtures must use actual app model classes");
    [game setValue:[@"Regression Missing " stringByAppendingString:extension.uppercaseString] forKey:@"name"];
    NSString *name = [@"missing-regression." stringByAppendingString:extension];
    NSURL *missing = [NSURL fileURLWithPath:[dataRoot stringByAppendingPathComponent:name]];
    require(![NSFileManager.defaultManager fileExistsAtPath:missing.path], @"fixture ROM must remain absent");
    [rom setValue:name forKey:@"fileName"];
    [rom setValue:missing.absoluteString forKey:@"location"];
    [rom setValue:nil forKey:@"source"];
    [rom setValue:game forKey:@"game"];
    require([[game valueForKey:@"roms"] count] == 1, @"fixture game must have a default ROM");

    SEL selector = useROMSelector ? NSSelectorFromString(@"openGameDocumentWithRom:display:fullScreen:completionHandler:")
                                  : NSSelectorFromString(@"openGameDocumentWithGame:display:fullScreen:completionHandler:");
    require([controller respondsToSelector:selector], @"actual game-opening selector missing");
    require([controller methodForSelector:selector] != [NSDocumentController instanceMethodForSelector:selector],
            @"game-opening dispatch must not use the fatalError base implementation");
    __block BOOL completed = NO;
    void (^completion)(id, NSError *) = ^(id document, NSError *error) {
        require(document == nil, @"missing fixture must not create a game document");
        require([error.domain isEqualToString:@"org.openemu.OpenEmu.OEGameDocument"] && error.code == 1,
                @"real game-opening callback must report fileDoesNotExist");
        completed = YES;
        event([NSString stringWithFormat:@"MISSING_%@_%@_ERROR_CALLBACK", extension.uppercaseString, useROMSelector ? @"ROM" : @"GAME"]);
    };
    ((void (*)(id, SEL, id, BOOL, BOOL, id))objc_msgSend)(controller, selector, useROMSelector ? rom : game, NO, NO, completion);
    require(completed, @"missing-ROM check should finish synchronously before core setup");
    require(controller.documents.count == 0, @"failed open must leave no registered document");
    [context deleteObject:rom];
    [context deleteObject:game];
    [context processPendingChanges];
}

static void tick(void) {
    if([started timeIntervalSinceNow] < -30) { event(@"FAIL game driver timeout"); _exit(97); }
    if(exercised || NSApp.modalWindow != nil || [started timeIntervalSinceNow] > -2) return;
    Class databaseClass = appClass(@"OELibraryDatabase");
    if(![databaseClass respondsToSelector:NSSelectorFromString(@"defaultDatabase")]) return;
    id database = ((id (*)(id, SEL))objc_msgSend)(databaseClass, NSSelectorFromString(@"defaultDatabase"));
    if(!database) return;
    NSURL *databaseURL = [database valueForKey:@"databaseFolderURL"];
    require([canonical(databaseURL.path) isEqualToString:canonical([dataRoot stringByAppendingPathComponent:@"Game Library"])],
            @"app database must belong only to the private fixture");
    NSManagedObjectContext *context = [database valueForKey:@"mainThreadContext"];
    if(!context) return;
    exercised = YES;
    NSDocumentController *controller = NSDocumentController.sharedDocumentController;
    require([controller isKindOfClass:appClass(@"GameDocumentController")], @"shared controller must be GameDocumentController");
    require(firstInitializedController == appClass(@"GameDocumentController"),
            @"the first document controller initialized during startup must be GameDocumentController");
    event(@"FIRST_DOCUMENT_CONTROLLER_GAME_VERIFIED");
    require([(id)NSApp.delegate valueForKey:@"documentController"] == controller,
            @"the delegate must retain the already-installed shared game document controller");
    event(@"GAME_DOCUMENT_CONTROLLER_VERIFIED");
    verifyMissingGame(controller, context, @"nes", NO);
    verifyMissingGame(controller, context, @"nds", NO);
    verifyMissingGame(controller, context, @"nes", YES);
    [timer invalidate];
    event(@"GAME_DISPATCH_REGRESSION_PASS_APP_ALIVE");
    // The external coordinator verifies the owned process is still alive, then
    // terminates only that child. This is not a game/core compatibility test.
}

__attribute__((constructor)) static void installGameRegressionDriver(void) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if(![arguments.firstObject.lastPathComponent isEqualToString:@"OpenEmu"] ||
           [arguments containsObject:@"--openemu-delete-data"]) return;
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        if(!environment[@"OE_GAME_TEST_WORKSPACE"]) return;
        workspace = canonical(environment[@"OE_GAME_TEST_WORKSPACE"]);
        dataRoot = canonical(environment[@"OE_GAME_TEST_DATA_ROOT"] ?: @"");
        require([workspace hasPrefix:@"/private/tmp/openemu-game-dispatch-"] || [workspace hasPrefix:@"/tmp/openemu-game-dispatch-"],
                @"driver requires a private mktemp workspace");
        require([dataRoot hasPrefix:[workspace stringByAppendingString:@"/"]], @"data root must be inside the private workspace");
        NSUInteger index = [arguments indexOfObject:@"--data-folder"];
        require(index != NSNotFound && index + 1 < arguments.count && [canonical(arguments[index + 1]) isEqualToString:dataRoot],
                @"test launch must specify only its private data folder");
        event(@"GAME_DRIVER_LOADED");
        Class controllerClass = NSDocumentController.class;
        Method original = class_getInstanceMethod(controllerClass, @selector(init));
        // Keep the hook local to NSDocumentController even if init is inherited.
        class_addMethod(controllerClass, @selector(init), method_getImplementation(original), method_getTypeEncoding(original));
        method_exchangeImplementations(class_getInstanceMethod(controllerClass, @selector(init)),
                                       class_getInstanceMethod(controllerClass, @selector(initOEGameRegression)));
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            (void)notification;
            started = NSDate.date;
            timer = [NSTimer timerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *unused) { (void)unused; tick(); }];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSModalPanelRunLoopMode];
        }];
    }
}
