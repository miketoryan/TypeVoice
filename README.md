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

When the audio service is warm and its heartbeat is fresh, tapping the keyboard microphone does not open TypeVoice. If iOS has suspended the containing app, or the warm window has expired, the keyboard falls back to opening TypeVoice so the audio session can be prepared again.

## Current scope — v0.1

- iOS 16+
- TypeVoice app + custom keyboard extension
- background-ready microphone service
- warm start / cold-start fallback
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

The microphone may remain active during the configured Quick Dictation ready window so iOS can keep the containing app eligible for background audio execution. iOS will show its normal microphone privacy indicator while the microphone session is active.

## Design references

The architecture was independently implemented after studying several open-source iOS voice-keyboard projects, especially:

- Dictus iOS — MIT
- VivaDicta — MIT
- VocaPhone — AGPL-3.0, architecture/behavior reference only
- Sayboard — GPL-3.0, architecture/behavior reference only

No source code from copyleft projects is copied into TypeVoice.

## Status

v0.1 is the first architecture build. It is intended for on-device testing before UI polish and App Store hardening.
