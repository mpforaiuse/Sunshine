/**
 * @file src/platform/macos/sck_audio.mm
 * @brief ScreenCaptureKit audio capture that never joins an unresponsive Core Audio start call.
 */

// header include
#include "sck_audio.h"

// platform includes
#import <ScreenCaptureKit/ScreenCaptureKit.h>

// local includes
#include "src/logging.h"

using capture_state_t = platf::sck_audio::capture_state_t;

namespace platf::sck_audio {
  bool append_sample(CMSampleBufferRef sampleBuffer, capture_state_t &state, std::uint32_t sampleRate, int channels) {
    if (!sampleBuffer || channels < 1 || channels > 2 || !CMSampleBufferDataIsReady(sampleBuffer)) {
      return false;
    }
    const auto *format = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sampleBuffer));
    if (!format || format->mFormatID != kAudioFormatLinearPCM || !(format->mFormatFlags & kAudioFormatFlagIsFloat) || format->mBitsPerChannel != 32 || format->mChannelsPerFrame != channels || format->mSampleRate != sampleRate) {
      BOOST_LOG(::error) << "ScreenCaptureKit returned an unexpected PCM format";
      return false;
    }
    std::size_t required = 0;
    auto status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, &required, nullptr, 0, nullptr, nullptr, 0, nullptr);
    if (status != noErr || required < sizeof(AudioBufferList)) {
      return false;
    }
    std::vector<std::byte> storage(required);
    auto *buffers = reinterpret_cast<AudioBufferList *>(storage.data());
    CMBlockBufferRef block = nullptr;
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, nullptr, buffers, required, nullptr, nullptr, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block);
    if (status != noErr) {
      if (block) {
        CFRelease(block);
      }
      return false;
    }
    const auto frames = static_cast<std::size_t>(CMSampleBufferGetNumSamples(sampleBuffer));
    const bool planar = format->mFormatFlags & kAudioFormatFlagIsNonInterleaved;
    bool valid = buffers->mNumberBuffers == (planar ? channels : 1);
    for (UInt32 index = 0; valid && index < buffers->mNumberBuffers; ++index) {
      const auto &buffer = buffers->mBuffers[index];
      valid = buffer.mData && buffer.mDataByteSize >= frames * sizeof(float) * (planar ? 1 : channels);
    }
    if (valid) {
      if (planar) {
        std::vector<float> interleaved(frames * channels);
        for (std::size_t frame = 0; frame < frames; ++frame) {
          for (int channel = 0; channel < channels; ++channel) {
            interleaved[frame * channels + channel] = static_cast<const float *>(buffers->mBuffers[channel].mData)[frame];
          }
        }
        state.push(interleaved);
      } else {
        state.push({static_cast<const float *>(buffers->mBuffers[0].mData), frames * channels});
      }
    }
    if (block) {
      CFRelease(block);
    }
    return valid;
  }
}  // namespace platf::sck_audio

/**
 * @brief Native receiver whose PCM state remains valid after a session is cancelled.
 */
@interface SunshineAudioReceiver: NSObject <SCStreamOutput, SCStreamDelegate> {
@public
  std::shared_ptr<capture_state_t> state;  ///< Shared state retained by late native callbacks.
  std::uint32_t sampleRate;  ///< Negotiated PCM sample rate.
  int channels;  ///< Negotiated mono or stereo channel count.
}
@end

@implementation SunshineAudioReceiver

/**
 * @brief Wake the audio pipeline when macOS stops capture unexpectedly.
 * @param stream Native stream that stopped.
 * @param error Native capture failure.
 */
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  if (!state->finished()) {
    BOOST_LOG(::error) << "ScreenCaptureKit audio stopped: " << error.localizedDescription.UTF8String;
    state->fail();
  }
}

/**
 * @brief Validate native audio and publish PCM to the active session.
 * @param stream Native stream delivering the packet.
 * @param sampleBuffer Captured sample buffer.
 * @param type Native output type.
 */
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeAudio || state->finished() || !CMSampleBufferDataIsReady(sampleBuffer)) {
    return;
  }
  if (!platf::sck_audio::append_sample(sampleBuffer, *state, sampleRate, channels)) {
    BOOST_LOG(::error) << "ScreenCaptureKit returned an invalid PCM audio packet";
    state->fail();
  }
}

@end

/**
 * @brief Own native objects independently from the synchronous streaming thread.
 */
@interface SunshineAudioCapture: NSObject {
@public
  std::shared_ptr<capture_state_t> state;  ///< Cancellation, startup, and PCM state.
  SCStream *stream;  ///< Native stream retained through asynchronous stop completion.
  SunshineAudioReceiver *receiver;  ///< Native sample receiver with no pointer to the microphone owner.
  dispatch_queue_t controlQueue;  ///< Serializes creation and shutdown of native capture objects.
}
/**
 * @brief Begin asynchronous native setup.
 * @param sampleRate PCM sample rate requested by Moonlight.
 * @param channels PCM channel count requested by Moonlight.
 */
- (void)startWithSampleRate:(std::uint32_t)sampleRate channels:(int)channels;
/**
 * @brief Cancel delivery immediately and request asynchronous native shutdown.
 */
