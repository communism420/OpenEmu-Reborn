// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <sys/stat.h>
#import <sys/resource.h>
#import <signal.h>
#import "OEPreferences.h"

static void Check(BOOL condition, NSString *message) {
    if(!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

@interface TestObserver : NSObject
@property NSUInteger changes;
@property NSUInteger priors;
@property NSString *previous;
@property NSString *next;
@end
@implementation TestObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    (void)keyPath; (void)object; (void)context;
    if([change[NSKeyValueChangeNotificationIsPriorKey] boolValue]) self.priors++;
    else { self.changes++; self.previous = change[NSKeyValueChangeOldKey]; self.next = change[NSKeyValueChangeNewKey]; }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Check(argc >= 3, @"mode and explicit temporary directory required");
        NSString *mode = @(argv[1]);
        NSURL *root = [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
        NSURL *url = [root URLByAppendingPathComponent:@"Settings.plist"];
        NSFileManager *fm = NSFileManager.defaultManager;
        OEPreferences *store = OEPreferences.shared;
        NSError *error = nil;
        __block NSUInteger failures = 0;
        __block NSUInteger changes = 0;
        id failureToken = [NSNotificationCenter.defaultCenter addObserverForName:OEPreferencesPersistenceDidFailNotification object:store queue:nil usingBlock:^(NSNotification *notification) {
            Check([notification.userInfo[NSUnderlyingErrorKey] isKindOfClass:NSError.class], @"failure has error");
            failures++;
        }];
        id changeToken = [NSNotificationCenter.defaultCenter addObserverForName:OEPreferencesDidChangeNotification object:store queue:nil usingBlock:^(NSNotification *notification) {
            (void)notification; @synchronized(store) { changes++; }
        }];
        [store registerDefaults:@{@"language": @"original", @"registeredOnly": @YES, @"counter": @1}];
        Check(!OEPreferences.isConfigured && [store boolForKey:@"registeredOnly"], @"registration before configuration is memory-only");
        if([mode isEqual:@"batch"]) {
            Check([OEPreferences configureWithURL:url readOnly:NO error:&error], @"configure atomic migration test");
            Check(chmod(root.fileSystemRepresentation, 0500) == 0, @"block first migration write");
            Check(![store setValues:@{@"legacyA": @1, @"legacyB": @2} error:&error], @"unwritable first migration fails");
            Check(![fm fileExistsAtPath:url.path] && [store objectForKey:@"legacyA"] == nil && [store objectForKey:@"legacyB"] == nil,
                  @"failed first migration leaves no partial Settings.plist or values");
            Check(chmod(root.fileSystemRepresentation, 0700) == 0, @"restore migration write access");

            Check([store setValues:@{@"legacyA": @1, @"legacyB": @2} error:&error], @"complete migration retries successfully");
            NSData *before = [NSData dataWithContentsOfURL:url];
            NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:url error:&error];
            Check([saved[@"legacyA"] isEqual:@1] && [saved[@"legacyB"] isEqual:@2], @"all imported keys are saved together");
            Check(![store setValues:@{@"legacyA": @99, @"unsupported": [NSObject new]} error:&error], @"invalid batch rejected as a whole");
            Check([[NSData dataWithContentsOfURL:url] isEqual:before] && [store integerForKey:@"legacyA"] == 1 && [store objectForKey:@"unsupported"] == nil,
                  @"invalid batch preserves all existing file and memory values");

            // Force a real short write followed by EFBIG in the temporary file.
            // The process-local limit cannot affect the application or compiler.
            struct rlimit originalLimit;
            Check(getrlimit(RLIMIT_FSIZE, &originalLimit) == 0, @"read test process file-size limit");
            struct rlimit shortWriteLimit = originalLimit;
            shortWriteLimit.rlim_cur = 1024;
            void (*originalHandler)(int) = signal(SIGXFSZ, SIG_IGN);
            Check(setrlimit(RLIMIT_FSIZE, &shortWriteLimit) == 0, @"enable deterministic partial-write failure");
            BOOL wroteBatch = [store setValues:@{@"legacyA": @99, @"large": [NSMutableData dataWithLength:16384]} error:&error];
            Check(setrlimit(RLIMIT_FSIZE, &originalLimit) == 0, @"restore file-size limit");
            signal(SIGXFSZ, originalHandler);
            Check(!wroteBatch && [[NSData dataWithContentsOfURL:url] isEqual:before] && [store integerForKey:@"legacyA"] == 1 && [store objectForKey:@"large"] == nil,
                  @"interrupted atomic batch preserves entire previous settings file and memory");
            Check([fm contentsOfDirectoryAtPath:root.path error:&error].count == 2, @"failed partial write leaves no temporary file");

            TestObserver *batchObserver = [TestObserver new];
            [store addObserver:batchObserver forKeyPath:@"legacyA" options:NSKeyValueObservingOptionPrior | NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew context:NULL];
            Check([store setValues:@{@"legacyA": @3, @"legacyB": @4} error:&error], @"subsequent atomic batch succeeds");
            Check(batchObserver.changes == 1 && batchObserver.priors == 1 && [batchObserver.previous isEqual:@1] && [batchObserver.next isEqual:@3],
                  @"batch emits one correct KVO pair per changed key");
            [store removeObserver:batchObserver forKeyPath:@"legacyA"];
            Check([store integerForKey:@"legacyB"] == 4 && [store synchronize], @"all keys and successful state recovered");
            NSLog(@"PASS: atomic batch migration, failed first write, invalid batch, partial-write interruption, KVO");
            return 0;
        }
        if([mode isEqual:@"arguments"] || [mode isEqual:@"arguments-saved"]) {
            if([mode isEqual:@"arguments"]) {
                [store registerDefaults:@{@"setupAssistantFinished": @NO, @"argumentWins": @"registered"}];
                Check([@{@"setupAssistantFinished": @NO, @"argumentWins": @"saved"} writeToURL:url error:&error], @"argument precedence test saved settings setup");
                Check([OEPreferences configureWithURL:url readOnly:NO error:&error], @"configure argument test writer");
                Check([store boolForKey:@"setupAssistantFinished"], @"CLI setupAssistantFinished YES overrides saved and registered false");
                Check([[store objectForKey:@"argumentWins"] isEqual:@"from-command-line"], @"argument domain has highest precedence");
                [store setObject:@"new-saved" forKey:@"argumentWins"];
                Check([[store dictionaryRepresentation][@"argumentWins"] isEqual:@"from-command-line"], @"dictionary view respects argument precedence");
                Check([[store stringForKey:@"argumentOnly"] isEqual:@"transient"], @"argument-only setting is readable");
                NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:url error:&error];
                Check([saved[@"argumentWins"] isEqual:@"new-saved"] && ![saved[@"setupAssistantFinished"] boolValue] && saved[@"argumentOnly"] == nil,
                      @"arguments are never copied into saved settings");
                Check([store volatileDomainForName:NSArgumentDomain][@"argumentOnly"] != nil, @"argument domain remains readable in memory");
            } else {
                Check([OEPreferences configureWithURL:url readOnly:YES error:&error], @"reopen arguments profile without command-line overrides");
                Check(![store boolForKey:@"setupAssistantFinished"] && [[store stringForKey:@"argumentWins"] isEqual:@"new-saved"] && [store objectForKey:@"argumentOnly"] == nil,
                      @"next process sees saved settings, not previous arguments");
            }
            NSLog(@"PASS: %@ command-line preference test", mode);
            return 0;
        }
        if([mode isEqual:@"contended"] || [mode isEqual:@"reopen"]) {
            NSData *before = [NSData dataWithContentsOfURL:url];
            Check(before != nil, @"writer-lock test has existing settings");
            BOOL configured = [OEPreferences configureWithURL:url readOnly:NO error:&error];
            if([mode isEqual:@"contended"]) {
                Check(!configured && error != nil && !OEPreferences.isConfigured, @"second writer rejected before configuration");
                Check([[NSData dataWithContentsOfURL:url] isEqual:before], @"second writer preserves first writer's data");
            } else {
                Check(configured && [store integerForKey:@"integer"] == 12, @"writer lock released after previous process exits");
                [store setBool:YES forKey:@"reopened"];
                Check([store synchronize], @"reopened writer persists successfully");
            }
            NSLog(@"PASS: %@ writer-lock test", mode);
            return 0;
        }
        Check(![fm fileExistsAtPath:url.path], @"registration creates no file");
        Check([NSUserDefaults.standardUserDefaults conformsToProtocol:@protocol(OEPreferencesStore)], @"NSUserDefaults protocol compatibility");
        if([mode isEqual:@"invalid"]) {
            Check([@"not a plist" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error], @"invalid file test setup");
            error = nil;
            Check(![OEPreferences configureWithURL:url readOnly:NO error:&error] && error, @"invalid settings rejected");
            Check(!OEPreferences.isConfigured, @"failed configure does not stick");
            Check([fm removeItemAtURL:url error:&error], @"remove own test file");
            Check([fm createSymbolicLinkAtURL:url withDestinationURL:[root URLByAppendingPathComponent:@"missing"] error:&error], @"symlink test setup");
            Check(![OEPreferences configureWithURL:url readOnly:NO error:&error], @"symbolic link rejected");
            NSLog(@"PASS: invalid plist and symbolic link rejection");
            return 0;
        }
        BOOL readOnly = [mode isEqual:@"readonly"];
        Check([OEPreferences configureWithURL:url readOnly:readOnly error:&error], @"configure settings");
        Check([OEPreferences configureWithURL:url readOnly:readOnly error:&error], @"same settings configuration accepted");
        Check(![OEPreferences configureWithURL:[root URLByAppendingPathComponent:@"Other.plist"] readOnly:readOnly error:&error], @"settings cannot switch");
        Check(![fm fileExistsAtPath:url.path], @"configuration creates no file");
        if(readOnly) {
            [store setObject:@2 forKey:@"counter"];
            Check([store integerForKey:@"counter"] == 1 && failures == 1, @"read-only setter rejected");
            Check(![fm fileExistsAtPath:url.path], @"read-only setter creates no file");
            Check([@{@"counter": @7} writeToURL:url error:&error], @"simulate host's first atomic write");
            Check([store integerForKey:@"counter"] == 7, @"reader refreshes host value");
            Check([@{@"counter": @8} writeToURL:url error:&error], @"simulate host's next atomic write");
            Check([store integerForKey:@"counter"] == 8, @"reader refreshes again");
            Check([@"bad" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error], @"simulate corrupted settings");
            Check([store integerForKey:@"counter"] == 8 && failures == 2, @"invalid file keeps last reader values and reports error");
            Check([@{@"counter": @9} writeToURL:url error:&error], @"restore readable settings");
            Check([store integerForKey:@"counter"] == 9, @"reader recovers after valid host write");
            NSURL *disconnected = [root URLByAppendingPathExtension:@"disconnected"];
            Check([fm moveItemAtURL:root toURL:disconnected error:&error], @"simulate disconnected reader data folder");
            Check([store integerForKey:@"counter"] == 9 && failures == 3, @"missing data folder retains reader values and reports error");
            Check(![fm fileExistsAtPath:root.path], @"reader does not recreate missing data folder");
            NSLog(@"PASS: readonly helper never writes preferences and sees host updates");
            return 0;
        }
        TestObserver *observer = [TestObserver new];
        [store addObserver:observer forKeyPath:@"language" options:NSKeyValueObservingOptionPrior | NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew context:NULL];
        [store setObject:@"Русский" forKey:@"language"];
        Check(observer.changes == 1 && observer.priors == 1 && [observer.previous isEqual:@"original"] && [observer.next isEqual:@"Русский"], @"single correct KVO prior/new pair");
        [store removeObserver:observer forKeyPath:@"language"];
        NSDictionary *disk = [NSDictionary dictionaryWithContentsOfURL:url error:&error];
        Check([disk[@"language"] isEqual:@"Русский"] && disk[@"registeredOnly"] == nil, @"persisted values saved; registrations stay in memory");
        NSTask *secondWriter = [[NSTask alloc] init];
        secondWriter.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments.firstObject];
        secondWriter.arguments = @[@"contended", root.path];
        Check([secondWriter launchAndReturnError:&error], @"launch isolated competing writer");
        [secondWriter waitUntilExit];
        Check(secondWriter.terminationStatus == 0, @"competing writer test passes");
        [store setObject:@"YES" forKey:@"boolean"];
        [store setObject:@"12" forKey:@"integer"];
        [store setDouble:3.5 forKey:@"double"];
        [store setFloat:2.25 forKey:@"float"];
        [store setObject:@[@"a", @"b"] forKey:@"array"];
        [store setObject:[@"bytes" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"data"];
        [store setObject:root forKey:@"url"];
        Check([store boolForKey:@"boolean"] && [store integerForKey:@"integer"] == 12, @"string number conversions");
        Check([store doubleForKey:@"double"] == 3.5 && [store floatForKey:@"float"] == 2.25, @"floating point getters");
        Check([store stringArrayForKey:@"array"].count == 2 && [store dataForKey:@"data"].length == 5, @"array and data getters");
        Check([[store URLForKey:@"url"].path isEqual:root.path], @"URL roundtrip");
        NSMutableDictionary *input = [@{@"nested": @[@1]} mutableCopy];
        [store setObject:input forKey:@"dictionary"];
        input[@"nested"] = @[@2];
        Check([[store dictionaryForKey:@"dictionary"][@"nested"][0] isEqual:@1], @"stored values do not alias caller's mutable objects");
        [store removeObjectForKey:@"language"];
        Check([[store stringForKey:@"language"] isEqual:@"original"], @"removal restores registered default");
        Check([store volatileDomainForName:NSRegistrationDomain][@"registeredOnly"] != nil && [store dictionaryRepresentation][@"array"] != nil, @"merged and registration views");
        NSData *before = [NSData dataWithContentsOfURL:url];
        [store setObject:[NSObject new] forKey:@"invalid"];
        Check(failures == 1 && [store objectForKey:@"invalid"] == nil && [[NSData dataWithContentsOfURL:url] isEqual:before], @"invalid value preserves prior file and memory");
        Check(chmod(root.fileSystemRepresentation, 0500) == 0, @"deny directory writes for test");
        [store setObject:@"lost" forKey:@"language"];
        Check(failures == 2 && [[store stringForKey:@"language"] isEqual:@"original"] && [[NSData dataWithContentsOfURL:url] isEqual:before], @"failed disk write keeps previous state and reports failure");
        Check(![store synchronize] && store.lastError != nil, @"failed persistence is visible through synchronize and lastError");
        Check(chmod(root.fileSystemRepresentation, 0700) == 0, @"restore test directory permissions");
        dispatch_apply(24, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
            @autoreleasepool { [store setInteger:index forKey:[NSString stringWithFormat:@"parallel-%zu", index]]; }
        });
        disk = [NSDictionary dictionaryWithContentsOfURL:url error:&error];
        for(NSUInteger index = 0; index < 24; index++) Check([disk[[NSString stringWithFormat:@"parallel-%lu", index]] unsignedIntegerValue] == index, @"parallel writes preserve every key");
        Check([store synchronize] && store.lastError == nil && changes > 24, @"successful state recovered and notifications emitted");
        Check([fm contentsOfDirectoryAtPath:root.path error:&error].count == 2, @"atomic writes leave only settings and process lock files");
        struct stat status;
        Check(stat(url.fileSystemRepresentation, &status) == 0 && (status.st_mode & 0777) == 0600, @"settings file private permissions");
        NSURL *lockURL = [url URLByAppendingPathExtension:@"lock"];
        Check(stat(lockURL.fileSystemRepresentation, &status) == 0 && (status.st_mode & 0777) == 0600, @"lock file private permissions");
        NSURL *savedLockURL = [lockURL URLByAppendingPathExtension:@"original"];
        Check([fm moveItemAtURL:lockURL toURL:savedLockURL error:&error], @"simulate replaced lock file");
        Check([NSData.data writeToURL:lockURL options:NSDataWritingWithoutOverwriting error:&error], @"create replacement lock file");
        [store setInteger:99 forKey:@"integer"];
        Check([store integerForKey:@"integer"] == 12 && failures == 3, @"replaced lock refuses stale writer");
        Check([fm removeItemAtURL:lockURL error:&error] && [fm moveItemAtURL:savedLockURL toURL:lockURL error:&error], @"restore original test lock");
        NSURL *disconnected = [root URLByAppendingPathExtension:@"disconnected"];
        Check([fm moveItemAtURL:root toURL:disconnected error:&error], @"simulate disconnected writer data folder");
        [store setInteger:99 forKey:@"integer"];
        Check([store integerForKey:@"integer"] == 12 && failures == 4, @"missing data folder preserves writer state and reports error");
        Check(![fm fileExistsAtPath:root.path], @"writer does not recreate missing data folder");
        [NSNotificationCenter.defaultCenter removeObserver:failureToken];
        [NSNotificationCenter.defaultCenter removeObserver:changeToken];
        NSLog(@"PASS: typed settings, atomic persistence, KVO, readonly protocol compatibility, failure preservation, concurrency");
    }
    return 0;
}
