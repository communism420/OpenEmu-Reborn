// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-2-Clause
// Test-only injected driver. Never link this file into the application.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *workspace, *dataRoot, *mode, *expectedTitle;
static NSDate *started;
static NSTimer *timer;
static BOOL exercised;
static NSViewController *pane;

static NSString *canonical(NSString *path) {
    return path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
}

static void event(NSString *message) {
    NSString *path = [workspace stringByAppendingPathComponent:@"shader-driver-events.txt"];
    int descriptor = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0600);
    if(descriptor < 0) _exit(97);
    NSData *line = [[NSString stringWithFormat:@"%@ %@\n", mode, message] dataUsingEncoding:NSUTF8StringEncoding];
    (void)write(descriptor, line.bytes, line.length);
    close(descriptor);
}

static void require(BOOL condition, NSString *message) {
    if(!condition) { event([@"FAIL " stringByAppendingString:message]); _exit(97); }
}

static Class appClass(NSString *name) {
    return NSClassFromString([@"OpenEmu." stringByAppendingString:name]) ?: NSClassFromString(name);
}

static id shared(NSString *className) {
    Class cls = NSClassFromString(className) ?: NSClassFromString([@"OpenEmuKit." stringByAppendingString:className]);
    require([cls respondsToSelector:NSSelectorFromString(@"shared")], [@"missing shared " stringByAppendingString:className]);
    return ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"shared"));
}

static id shaderNamed(id store, NSString *name) {
    return ((id (*)(id, SEL, id))objc_msgSend)(store, NSSelectorFromString(@"shaderWithName:"), name);
}

static NSString *systemShaderName(id store, NSString *identifier) {
    return ((id (*)(id, SEL, id))objc_msgSend)(store, NSSelectorFromString(@"shaderNameForSystem:"), identifier);
}

static NSMenuItem *itemNamed(NSPopUpButton *picker, NSString *name) {
    NSArray *matches = [picker.itemArray filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSMenuItem *item, NSDictionary *bindings) {
        (void)bindings;
        return [item.representedObject isKindOfClass:NSString.class] && [item.representedObject isEqualToString:name];
    }]];
    require(matches.count == 1, [@"picker must contain exactly one stable-name item: " stringByAppendingString:name]);
    return matches.firstObject;
}

static void assertAllSystems(id systemStore, NSArray<NSString *> *identifiers, NSString *name) {
    for(NSString *identifier in identifiers) {
        require([systemShaderName(systemStore, identifier) isEqualToString:name],
                [NSString stringWithFormat:@"unexpected shader for bundled system %@", identifier]);
    }
}

static void selectGlobal(NSPopUpButton *picker, NSString *name) {
    [picker selectItem:itemNamed(picker, name)];
    require(picker.target == pane && picker.action == NSSelectorFromString(@"changeGlobalDefaultShader:"),
            @"picker must retain the real XIB target/action");
    require([NSApp sendAction:picker.action to:picker.target from:picker], @"real global shader action was not dispatched");
    event([@"REAL_GLOBAL_ACTION " stringByAppendingString:name]);
}

