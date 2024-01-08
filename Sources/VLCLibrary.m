/*****************************************************************************
 * VLCLibrary.m: VLCKit.framework VLCLibrary implementation
 *****************************************************************************
 * Copyright (C) 2007 Pierre d'Herbemont
 * Copyright (C) 2007-2019 VLC authors and VideoLAN
 * $Id$
 *
 * Authors: Pierre d'Herbemont <pdherbemont # videolan.org>
 *          Felix Paul Kühne <fkuehne # videolan.org>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#import <VLCLibrary.h>
#import <VLCLibVLCBridging.h>
#import <VLCConsoleLogger.h>
#import <VLCFileLogger.h>
#import <VLCEventsHandler.h>
#import <VLCEventsConfiguration.h>

#if TARGET_OS_TV
# include "vlc-plugins-AppleTV.h"
#elif TARGET_OS_IPHONE
# include "vlc-plugins-iPhone.h"
#else
# include "vlc-plugins-MacOSX.h"
#endif

#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include <vlc/vlc.h>
#include <vlc_common.h>

static void HandleMessage(void *,
                          int,
                          const libvlc_log_t *,
                          const char *,
                          va_list);

static VLCLibrary * sharedLibrary = nil;

@interface VLCLegacyExternalLogger : NSObject<VLCLogging>
+ (instancetype)new NS_UNAVAILABLE;
+ (instancetype)createWithTarget:(id<VLCLibraryLogReceiverProtocol>)target;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithTarget:(id<VLCLibraryLogReceiverProtocol>)target;
@end

@implementation VLCLegacyExternalLogger {
    id<VLCLibraryLogReceiverProtocol> _target;
}
@synthesize level = _level;
+ (instancetype)createWithTarget:(id<VLCLibraryLogReceiverProtocol>)target {
    return [[self alloc] initWithTarget:target];
}
- (instancetype)initWithTarget:(id<VLCLibraryLogReceiverProtocol>)target {
    self = [super init];
    if (!self)
        return nil;
    _target = target;
    _level = kVLCLogLevelDebug;
    return self;
}
- (void)handleMessage:(NSString *)message
             logLevel:(VLCLogLevel)level
              context:(VLCLogContext *)context {
    if ([_target respondsToSelector:@selector(handleMessage:debugLevel:)])
        [_target handleMessage:message debugLevel:(int)level];
}
@end

@interface VLCLibrary()
@property (nonatomic, readonly) dispatch_queue_t logSyncQueue;
@end

@implementation VLCLibrary

static id<VLCEventsConfiguring> _sharedEventsConfiguration = nil;

+ (nullable id<VLCEventsConfiguring>)sharedEventsConfiguration
{
    return _sharedEventsConfiguration;
}

+ (void)setSharedEventsConfiguration:(nullable id<VLCEventsConfiguring>)value
{
    _sharedEventsConfiguration = value;
}

+ (void)load {
    [self setSharedEventsConfiguration:[VLCEventsLegacyConfiguration new]];
}

+ (VLCLibrary *)sharedLibrary
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedLibrary = [[VLCLibrary alloc] init];
    });
    return sharedLibrary;
}

+ (void *)sharedInstance
{
    return [self sharedLibrary].instance;
}

- (instancetype)init
{
    if (self = [super init]) {
        [self prepareInstanceWithOptions:nil];
    }
    return self;
}

- (instancetype)initWithOptions:(NSArray *)options
{
    if (self = [super init]) {
        [self prepareInstanceWithOptions:options];
    }
    return self;
}

- (void)prepareInstanceWithOptions:(NSArray *)options
{
    _logSyncQueue = dispatch_queue_create("org.videolan.vlclibrary.logsyncqueue", DISPATCH_QUEUE_SERIAL);
    NSArray *allOptions = options ? [[self _defaultOptions] arrayByAddingObjectsFromArray:options] : [self _defaultOptions];

    NSUInteger paramNum = 0;
    int count = (int)allOptions.count;
    const char *lib_vlc_params[count];
    while (paramNum < count) {
        lib_vlc_params[paramNum] = [allOptions[paramNum] cStringUsingEncoding:NSASCIIStringEncoding];
        paramNum++;
    }
    _instance = libvlc_new(count, lib_vlc_params);

    NSAssert(_instance, @"libvlc failed to initialize");
}

- (NSArray *)_defaultOptions
{
    NSArray *vlcParams = [[NSUserDefaults standardUserDefaults] objectForKey:@"VLCParams"];
#if TARGET_OS_IPHONE
    if (!vlcParams) {
        vlcParams = @[@"--no-color",
                      @"--no-osd",
                      @"--no-video-title-show",
                      @"--no-snapshot-preview",
                      @"--http-reconnect",
#ifndef NOSCARYCODECS
#ifndef __LP64__
                      @"--avcodec-fast",
#endif
#endif
                      @"--text-renderer=freetype",
                      @"--avi-index=3",
                      @"--audio-resampler=soxr"];
    }
#else
    if (!vlcParams) {
        NSMutableArray *defaultParams = [NSMutableArray array];
        [[NSUserDefaults standardUserDefaults] setObject:defaultParams forKey:@"VLCParams"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        vlcParams = defaultParams;
    }
#endif

    return vlcParams;
}

- (void)setDebugLogging:(BOOL)debugLogging
{
    self.loggers = debugLogging ? @[[VLCConsoleLogger new]] : nil;
}

- (BOOL)debugLogging {
    return _loggers.count > 0;
}

- (void)setLoggers:(NSArray< id<VLCLogging> > *)loggers {
    if (_instance == NULL)
        return;
    _loggers = [loggers copy];
    dispatch_sync(_logSyncQueue, ^{
        libvlc_log_unset(_instance);
    });
    if (_loggers.count > 0)
        libvlc_log_set(_instance, HandleMessage, (__bridge void *)(self));
}

- (void)setDebugLoggingLevel:(int)debugLoggingLevel
{
    id<VLCLogging> logger = _loggers.firstObject;
    if (![logger respondsToSelector:@selector(setLevel:)])
        return;
    
    logger.level = MAX(0, MIN(debugLoggingLevel, 3));
}

- (int)debugLoggingLevel {
    id<VLCLogging> logger = _loggers.firstObject;
    if (![logger respondsToSelector:@selector(level)])
        return -1;
    
    return (int)logger.level;
    
}

- (BOOL)setDebugLoggingToFile:(NSString * _Nonnull)filePath
{
    BOOL available = [[NSFileManager defaultManager] createFileAtPath:filePath
                                                             contents:nil
                                                           attributes:nil];
    if (!available)
        return NO;
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
    if (fileHandle == nil)
        return NO;
    [fileHandle seekToEndOfFile];
    
    VLCFileLogger *logger = [VLCFileLogger createWithFileHandle:fileHandle];
    [self setLoggers:@[logger]];
    return logger != nil;
}

- (void)setDebugLoggingTarget:(nullable id<VLCLibraryLogReceiverProtocol>) target
{
    VLCLegacyExternalLogger *logger = [VLCLegacyExternalLogger createWithTarget:target];
    [self setLoggers:@[logger]];
}

- (NSString *)version
{
    return @(libvlc_get_version());
}

- (NSString *)compiler
{
    return @(libvlc_get_compiler());
}

- (NSString *)changeset
{
    return @(libvlc_get_changeset());
}

- (void)setHumanReadableName:(NSString *)readableName withHTTPUserAgent:(NSString *)userAgent
{
    if (_instance)
        libvlc_set_user_agent(_instance, [readableName UTF8String], [userAgent UTF8String]);
}

- (void)setApplicationIdentifier:(NSString *)identifier withVersion:(NSString *)version andApplicationIconName:(NSString *)icon
{
    if (_instance)
        libvlc_set_app_id(_instance, [identifier UTF8String], [version UTF8String], [icon UTF8String]);
}

- (void)dealloc
{
    if (_instance != NULL) {
        dispatch_sync(_logSyncQueue, ^{
            libvlc_log_unset(_instance);
        });
        libvlc_release(_instance);
    }
}

@end

@interface VLCLogContext ()
@property (nonatomic, readwrite) uintptr_t objectId;
@property (nonatomic, readwrite) NSString *objectType;
@property (nonatomic, readwrite) NSString *module;
@property (nonatomic, readwrite, nullable) NSString *header;
@property (nonatomic, readwrite, nullable) NSString *file;
@property (nonatomic, readwrite) int line;
@property (nonatomic, readwrite, nullable) NSString *function;
@property (nonatomic, readwrite) unsigned long threadId;
@end

@implementation VLCLogContext

@end

static VLCLogLevel logLevelFromLibvlcLevel(int level) {
    switch (level)
    {
        case LIBVLC_NOTICE:
            return kVLCLogLevelInfo;
        case LIBVLC_ERROR:
            return kVLCLogLevelError;
        case LIBVLC_WARNING:
            return kVLCLogLevelWarning;
        case LIBVLC_DEBUG:
        default:
            return kVLCLogLevelDebug;
    }
}

static VLCLogContext* logContextFromLibvlcLogContext(const libvlc_log_t *ctx) {
    VLCLogContext *context = nil;
    if (ctx) {
        context = [VLCLogContext new];
        context.objectId = ctx->i_object_id;
        context.objectType = [NSString stringWithUTF8String:ctx->psz_object_type];
        context.module = [NSString stringWithUTF8String:ctx->psz_module];
        if (ctx->psz_header != NULL)
            context.header = [NSString stringWithUTF8String:ctx->psz_header];
        if (ctx->file != NULL)
            context.file = [NSString stringWithUTF8String:ctx->file];
        context.line = ctx->line;
        if (ctx->func != NULL)
            context.function = [NSString stringWithUTF8String:ctx->func];
        context.threadId = ctx->tid;
    }
    return context;
}

static void HandleMessage(void *data,
                          int level,
                          const libvlc_log_t *ctx,
                          const char *fmt,
                          va_list args)
{
    VLCLibrary *libraryInstance = (__bridge VLCLibrary *)data;
    
    char *messageStr;
    int len = vasprintf(&messageStr, fmt, args);
    if (len == -1) {
        return;
    }
    
    NSString *message = [[NSString alloc] initWithBytesNoCopy:messageStr
                                                       length:len
                                                     encoding:NSUTF8StringEncoding
                                                 freeWhenDone:YES];
    const VLCLogLevel logLevel = logLevelFromLibvlcLevel(level);
    VLCLogContext *context = logContextFromLibvlcLogContext(ctx);
    dispatch_sync(libraryInstance.logSyncQueue, ^{
        [libraryInstance.loggers enumerateObjectsWithOptions:NSEnumerationConcurrent
                                                  usingBlock:^(id<VLCLogging>  _Nonnull logger,
                                                               NSUInteger idx,
                                                               BOOL * _Nonnull stop) {
            @autoreleasepool {
                if (logLevel > logger.level)
                    return;
                [logger handleMessage:message logLevel:logLevel context:context];
            }
        }];
    });
}
