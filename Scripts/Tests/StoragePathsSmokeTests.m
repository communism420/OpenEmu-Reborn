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
#import "OEStoragePaths.h"

static void Check(BOOL condition, NSString *message) {
    if(!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Check(argc == 2, @"one explicit temporary test directory required");
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *testRoot = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        NSURL *root = [testRoot URLByAppendingPathComponent:@"Данные OpenEmu с пробелами" isDirectory:YES];
        NSURL *missing = [testRoot URLByAppendingPathComponent:@"missing" isDirectory:YES];
        NSURL *readOnly = [testRoot URLByAppendingPathComponent:@"read-only" isDirectory:YES];
        NSURL *file = [testRoot URLByAppendingPathComponent:@"file"];
        NSURL *other = [testRoot URLByAppendingPathComponent:@"other" isDirectory:YES];
        NSError *error;
        Check(!OEStoragePaths.isConfigured, @"initially unconfigured");
        Check(![OEStoragePaths validateDataRootWithError:&error], @"unconfigured root cannot be validated");
        Check(![OEStoragePaths createDirectoryAtURL:missing error:&error], @"managed directory creation requires configuration");
        Check([OEStoragePaths.dataRootURL.lastPathComponent isEqual:@"OpenEmu"], @"default SDK compatibility");
        Check(![OEStoragePaths configureWithDataRootURL:[NSURL URLWithString:@"https://example.com/data"] error:&error] && error, @"non-file URL rejected");
        error = nil;
        Check(![OEStoragePaths configureWithDataRootURL:[NSURL URLWithString:@"file://remote-host/data"] error:&error] && error, @"remote file URL rejected");
        error = nil;
        Check(![OEStoragePaths configureWithDataRootURL:[NSURL fileURLWithPath:@"/"] error:&error] && error, @"filesystem root rejected");
        error = nil;
        Check(![OEStoragePaths configureWithDataRootURL:missing error:&error] && error, @"missing folder rejected");
        Check(![fm fileExistsAtPath:missing.path], @"missing folder never created");
        Check([@"data" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error], @"test file created");
        Check(![OEStoragePaths configureWithDataRootURL:file error:&error], @"regular file rejected");
        Check([fm createDirectoryAtURL:readOnly withIntermediateDirectories:NO attributes:nil error:&error], @"read-only directory created");
        Check(chmod(readOnly.fileSystemRepresentation, 0500) == 0, @"test folder made read-only");
        Check(![OEStoragePaths configureWithDataRootURL:readOnly error:&error], @"read-only directory rejected");
        Check(chmod(readOnly.fileSystemRepresentation, 0700) == 0, @"test permissions restored");
        Check(!OEStoragePaths.isConfigured, @"invalid configurations do not stick");
        Check([fm createDirectoryAtURL:root withIntermediateDirectories:NO attributes:nil error:&error], @"root created by caller");
        Check([fm createDirectoryAtURL:other withIntermediateDirectories:NO attributes:nil error:&error], @"other directory created by caller");
        Check([OEStoragePaths configureWithDataRootURL:root error:&error], @"existing unicode directory accepted");
        Check(OEStoragePaths.isConfigured, @"configured flag set");
        root = root.URLByStandardizingPath.URLByResolvingSymlinksInPath;
        Check([OEStoragePaths.dataRootURL.path isEqual:root.path], @"root points to selection");
        for(NSURL *child in @[OEStoragePaths.cachesURL, OEStoragePaths.temporaryDirectoryURL, OEStoragePaths.logsURL]) {
            Check([child.URLByDeletingLastPathComponent.path isEqual:root.path], @"derived folder stays under root");
            Check(![fm fileExistsAtPath:child.path], @"path getter has no write side effect");
        }
        Check([fm contentsOfDirectoryAtPath:root.path error:&error].count == 0, @"write check leaves no files");
        Check([OEStoragePaths configureWithDataRootURL:root error:&error], @"same-root configuration is idempotent");
        Check(![OEStoragePaths configureWithDataRootURL:other error:&error], @"root cannot switch at runtime");
        NSURL *link = [testRoot URLByAppendingPathComponent:@"alias"];
        Check([fm createSymbolicLinkAtURL:link withDestinationURL:root error:&error], @"test symlink created");
        Check([OEStoragePaths configureWithDataRootURL:link error:&error], @"same canonical root through symlink accepted");
        dispatch_apply(32, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
            @autoreleasepool {
                (void)index;
                NSError *threadError;
                Check([OEStoragePaths configureWithDataRootURL:root error:&threadError], @"concurrent same-root configuration");
                Check([OEStoragePaths.dataRootURL.path isEqual:root.path], @"concurrent root lookup");
            }
        });
        Check([fm contentsOfDirectoryAtPath:root.path error:&error].count == 0, @"concurrent checks clean their probes");
        Check([OEStoragePaths validateDataRootWithError:&error], @"same root validates by filesystem identity");
        Check([OEStoragePaths createDirectoryAtURL:root error:&error], @"creating root itself only validates it");
        NSURL *nested = [root URLByAppendingPathComponent:@"Caches/One/Two" isDirectory:YES];
        Check([OEStoragePaths createDirectoryAtURL:nested error:&error], @"managed nested directories created");
        Check([fm fileExistsAtPath:nested.path], @"nested directory exists");
        Check([OEStoragePaths createDirectoryAtURL:nested error:&error], @"existing managed directory is accepted");
        Check(![OEStoragePaths createDirectoryAtURL:[other URLByAppendingPathComponent:@"outside"] error:&error], @"outside-root creation rejected");
        Check(![fm fileExistsAtPath:[other URLByAppendingPathComponent:@"outside"].path], @"outside directory remains absent");
        NSURL *escape = [root URLByAppendingPathComponent:@"escape"];
        Check([fm createSymbolicLinkAtURL:escape withDestinationURL:other error:&error], @"escaping symlink test setup");
        Check(![OEStoragePaths createDirectoryAtURL:[escape URLByAppendingPathComponent:@"escaped"] error:&error], @"escaping symlink rejected");
        Check(![fm fileExistsAtPath:[other URLByAppendingPathComponent:@"escaped"].path], @"symlink destination untouched");
        NSURL *traversal = [NSURL fileURLWithPath:[root.path stringByAppendingString:@"/escape/../traversed"]];
        Check(![OEStoragePaths createDirectoryAtURL:traversal error:&error], @"parent traversal rejected");
        NSURL *internalLink = [root URLByAppendingPathComponent:@"internal-alias"];
        Check([fm createSymbolicLinkAtURL:internalLink withDestinationURL:nested error:&error], @"internal symlink test setup");
        Check(![OEStoragePaths createDirectoryAtURL:[internalLink URLByAppendingPathComponent:@"child"] error:&error], @"internal symlink also rejected to keep directory checks stable");
        NSURL *moved = [testRoot URLByAppendingPathComponent:@"moved-away" isDirectory:YES];
        Check([fm moveItemAtURL:root toURL:moved error:&error], @"simulate missing root");
        Check(![OEStoragePaths configureWithDataRootURL:root error:&error], @"missing configured root rejects recheck");
        Check(OEStoragePaths.isConfigured, @"failed recheck does not clear configuration");
        Check([OEStoragePaths.dataRootURL.path isEqual:root.path], @"missing root does not trigger fallback");
        Check(![fm fileExistsAtPath:root.path], @"missing configured root is not recreated");
        Check(![OEStoragePaths validateDataRootWithError:&error], @"missing root fails validation");
        Check(![OEStoragePaths createDirectoryAtURL:[root URLByAppendingPathComponent:@"Caches/new"] error:&error], @"missing root blocks child creation");
        Check(![fm fileExistsAtPath:root.path], @"safe directory helper never recreates root");
        Check([fm createDirectoryAtURL:root withIntermediateDirectories:NO attributes:nil error:&error], @"simulate replacement directory at same pathname");
        Check(![OEStoragePaths validateDataRootWithError:&error], @"different directory at same path fails identity validation");
        Check(![OEStoragePaths configureWithDataRootURL:root error:&error], @"same-path replacement cannot reconfigure root");
        Check(![OEStoragePaths createDirectoryAtURL:[root URLByAppendingPathComponent:@"unexpected"] error:&error], @"same-path replacement cannot receive child directories");
        Check([fm contentsOfDirectoryAtPath:root.path error:&error].count == 0, @"replacement root receives no writes");
        NSLog(@"PASS: storage validation, no side effects, immutable root, concurrency, disappearance");
    }
    return 0;
}
