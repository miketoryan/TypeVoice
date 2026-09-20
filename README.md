# TypeVoice

TypeVoice is an iOS AI voice keyboard focused on one job: tap the microphone, speak naturally, and insert cleaned text directly at the current cursor.

## Current behavior

TypeVoice uses a **finite warm-microphone window**, not an indefinitely wakeable background service.

```
TypeVoice keyboard becomes visible
        ↓
If microphone is warm
        ↓
Record immediately without leaving the current app
        ↓
Stop recording
        ↓
Transcribe + clean up
        ↓
UITextDocumentProxy.insertText(...)
        ↓
Text appears at the current cursor
```

When the TypeVoice keyboard is dismissed or switched away from, the selected warm window starts:

- 10 seconds
- 30 seconds
- 1 minute
- 5 minutes

While the TypeVoice keyboard remains visible, **no standby countdown runs**.

When the warm window expires, TypeVoice releases microphone input and enters **cold standby**. Quick Dictation remains enabled. The next keyboard use opens TypeVoice briefly, waits until the containing app is fully foreground-active, rebuilds the audio session and microphone graph, starts dictation, then returns to the original input app.

## iOS constraint

Apple does not allow a custom keyboard extension to own microphone input directly. TypeVoice therefore uses:

- the containing app for microphone ownership and transcription;
- a persistent input tap during the finite warm window;
- a separate silent-output anchor only to improve short background residency;
- LocalBridge on 127.0.0.1 for app/keyboard command and state exchange;
- Darwin notifications only for lightweight visibility, command and result signals;
- a real user-tapped SwiftUI `Link` for cold foreground activation;
- `UITextDocumentProxy` for final text insertion.

There is no Picture in Picture design.

## Warm and cold paths

### Warm path

If the foreground-started microphone engine is healthy and still receiving real audio buffers, tapping the keyboard microphone opens only the recording-file gate. It does **not** restart AVAudioEngine or rebuild AVAudioSession in the background.

### Cold path

If microphone flow has ended, the keyboard does not spend time repeatedly trying to restart microphone IO from the background. It presents a real foreground activation link.

The containing app parks the keyboard request until `UIApplication.shared.applicationState == .active`. Only then does it:

1. clear the old microphone graph;
2. wait for ordered AVAudioSession teardown to finish;
3. reactivate the recording session;
4. rebuild and start the input engine;
5. verify real audio buffers are arriving;
6. start recording if requested;
7. return to the original app.

This avoids the `AUIOClient_StartIO / 2003329396` failure caused by trying to start microphone IO before the containing app is truly foreground-active.

## State model

Quick Dictation and microphone temperature are separate states.

- **Quick Dictation disabled** — user explicitly turned the feature off.
- **Quick Dictation enabled + warm** — keyboard can record immediately.
- **Quick Dictation enabled + cold** — microphone has been released; next keyboard use foreground-activates TypeVoice.
- **Recording / transcribing / cleaning** — active request states.

Standby timeout never disables Quick Dictation by itself.

## Audio behavior

TypeVoice uses a non-mixing `.playAndRecord` session while the warm microphone is active. If music is playing, iOS pauses competing playback while TypeVoice owns the session. When the warm session is released, TypeVoice deactivates with `.notifyOthersOnDeactivation`, allowing the previous audio app to resume when supported by iOS/the player.

## Language behavior

There is no Chinese/English recognition switch on the keyboard. Speech language is detected automatically by the speech/model pipeline, including mixed Chinese and English.

The Chinese/English setting in TypeVoice changes only the interface language.

## Reliability rules

The current architecture deliberately avoids several older experiments:

- no periodic keyboard heartbeat used as a background keep-alive;
- no 1.5-second background claim/retry loop before foreground activation;
- no hidden programmatic recovery launcher after a failed warm start;
- no attempt to rebuild microphone input from a Darwin/background callback;
- no trust in `AVAudioEngine.isRunning` alone — recent real input buffers are required;
- stale standby-timeout callbacks are generation-checked so an old timeout cannot tear down a newly warmed microphone;
- AVAudioSession teardown/re-activation is serialized so delayed `setActive(false)` cannot race a new `setActive(true)`.

## Build

The project uses XcodeGen.

```bash
brew install xcodegen
git clone https://github.com/miketoryan/TypeVoice.git
cd TypeVoice
xcodegen generate
open TypeVoice.xcodeproj
```

In Xcode:

1. Select your Apple Developer Team for TypeVoice and TypeVoiceKeyboard.
2. Confirm the App Group entitlement if using a signing setup that supports it.
3. Build and install on a real iPhone.
4. Add TypeVoice under Settings → General → Keyboard → Keyboards.
5. Enable Allow Full Access.
6. Open TypeVoice, sign in with ChatGPT, and enable Quick Dictation.

## Design references

The architecture was independently implemented after studying several open-source iOS voice-keyboard projects, particularly:

- Dictus iOS — cold starts are deferred until the app is truly active; warm and cold engine paths are explicitly separated.
- DICTATOR — microphone input is never restarted from the background; audio-engine mutations are serialized; silent output is treated as residency support rather than microphone health.
- VivaDicta — finite prewarm sessions keep one input engine/tap alive and terminate the session on timeout.
- Sayboard — one persistent audio session/tap is kept for a bounded session and recording is gated separately from engine lifetime.

No copyleft source code is copied into TypeVoice.

## Version

Current development line: v0.21.
