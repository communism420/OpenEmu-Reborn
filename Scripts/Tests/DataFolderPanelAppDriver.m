// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause
// Test-only injected driver. Never link this file into the application.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *workspace, *language;
static NSDate *started, *firstVisible;
static NSTimer *timer;
static NSUInteger samples;
static NSMutableSet<NSString *> *locatorReads;
static NSUInteger bootstrapSuiteRequests;

static NSString *canonical(NSString *path) {
    return path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
}

static void event(NSString *message) {
    NSString *path = [workspace stringByAppendingPathComponent:@"panel-driver-events.txt"];
    int descriptor = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0600);
    if(descriptor < 0) _exit(97);
    NSData *line = [[NSString stringWithFormat:@"%@ %@\n", language, message] dataUsingEncoding:NSUTF8StringEncoding];
    (void)write(descriptor, line.bytes, line.length);
    close(descriptor);
}

static void require(BOOL condition, NSString *message) {
    if(!condition) { event([@"FAIL " stringByAppendingString:message]); _exit(97); }
}

static BOOL isLocator(NSString *key) { return [key hasPrefix:@"OEDataFolder"]; }

// All public typed getters and writers use memory only. The superclass is
// initialized with a unique, empty suite, never the real app's preferences.
// No persistent-domain method forwards to Foundation's backing store.
@interface OEPanelMemoryDefaults : NSUserDefaults
@property NSMutableDictionary<NSString *, id> *values;
@property NSMutableDictionary<NSString *, id> *registered;
@property NSMutableDictionary<NSString *, NSDictionary *> *volatileDomains;
@end

@implementation OEPanelMemoryDefaults
- (id)objectForKey:(NSString *)key {
    @synchronized(self) {
        if(isLocator(key)) [locatorReads addObject:key];
        return self.values[key] ?: self.registered[key];
    }
}
- (void)setObject:(id)value forKey:(NSString *)key {
    require(!isLocator(key), @"cancelling first-run must never write a folder locator");
    @synchronized(self) { if(value) self.values[key] = value; else [self.values removeObjectForKey:key]; }
}
- (void)removeObjectForKey:(NSString *)key { [self setObject:nil forKey:key]; }
- (NSString *)stringForKey:(NSString *)key { id value = [self objectForKey:key]; return [value isKindOfClass:NSString.class] ? value : nil; }
- (NSArray *)arrayForKey:(NSString *)key { id value = [self objectForKey:key]; return [value isKindOfClass:NSArray.class] ? value : nil; }
- (NSDictionary *)dictionaryForKey:(NSString *)key { id value = [self objectForKey:key]; return [value isKindOfClass:NSDictionary.class] ? value : nil; }
- (NSData *)dataForKey:(NSString *)key { id value = [self objectForKey:key]; return [value isKindOfClass:NSData.class] ? value : nil; }
- (NSArray<NSString *> *)stringArrayForKey:(NSString *)key { return [self arrayForKey:key]; }
- (NSInteger)integerForKey:(NSString *)key { return [[self objectForKey:key] integerValue]; }
- (float)floatForKey:(NSString *)key { return [[self objectForKey:key] floatValue]; }
- (double)doubleForKey:(NSString *)key { return [[self objectForKey:key] doubleValue]; }
- (BOOL)boolForKey:(NSString *)key { return [[self objectForKey:key] boolValue]; }
- (NSURL *)URLForKey:(NSString *)key {
    id value = [self objectForKey:key];
    if([value isKindOfClass:NSURL.class]) return value;
    return [value isKindOfClass:NSString.class] ? [NSURL fileURLWithPath:value] : nil;
}
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setFloat:(float)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setDouble:(double)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setURL:(NSURL *)value forKey:(NSString *)key { [self setObject:value forKey:key]; }
- (void)registerDefaults:(NSDictionary<NSString *, id> *)defaults { @synchronized(self) { [self.registered addEntriesFromDictionary:defaults]; } }
- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    @synchronized(self) {
        NSMutableDictionary *result = [self.registered mutableCopy] ?: [NSMutableDictionary dictionary];
        [result addEntriesFromDictionary:self.values ?: @{}];
        return result;
    }
}
- (BOOL)synchronize { return YES; }
- (NSArray<NSString *> *)persistentDomainNames { return @[]; }
- (NSDictionary *)persistentDomainForName:(NSString *)name { (void)name; return nil; }
- (void)setPersistentDomain:(NSDictionary *)domain forName:(NSString *)name {
    (void)domain; (void)name;
    require(NO, @"first-run cancellation must not replace any persistent defaults domain");
}
- (void)removePersistentDomainForName:(NSString *)name {
    (void)name;
    require(NO, @"first-run test must not reset any defaults domain");
}
- (NSArray<NSString *> *)volatileDomainNames { @synchronized(self) { return self.volatileDomains.allKeys ?: @[]; } }
- (NSDictionary *)volatileDomainForName:(NSString *)name { @synchronized(self) { return self.volatileDomains[name] ?: @{}; } }
- (void)setVolatileDomain:(NSDictionary *)domain forName:(NSString *)name {
    @synchronized(self) { self.volatileDomains[name] = domain; }
}
- (void)removeVolatileDomainForName:(NSString *)name { @synchronized(self) { [self.volatileDomains removeObjectForKey:name]; } }
- (void)addSuiteNamed:(NSString *)name { (void)name; }
- (void)removeSuiteNamed:(NSString *)name { (void)name; }
@end

