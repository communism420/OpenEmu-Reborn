// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-3-Clause
#import <Foundation/Foundation.h>
#import "OEHostLocalization.h"

static void require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(EXIT_FAILURE);
    }
}

int main(void) {
    @autoreleasepool {
        NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
        NSString *home = environment[@"CFFIXED_USER_HOME"];
        require([home hasPrefix:@"/private/tmp/openemu-helper-localization."], @"private fixture home required");
        NSString *domain = NSBundle.mainBundle.bundleIdentifier;
        require([domain hasPrefix:@"org.openemu.tests.HelperLocalization"], @"only the uniquely identified fixture may run");
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSDictionary *persisted = [defaults persistentDomainForName:domain];
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if ([arguments containsObject:@"--fixture-standalone"]) {
            require(OEHostLocalizationBundle() == NSBundle.mainBundle, @"standalone tools must not invent or read an unrelated host resource path");
            printf("PASS: standalone executable retains its own bundle fallback\n");
        } else if ([arguments containsObject:@"--fixture-child"]) {
            NSData *expectedData = [environment[@"OE_EXPECTED_LANGUAGES"] dataUsingEncoding:NSUTF8StringEncoding];
            NSArray *expectedLanguages = [NSJSONSerialization JSONObjectWithData:expectedData options:0 error:nil];
            require([[defaults stringArrayForKey:@"AppleLanguages"] isEqual:expectedLanguages], @"effective language list must survive subprocess argument serialization exactly");
            NSBundle *bundle = OEHostLocalizationBundle();
            require([bundle.bundleURL.lastPathComponent isEqualToString:environment[@"OE_EXPECTED_LPROJ"]], @"helper must resolve the expected parent-app translation table");
            NSString *root = environment[@"OE_LOCALIZATION_SOURCE"];
            NSString *tablePath = [[root stringByAppendingPathComponent:environment[@"OE_EXPECTED_LPROJ"]] stringByAppendingPathComponent:@"Localizable.strings"];
            NSDictionary *table = [NSDictionary dictionaryWithContentsOfFile:tablePath];
            require(table != nil, @"expected source catalog must be readable");
            NSArray *keys = @[@"The emulator does not have read permissions to the ROM.",
                              @"The emulator could not load ROM.",
                              @"Save state loading is disabled in hardcore mode.",
                              @"Invalid HTTP response"];
            for (NSString *key in keys) {
                NSString *localized = [bundle localizedStringForKey:key value:nil table:nil];
                require([localized isEqual:table[key]], [@"helper translation mismatch: " stringByAppendingString:key]);
            }
            require([[bundle localizedStringForKey:@"__fixture_missing_key__" value:nil table:nil] isEqualToString:@"__fixture_missing_key__"], @"missing keys retain readable fallback");
        } else {
            NSArray<NSString *> *locales = @[@"ar", @"ca", @"de", @"en", @"es", @"fr", @"fr-CA", @"it", @"ja", @"nl", @"pt", @"ru", @"tr", @"zh-Hans", @"zh-Hant"];
            NSMutableArray<NSArray<NSString *> *> *selections = [NSMutableArray array];
            NSMutableArray<NSString *> *expectedTables = [NSMutableArray array];
            for (NSString *locale in locales) {
                [selections addObject:@[locale]];
                [expectedTables addObject:[[locale isEqualToString:@"fr-CA"] ? @"fr" : locale stringByAppendingPathExtension:@"lproj"]];
            }
            [selections addObjectsFromArray:@[@[@"zz-Unknown", @"fr-CA", @"en"], @[@"zz-Unknown"], @[@"x\", ru) --fixture-injection"]]];
            [expectedTables addObjectsFromArray:@[@"fr.lproj", @"en.lproj", @"en.lproj"]];
            NSURL *helper = [NSBundle.mainBundle.executableURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Helper"];
            for (NSUInteger index = 0; index < selections.count; index++) {
                [defaults setVolatileDomain:@{@"AppleLanguages": selections[index], @"OEInterfaceLanguage": @"ja"}
                                    forName:NSArgumentDomain];
                NSMutableDictionary *childEnvironment = [environment mutableCopy];
                NSData *json = [NSJSONSerialization dataWithJSONObject:selections[index] options:0 error:nil];
                childEnvironment[@"OE_EXPECTED_LANGUAGES"] = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
                childEnvironment[@"OE_EXPECTED_LPROJ"] = expectedTables[index];
                NSTask *task = [[NSTask alloc] init];
                task.executableURL = helper;
                task.environment = childEnvironment;
                task.arguments = [@[@"--fixture-child"] arrayByAddingObjectsFromArray:OEHelperLanguageArguments()];
                NSError *error = nil;
                require([task launchAndReturnError:&error], error.localizedDescription ?: @"helper launch failed");
                [task waitUntilExit];
                require(task.terminationStatus == 0, @"helper failed");
            }
            [defaults setVolatileDomain:@{@"AppleLanguages": @[]} forName:NSArgumentDomain];
            require(OEHelperLanguageArguments().count == 0, @"absent effective languages do not invent an override");
            printf("PASS: %lu real embedded-Info helper subprocesses; 4 error keys each, all bundled locales, regional/unknown fallbacks and escaped language arguments\n", (unsigned long)selections.count);
        }
        NSDictionary *after = [defaults persistentDomainForName:domain];
        require(persisted == after || [persisted isEqual:after], @"language propagation must not write persistent preferences");
    }
    return EXIT_SUCCESS;
}
