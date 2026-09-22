// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 3. Neither the name of the OpenEmu Team nor the names of its contributors may
//    be used to endorse or promote products derived from this software without
//    specific prior written permission.
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

#ifndef OEHostLocalization_h
#define OEHostLocalization_h

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <limits.h>

NS_ASSUME_NONNULL_BEGIN

/// The host's language override lives in its volatile argument domain. Forward
/// that effective language list, not the saved choice awaiting an app restart.
/// NSArray's property-list representation quotes/escapes individual strings;
/// NSTask passes it as one argument without involving a shell.
static inline NSArray<NSString *> *OEHelperLanguageArguments(void)
{
    NSArray<NSString *> *languages = [NSUserDefaults.standardUserDefaults stringArrayForKey:@"AppleLanguages"];
    return languages.count ? @[@"-AppleLanguages", languages.description] : @[];
}

/// An auxiliary executable has its own embedded Info.plist and Bundle.main,
/// but the translated tables live in its enclosing application's Resources.
/// Resolve only from the running executable; no external bundle path is read.
/// This header is included by the existing private module and transport source,
/// so both Swift helper errors and native-core transport errors share the rule.
static inline NSBundle *OEHostLocalizationBundle(void)
{
    static NSBundle *localizationBundle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        localizationBundle = NSBundle.mainBundle;
        char executable[PATH_MAX];
        uint32_t length = sizeof(executable);
        if (_NSGetExecutablePath(executable, &length) != 0) { return; }
        NSString *path = [[NSString stringWithUTF8String:executable] stringByResolvingSymlinksInPath];
        // Both supported executables are direct children of Contents/MacOS.
        // Do not walk into an unrelated enclosing app for standalone tools.
        NSString *macOS = path.stringByDeletingLastPathComponent;
        NSString *contents = macOS.stringByDeletingLastPathComponent;
        NSString *application = contents.stringByDeletingLastPathComponent;
        if (![macOS.lastPathComponent isEqualToString:@"MacOS"] ||
            ![contents.lastPathComponent isEqualToString:@"Contents"] ||
            ![application.pathExtension isEqualToString:@"app"]) { return; }
        NSURL *resources = [NSURL fileURLWithPath:[contents stringByAppendingPathComponent:@"Resources"] isDirectory:YES];
        NSArray<NSURL *> *children = [NSFileManager.defaultManager contentsOfDirectoryAtURL:resources
                                                               includingPropertiesForKeys:nil options:0 error:nil];
        NSMutableArray<NSString *> *available = [NSMutableArray array];
        for (NSURL *child in children) {
            if (![child.pathExtension isEqualToString:@"lproj"]) { continue; }
            NSString *language = child.lastPathComponent.stringByDeletingPathExtension;
            if ([language isEqualToString:@"Base"]) { continue; }
            // fr-CA supplies only InfoPlist.strings; use the complete French
            // table rather than losing all helper translations in that locale.
            if ([NSFileManager.defaultManager fileExistsAtPath:[child URLByAppendingPathComponent:@"Localizable.strings"].path]) {
                [available addObject:language];
            }
        }
        NSArray<NSString *> *preferences = [NSUserDefaults.standardUserDefaults stringArrayForKey:@"AppleLanguages"] ?: @[];
        NSMutableArray<NSString *> *fallbacks = [preferences mutableCopy];
        [fallbacks addObject:@"en"];
        NSArray<NSString *> *preferred = [NSBundle preferredLocalizationsFromArray:available forPreferences:fallbacks];
        NSString *language = preferred.firstObject;
        if (!language) { return; }
        NSURL *selected = [resources URLByAppendingPathComponent:[language stringByAppendingPathExtension:@"lproj"] isDirectory:YES];
        NSBundle *bundle = [NSBundle bundleWithURL:selected];
        if (bundle) { localizationBundle = bundle; }
    });
    return localizationBundle;
}

NS_ASSUME_NONNULL_END
#endif
