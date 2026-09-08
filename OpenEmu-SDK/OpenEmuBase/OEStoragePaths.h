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

NS_ASSUME_NONNULL_BEGIN

/// Shared paths for files owned by OpenEmu. Configure the host and each helper
/// before creating a core controller or reading any saved application data.
@interface OEStoragePaths : NSObject

@property(class, nonatomic, readonly) BOOL isConfigured;
@property(class, nonatomic, readonly) NSURL *dataRootURL;
@property(class, nonatomic, readonly) NSURL *cachesURL;
@property(class, nonatomic, readonly) NSURL *temporaryDirectoryURL;
@property(class, nonatomic, readonly) NSURL *logsURL;

/// Select an existing, writable local directory. This never creates the root.
/// A process cannot switch roots after configuration; configuring the same root
/// again is allowed and rechecks write access. Path getters never create folders
/// or fall back if the configured directory subsequently becomes unavailable.
/// Unconfigured SDK clients retain the original Application Support location.
+ (BOOL)configureWithDataRootURL:(NSURL *)dataRootURL
                         error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(configure(dataRootURL:));

/// Check that the configured directory still exists and is the same filesystem
/// object. A new directory at a disconnected volume's old path is not accepted.
+ (BOOL)validateDataRootWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(validateDataRoot());

/// Create missing directories beneath the selected root, without following
/// symbolic links. Passing the root itself only validates it and never creates
/// it. Absolute paths outside the root and parent-traversal components fail.
+ (BOOL)createDirectoryAtURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(createDirectory(at:));

@end

NS_ASSUME_NONNULL_END
