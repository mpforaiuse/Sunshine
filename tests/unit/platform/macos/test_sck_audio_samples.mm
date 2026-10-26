/**
 * @file tests/unit/platform/macos/test_sck_audio_samples.mm
 * @brief Validate real Core Media PCM packets before they enter the audio ring.
 */

#ifdef __APPLE__

  // test includes
  #include "../../../tests_common.h"

  // standard includes
  #include <array>

  // platform includes
  #import <AudioToolbox/AudioToolbox.h>

  // local includes
  #include "src/platform/macos/sck_audio.h"

using namespace std::chrono_literals;

namespace {
  /**
   * @brief Build a two-frame native stereo sample with independently identifiable channels.
   * @param planar Whether each channel occupies its own buffer.
   * @param floating_point Whether the format describes float PCM.
   * @return A retained ready Core Media sample, or nullptr on fixture failure.
   */
  CMSampleBufferRef make_audio_sample(bool planar, bool floating_point = true) {
    AudioStreamBasicDescription format {};
    format.mSampleRate = 48000;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsPacked | (floating_point ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | (planar ? kAudioFormatFlagIsNonInterleaved : 0);
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(float) * (planar ? 1 : 2);
    format.mBytesPerPacket = format.mBytesPerFrame;
    CMAudioFormatDescriptionRef description = nullptr;
    if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &format, 0, nullptr, 0, nullptr, nullptr, &description) != noErr) {
      return nullptr;
    }
    CMSampleBufferRef sample = nullptr;
    CMSampleTimingInfo timing {CMTimeMake(1, 48000), kCMTimeZero, kCMTimeInvalid};
    auto status = CMSampleBufferCreate(kCFAllocatorDefault, nullptr, false, nullptr, nullptr, description, 2, 1, &timing, 0, nullptr, &sample);
    CFRelease(description);
    if (status != noErr) {
      return nullptr;
    }
    std::array<float, 4> interleaved {1, 2, 3, 4};
    std::array<float, 2> left {1, 3};
    std::array<float, 2> right {2, 4};

    struct {
      UInt32 count;
      AudioBuffer buffers[2];
    } list {};

    list.count = planar ? 2 : 1;
    list.buffers[0] = {planar ? 1U : 2U, static_cast<UInt32>(planar ? sizeof(left) : sizeof(interleaved)), planar ? left.data() : interleaved.data()};
    list.buffers[1] = {1, sizeof(right), right.data()};
    status = CMSampleBufferSetDataBufferFromAudioBufferList(sample, kCFAllocatorDefault, kCFAllocatorDefault, 0, reinterpret_cast<AudioBufferList *>(&list));
    if (status == noErr) {
      status = CMSampleBufferSetDataReady(sample);
    }
    if (status != noErr) {
      CFRelease(sample);
      return nullptr;
    }
    return sample;
  }
}  // namespace

/**
 * @brief Preserve stereo channel ordering for both native float layouts.
 */
TEST(ScreenCaptureAudioSamplesTest, ReadsPlanarAndInterleavedFloatPcm) {
  for (bool planar : {false, true}) {
    platf::sck_audio::capture_state_t state(8);
    auto sample = make_audio_sample(planar);
    ASSERT_NE(sample, nullptr);
    EXPECT_TRUE(platf::sck_audio::append_sample(sample, state, 48000, 2));
    CFRelease(sample);
    std::array<float, 4> output {};
    EXPECT_EQ(state.read(output, 0ms), platf::capture_e::ok);
    EXPECT_EQ(output, (std::array<float, 4> {1, 2, 3, 4}));
  }
}

/**
 * @brief Reject format changes before misinterpreting data as negotiated stereo float PCM.
 */
TEST(ScreenCaptureAudioSamplesTest, RejectsIncompatibleFormatAndMissingSample) {
  platf::sck_audio::capture_state_t state(8);
  EXPECT_FALSE(platf::sck_audio::append_sample(nullptr, state, 48000, 2));
  auto sample = make_audio_sample(false);
  ASSERT_NE(sample, nullptr);
  EXPECT_FALSE(platf::sck_audio::append_sample(sample, state, 44100, 2));
  EXPECT_FALSE(platf::sck_audio::append_sample(sample, state, 48000, 1));
  EXPECT_FALSE(platf::sck_audio::append_sample(sample, state, 48000, 0));
  EXPECT_FALSE(platf::sck_audio::append_sample(sample, state, 48000, 6));
  CFRelease(sample);
  sample = make_audio_sample(false, false);
  ASSERT_NE(sample, nullptr);
  EXPECT_FALSE(platf::sck_audio::append_sample(sample, state, 48000, 2));
  CFRelease(sample);
}

/**
 * @brief Reject unsupported negotiation without opening a display or showing a permission prompt.
 */
TEST(ScreenCaptureAudioSamplesTest, RejectsUnsupportedNegotiation) {
  EXPECT_EQ(platf::sck_audio::create(44100, 2), nullptr);
  EXPECT_EQ(platf::sck_audio::create(48000, 0), nullptr);
  EXPECT_EQ(platf::sck_audio::create(48000, 6), nullptr);
}

#endif