- (void)stop;
@end

@implementation SunshineAudioCapture

- (void)startWithSampleRate:(std::uint32_t)sampleRate channels:(int)channels {
  [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                             onScreenWindowsOnly:NO
                                               completionHandler:^(SCShareableContent *content, NSError *error) {
                                                 dispatch_async(controlQueue, ^{
                                                   if (state->finished()) {
                                                     return;
                                                   }
                                                   if (error || content.displays.count == 0) {
                                                     BOOST_LOG(::error) << "ScreenCaptureKit audio could not enumerate displays: " << (error ? error.localizedDescription.UTF8String : "No display available");
                                                     state->fail();
                                                     return;
                                                   }
                                                   SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:content.displays.firstObject excludingWindows:@[]];
                                                   SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
                                                   configuration.width = 2;
                                                   configuration.height = 2;
                                                   configuration.minimumFrameInterval = CMTimeMake(1, 1);
                                                   configuration.queueDepth = 3;
                                                   configuration.capturesAudio = YES;
                                                   configuration.excludesCurrentProcessAudio = YES;
                                                   configuration.sampleRate = sampleRate;
                                                   configuration.channelCount = channels;
                                                   receiver = [[SunshineAudioReceiver alloc] init];
                                                   receiver->state = state;
                                                   receiver->sampleRate = sampleRate;
                                                   receiver->channels = channels;
                                                   stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:receiver];
                                                   dispatch_queue_t queue = dispatch_queue_create("Sunshine.ScreenCaptureKit.Audio", DISPATCH_QUEUE_SERIAL);
                                                   NSError *outputError = nil;
                                                   if (![stream addStreamOutput:receiver type:SCStreamOutputTypeAudio sampleHandlerQueue:queue error:&outputError]) {
                                                     BOOST_LOG(::error) << "ScreenCaptureKit audio output failed: " << outputError.localizedDescription.UTF8String;
                                                     state->fail();
                                                     return;
                                                   }
                                                   [stream startCaptureWithCompletionHandler:^(NSError *startError) {
                                                     dispatch_async(controlQueue, ^{
                                                       if (state->finished()) {
                                                         [self stop];
                                                       } else if (startError) {
                                                         BOOST_LOG(::error) << "ScreenCaptureKit audio failed to start: " << startError.localizedDescription.UTF8String;
                                                         state->fail();
                                                       } else {
                                                         state->started();
                                                       }
                                                     });
                                                   }];
                                                 });
                                               }];
}

- (void)stop {
  state->close();
  dispatch_async(controlQueue, ^{
    // A late start completion may still need to stop a stream created after cancellation.
    SCStream *stoppingStream = stream;
    SunshineAudioReceiver *stoppingReceiver = receiver;
    [stoppingStream stopCaptureWithCompletionHandler:^(NSError *error) {
      // Retain both native objects until Apple finishes; the server never joins this callback.
      (void) stoppingReceiver;
      (void) stoppingStream;
      if (error) {
        BOOST_LOG(debug) << "ScreenCaptureKit audio stop: " << error.localizedDescription.UTF8String;
      }
    }];
  });
}

@end

namespace platf::sck_audio {
  namespace {
    /**
     * @brief Bridge asynchronous ScreenCaptureKit audio into Sunshine's PCM interface.
     */
    struct microphone_t: mic_t {
      SunshineAudioCapture *capture;  ///< ARC retains native setup through this microphone's lifetime.

      ~microphone_t() override {
        [capture stop];
      }

      /**
       * @brief Read PCM with a finite wait so disconnect can always finish.
       * @param output Destination PCM packet.
       * @return Capture status for the streaming pipeline.
       */
      capture_e sample(std::vector<float> &output) override {
        return capture->state->read(output, std::chrono::milliseconds(100));
      }
    };
  }  // namespace

  std::unique_ptr<mic_t> create(std::uint32_t sample_rate, int channels) {
    if (channels < 1 || channels > 2 || sample_rate != 48000) {
      BOOST_LOG(::error) << "ScreenCaptureKit audio requires 48 kHz mono or stereo; select stereo in Moonlight or use the Core Audio backend";
      return nullptr;
    }
    auto microphone = std::make_unique<microphone_t>();
    microphone->capture = [[SunshineAudioCapture alloc] init];
    microphone->capture->controlQueue = dispatch_queue_create("Sunshine.ScreenCaptureKit.AudioControl", DISPATCH_QUEUE_SERIAL);
    microphone->capture->state = std::make_shared<capture_state_t>(sample_rate * channels / 4);
    [microphone->capture startWithSampleRate:sample_rate channels:channels];
    if (!microphone->capture->state->wait_started(std::chrono::seconds(3))) {
      BOOST_LOG(::error) << "ScreenCaptureKit audio startup failed or exceeded 3 seconds; the host remains available for another connection";
      return nullptr;
    }
    BOOST_LOG(info) << "ScreenCaptureKit system audio started: " << sample_rate << " Hz, " << channels << " channels";
    return microphone;
  }
}  // namespace platf::sck_audio
