/*****************************************************************************
 * VLCTranscoder.m: VLCKit.framework VLCTranscoder implementation
 *****************************************************************************
 * Copyright (C) 2018 Carola Nitz
 * Copyright (C) 2018 VLC authors and VideoLAN
 * $Id$
 *
 * Authors:  Carola Nitz <caro # videolan.org>
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
#import <VLCTranscoder.h>

#import <VLCLibrary.h>
#import <VLCLibVLCBridging.h>
#import <VLCEventsHandler.h>

#include <vlc/vlc.h>

@interface VLCTranscoder()
{
    libvlc_media_player_t *_p_mp; //player instance used for transcoding
    dispatch_queue_t _libVLCTranscoderQueue;
    VLCEventsHandler *_eventsHandler;
}
@end

@implementation VLCTranscoder

- (instancetype)init
{
    if (self = [super init]) {
        _libVLCTranscoderQueue = dispatch_queue_create("libVLCTranscoderQueue", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)reencodeAndMuxSRTFile:(NSString *)srtPath toMP4File:(NSString *)mp4Path outputPath:(NSString *)outPath
{
    libvlc_media_t* p_media = libvlc_media_new_path([mp4Path UTF8String]);
    if (p_media == NULL) {
        NSAssert(0, @"p_media wasn't allocated");
        return NO;
    }
    NSString *transcodingOptions = [NSString stringWithFormat:@":sout=#transcode{venc={module=avcodec{codec=h264_videotoolbox}, vcodec=h264},venc={module=vpx{quality-mode=2},vcodec=VP80},samplerate=44100,soverlay}:file{dst='%@',mux=mkv}", outPath];
    libvlc_media_add_option(p_media, [[NSString stringWithFormat:@"--sub-file=%@", srtPath] UTF8String]);
    libvlc_media_add_option(p_media, [transcodingOptions UTF8String]);

    static const struct libvlc_media_player_cbs cbs = {
        .version = 0,
        .on_state_changed = HandleMuxMediaInstanceStateChanged,
    };

    _eventsHandler = [VLCEventsHandler handlerWithObject:self configuration:[VLCLibrary sharedEventsConfiguration]];
    _p_mp = libvlc_media_player_new_from_media([[VLCLibrary sharedLibrary] instance], p_media,
                                               &cbs, (__bridge void *)_eventsHandler);
    if (_p_mp == NULL) {
        NSAssert(0, @"_p_mp wasn't allocated");
        return NO;
    }

    BOOL canPlay = libvlc_media_player_play( _p_mp ) == 0;
    NSAssert(canPlay, @"playback failed");
    return canPlay;
}

- (void)mediaPlayerStateChangeForMux:(const VLCMediaPlayerState)newState
{
    if (_p_mp) {
        libvlc_media_player_stop_async( _p_mp );
        if ([self.delegate respondsToSelector:@selector(transcode:finishedSucessfully:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate transcode:self finishedSucessfully: newState != VLCMediaPlayerStateError];
            });
        }
    }
}

static void HandleMuxMediaInstanceStateChanged(void *opaque, libvlc_state_t state)
{
    /* v4's on_state_changed fires for every transition; the muxing operation
     * only ends on a terminal state, so ignore the rest to avoid stopping the
     * player as soon as it reaches Opening/Playing. */
    VLCMediaPlayerState newState;
    if (state == libvlc_Stopped) {
        newState = VLCMediaPlayerStateStopped;
    } else if (state == libvlc_Error) {
        newState = VLCMediaPlayerStateError;
    } else {
        return;
    }
    @autoreleasepool {
        VLCEventsHandler *eventsHandler = (__bridge VLCEventsHandler *)opaque;
        [eventsHandler handleEvent:^(id _Nonnull object) {
            VLCTranscoder *transcoder = (VLCTranscoder *)object;
            [transcoder mediaPlayerStateChangeForMux: newState];
        }];
    }
}

- (void)dealloc
{
    libvlc_media_player_release(_p_mp);
}
@end
