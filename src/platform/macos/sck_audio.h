/**
 * @file src/platform/macos/sck_audio.h
 * @brief Native ScreenCaptureKit audio capture with bounded session lifetime.
 */
#pragma once

// standard includes
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <span>
#include <stdexcept>
#include <vector>

// local includes
#include "src/platform/common.h"

#ifdef __APPLE__
  // platform includes
  #include <CoreMedia/CoreMedia.h>
#endif

namespace platf::sck_audio {
  /**
   * @brief Thread-safe, bounded PCM handoff that outlives asynchronous native callbacks.
   */
  class capture_state_t {
  public:
    /**
     * @brief Allocate a fixed-capacity audio ring.
     * @param capacity Maximum number of interleaved PCM samples retained.
     */
    explicit capture_state_t(std::size_t capacity):
        samples_(capacity) {
      if (!capacity) {
        throw std::invalid_argument("Audio buffer capacity must be positive");
      }
    }

    /**
     * @brief Accept native startup completion unless this session has already ended.
     */
    void started() {
      std::lock_guard lock(mutex_);
      if (!closed_ && !failed_) {
        started_ = true;
      }
      changed_.notify_all();
    }

    /**
     * @brief Report native capture failure and wake every waiter.
     */
    void fail() {
      std::lock_guard lock(mutex_);
      failed_ = true;
      changed_.notify_all();
    }

    /**
     * @brief Cancel this session without waiting for a native completion handler.
     */
    void close() {
      std::lock_guard lock(mutex_);
      closed_ = true;
      size_ = 0;
      changed_.notify_all();
    }

    /**
     * @brief Check whether asynchronous callbacks may still publish into this session.
     * @return True after cancellation or native failure.
     */
    bool finished() const {
      std::lock_guard lock(mutex_);
      return closed_ || failed_;
    }

    /**
     * @brief Wait for startup, cancellation, or failure for a bounded interval.
     * @param timeout Maximum time to wait.
     * @return True only when native capture started before cancellation or failure.
     */
    bool wait_started(std::chrono::milliseconds timeout) {
      std::unique_lock lock(mutex_);
      changed_.wait_for(lock, timeout, [&] {
        return started_ || closed_ || failed_;
      });
      return started_ && !closed_ && !failed_;
    }

    /**
     * @brief Publish interleaved PCM, dropping the oldest samples on overflow.
     * @param input Complete, channel-aligned PCM frames.
     */
    void push(std::span<const float> input) {
      std::lock_guard lock(mutex_);
      if (closed_ || failed_) {
        return;
      }
      if (input.size() > samples_.size()) {
        input = input.last(samples_.size());
      }
      const auto discard = size_ + input.size() > samples_.size() ? size_ + input.size() - samples_.size() : 0;
      head_ = (head_ + discard) % samples_.size();
      size_ -= discard;
      for (float value : input) {
        samples_[(head_ + size_) % samples_.size()] = value;
        ++size_;
      }
      changed_.notify_all();
    }

    /**
     * @brief Read one packet without allowing a missing callback to hang shutdown.
     * @param output Destination for interleaved PCM.
     * @param timeout Maximum time to wait for a complete packet.
     * @return Capture status for the streaming pipeline.
     */
    capture_e read(std::span<float> output, std::chrono::milliseconds timeout) {
      std::unique_lock lock(mutex_);
      if (output.empty() || output.size() > samples_.size()) {
        return capture_e::capture_error;
      }
      changed_.wait_for(lock, timeout, [&] {
        return size_ >= output.size() || closed_ || failed_;
      });
      if (closed_) {
        return capture_e::interrupted;
      }
      if (failed_) {
        return capture_e::reinit;
      }
      if (size_ < output.size()) {
        std::fill(output.begin(), output.end(), 0.0f);
        return capture_e::timeout;
      }
      for (float &value : output) {
        value = samples_[head_];
        head_ = (head_ + 1) % samples_.size();
        --size_;
      }
      return capture_e::ok;
    }

  private:
    mutable std::mutex mutex_;  ///< Protects lifecycle and PCM state.
    std::condition_variable changed_;  ///< Wakes readers and startup waiters.
    std::vector<float> samples_;  ///< Fixed-capacity interleaved PCM ring.
    std::size_t head_ = 0;  ///< Index of the oldest retained sample.
    std::size_t size_ = 0;  ///< Number of retained samples.
    bool started_ = false;  ///< Native startup completed successfully.
    bool failed_ = false;  ///< Native capture reported an error.
    bool closed_ = false;  ///< The owning streaming session ended.
  };

#ifdef __APPLE__
  /**
   * @brief Validate and append planar or interleaved native float PCM.
   * @param sampleBuffer Ready native audio sample buffer.
   * @param state Destination session ring.
   * @param sampleRate Expected sample rate.
   * @param channels Expected mono or stereo channel count.
   * @return False when the native packet has an incompatible or truncated format.
   */
  bool append_sample(CMSampleBufferRef sampleBuffer, capture_state_t &state, std::uint32_t sampleRate, int channels);
#endif

  /**
   * @brief Create native system-audio capture without creating a Core Audio aggregate device.
   * @param sample_rate Requested PCM sample rate.
   * @param channels Requested channel count; ScreenCaptureKit supports mono or stereo here.
   * @return A ready microphone, or nullptr after bounded startup failure.
   */
  std::unique_ptr<mic_t> create(std::uint32_t sample_rate, int channels);
}  // namespace platf::sck_audio
