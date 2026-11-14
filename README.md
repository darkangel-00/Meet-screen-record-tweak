# Meet Local Recorder (experimental Theos tweak)

An Objective-C++/Logos `.dylib` intended for injection into a Google Meet IPA
that you are authorized to modify, for personal testing with recording consent.
Not tested on iOS 26.6.1 or Google Meet's current WebRTC implementation.

## What it does

- Adds a draggable REC/STOP button to the foreground key UIWindow.
- Starts ReplayKit with microphone enabled; stops into a temporary MP4.
- Requests add-only Photos permission, adds the movie, deletes the temp MP4
  only after PhotoKit confirms success, and reports errors on screen.
- Intercepts AVAudioSession mode/category changes to attempt to change
  VoiceChat/VideoChat to Default/PlayAndRecord/MixWithOthers/DefaultToSpeaker.
- Contains hooks for three CXProvider report methods. By default these pass
  through to avoid breaking signaling/audio activation; set the experimental
  compile option to enable suppression, at your own risk.

## What it cannot guarantee

ReplayKit may omit remote participant audio even when the video and local
microphone work; an audio-session hook doesn't grant protected system-audio
access, disable system restrictions, or control audio routing within WebRTC.
Forcing Default mode may remove automatic echo cancellation or mute your mic.
It is not a verified "CallKit bypass" or production-ready call recorder.
ReplayKit's recording APIs are deprecated in current Apple SDKs but retained
here because the specific in-app API was requested.

## Build (Theos + matching iOS SDK and toolchain required)

    export THEOS="$HOME/theos" # adjust to your installation
    make clean package FINALPACKAGE=1
    find .theos/obj -name 'MeetLocalRecorder.dylib'

To just compile, use `make clean all`.

Required target and architecture are set in Makefile. `ARCHS=arm64` is correct
for third-party apps on iPhone 15; building an additional arm64e slice is not
required. Choose the Logos Substrate-compatible injector that your sideloader
bundles. This tweak does not use jailbreak filesystem paths.

To disable audio-session rewrites, edit Makefile to
`-DMLR_FORCE_DEFAULT_AUDIO=0`.
To experimentally suppress CXProvider reports, change
`-DMLR_EXPERIMENTAL_CALLKIT_SUPPRESS=0` to `=1` (can break calls).
Rebuild the dylib after changes.

## Info.plist privacy keys: BEFORE re-signing

Use the included stdlib-only script:

    python3 patch_ipa_info.py original.ipa Meet-unsigned-patched.ipa

It edits the **main app** `Payload/<AppName>.app/Info.plist`, creating:

    <key>NSPhotoLibraryAddUsageDescription</key>
    <string>Save meeting recordings you start to your Photos library.</string>

If the app lacks `NSMicrophoneUsageDescription`, the script adds it as well.
Editing the signed IPA INVALIDATES the old signature. Always inject + sign the
patched result with Feather (ElleKit) or Sideloadly (CydiaSubstrate).
For Sideloadly, open Advanced Options, enable tweak injection, choose the dylib,
and enable compatible Substrate injection before signing/installing.
For Feather, import the patched IPA, select tweak injection in signing options,
add the dylib/compatible ElleKit support, sign and install.

The `MeetLocalRecorder.plist` filter currently targets `com.google.Tachyon`.
Check the exact `CFBundleIdentifier` in the IPA because resigner tools may
change it; update the filter accordingly. An injected dylib must also be
loaded by the app's binary/framework loader. Merely copying it into the IPA
is not sufficient. The `.deb` is optional; the `.dylib` is the main artifact.

## Testing and diagnosis

1. On a consented test call, tap REC and grant relevant permissions.
2. Verify local video, microphone, remote participant audio, and WebRTC mic
   separately. Do not equate successful MP4 creation with captured app audio.
3. Tap STOP, grant add-only Photos permission, inspect the new movie in Photos.
4. If playback/mic fails, first turn off MLR_FORCE_DEFAULT_AUDIO and retry.
5. If the app freezes with CallKit suppression, disable it immediately.
6. If PhotoKit fails, the temporary file is retained (see the error path).

No CI build/test is provided; validation requires a real iOS SDK, Theos,
a matching injector, and a physical iOS 26.6.1 device.
# Trigger
# Trigger 2
