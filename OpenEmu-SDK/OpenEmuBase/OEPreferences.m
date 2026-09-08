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

#import "OEPreferences.h"
#import <errno.h>
#import <fcntl.h>
#import <stdio.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>

NSNotificationName const OEPreferencesDidChangeNotification = @"OEPreferencesDidChangeNotification";
NSNotificationName const OEPreferencesPersistenceDidFailNotification = @"OEPreferencesPersistenceDidFailNotification";

static NSError *OEPreferencesError(NSString *message, NSURL *url, int underlyingCode)
{
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
    if(url != nil) info[NSURLErrorKey] = url;
    if(underlyingCode != 0)
        info[NSUnderlyingErrorKey] = [NSError errorWithDomain:NSPOSIXErrorDomain code:underlyingCode userInfo:nil];
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:info];
}

static NSDictionary *OEReadPreferences(NSURL *url, NSError **error)
{
    struct stat status;
    if(lstat(url.fileSystemRepresentation, &status) == -1)
    {
        if(errno == ENOENT)
        {
            // A new profile may not have a settings file yet. A missing data
            // folder is different: keep the last values and report the lost
            // location instead of silently reverting to registered defaults.
            int directory = open(url.URLByDeletingLastPathComponent.fileSystemRepresentation,
                                 O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            if(directory != -1)
            {
                close(directory);
                return @{};
            }
            if(error) *error = OEPreferencesError(@"The OpenEmu settings folder is missing or cannot be opened.", url, errno);
            return nil;
        }
        if(error) *error = OEPreferencesError(@"OpenEmu could not read its settings file.", url, errno);
        return nil;
    }
    if(!S_ISREG(status.st_mode))
    {
        if(error) *error = OEPreferencesError(@"OpenEmu's settings must be a regular file, not a folder or symbolic link.", url, 0);
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if(data == nil) return nil;
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error];
    if(![value isKindOfClass:NSDictionary.class])
    {
        if(error && *error == nil) *error = OEPreferencesError(@"OpenEmu's settings file is not a valid settings dictionary.", url, 0);
        return nil;
    }
    return value;
}

static BOOL OEWritePreferences(NSData *data, NSURL *url, NSError **error)
{
    // Do not create a missing data root. In particular, a disconnected volume
    // must never be replaced by a newly-created folder at its former mount path.
    int directory = open(url.URLByDeletingLastPathComponent.fileSystemRepresentation,
                         O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if(directory == -1)
    {
        if(error) *error = OEPreferencesError(@"The OpenEmu settings folder is missing or cannot be opened.", url, errno);
        return NO;
    }
    NSString *name = url.lastPathComponent;
    struct stat status;
    int failure = 0;
    if(fstatat(directory, name.fileSystemRepresentation, &status, AT_SYMLINK_NOFOLLOW) == 0)
    {
        if(!S_ISREG(status.st_mode)) failure = EINVAL;
    }
    else if(errno != ENOENT) failure = errno;

    NSString *temporaryName = [@".openemu-settings-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int file = failure == 0 ? openat(directory, temporaryName.fileSystemRepresentation,
                                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600) : -1;
    if(file == -1 && failure == 0) failure = errno;
    if(file != -1)
    {
        const uint8_t *bytes = data.bytes;
        NSUInteger remaining = data.length;
        while(remaining > 0)
        {
            ssize_t count = write(file, bytes, remaining);
            if(count == -1 && errno == EINTR) continue;
            if(count <= 0) { failure = count == 0 ? EIO : errno; break; }
            bytes += count;
            remaining -= (NSUInteger)count;
        }
        if(failure == 0 && fsync(file) != 0) failure = errno;
        if(close(file) != 0 && failure == 0) failure = errno;
        if(failure == 0 && renameat(directory, temporaryName.fileSystemRepresentation,
                                   directory, name.fileSystemRepresentation) != 0)
            failure = errno;
        if(failure != 0) unlinkat(directory, temporaryName.fileSystemRepresentation, 0);
    }
    close(directory);
    if(failure != 0 && error)
        *error = OEPreferencesError(@"OpenEmu could not save its settings. The previous settings file was kept.", url, failure);
    return failure == 0;
}

static int OELockPreferences(NSURL *url, NSError **error)
{
    NSURL *lockURL = [url URLByAppendingPathExtension:@"lock"];
    int descriptor = open(lockURL.fileSystemRepresentation,
                          O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if(descriptor == -1 && errno == EEXIST)
        descriptor = open(lockURL.fileSystemRepresentation, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if(descriptor == -1)
    {
        if(error) *error = OEPreferencesError(@"OpenEmu could not lock its settings file.", lockURL, errno);
        return -1;
    }

    struct stat status;
    int failure = 0;
    if(fstat(descriptor, &status) != 0) failure = errno;
    else if(!S_ISREG(status.st_mode) || status.st_nlink != 1) failure = EINVAL;
    if(failure == 0 && flock(descriptor, LOCK_EX | LOCK_NB) != 0) failure = errno;
    if(failure == 0 && fchmod(descriptor, 0600) != 0) failure = errno;
    if(failure != 0)
    {
        close(descriptor);
        NSString *message = failure == EWOULDBLOCK ? @"Another OpenEmu application is using this data folder. Quit it before continuing."
                                                  : @"OpenEmu could not lock its settings file.";
        if(error) *error = OEPreferencesError(message, lockURL, failure);
        return -1;
    }
    return descriptor;
}

@interface OEPreferences ()
{
    NSRecursiveLock *_lock;
    NSDictionary<NSString *, id> *_values;
    NSDictionary<NSString *, id> *_argumentOverrides;
    NSMutableDictionary<NSString *, id> *_registered;
    NSURL *_url;
    BOOL _readOnly;
    BOOL _lastWriteSucceeded;
    NSError *_lastError;
    int _writerLock;
}
@end

@implementation OEPreferences

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    // Generic KVC setters otherwise add a second notification around our own
    // will/did-change pair. All settings changes are notified after a saved write.
    return NO;
}

+ (OEPreferences *)shared
{
    static OEPreferences *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ store = [[self alloc] init]; });
    return store;
}

- (instancetype)init
{
    if((self = [super init]))
    {
        _lock = [[NSRecursiveLock alloc] init];
        _values = @{};
        // Command-line settings are process-local overrides, like UserDefaults'
        // argument domain. Reading this domain never saves app preferences in
        // macOS; neither arguments nor registered defaults enter Settings.plist.
        _argumentOverrides = [[NSUserDefaults.standardUserDefaults volatileDomainForName:NSArgumentDomain] copy];
        _registered = [NSMutableDictionary dictionary];
        _lastWriteSucceeded = YES;
        _writerLock = -1;
    }
    return self;
}

- (void)dealloc
{
    if(_writerLock != -1) close(_writerLock);
}

- (NSError *)lastError
{
    [_lock lock];
    NSError *error = _lastError;
    [_lock unlock];
    return error;
}

+ (BOOL)isConfigured
{
    OEPreferences *store = self.shared;
    [store->_lock lock];
    BOOL result = store->_url != nil;
    [store->_lock unlock];
    return result;
}

+ (BOOL)configureWithURL:(NSURL *)url readOnly:(BOOL)readOnly error:(NSError **)error
{
    OEPreferences *store = self.shared;
    [store->_lock lock];
    @try
    {
        NSURL *fileURL = [url.URLByDeletingLastPathComponent.URLByStandardizingPath.URLByResolvingSymlinksInPath URLByAppendingPathComponent:url.lastPathComponent];
        NSNumber *isDirectory;
        if(!url.isFileURL || (url.host.length > 0 && ![url.host isEqual:@"localhost"]) || url.lastPathComponent.length == 0 ||
           ![fileURL.URLByDeletingLastPathComponent getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:error] || !isDirectory.boolValue)
        {
            if(error && *error == nil) *error = OEPreferencesError(@"Choose an existing folder for OpenEmu's settings.", url, 0);
            return NO;
        }
        if(store->_url != nil && (![store->_url.path isEqual:fileURL.path] || store->_readOnly != readOnly))
        {
            if(error) *error = OEPreferencesError(@"OpenEmu's settings file cannot change while the application is running.", fileURL, 0);
            return NO;
        }
        // Acquire before reading: another process may have just saved a newer
        // value. Read-only helpers never create or acquire this lock.
        int writerLock = store->_writerLock;
        if(!readOnly && writerLock == -1)
        {
            writerLock = OELockPreferences(fileURL, error);
            if(writerLock == -1) return NO;
        }
        NSDictionary *values = OEReadPreferences(fileURL, error);
        if(values == nil)
        {
            if(writerLock != -1 && writerLock != store->_writerLock) close(writerLock);
            return NO;
        }
        store->_values = values;
        store->_url = fileURL;
        store->_readOnly = readOnly;
        store->_writerLock = writerLock;
        return YES;
    }
    @finally { [store->_lock unlock]; }
}

- (void)reportFailure:(NSError *)error
{
    [NSNotificationCenter.defaultCenter postNotificationName:OEPreferencesPersistenceDidFailNotification object:self
                                                    userInfo:@{ NSUnderlyingErrorKey: error }];
}

- (BOOL)hasCurrentWriterLock
{
    // Deleting or replacing a lock file would let another process lock a new
    // inode. Refuse writes through the old lease instead of racing that writer.
    struct stat heldStatus, pathStatus;
    NSURL *lockURL = [_url URLByAppendingPathExtension:@"lock"];
    return _writerLock != -1 && fstat(_writerLock, &heldStatus) == 0 &&
        lstat(lockURL.fileSystemRepresentation, &pathStatus) == 0 &&
        S_ISREG(pathStatus.st_mode) && heldStatus.st_dev == pathStatus.st_dev && heldStatus.st_ino == pathStatus.st_ino;
}

- (void)refreshReadOnlyValues
{
    if(!_readOnly || _url == nil) return;
    NSError *error;
    NSDictionary *values = OEReadPreferences(_url, &error);
    if(values != nil) _values = values;
    else
    {
        _lastError = error;
        [self reportFailure:error];
    }
}

- (id)objectForKey:(NSString *)key
{
    [_lock lock];
    [self refreshReadOnlyValues];
    id value = _argumentOverrides[key] ?: _values[key] ?: _registered[key];
    [_lock unlock];
    return value;
}

- (NSString *)stringForKey:(NSString *)key
{
    id value = [self objectForKey:key];
    if([value isKindOfClass:NSString.class]) return value;
    return [value isKindOfClass:NSNumber.class] ? [value stringValue] : nil;
}

- (BOOL)boolForKey:(NSString *)key
{
    id value = [self objectForKey:key];
    return [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class] ? [value boolValue] : NO;
}

- (NSInteger)integerForKey:(NSString *)key
{
    id value = [self objectForKey:key];
    return [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class] ? [value integerValue] : 0;
}

- (double)doubleForKey:(NSString *)key
{
    id value = [self objectForKey:key];
    return [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class] ? [value doubleValue] : 0;
}

- (float)floatForKey:(NSString *)key { return (float)[self doubleForKey:key]; }
- (NSData *)dataForKey:(NSString *)key { id value = [self objectForKey:key]; return [value isKindOfClass:NSData.class] ? value : nil; }
- (NSArray *)arrayForKey:(NSString *)key { id value = [self objectForKey:key]; return [value isKindOfClass:NSArray.class] ? value : nil; }
- (NSDictionary *)dictionaryForKey:(NSString *)key { id value = [self objectForKey:key]; return [value isKindOfClass:NSDictionary.class] ? value : nil; }

- (NSArray<NSString *> *)stringArrayForKey:(NSString *)key
{
    NSArray *array = [self arrayForKey:key];
    for(id value in array) if(![value isKindOfClass:NSString.class]) return nil;
    return array;
}

- (NSURL *)URLForKey:(NSString *)key
{
    NSString *value = [self stringForKey:key];
    if(value == nil) return nil;
    return value.isAbsolutePath ? [NSURL fileURLWithPath:value.stringByExpandingTildeInPath] : [NSURL URLWithString:value];
}

- (void)setObject:(id)value forKey:(NSString *)key
{
    [self applyValues:value == nil ? @{} : @{key: value} removingKeys:value == nil ? @[key] : @[] error:NULL];
}

- (BOOL)setValues:(NSDictionary<NSString *,id> *)values error:(NSError **)error
{
    return [self applyValues:values removingKeys:@[] error:error];
}

- (BOOL)applyValues:(NSDictionary<NSString *, id> *)values removingKeys:(NSArray<NSString *> *)removingKeys error:(NSError **)outError
{
    [_lock lock];
    NSError *error;
    NSArray<NSString *> *changedKeys = @[];
    if(_url == nil || _readOnly)
        error = OEPreferencesError(_readOnly ? @"Only the main OpenEmu application can save settings." : @"Choose OpenEmu's data folder before saving settings.", _url, 0);
    else if(![self hasCurrentWriterLock])
        error = OEPreferencesError(@"The OpenEmu data folder or settings lock has changed. Restart OpenEmu before saving settings.", _url, 0);
    else
    {
        NSMutableDictionary *next = [_values mutableCopy];
        for(NSString *key in values)
        {
            id value = values[key];
            next[key] = [value isKindOfClass:NSURL.class] ? [value absoluteString] : value;
        }
        [next removeObjectsForKeys:removingKeys];
        if(![next isEqualToDictionary:_values])
        {
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:next format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
            if(data != nil && OEWritePreferences(data, _url, &error))
            {
                NSMutableSet<NSString *> *keys = [NSMutableSet setWithArray:values.allKeys];
                [keys addObjectsFromArray:removingKeys];
                NSMutableArray<NSString *> *differentKeys = [NSMutableArray array];
                for(NSString *key in keys)
                {
                    id before = _values[key], after = next[key];
                    if(before != after && ![before isEqual:after]) [differentKeys addObject:key];
                }
                changedKeys = [differentKeys sortedArrayUsingSelector:@selector(compare:)];
                for(NSString *key in changedKeys) [self willChangeValueForKey:key];
                _values = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
                for(NSString *key in changedKeys.reverseObjectEnumerator) [self didChangeValueForKey:key];
            }
        }
    }
    _lastWriteSucceeded = error == nil;
    _lastError = error;
    [_lock unlock];
    if(error != nil)
    {
        if(outError != NULL) *outError = error;
        [self reportFailure:error];
    }
    else if(changedKeys.count != 0)
        [NSNotificationCenter.defaultCenter postNotificationName:OEPreferencesDidChangeNotification object:self
                                                        userInfo:changedKeys.count == 1 ? @{ @"key": changedKeys.firstObject } : nil];
    return error == nil;
}

- (void)setBool:(BOOL)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setDouble:(double)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setFloat:(float)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)removeObjectForKey:(NSString *)key { [self setObject:nil forKey:key]; }

