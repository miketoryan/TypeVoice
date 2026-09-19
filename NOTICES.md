# TypeVoice design references

TypeVoice is an independent implementation.

During architecture research, the following public projects were reviewed:

- getdictus/dictus-ios — MIT License
- n0an/VivaDicta — MIT License
- VocaHQ/vocaphone — GNU AGPL v3
- stanlsv/sayboard — GNU GPL v3
- cosmicshuai/open_voice_typer — public source reviewed for architecture; no code copied

Copyleft projects were used only to understand public behavior, iOS constraints, and architectural patterns. TypeVoice does not copy source from those repositories.

Key ideas independently implemented here include:

- microphone ownership in the containing iOS app rather than the keyboard extension;
- App Group shared state;
- Darwin notifications as payload-free process signals;
- a warm audio session with a heartbeat and expiration window;
- cold-start fallback to the containing app;
- single-attempt UITextDocumentProxy insertion with result-ID deduplication.