static void tick(void) {
    if([started timeIntervalSinceNow] < -30) { event(@"FAIL shader driver timeout"); _exit(97); }
    if(exercised || NSApp.modalWindow || [started timeIntervalSinceNow] > -2) return;
    Class databaseClass = appClass(@"OELibraryDatabase");
    id database = ((id (*)(id, SEL))objc_msgSend)(databaseClass, NSSelectorFromString(@"defaultDatabase"));
    if(!database) return;
    NSURL *databaseURL = [database valueForKey:@"databaseFolderURL"];
    require([canonical(databaseURL.path) isEqualToString:canonical([dataRoot stringByAppendingPathComponent:@"Game Library"])],
            @"app database must belong only to the private fixture");
    id context = [database valueForKey:@"mainThreadContext"];
    if(!context) return;
    exercised = YES;

    NSArray<NSString *> *identifiers = [NSArray arrayWithContentsOfFile:[workspace stringByAppendingPathComponent:@"bundled-system-identifiers.plist"]];
    require(identifiers.count > 0, @"bundled system inventory missing");
    NSArray<NSString *> *databaseIdentifiers = ((id (*)(id, SEL, id))objc_msgSend)(appClass(@"OEDBSystem"), NSSelectorFromString(@"allSystemIdentifiersIn:"), context);
    require([[NSSet setWithArray:identifiers] isSubsetOfSet:[NSSet setWithArray:databaseIdentifiers]],
            @"private database must register every bundled system before global reset is tested");

    id shaders = shared(@"OEShaderStore");
    id systems = shared(@"OESystemShaderStore");
    id preferences = shared(@"OEPreferences");
    id off = shaderNamed(shaders, @"No Shader");
    require(off != nil && shaderNamed(shaders, @"Pixellate") != nil, @"both No Shader and Pixellate must be discoverable models");
    NSURL *offURL = [off valueForKey:@"url"];
    require([canonical(offURL.path) hasPrefix:[canonical(NSBundle.mainBundle.resourcePath) stringByAppendingString:@"/Shaders/"]],
            @"No Shader must come from the actual app bundle, not a user override");
    require([[off valueForKey:@"defaultParameters"] count] == 0, @"No Shader must have no effect parameters");

    pane = [[appClass(@"PrefGameplayController") alloc] initWithNibName:@"PrefGameplayController" bundle:NSBundle.mainBundle];
    require(pane.view != nil, @"actual gameplay preference view must load");
    NSPopUpButton *picker = [pane valueForKey:@"globalDefaultShaderSelection"];
    require([picker isKindOfClass:NSPopUpButton.class], @"actual global shader popup missing");
    NSMenuItem *offItem = itemNamed(picker, @"No Shader");
    require(picker.itemArray.firstObject == offItem, @"No Shader must be the first choice");
    require([offItem.title isEqualToString:expectedTitle], @"localized title must map to stable No Shader identity");
    event([@"PICKER_TITLE_VERIFIED " stringByAppendingString:offItem.title]);

    NSString *currentDefault = [shaders valueForKey:@"defaultShaderName"];
    if([mode isEqualToString:@"per-system"]) {
        require([currentDefault isEqualToString:@"Pixellate"], @"adding No Shader must not change the existing global default");
        assertAllSystems(systems, identifiers, @"Pixellate");
        for(NSString *identifier in identifiers) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(systems, NSSelectorFromString(@"setShader:forSystem:"), off, identifier);
            require([systemShaderName(systems, identifier) isEqualToString:@"No Shader"], @"per-system selection must accept No Shader");
        }
        assertAllSystems(systems, identifiers, @"No Shader");
        require([[shaders valueForKey:@"defaultShaderName"] isEqualToString:@"Pixellate"], @"per-system choice must not change global default");
        event([NSString stringWithFormat:@"ALL_BUNDLED_SYSTEMS_WRITTEN %lu", (unsigned long)identifiers.count]);
    } else if([mode isEqualToString:@"global"]) {
        require([currentDefault isEqualToString:@"Pixellate"], @"per-system test must retain global Pixellate after relaunch");
        assertAllSystems(systems, identifiers, @"No Shader");
        event(@"PER_SYSTEM_PERSISTENCE_VERIFIED");
        // Synthetic assignment IDs are private fixture settings, not real user
        // presets. The real global action must clear these as well as shaders.
        for(NSString *identifier in identifiers) {
            NSString *key = [NSString stringWithFormat:@"videoShader.%@.preset", identifier];
            ((void (*)(id, SEL, id, id))objc_msgSend)(preferences, NSSelectorFromString(@"setObject:forKey:"), @"fixture-only-preset-assignment", key);
        }
        selectGlobal(picker, @"No Shader");
        require([[shaders valueForKey:@"defaultShaderName"] isEqualToString:@"No Shader"], @"localized action must persist canonical No Shader, not its title");
        assertAllSystems(systems, identifiers, @"No Shader");
        for(NSString *identifier in identifiers) {
            for(NSString *suffix in @[@"", @".preset"]) {
                NSString *key = [NSString stringWithFormat:@"videoShader.%@%@", identifier, suffix];
                require(((id (*)(id, SEL, id))objc_msgSend)(preferences, NSSelectorFromString(@"objectForKey:"), key) == nil,
                        @"real global action must clear each per-system override and named-preset assignment");
            }
        }
    } else if([mode isEqualToString:@"re-enable"]) {
        require([currentDefault isEqualToString:@"No Shader"], @"global No Shader must survive a fresh process");
        require([picker.selectedItem.representedObject isEqual:@"No Shader"] && [picker.selectedItem.title isEqualToString:expectedTitle],
                @"reloaded localized popup must select the stable stored shader");
        assertAllSystems(systems, identifiers, @"No Shader");
        event(@"GLOBAL_PERSISTENCE_VERIFIED");
        selectGlobal(picker, @"Pixellate");
        assertAllSystems(systems, identifiers, @"Pixellate");
        require([[shaders valueForKey:@"defaultShaderName"] isEqualToString:@"Pixellate"], @"shader effects must be selectable again");
    } else {
        require([mode isEqualToString:@"final-reload"], @"unexpected test mode");
        require([currentDefault isEqualToString:@"Pixellate"], @"re-enabled shader must survive relaunch");
        assertAllSystems(systems, identifiers, @"Pixellate");
        event(@"RE_ENABLED_PERSISTENCE_VERIFIED");
    }
    ((void (*)(id, SEL))objc_msgSend)(shaders, NSSelectorFromString(@"reload"));
    require([picker.selectedItem.representedObject isEqual:[shaders valueForKey:@"defaultShaderName"]],
            @"menu rebuild must preserve selection by canonical name");
    require([itemNamed(picker, @"No Shader").title isEqualToString:expectedTitle], @"menu rebuild must preserve localized off title");
    require(((BOOL (*)(id, SEL))objc_msgSend)(preferences, NSSelectorFromString(@"synchronize")), @"private preferences must flush successfully");
    require(NSDocumentController.sharedDocumentController.documents.count == 0, @"shader settings test must not open game documents");
    [timer invalidate];
    event(@"NO_SHADER_REGRESSION_PASS_APP_ALIVE");
}