- (void)registerDefaults:(NSDictionary<NSString *, id> *)defaults
{
    NSError *error;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:defaults format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if(data == nil)
    {
        [_lock lock];
        _lastError = error;
        [_lock unlock];
        [self reportFailure:error];
        return;
    }
    NSDictionary *copy = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    [_lock lock];
    for(NSString *key in copy) [self willChangeValueForKey:key];
    [_registered addEntriesFromDictionary:copy];
    for(NSString *key in copy) [self didChangeValueForKey:key];
    [_lock unlock];
    [NSNotificationCenter.defaultCenter postNotificationName:OEPreferencesDidChangeNotification object:self];
}

- (NSDictionary<NSString *, id> *)dictionaryRepresentation
{
    [_lock lock];
    [self refreshReadOnlyValues];
    NSMutableDictionary *values = [_registered mutableCopy];
    [values addEntriesFromDictionary:_values];
    [values addEntriesFromDictionary:_argumentOverrides];
    [_lock unlock];
    return [values copy];
}

- (NSDictionary<NSString *, id> *)volatileDomainForName:(NSString *)name
{
    [_lock lock];
    NSDictionary *values = [name isEqual:NSRegistrationDomain] ? [_registered copy]
        : [name isEqual:NSArgumentDomain] ? _argumentOverrides : @{};
    [_lock unlock];
    return values;
}

- (BOOL)synchronize
{
    [_lock lock];
    [self refreshReadOnlyValues];
    BOOL result = _url != nil && _lastWriteSucceeded;
    [_lock unlock];
    return result;
}

- (id)valueForUndefinedKey:(NSString *)key { return [self objectForKey:key]; }
- (void)setValue:(id)value forUndefinedKey:(NSString *)key { [self setObject:value forKey:key]; }

@end

@implementation NSUserDefaults (OEPreferencesStore)
@end
