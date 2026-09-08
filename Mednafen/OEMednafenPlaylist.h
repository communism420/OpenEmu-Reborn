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

#pragma once

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <OpenEmuBase/OEStoragePaths.h>
#import <sys/stat.h>
#import <errno.h>

// Foundation-only helpers, shared by the core wrapper and its isolated tests.
// The returned disc list is non-nil ONLY for a playlist generated here. Existing
// user playlists must continue through Mednafen's ordinary, checked M3U parser.
static NSString *OEMednafenCreateMultiDiscPlaylist(NSString *diskPath, NSUInteger totalDiscs,
                                                  NSURL *supportDirectory,
                                                  NSArray<NSString *> **generatedDiscPaths,
                                                  NSError **error)
{
    if (generatedDiscPaths) *generatedDiscPaths = nil;
    if (![OEStoragePaths validateDataRootWithError:error]) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *sourceDirectory = [NSURL fileURLWithPath:diskPath.stringByDeletingLastPathComponent isDirectory:YES]
        .URLByStandardizingPath.URLByResolvingSymlinksInPath;
    NSString *folder = sourceDirectory.path;
    NSArray<NSString *> *folderContents = [fm contentsOfDirectoryAtPath:folder error:error];
    if (!folderContents) return nil;

    NSMutableArray<NSString *> *cues = [NSMutableArray array];
    for (NSString *name in folderContents) {
        NSString *ext = name.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"cue"] && ![ext isEqualToString:@"ccd"]) continue;
        NSURL *cueURL = [sourceDirectory URLByAppendingPathComponent:name];
        NSNumber *regularFile = nil;
        if (![cueURL getResourceValue:&regularFile forKey:NSURLIsRegularFileKey error:error]) return nil;
        if (regularFile.boolValue) [cues addObject:name];
    }
    [cues sortUsingSelector:@selector(localizedStandardCompare:)];
    if (totalDiscs == 0 || cues.count != totalDiscs) {
        // This was already a nonfatal auto-generation skip. Leave the caller's
        // ordinary single-disc loading and existing multi-disc guard unchanged.
        NSLog(@"[Mednafen] Auto-m3u skipped: game expects %lu discs but folder has %lu CUE/CCD files (%@)",
              (unsigned long)totalDiscs, (unsigned long)cues.count, folder);
        return nil;
    }

    NSString *baseName = diskPath.lastPathComponent.stringByDeletingPathExtension;
    NSRegularExpression *cleanup = [NSRegularExpression regularExpressionWithPattern:@"\\s*\\(?\\s*Disc\\s*\\d+\\s*\\)?\\s*"
                                                                             options:NSRegularExpressionCaseInsensitive error:NULL];
    NSString *cleanedBase = [[cleanup stringByReplacingMatchesInString:baseName options:0
                                                               range:NSMakeRange(0, baseName.length) withTemplate:@""]
                            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (cleanedBase.length == 0) cleanedBase = baseName;
    NSString *playlistName = [cleanedBase stringByAppendingPathExtension:@"m3u"];
    NSString *siblingPlaylist = [folder stringByAppendingPathComponent:playlistName];
    BOOL isDirectory = NO;
    if ([fm fileExistsAtPath:siblingPlaylist isDirectory:&isDirectory] && !isDirectory) {
        return siblingPlaylist; // Read a user's existing playlist; never rewrite it.
    }

    NSMutableArray<NSString *> *absoluteCues = [NSMutableArray arrayWithCapacity:cues.count];
    for (NSString *cue in cues) {
        NSString *absoluteCue = [folder stringByAppendingPathComponent:cue];
        // An M3U is line-based; a filename containing a newline cannot be represented safely.
        if ([absoluteCue rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadInvalidFileNameError
                                               userInfo:@{NSLocalizedDescriptionKey: @"A disc path contains a newline and cannot be stored in an M3U playlist."}];
            return nil;
        }
        [absoluteCues addObject:absoluteCue];
    }

    NSData *folderBytes = [folder dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(folderBytes.bytes, (CC_LONG)folderBytes.length, digest);
    NSMutableString *folderIdentifier = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [folderIdentifier appendFormat:@"%02x", digest[i]];
    NSURL *playlistDirectory = [[supportDirectory URLByAppendingPathComponent:@"Playlists" isDirectory:YES]
                                 URLByAppendingPathComponent:folderIdentifier isDirectory:YES];
    if (![OEStoragePaths createDirectoryAtURL:playlistDirectory error:error]) return nil;

    NSURL *playlistURL = [playlistDirectory URLByAppendingPathComponent:playlistName];
    struct stat existing;
    int status = lstat(playlistURL.fileSystemRepresentation, &existing);
    if ((status == 0 && !S_ISREG(existing.st_mode)) || (status != 0 && errno != ENOENT)) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInvalidFileNameError
                                           userInfo:@{NSLocalizedDescriptionKey: @"The generated playlist path is not a regular file."}];
        return nil;
    }
    NSString *contents = [[absoluteCues componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    if (![contents writeToURL:playlistURL atomically:YES encoding:NSUTF8StringEncoding error:error]) return nil;
    if (generatedDiscPaths) *generatedDiscPaths = absoluteCues.copy;
    return playlistURL.path;
}

static NSURL *OEMednafenSBIURLForCueSheet(NSString *cueSheet, NSString *playlistPath)
{
    NSString *cuePath = cueSheet.isAbsolutePath ? cueSheet
        : [playlistPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:cueSheet];
    return [NSURL fileURLWithPath:[cuePath.stringByDeletingPathExtension stringByAppendingPathExtension:@"sbi"]];
}
