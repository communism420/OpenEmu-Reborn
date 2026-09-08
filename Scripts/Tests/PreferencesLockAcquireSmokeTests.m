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
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

static int TestAcquireFlock(int descriptor, int operation);

// Only this standalone test translation unit substitutes flock. The real SDK
// source, including configuration and its post-acquisition checks, is unchanged.
#define flock TestAcquireFlock
#include "../../OpenEmu-SDK/OpenEmuBase/OEPreferences.m"
#undef flock

static NSString *TestLockPath;
static int TestWorkerLock = -1;
static int TestNewWriterLock = -1;
static BOOL TestArmed;
static BOOL TestInterleavingRan;

static void Check(BOOL condition, NSString *message) {
    if(!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

static int TestAcquireFlock(int descriptor, int operation) {
    BOOL staleAcquisition = NO;
    if(TestArmed && operation == (LOCK_EX | LOCK_NB)) {
        TestArmed = NO;
        struct stat opened, worker, replacement;
        Check(fstat(descriptor, &opened) == 0 && fstat(TestWorkerLock, &worker) == 0 &&
              opened.st_dev == worker.st_dev && opened.st_ino == worker.st_ino,
              @"configuration opened the still-held old worker lock inode");
        Check([TestLockPath hasPrefix:@"/private/tmp/openemu-lock-acquire-tests."] ||
              [TestLockPath hasPrefix:@"/tmp/openemu-lock-acquire-tests."], @"only the private fixture lock may be removed");
        // Model the worker's final unlink, then another launch creating and
        // holding a new inode before this already-open old fd obtains flock.
        Check(unlink(TestLockPath.fileSystemRepresentation) == 0, @"worker removes only its private lock path");
        Check(flock(TestWorkerLock, LOCK_UN) == 0, @"worker releases the removed inode");
        close(TestWorkerLock);
        TestWorkerLock = -1;
        TestNewWriterLock = open(TestLockPath.fileSystemRepresentation,
                                 O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        Check(TestNewWriterLock >= 0 && fstat(TestNewWriterLock, &replacement) == 0 &&
              replacement.st_ino != opened.st_ino && flock(TestNewWriterLock, LOCK_EX | LOCK_NB) == 0,
              @"a new writer owns a distinct current lock inode");
        TestInterleavingRan = YES;
        staleAcquisition = YES;
    }
    int result = flock(descriptor, operation);
    if(staleAcquisition) Check(result == 0, @"flock succeeds on the old inode; only the path-identity guard can reject it");
    return result;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Check(argc == 2, @"one explicit mktemp fixture root is required");
        NSString *inputPath = @(argv[1]);
        Check([inputPath hasPrefix:@"/private/tmp/openemu-lock-acquire-tests."], @"private fixture prefix required");
        NSURL *root = [NSURL fileURLWithPath:inputPath isDirectory:YES];
        NSURL *settingsURL = [root URLByAppendingPathComponent:@"Settings.plist"];
        TestLockPath = [settingsURL URLByAppendingPathExtension:@"lock"].path;
        NSError *error = nil;
        Check([@{@"currentWriterSentinel": @"unchanged"} writeToURL:settingsURL error:&error], @"fixture settings seeded");
        NSData *original = [NSData dataWithContentsOfURL:settingsURL];
        TestWorkerLock = open(TestLockPath.fileSystemRepresentation,
                              O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        Check(TestWorkerLock >= 0 && flock(TestWorkerLock, LOCK_EX | LOCK_NB) == 0, @"worker lease seeded");
        TestArmed = YES;
        Check(![OEPreferences configureWithURL:settingsURL readOnly:NO error:&error] && error != nil,
              @"configuration rejects a successfully locked but unlinked old inode");
        Check(TestInterleavingRan && !OEPreferences.isConfigured,
              @"stale lease never initializes the preference store");
        Check([[NSData dataWithContentsOfURL:settingsURL] isEqual:original], @"rejected configuration keeps current settings byte-identical");
        Check([OEPreferences.shared objectForKey:@"currentWriterSentinel"] == nil,
              @"rejected configuration never loads another writer's values");
        int contender = open(TestLockPath.fileSystemRepresentation, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
        Check(contender >= 0 && flock(contender, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK,
              @"rejection preserves the new writer's current lock and lease");
        close(contender);
        Check(flock(TestNewWriterLock, LOCK_UN) == 0, @"fixture new writer releases its lease");
        close(TestNewWriterLock);
        TestNewWriterLock = -1;
        error = nil;
        Check([OEPreferences configureWithURL:settingsURL readOnly:NO error:&error], @"configuration can retry on the current inode");
        Check([[OEPreferences.shared stringForKey:@"currentWriterSentinel"] isEqual:@"unchanged"], @"valid retry reads the expected settings");
        NSLog(@"PASS: deterministic open-old-fd/unlink/recreate/flock race rejects stale configuration; valid retry succeeds");
    }
    return 0;
}
