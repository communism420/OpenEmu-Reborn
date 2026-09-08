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

#import "OEStoragePaths.h"
#import <errno.h>
#import <fcntl.h>
#import <stdio.h>
#import <sys/stat.h>
#import <unistd.h>

static NSURL *configuredDataRootURL;
static dev_t configuredRootDevice;
static ino_t configuredRootInode;

static BOOL OEStorageFailure(NSError **error, NSURL *url, NSInteger code,
                             NSString *message, int underlyingCode)
{
    if(error != NULL)
    {
        NSMutableDictionary *info = [@{ NSLocalizedDescriptionKey: message } mutableCopy];
        if(url != nil) info[NSURLErrorKey] = url;
        if(underlyingCode != 0)
            info[NSUnderlyingErrorKey] = [NSError errorWithDomain:NSPOSIXErrorDomain code:underlyingCode userInfo:nil];
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:code userInfo:info];
    }
    return NO;
}

// Call while holding the OEStoragePaths class lock. The returned descriptor is
// tied to the selected directory, not a potentially replaced pathname.
static int OEOpenConfiguredDataRoot(NSError **error)
{
    if(configuredDataRootURL == nil)
    {
        OEStorageFailure(error, nil, NSFileWriteUnknownError, @"Choose OpenEmu's data folder before saving files.", 0);
        return -1;
    }
    int directory = open(configuredDataRootURL.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if(directory == -1)
    {
        OEStorageFailure(error, configuredDataRootURL, NSFileWriteNoPermissionError, @"The OpenEmu data folder is missing or cannot be opened.", errno);
        return -1;
    }
    struct stat status;
    int failure = fstat(directory, &status) == 0 ? 0 : errno;
    if(failure != 0 || status.st_dev != configuredRootDevice || status.st_ino != configuredRootInode)
    {
        close(directory);
        OEStorageFailure(error, configuredDataRootURL, NSFileWriteUnknownError,
                         @"The OpenEmu data folder has changed. Reconnect the original folder and restart OpenEmu.", failure);
        return -1;
    }
    return directory;
}

@implementation OEStoragePaths

+ (BOOL)isConfigured
{
    @synchronized([OEStoragePaths class])
    {
        return configuredDataRootURL != nil;
    }
}

+ (NSURL *)dataRootURL
{
    @synchronized([OEStoragePaths class])
    {
        if(configuredDataRootURL != nil)
            return configuredDataRootURL;

        // Compatibility for SDK clients that do not use the host's first-run UI.
        NSURL *applicationSupport = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        if(applicationSupport == nil)
            applicationSupport = [NSFileManager.defaultManager.homeDirectoryForCurrentUser URLByAppendingPathComponent:@"Library/Application Support" isDirectory:YES];
        return [applicationSupport URLByAppendingPathComponent:@"OpenEmu" isDirectory:YES];
    }
}

+ (NSURL *)cachesURL
{
    return [self.dataRootURL URLByAppendingPathComponent:@"Caches" isDirectory:YES];
}

+ (NSURL *)temporaryDirectoryURL
{
    return [self.dataRootURL URLByAppendingPathComponent:@"Temporary" isDirectory:YES];
}

+ (NSURL *)logsURL
{
    return [self.dataRootURL URLByAppendingPathComponent:@"Logs" isDirectory:YES];
}

+ (BOOL)configureWithDataRootURL:(NSURL *)dataRootURL error:(NSError **)error
{
    @synchronized([OEStoragePaths class])
    {
        if(!dataRootURL.isFileURL || (dataRootURL.host.length > 0 && ![dataRootURL.host isEqualToString:@"localhost"]))
            return OEStorageFailure(error, dataRootURL, NSFileWriteInvalidFileNameError, @"Choose a local folder for OpenEmu data.", 0);

        NSURL *root = dataRootURL.URLByStandardizingPath.URLByResolvingSymlinksInPath;
        if(root.path.length == 0 || [root.path isEqualToString:@"/"])
            return OEStorageFailure(error, dataRootURL, NSFileWriteInvalidFileNameError, @"Choose a data folder, not the root of the filesystem.", 0);

        if(configuredDataRootURL != nil && ![configuredDataRootURL.path isEqualToString:root.path])
            return OEStorageFailure(error, root, NSFileWriteUnknownError, @"OpenEmu's data folder cannot change while the application is running.", 0);

        // Open the existing directory first. Using operations relative to this
        // descriptor avoids creating the selected folder or following a swapped
        // probe-file symlink during the write check.
        int directory = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if(directory == -1)
            return OEStorageFailure(error, root, NSFileWriteNoPermissionError, @"The OpenEmu data folder is missing or cannot be opened.", errno);

        struct stat status;
        if(fstat(directory, &status) != 0)
        {
            int failure = errno;
            close(directory);
            return OEStorageFailure(error, root, NSFileWriteUnknownError, @"OpenEmu could not identify the selected data folder.", failure);
        }
        if(configuredDataRootURL != nil && (status.st_dev != configuredRootDevice || status.st_ino != configuredRootInode))
        {
            close(directory);
            return OEStorageFailure(error, root, NSFileWriteUnknownError, @"A different folder is now at the selected data path. Restart OpenEmu to choose a data folder.", 0);
        }

        NSString *probeName = [@".openemu-write-check-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSString *renamedProbeName = [probeName stringByAppendingString:@"-renamed"];
        int probe = openat(directory, probeName.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        int failure = 0;
        if(probe == -1)
            failure = errno;
        else
        {
            ssize_t count = write(probe, "1", 1);
            if(count != 1)
                failure = count == 0 ? EIO : errno;
            if(failure == 0 && fsync(probe) != 0)
                failure = errno;
            if(close(probe) != 0 && failure == 0)
                failure = errno;

            // Saves and preferences use atomic replacement. Check that this
            // volume supports renaming as well as creating a file.
            if(failure == 0 && renameatx_np(directory, probeName.fileSystemRepresentation,
                                          directory, renamedProbeName.fileSystemRepresentation, RENAME_EXCL) != 0)
                failure = errno;

            const char *remainingName = failure == 0 ? renamedProbeName.fileSystemRepresentation : probeName.fileSystemRepresentation;
            if(unlinkat(directory, remainingName, 0) != 0 && failure == 0)
                failure = errno;
        }
        if(close(directory) != 0 && failure == 0)
            failure = errno;

        if(failure != 0)
            return OEStorageFailure(error, root, NSFileWriteNoPermissionError, @"OpenEmu could not safely write files in the selected data folder.", failure);

        configuredDataRootURL = [root copy];
        configuredRootDevice = status.st_dev;
        configuredRootInode = status.st_ino;
        return YES;
    }
}

+ (BOOL)validateDataRootWithError:(NSError **)error
{
    @synchronized([OEStoragePaths class])
    {
        int directory = OEOpenConfiguredDataRoot(error);
        if(directory == -1) return NO;
        close(directory);
        return YES;
    }
}

+ (BOOL)createDirectoryAtURL:(NSURL *)url error:(NSError **)error
{
    @synchronized([OEStoragePaths class])
    {
        int directory = OEOpenConfiguredDataRoot(error);
        if(directory == -1) return NO;
        if(!url.isFileURL || (url.host.length > 0 && ![url.host isEqualToString:@"localhost"]) ||
           [url.pathComponents containsObject:@".."])
        {
            close(directory);
            return OEStorageFailure(error, url, NSFileWriteInvalidFileNameError, @"OpenEmu can only create folders inside the selected data folder.", 0);
        }

        NSArray<NSString *> *rootComponents = configuredDataRootURL.pathComponents;
        NSArray<NSString *> *components = url.URLByStandardizingPath.pathComponents;
        if(components.count < rootComponents.count || ![[components subarrayWithRange:NSMakeRange(0, rootComponents.count)] isEqualToArray:rootComponents])
        {
            close(directory);
            return OEStorageFailure(error, url, NSFileWriteInvalidFileNameError, @"The requested folder is outside OpenEmu's selected data folder.", 0);
        }

        for(NSUInteger index = rootComponents.count; index < components.count; index++)
        {
            const char *component = components[index].fileSystemRepresentation;
            int nextDirectory = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            int failure = 0;
            if(nextDirectory == -1 && errno == ENOENT)
            {
                if(mkdirat(directory, component, 0700) != 0 && errno != EEXIST)
                    failure = errno;
                else
                    nextDirectory = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            }
            if(nextDirectory == -1)
            {
                if(failure == 0) failure = errno;
                close(directory);
                return OEStorageFailure(error, url, NSFileWriteNoPermissionError,
                                        @"OpenEmu could not create the requested folder. Symbolic links in data-folder paths are not followed.", failure);
            }
            close(directory);
            directory = nextDirectory;
        }
        close(directory);
        return YES;
    }
}

@end
