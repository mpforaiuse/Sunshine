# Native macOS audio reliability

This fork adds an optional ScreenCaptureKit system-audio backend for macOS.
Its first objective is audible stereo streaming and repeatable disconnect/reconnect without an additional audio driver.

## Recorded failure

The stock `2026.914.233613` Apple Silicon build was observed crashing after three stream disconnects on macOS 26.2.
Each session logged `CLIENT DISCONNECTED`, followed approximately ten seconds later by `Hang detected! Session failed to terminate in 10 seconds.`
The macOS crash reports showed the capture thread blocked in `AudioDeviceStart`, while the session handler waited for the audio thread to join.
System-audio access had already been granted.
Disabling audio allowed a subsequent disconnect to finish, but did not meet the requirement for sound.
Changing the USB output from 44.1 kHz to 48 kHz was an unverified diagnostic experiment, not an established fix.

## Change

Choose **Audio/Video > System Audio Capture > ScreenCaptureKit (stereo)** and keep **Audio Sink** blank.
The equivalent configuration is:

```ini
stream_audio = enabled
macos_audio_capture = screencapturekit
```

ScreenCaptureKit supplies PCM directly, without the process tap and aggregate-device startup sequence implicated in the recorded hang.
Startup waits at most three seconds, PCM reads wait at most 100 milliseconds, and disconnect requests native shutdown asynchronously.
Callbacks retain their own session state, so a callback arriving after cancellation cannot access a destroyed microphone or feed a later session.
The PCM ring has a fixed capacity and drops the oldest samples if a consumer falls behind.
The existing Core Audio backend remains the default for compatibility and comparison.

## Limits

The new backend accepts 48 kHz mono or stereo.
Select stereo in Moonlight.
Host audio remains audible even when Moonlight requests host muting.
Use the existing Core Audio backend for surround layouts or automatic host muting.
A custom Audio Sink continues to select the existing explicit-device path.

## Validation

The first local build passed 37 targeted native tests and 216 web tests.
The native tests cover real Core Media float PCM packets, planar channel ordering, incompatible formats, bounded buffering, cancellation, and late callbacks.
The settings control was inspected in a headless browser using the existing application styles.
These checks do not establish successful live audio capture or playback on a Moonlight client.
The acceptance test is audible playback, disconnect, a wait of at least fifteen seconds, and reconnect with audible playback again.
Repeat that cycle before treating the original failure as resolved.

## Local development build

Initialize the repository's submodules and follow the upstream macOS dependency instructions in `docs/building.md`.
Run `uv sync --locked` for the repository's formatting tools.
The local development app uses the configurable `PROJECT_FQDN` and `SUNSHINE_MACOS_DISPLAY_NAME` CMake values to distinguish its macOS permissions from the installed upstream app.
The tested build uses the following settings, with dependency paths adjusted to the local Homebrew installation:

```sh
BRANCH=master BUILD_VERSION=2026.1026.1 cmake -S . -B cmake-build-native-audio -G Ninja \
  -DBUILD_DOCS=OFF -DBUILD_TESTS=ON \
  -DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@4 \
  -DCMAKE_EXE_LINKER_FLAGS=-L/opt/homebrew/opt/icu4c@79/lib \
  -DPROJECT_FQDN=dev.mpforaiuse.app.SunshineNativeAudio \
  -DSUNSHINE_MACOS_DISPLAY_NAME="Sunshine Native Audio"
cmake --build cmake-build-native-audio -j 6
./cmake-build-native-audio/tests/test_sunshine \
  --gtest_filter='ScreenCaptureAudio*:ConfigPersistenceTest.*:ConfigDefaultsTest.*:ConfigConsistencyTest.*:MacosAudioPermissionTest.*'
npm test
```

The development app requires its own macOS capture permission and should be tested with a separate configuration directory.
Keep pairing certificates and credentials local, outside the repository.
The original Sunshine source and this fork remain under the repository's GPL-3.0-only license.
