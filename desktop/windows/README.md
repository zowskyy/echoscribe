# EchoScribe

Windows tray app for push-to-talk transcription and local browser summaries.

Default transcription behavior:

- Hold `Alt+A` to record.
- Release the hotkey to transcribe.
- The result is copied to the clipboard and pasted into the previously active window.
- API errors are copied and pasted with the `[ECHOSCRIBE ERROR]` prefix.

Browser summary flow:

- The Chrome extension reads the current page or selected text.
- Chrome sends the content to `EchoScribe.NativeHost.exe` through Native Messaging.
- The native host calls the configured provider and returns the summary.
- API keys stay local in `appsettings.json`; they are not stored in the extension.

Configuration lives in `appsettings.json` next to the executable. The project can also import provider keys from `*.env` files in the project root.

The settings dialog is split into three tabs:

- `Audio`: STT provider/model, language, and hotkey.
- `Web Summary`: Chrome summary provider/model, URL extraction, and the URL summary prompt.
- `API-Keys`: all provider keys in one place, so STT can use ElevenLabs while summaries use Claude, OpenAI, Gemini, or xAI.

Speech-to-text providers:

- `openai`: `OPENAI_API_KEY`, default model `gpt-4o-mini-transcribe`
- `elevenlabs`: `ELEVENLABS_API_KEY`, default model `scribe_v2`
- `gemini`: `GEMINI_API_KEY` or `GOOGLE_API_KEY`, default model `gemini-3.1-flash-lite`
- `xai`: `XAI_API_KEY`, uses `https://api.x.ai/v1/stt`

Summary providers:

- `openai`: Chat Completions, default summary model `gpt-5.4-mini`
- `gemini`: `generateContent`, default summary model `gemini-3.1-flash-lite`
- `anthropic`: Messages API, default summary model `claude-sonnet-4-6`
- `xai`: OpenAI-compatible Chat Completions, default summary model `grok-4.3`

Claude/Anthropic is implemented for text summaries only. This app does not support Claude speech-to-text or text-to-speech unless Anthropic ships suitable audio models and the app is extended for them.

Build and publish:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\publish-echoscribe.ps1
```

Register the Chrome Native Messaging host and open the unpacked extension folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\register-chrome-host.ps1
```

Then open `chrome://extensions`, enable developer mode, and load `publish\chrome-extension` as an unpacked extension.
