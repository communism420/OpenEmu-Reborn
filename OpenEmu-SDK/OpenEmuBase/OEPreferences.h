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

/// Posted on the changing thread; userInfo["key"] identifies a single changed
/// setting, and is absent when registered defaults or the whole file changed.
FOUNDATION_EXPORT NSNotificationName const OEPreferencesDidChangeNotification;
/// userInfo[NSUnderlyingErrorKey] contains the failure. The previous saved file
/// and value are retained when a write fails; clients should present the error.
FOUNDATION_EXPORT NSNotificationName const OEPreferencesPersistenceDidFailNotification;

/// The small settings interface shared by the app and reusable Kit components.
/// NSUserDefaults remains usable by standalone clients and existing unit tests.
@protocol OEPreferencesStore <NSObject>
- (nullable id)objectForKey:(NSString *)key;
- (nullable NSString *)stringForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key;
- (double)doubleForKey:(NSString *)key;
- (float)floatForKey:(NSString *)key;
- (nullable NSData *)dataForKey:(NSString *)key;
- (nullable NSArray *)arrayForKey:(NSString *)key;
- (nullable NSDictionary<NSString *, id> *)dictionaryForKey:(NSString *)key;
- (nullable NSArray<NSString *> *)stringArrayForKey:(NSString *)key;
- (nullable NSURL *)URLForKey:(NSString *)key NS_SWIFT_NAME(url(forKey:));
- (void)setObject:(nullable id)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (void)removeObjectForKey:(NSString *)key;
- (void)registerDefaults:(NSDictionary<NSString *, id> *)defaults NS_SWIFT_NAME(register(defaults:));
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;
- (NSDictionary<NSString *, id> *)volatileDomainForName:(NSString *)name;
- (BOOL)synchronize;
@end

@interface NSUserDefaults (OEPreferencesStore) <OEPreferencesStore>
@end

/// File-backed OpenEmu settings. This deliberately does not subclass or replace
/// UserDefaults: macOS keeps its own preferences and only the data-root bookmark
/// needs the system defaults database. All accesses are protected by a lock.
NS_SWIFT_SENDABLE
@interface OEPreferences : NSObject <OEPreferencesStore>
@property(class, nonatomic, readonly) OEPreferences *shared;
@property(class, nonatomic, readonly) BOOL isConfigured;
@property(nonatomic, readonly, nullable) NSError *lastError;

/// Configure once, before application settings are used. The file may not exist
/// yet but its parent directory must. Registration is permitted before this call
/// and never writes files. Helpers use readOnly:YES and refresh from the host's
/// file when reading; the main application is the only writer. A writable store
/// holds an exclusive process-lifetime lock in a sibling Settings.plist.lock
/// file, preventing a second app process from overwriting newer preferences.
/// Explicit command-line preferences override saved values in memory only.
+ (BOOL)configureWithURL:(NSURL *)url readOnly:(BOOL)readOnly error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(configure(url:readOnly:));

/// Merge a group of settings in one atomic write, for migrations and related
/// changes that must succeed together. Failure leaves every previous value and
/// the previous file unchanged. Arguments and registrations are not persisted.
- (BOOL)setValues:(NSDictionary<NSString *, id> *)values error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(setValues(_:));

- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
- (void)setDouble:(double)value forKey:(NSString *)key;
- (void)setFloat:(float)value forKey:(NSString *)key;
@end

NS_ASSUME_NONNULL_END