static OEPanelMemoryDefaults *privateDefaults;
static id fixtureStandardDefaults(id cls, SEL selector) { (void)cls; (void)selector; return privateDefaults; }

@interface NSUserDefaults (OEPanelFixtureBootstrap)
- (instancetype)initOEPanelWithSuiteName:(NSString *)name __attribute__((objc_method_family(init)));
@end
@implementation NSUserDefaults (OEPanelFixtureBootstrap)
- (instancetype)initOEPanelWithSuiteName:(NSString *)name {
    if([name isEqualToString:@"org.openemu.OpenEmu"]) {
        require(privateDefaults != nil, @"private bootstrap defaults must exist before redirection");
        ++bootstrapSuiteRequests;
        event(@"BOOTSTRAP_SUITE_REDIRECTED_TO_MEMORY");
        // An init-family method retains the returned shared fixture and
        // releases the unused allocation when assigning a different self.
        self = privateDefaults;
        return self;
    }
    return [self initOEPanelWithSuiteName:name];
}
@end

static void requireUnconfigured(void) {
    for(NSString *name in @[@"OEStoragePaths", @"OEPreferences"]) {
        Class cls = NSClassFromString(name);
        require([cls respondsToSelector:NSSelectorFromString(@"isConfigured")], @"storage isolation check unavailable");
        require(!((BOOL (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"isConfigured")), @"first-run panel must precede storage/preferences setup");
    }
}

static void findButtons(NSView *view, NSMutableArray<NSButton *> *buttons) {
    if(view.isHidden) return;
    if([view isKindOfClass:NSButton.class]) [buttons addObject:(NSButton *)view];
    for(NSView *child in view.subviews) findButtons(child, buttons);
}

static NSRect screenRect(NSView *view) {
    return [view.window convertRectToScreen:[view convertRect:view.bounds toView:nil]];
}

static void tick(void) {
    if([started timeIntervalSinceNow] < -20) { event(@"FAIL panel driver timeout"); _exit(97); }
    NSWindow *window = NSApp.modalWindow;
    if(![window isKindOfClass:NSOpenPanel.class] || !window.isVisible) return;
    NSOpenPanel *panel = (NSOpenPanel *)window;
    if(!firstVisible) { firstVisible = NSDate.date; event(@"ACTUAL_FIRST_RUN_PANEL_VISIBLE"); }
    if([firstVisible timeIntervalSinceNow] > -0.8) return;
    require(NSUserDefaults.standardUserDefaults == privateDefaults, @"ordinary bootstrap must use private memory defaults");
    require(bootstrapSuiteRequests > 0, @"unique-ID test app must redirect the real bootstrap suite before reading locators");
    for(NSString *key in @[@"OEDataFolderBookmark", @"OEDataFolderIdentifier", @"OEDataFolderPath"]) {
        require([locatorReads containsObject:key], @"actual first-run bootstrap must read its empty private locator");
        require(privateDefaults.values[key] == nil && privateDefaults.registered[key] == nil, @"locator must remain absent");
    }
    requireUnconfigured();
    require(panel.canChooseDirectories && !panel.canChooseFiles, @"expected actual data-folder picker");
    NSString *title = [NSBundle.mainBundle localizedStringForKey:@"Choose OpenEmu Data Folder" value:nil table:nil];
    NSString *prompt = [NSBundle.mainBundle localizedStringForKey:@"Use This Folder" value:nil table:nil];
    require([panel.title isEqualToString:title] && [panel.prompt isEqualToString:prompt], @"actual localized data-folder panel not identified");
    if([language isEqualToString:@"ru"]) require(![title isEqualToString:@"Choose OpenEmu Data Folder"], @"Russian app localization must be active");

    NSScreen *screen = panel.screen ?: NSScreen.mainScreen;
    require(screen != nil, @"display visible frame unavailable");
    NSRect visible = screen.visibleFrame;
    NSRect tolerance = NSInsetRect(visible, -1, -1);
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    findButtons(panel.contentView, buttons);
    NSButton *choose = nil, *cancel = nil;
    for(NSButton *button in buttons) {
        if([button.title isEqualToString:panel.prompt]) choose = button;
        NSString *action = NSStringFromSelector(button.action);
        if([button.keyEquivalent isEqualToString:@"\x1b"] || [action isEqualToString:@"cancel:"] ||
           [button.title isEqualToString:@"Cancel"] || [button.title isEqualToString:@"Отменить"] || [button.title isEqualToString:@"Отмена"]) cancel = button;
    }
    BOOL localButtons = choose != nil && cancel != nil;
    if(!localButtons && samples == 0) event(@"REMOTE_BUTTON_FRAMES_UNAVAILABLE");
    event([NSString stringWithFormat:@"SAMPLE %lu frame=%@ visible=%@ choose=%@ cancel=%@", (unsigned long)++samples,
           NSStringFromRect(panel.frame), NSStringFromRect(visible),
           localButtons ? NSStringFromRect(screenRect(choose)) : @"remote-hosted",
           localButtons ? NSStringFromRect(screenRect(cancel)) : @"remote-hosted"]);
    require(NSContainsRect(tolerance, panel.frame), @"native modal layout expanded the panel outside NSScreen.visibleFrame");
    if(localButtons) {
        require(NSContainsRect(tolerance, screenRect(choose)) && NSContainsRect(tolerance, screenRect(cancel)), @"native action buttons must fit on screen");
        require(NSContainsRect(panel.frame, screenRect(choose)) && NSContainsRect(panel.frame, screenRect(cancel)), @"native action buttons must fit inside the panel");
    }
    if(samples < 12) return;
    [timer invalidate];
    event(@"PRIVATE_BOOTSTRAP_AND_MODAL_GEOMETRY_VERIFIED");
    if(localButtons) {
        require(cancel.isEnabled, @"native Cancel must be usable");
        event(@"NATIVE_CANCEL_CLICKED");
        [cancel performClick:nil];
    } else {
        // Recent macOS hosts native buttons in a remote view. Do not invent
        // their frames or use another app's UI; invoke this panel's public
        // Cancel action and keep the missing geometry coverage explicit.
        event(@"NATIVE_CANCEL_ACTION_SENT");
        [panel cancel:nil];
    }
}

__attribute__((constructor)) static void installPanelRegressionDriver(void) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if(![arguments.firstObject.lastPathComponent isEqualToString:@"OpenEmu"] ||
           [arguments containsObject:@"--openemu-delete-data"]) return;
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        if(!environment[@"OE_PANEL_TEST_WORKSPACE"]) return;
        workspace = canonical(environment[@"OE_PANEL_TEST_WORKSPACE"]);
        language = environment[@"OE_PANEL_TEST_LANGUAGE"] ?: @"";
        require([workspace hasPrefix:@"/private/tmp/openemu-first-panel-"] || [workspace hasPrefix:@"/tmp/openemu-first-panel-"], @"driver requires a private mktemp workspace");
        require([canonical(environment[@"CFFIXED_USER_HOME"] ?: @"") isEqualToString:[workspace stringByAppendingPathComponent:language]], @"private framework home required");
        require([NSBundle.mainBundle.bundleIdentifier hasPrefix:@"org.openemu.FirstPanelFixture."], @"native preferences require a uniquely identified private app copy");
        require(![arguments containsObject:@"--data-folder"] && !environment[@"XCTestConfigurationFilePath"], @"must exercise ordinary first-run picker, not an explicit/test data root");
        locatorReads = [NSMutableSet set];
        privateDefaults = [[OEPanelMemoryDefaults alloc] initWithSuiteName:[@"org.openemu.FirstPanelFixture." stringByAppendingString:NSUUID.UUID.UUIDString]];
        require([privateDefaults isKindOfClass:OEPanelMemoryDefaults.class], @"Foundation must retain the memory-only defaults subclass");
        privateDefaults.values = [@{@"AppleLanguages": @[language], @"AppleLocale": [language isEqualToString:@"ru"] ? @"ru_RU" : @"en_US"} mutableCopy];
        privateDefaults.registered = [NSMutableDictionary dictionary];
        privateDefaults.volatileDomains = [NSMutableDictionary dictionary];
        Method standard = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        require(standard != NULL, @"standard defaults interception unavailable");
        method_setImplementation(standard, (IMP)fixtureStandardDefaults);
        Method suite = class_getInstanceMethod(NSUserDefaults.class, @selector(initWithSuiteName:));
        Method replacement = class_getInstanceMethod(NSUserDefaults.class, @selector(initOEPanelWithSuiteName:));
        require(suite != NULL && replacement != NULL, @"bootstrap suite interception unavailable");
        method_exchangeImplementations(suite, replacement);
        require(NSUserDefaults.standardUserDefaults == privateDefaults, @"memory defaults must be installed before app initialization");
        requireUnconfigured();
        event(@"MEMORY_DEFAULTS_INSTALLED_BEFORE_BOOTSTRAP");
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note;
            require(NO, @"Cancel must exit before loading the app/library");
        }];
        // The modal is inside AppDelegate.init; didFinishLaunching is too late.
        started = NSDate.date;
        timer = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *unused) { (void)unused; tick(); }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSModalPanelRunLoopMode];
    }
}
