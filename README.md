# TypeVoice

TypeVoice is an iOS AI voice keyboard focused on one job: tap the microphone, speak naturally, and have cleaned text inserted directly at the current cursor.

## Target behavior

```
Tap TypeVoice microphone
        ↓
If the background audio service is ready
        ↓
Stay in the current app
        ↓
Record
        ↓
OpenAI speech-to-text
        ↓
Automatically detect Chinese / English / mixed speech
        ↓
AI cleanup
- remove filler words
- remove repetitions
- resolve obvious self-corrections
- remove abandoned fragments
- add natural punctuation
        ↓
UITextDocumentProxy.insertText(...)
        ↓
Text appears at the current cursor
```

There is **no Chinese/English recognition switch** on the keyboard. The language option in TypeVoice settings controls only the TypeVoice interface language.

There is **no Picture in Picture (PiP)** design.

## iOS constraint

Apple does not allow a custom keyboard extension to access the microphone directly. TypeVoice therefore uses:

- the containing app for microphone ownership and transcription;
- an App Group for shared state;
- Darwin notifications for lightweight cross-process start/stop/result signals;
- `UITextDocumentProxy` in the keyboard extension for direct insertion.

In the v0.20 ActiveSession experiment, TypeVoice starts one AVAudioEngine while the containing app is foregrounded. Standby keeps only a looping silent output path alive; the microphone input tap is absent. A keyboard dictation attaches the input tap to that already-running engine and removes it again when recording stops. This specifically avoids calling AVAudioEngine.start() from the background between dictations. If iOS has invalidated the running audio graph, the keyboard falls back to opening TypeVoice so the graph can be rebuilt in the foreground.

## Current scope — v0.1

- iOS 16+
- TypeVoice app + custom keyboard extension
- background-ready output-only ActiveSession service
- input-tap start/stop without background AVAudioEngine restart
- foreground recovery fallback when the active graph is invalidated
- OpenAI transcription (default model is configurable)
- OpenAI text cleanup (default model is configurable)
- automatic language detection by speech/model pipeline
- direct insertion with duplicate-result protection
- API key stored in Keychain
- Chinese / English UI setting only
- 10 / 20 / 60 minute ready windows

## Build

This repository uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) so the Xcode project is generated from `project.yml`.

```bash
brew install xcodegen
git clone https://github.com/miketoryan/TypeVoice.git
cd TypeVoice
xcodegen generate
open TypeVoice.xcodeproj
```

In Xcode:

1. Select your Apple Developer Team for both **TypeVoice** and **TypeVoiceKeyboard**.
2. Confirm the App Group exists for both targets: `group.com.miketoryan.typevoice`.
3. Build and install on a real iPhone.
4. On iPhone, go to **Settings → General → Keyboard → Keyboards → Add New Keyboard → TypeVoice**.
5. Enable **Allow Full Access** for TypeVoice. App Group communication requires it.
6. Open TypeVoice once, grant microphone permission, enter an OpenAI API key, then tap **Enable Quick Dictation**.
7. Switch to TypeVoice in any text field and tap the microphone.

> ChatGPT Plus and OpenAI API billing are separate. TypeVoice uses an OpenAI API key; a ChatGPT Plus subscription by itself does not provide API credits.

## Privacy

Audio is captured by the TypeVoice containing app. In the default configuration it is uploaded to the configured OpenAI-compatible API for transcription, and the resulting transcript is sent for cleanup. TypeVoice does not intentionally send text from the host app to the model.

The v0.20 design keeps background execution alive with silent output while no input tap is installed during standby. The microphone path is attached only during an actual dictation and removed immediately afterwards. iOS still controls the privacy indicator and may change audio-session behavior across OS versions, so this behavior is being validated on real devices.

## Design references

The architecture was independently implemented after studying several open-source iOS voice-keyboard projects, especially:

- Dictus iOS — MIT
- VivaDicta — MIT
- VocaPhone — AGPL-3.0, architecture/behavior reference only
- Sayboard — GPL-3.0, architecture/behavior reference only

No source code from copyleft projects is copied into TypeVoice.

## Status

v0.1 is the first architecture build. It is intended for on-device testing before UI polish and App Store hardening.
