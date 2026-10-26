/**
 * @file tests/unit/platform/macos/test_sck_audio.cpp
 * @brief Regressions for audio cancellation, late callbacks, and PCM buffering.
 */

// test includes
#include "../../../tests_common.h"

// standard includes
#include <array>
#include <future>

// local includes
#include "src/platform/macos/sck_audio.h"

using namespace std::chrono_literals;
using platf::capture_e;
using platf::sck_audio::capture_state_t;

/**
 * @brief Reject an empty ring instead of permitting modulo-by-zero during capture.
 */
TEST(ScreenCaptureAudioTest, RejectsEmptyCapacity) {
  EXPECT_THROW(capture_state_t(0), std::invalid_argument);
}

/**
 * @brief A missing native startup callback has a finite wait.
 */
TEST(ScreenCaptureAudioTest, StartupTimeoutIsBounded) {
  capture_state_t state(8);
  EXPECT_FALSE(state.wait_started(0ms));
  EXPECT_FALSE(state.finished());
}

/**
 * @brief Successful native startup releases a startup waiter.
 */
TEST(ScreenCaptureAudioTest, StartupCompletionIsObserved) {
  capture_state_t state(8);
  state.started();
  EXPECT_TRUE(state.wait_started(0ms));
}

/**
 * @brief A startup callback delivered after disconnect cannot resurrect capture.
 */
TEST(ScreenCaptureAudioTest, LateStartupCannotReopenClosedSession) {
  capture_state_t state(8);
  state.close();
  state.started();
  EXPECT_FALSE(state.wait_started(0ms));
  EXPECT_TRUE(state.finished());
  std::array<float, 2> output {};
  EXPECT_EQ(state.read(output, 0ms), capture_e::interrupted);
}

/**
 * @brief Native failure prevents a later success callback from reopening capture.
 */
TEST(ScreenCaptureAudioTest, NativeFailureCannotBeOverriddenByLateSuccess) {
  capture_state_t state(8);
  state.fail();
  state.started();
  EXPECT_FALSE(state.wait_started(0ms));
  EXPECT_TRUE(state.finished());
  std::array<float, 2> output {};
  EXPECT_EQ(state.read(output, 0ms), capture_e::reinit);
}

/**
 * @brief PCM ordering survives ring wraparound and multiple packet reads.
 */
TEST(ScreenCaptureAudioTest, PreservesPcmAcrossRingWraparound) {
  capture_state_t state(6);
  state.push(std::array<float, 4> {1, 2, 3, 4});
  std::array<float, 2> first {};
  ASSERT_EQ(state.read(first, 0ms), capture_e::ok);
  EXPECT_EQ(first, (std::array<float, 2> {1, 2}));
  state.push(std::array<float, 4> {5, 6, 7, 8});
  std::array<float, 6> rest {};
  ASSERT_EQ(state.read(rest, 0ms), capture_e::ok);
  EXPECT_EQ(rest, (std::array<float, 6> {3, 4, 5, 6, 7, 8}));
}

/**
 * @brief A slow client receives recent PCM rather than an ever-growing delayed stream.
 */
TEST(ScreenCaptureAudioTest, OverflowKeepsNewestSamples) {
  capture_state_t state(4);
  state.push(std::array<float, 4> {1, 2, 3, 4});
  state.push(std::array<float, 2> {5, 6});
  std::array<float, 4> output {};
  ASSERT_EQ(state.read(output, 0ms), capture_e::ok);
  EXPECT_EQ(output, (std::array<float, 4> {3, 4, 5, 6}));
}

/**
 * @brief An oversized native packet is bounded by the configured ring capacity.
 */
TEST(ScreenCaptureAudioTest, OversizedPacketKeepsNewestSamples) {
  capture_state_t state(4);
  state.push(std::array<float, 6> {1, 2, 3, 4, 5, 6});
  std::array<float, 4> output {};
  ASSERT_EQ(state.read(output, 0ms), capture_e::ok);
  EXPECT_EQ(output, (std::array<float, 4> {3, 4, 5, 6}));
}

/**
 * @brief A missing packet returns silence and a timeout without losing partial PCM.
 */
TEST(ScreenCaptureAudioTest, TimeoutDoesNotDiscardPartialPacket) {
  capture_state_t state(4);
  state.push(std::array<float, 2> {1, 2});
  std::array<float, 4> output {9, 9, 9, 9};
  EXPECT_EQ(state.read(output, 0ms), capture_e::timeout);
  EXPECT_EQ(output, (std::array<float, 4> {}));
  state.push(std::array<float, 2> {3, 4});
  ASSERT_EQ(state.read(output, 0ms), capture_e::ok);
  EXPECT_EQ(output, (std::array<float, 4> {1, 2, 3, 4}));
}

/**
 * @brief Invalid packet sizes fail immediately instead of waiting forever.
 */
TEST(ScreenCaptureAudioTest, RejectsUnserviceableReadSizes) {
  capture_state_t state(2);
  std::array<float, 4> oversized {};
  EXPECT_EQ(state.read(oversized, 0ms), capture_e::capture_error);
  EXPECT_EQ(state.read({}, 0ms), capture_e::capture_error);
}

/**
 * @brief Disconnect wakes a blocked audio reader without waiting for the native stop callback.
 */
TEST(ScreenCaptureAudioTest, DisconnectWakesBlockedReader) {
  auto state = std::make_shared<capture_state_t>(8);
  auto result = std::async(std::launch::async, [state] {
    std::array<float, 2> output {};
    return state->read(output, 100ms);
  });
  state->close();
  ASSERT_EQ(result.wait_for(1s), std::future_status::ready);
  EXPECT_EQ(result.get(), capture_e::interrupted);
}

/**
 * @brief PCM delivered after cancellation is ignored and cannot leak into a later session.
 */
TEST(ScreenCaptureAudioTest, LateAudioCannotCrossSessionBoundary) {
  capture_state_t old_session(4);
  old_session.push(std::array<float, 2> {1, 2});
  old_session.close();
  old_session.push(std::array<float, 2> {3, 4});
  capture_state_t new_session(4);
  std::array<float, 2> output {};
  EXPECT_EQ(new_session.read(output, 0ms), capture_e::timeout);
  new_session.push(std::array<float, 2> {5, 6});
  ASSERT_EQ(new_session.read(output, 0ms), capture_e::ok);
  EXPECT_EQ(output, (std::array<float, 2> {5, 6}));
}
