# AudioRoute — proof of concept

A native menu bar app for choosing a separate audio output for each application.

## Run

1. Double-click **AudioRoute.app** in this folder. A speaker icon appears in the menu bar; there is no Dock icon.
2. Start audio in Safari, a game, or another application, then click the icon.
3. Choose an output beside the application. macOS may ask for **System Audio Recording** access. Allow it to enable routing; no audio is saved or uploaded. If necessary, quit and reopen after granting permission.
4. Choose **System Default** to release an individual route and return control to the application/macOS. An application with its own explicit device setting will return to that setting.
5. Click **Quit** at the bottom of the popup, or right-click the icon and choose **Quit AudioRoute**. Quit stops playback callbacks, destroys the private audio devices and taps, and exits. Normal application audio resumes.

The gear menu includes **Reset All Outputs** and a shortcut to audio capture permissions. **Show idle apps** includes audio clients that are not currently running output.

## Scope and behaviour

- Apple Silicon Mac; macOS 14.2 or later. Built locally with Apple's command-line tools; ad-hoc signed, not notarized for public distribution.
- Real Core Audio process taps and output playback, not a simulated picker. No third-party packages, installer, driver, networking, account, or persistent helper.
- Routes are session-only. No launch-at-login setting or saved preferences.
- Stereo floating-point audio. On multichannel outputs, only the first two channels are used. Mono outputs are unavailable in this prototype.
- Input streams from physical microphones are disabled; only the selected application's tapped output is forwarded.
- The physical output supplies the aggregate-device clock, with tap drift compensation enabled. Unsupported formats and mismatched stream sample rates are rejected explicitly.
- Selecting a new output briefly releases the old route. Switching is not guaranteed gapless.
- Disconnecting a source/output releases its route. **Audio may resume on the system speakers.** This prototype does not promise privacy-preserving silence on disconnection.
- Sleep, system-default changes, and device sample-rate changes release routes. Select outputs again afterward.
- Browser/helper grouping is best effort. Some WebKit or other helper processes may appear as separate sources. This is application/process routing, not per-tab routing.
- An active audio client can be silent. “Waiting for audio” means no nonzero samples have reached the route yet, not proof that permission was denied.
- AirPlay, protected media, exclusive device access, spatial audio, and every Bluetooth configuration are not validated.

## Validation performed

- Release build completed using Swift/AppKit/SwiftUI and a small C real-time callback.
- Bundle property list and local code signature validated.
- Audio-buffer tests pass: interleaved and planar stereo, physical-input exclusion, short buffers, absent data, changed channel counts, non-finite samples, and audio activity counters.
- The development sandbox exposes no audio devices. Computer Use permission was unavailable, so live UI interaction, physical routing, latency, CPU usage during routing, and Quit while routing have **not** been verified on hardware.

## Hardware acceptance check

1. Connect headphones and a second output. Start two independent audio sources.
2. Send Safari to the speaker and the other app to headphones; confirm each device plays only its assigned source.
3. Switch one output and verify there is no duplicate playback or feedback.
4. Select System Default for one source and verify ordinary playback resumes.
5. Disconnect an output; verify its route is released and note the fallback behaviour above.
6. Try sleep/wake and restarting a source; verify the app remains responsive.
7. With routing active, click **Quit**; verify the icon disappears and sources resume ordinary playback without remaining muted.

## Build and test

Run `./build.sh` from this folder to rebuild the app (Apple Silicon). No Xcode project or package download is required. Rebuilding changes the ad-hoc signature and may require granting audio access again.

Run `./test.sh` for the buffer tests. `AudioRoute.app/Contents/MacOS/AudioRoute --inventory` prints audio devices and clients visible to the process. Running it inside restricted development tools may produce an empty inventory even when the desktop has working audio.

Source files: `Source/App.swift` (native interface and lifecycle), `Source/Audio.swift` (discovery and routing), and `Source/Render.c` (allocation-free audio callback).

API reference: [Apple — Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