__attribute__((constructor)) static void installNoShaderRegressionDriver(void) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if(![arguments.firstObject.lastPathComponent isEqualToString:@"OpenEmu"] ||
           [arguments containsObject:@"--openemu-delete-data"]) return;
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        if(!environment[@"OE_SHADER_TEST_WORKSPACE"]) return;
        workspace = canonical(environment[@"OE_SHADER_TEST_WORKSPACE"]);
        dataRoot = canonical(environment[@"OE_SHADER_TEST_DATA_ROOT"] ?: @"");
        mode = environment[@"OE_SHADER_TEST_MODE"] ?: @"";
        expectedTitle = environment[@"OE_SHADER_TEST_TITLE"] ?: @"";
        require([workspace hasPrefix:@"/private/tmp/openemu-no-shader-"] || [workspace hasPrefix:@"/tmp/openemu-no-shader-"],
                @"driver requires a private mktemp workspace");
        require([dataRoot hasPrefix:[workspace stringByAppendingString:@"/"]], @"data root must be inside the private workspace");
        NSUInteger index = [arguments indexOfObject:@"--data-folder"];
        require(index != NSNotFound && index + 1 < arguments.count && [canonical(arguments[index + 1]) isEqualToString:dataRoot],
                @"test launch must specify only its private data folder");
        event(@"NO_SHADER_DRIVER_LOADED");
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
