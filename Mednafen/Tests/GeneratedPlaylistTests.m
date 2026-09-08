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

#import "OEMednafenPlaylist.h"

static void Check(BOOL condition, NSString *message)
{
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSURL *Directory(NSURL *parent, NSString *name)
{
    NSURL *url = [parent URLByAppendingPathComponent:name isDirectory:YES];
    Check([NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:NO attributes:nil error:NULL], @"create fixture directory");
    return url;
}

static void Write(NSURL *url, NSString *contents)
{
    Check([contents writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL], @"write fixture file");
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        Check(argc == 2, @"one private temporary fixture directory required");
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *fixture = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES].URLByResolvingSymlinksInPath;
        NSURL *root = Directory(fixture, @"OpenEmu Data");
        NSURL *source = Directory(fixture, @"Диски с пробелами");
        NSURL *support = [root URLByAppendingPathComponent:@"Mednafen" isDirectory:YES];
        NSArray<NSString *> *names = @[@"Example (Disc 1).CUE", @"Example (Disc 2).ccd"];
        for (NSString *name in names) Write([source URLByAppendingPathComponent:name], @"fixture");
        Directory(source, @"not-a-disc.cue");
        NSError *error = nil;
        NSArray<NSString *> *discs = nil;
        NSString *diskPath = [source URLByAppendingPathComponent:names.firstObject].path;
        Check([OEStoragePaths configureWithDataRootURL:root error:&error], @"configure temporary data root");
        NSSet *before = [NSSet setWithArray:[fm contentsOfDirectoryAtPath:source.path error:NULL]];
        Check(chmod(source.fileSystemRepresentation, 0500) == 0, @"make ROM directory read-only");
        NSString *playlist = OEMednafenCreateMultiDiscPlaylist(diskPath, 2, support, &discs, &error);
        Check(playlist != nil && error == nil, @"generate from read-only ROM folder");
        Check([playlist.lastPathComponent isEqualToString:@"Example.m3u"], @"preserve cleaned playlist basename");
        NSString *hashDirectory = playlist.stringByDeletingLastPathComponent;
        Check(hashDirectory.lastPathComponent.length == 64, @"stable SHA-256 folder namespace");
        Check([hashDirectory.stringByDeletingLastPathComponent isEqualToString:[support.path stringByAppendingPathComponent:@"Playlists"]], @"playlist is inside core support folder");
        NSArray *expectedDiscs = @[[source.path stringByAppendingPathComponent:names[0]], [source.path stringByAppendingPathComponent:names[1]]];
        Check([discs isEqual:expectedDiscs], @"returned trusted list contains exactly sorted absolute CUE/CCD paths");
        NSString *contents = [NSString stringWithContentsOfFile:playlist encoding:NSUTF8StringEncoding error:NULL];
        Check([contents isEqualToString:[[discs componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"]], @"persisted playlist matches the list supplied to Mednafen");
        Check([before isEqual:[NSSet setWithArray:[fm contentsOfDirectoryAtPath:source.path error:NULL]]], @"ROM folder unchanged");
        Check(![fm fileExistsAtPath:[source.path stringByAppendingPathComponent:@"Example.m3u"]], @"no sibling playlist created");
        Check(chmod(source.fileSystemRepresentation, 0700) == 0, @"restore fixture permissions");

        NSString *again = OEMednafenCreateMultiDiscPlaylist([source.path stringByAppendingPathComponent:names[1]], 2, support, &discs, &error);
        Check([again isEqualToString:playlist], @"starting with another disc shares the same playlist");
        NSURL *sourceAlias = [fixture URLByAppendingPathComponent:@"Source Alias"];
        Check([fm createSymbolicLinkAtURL:sourceAlias withDestinationURL:source error:NULL], @"create source alias fixture");
        again = OEMednafenCreateMultiDiscPlaylist([sourceAlias.path stringByAppendingPathComponent:names[0]], 2, support, &discs, &error);
        Check([again isEqualToString:playlist], @"canonical source folder gives stable identifier through an alias");
        NSURL *secondSource = Directory(fixture, @"Other Edition");
        for (NSString *name in names) Write([secondSource URLByAppendingPathComponent:name], @"fixture");
        NSString *second = OEMednafenCreateMultiDiscPlaylist([secondSource.path stringByAppendingPathComponent:names[0]], 2, support, &discs, &error);
        Check(second && ![second isEqualToString:playlist], @"same title in different source folders cannot overwrite its playlist");

        Check([OEMednafenSBIURLForCueSheet(expectedDiscs[0], playlist).path isEqualToString:[source.path stringByAppendingPathComponent:@"Example (Disc 1).sbi"]], @"absolute CUE resolves SBI beside its disc, not beside the generated M3U");
        NSString *userPlaylist = [source.path stringByAppendingPathComponent:@"Example.m3u"];
        Check([OEMednafenSBIURLForCueSheet(names[0], userPlaylist).path isEqualToString:[source.path stringByAppendingPathComponent:@"Example (Disc 1).sbi"]], @"relative user CUE keeps original SBI resolution");
        Check([OEMednafenSBIURLForCueSheet(@"Subfolder/Disc.cue", userPlaylist).path isEqualToString:[source.path stringByAppendingPathComponent:@"Subfolder/Disc.sbi"]], @"relative subdirectories remain relative to the user playlist");

        error = nil;
        NSURL *skippedSupport = [root URLByAppendingPathComponent:@"Skipped Mednafen" isDirectory:YES];
        Check(OEMednafenCreateMultiDiscPlaylist(diskPath, 3, skippedSupport, &discs, &error) == nil && discs == nil && error == nil, @"wrong disc count skips generation without introducing a fatal error");
        Check(![fm fileExistsAtPath:skippedSupport.path], @"count mismatch creates no support directory or playlist");
        Check([before isEqual:[NSSet setWithArray:[fm contentsOfDirectoryAtPath:source.path error:NULL]]], @"count mismatch leaves source folder unchanged");
        NSURL *newlines = Directory(fixture, @"Newline\nFolder");
        for (NSString *name in names) Write([newlines URLByAppendingPathComponent:name], @"fixture");
        error = nil;
        Check(OEMednafenCreateMultiDiscPlaylist([newlines.path stringByAppendingPathComponent:names[0]], 2, support, &discs, &error) == nil && error, @"newline path cannot inject M3U entries");

        NSURL *outside = Directory(fixture, @"Outside");
        NSURL *unsafeSupport = Directory(root, @"Unsafe Mednafen");
        Check([fm createSymbolicLinkAtURL:[unsafeSupport URLByAppendingPathComponent:@"Playlists"] withDestinationURL:outside error:NULL], @"create escaping parent symlink fixture");
        error = nil;
        Check(OEMednafenCreateMultiDiscPlaylist(diskPath, 2, unsafeSupport, &discs, &error) == nil && error, @"managed parent symlink is refused");
        Check([fm contentsOfDirectoryAtPath:outside.path error:NULL].count == 0, @"escaping parent did not write outside root");
        NSURL *outsideFile = [outside URLByAppendingPathComponent:@"unchanged"];
        Write(outsideFile, @"keep me");
        Check([fm removeItemAtPath:playlist error:NULL], @"remove generated fixture playlist");
        Check([fm createSymbolicLinkAtPath:playlist withDestinationPath:outsideFile.path error:NULL], @"create escaping file symlink fixture");
        error = nil;
        Check(OEMednafenCreateMultiDiscPlaylist(diskPath, 2, support, &discs, &error) == nil && error, @"generated file symlink is refused");
        Check([[NSString stringWithContentsOfURL:outsideFile encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"keep me"], @"symlink target unchanged");
        Check([fm removeItemAtPath:playlist error:NULL], @"remove fixture symlink");
        Check(chmod(hashDirectory.fileSystemRepresentation, 0500) == 0, @"make output directory read-only");
        error = nil;
        Check(OEMednafenCreateMultiDiscPlaylist(diskPath, 2, support, &discs, &error) == nil && error && discs == nil, @"write failure does not return a usable playlist/list");
        Check(chmod(hashDirectory.fileSystemRepresentation, 0700) == 0, @"restore output permissions");

        Write([NSURL fileURLWithPath:userPlaylist], @"# User playlist stays unchanged\nExample (Disc 2).ccd\nExample (Disc 1).CUE\n");
        NSData *userBytes = [NSData dataWithContentsOfFile:userPlaylist];
        discs = @[@"must be cleared"];
        error = nil;
        NSString *reused = OEMednafenCreateMultiDiscPlaylist(diskPath, 2, support, &discs, &error);
        Check([reused isEqualToString:userPlaylist] && discs == nil && error == nil, @"existing user playlist uses ordinary parser, never the trusted-list entry point");
        Check([[NSData dataWithContentsOfFile:userPlaylist] isEqual:userBytes], @"existing sibling playlist bytes unchanged");
        Check([fm removeItemAtPath:userPlaylist error:NULL], @"remove fixture user playlist");

        NSURL *disconnected = [fixture URLByAppendingPathComponent:@"Disconnected Data"];
        Check([fm moveItemAtURL:root toURL:disconnected error:NULL], @"simulate unavailable data disk");
        error = nil;
        Check(OEMednafenCreateMultiDiscPlaylist(diskPath, 2, support, &discs, &error) == nil && error && discs == nil, @"missing data root fails closed");
        error = nil;
        Check(OEMednafenCreateMultiDiscPlaylist(diskPath, 3, support, &discs, &error) == nil && error, @"disc count mismatch must not hide an unavailable data root");
        Check(![fm fileExistsAtPath:root.path], @"missing data root is not recreated");
        Check([before isEqual:[NSSet setWithArray:[fm contentsOfDirectoryAtPath:source.path error:NULL]]], @"all failure paths leave original source folder unchanged");
        NSLog(@"PASS: generated playlists, existing playlists, SBI paths, and filesystem failure cases");
    }
    return 0;
}
