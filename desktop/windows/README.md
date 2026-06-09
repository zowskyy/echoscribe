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
- `EchoScribe.NativeHost.exe` is not a service and does not run at Windows startup. Chrome starts it only when the extension sends a Native Messaging request.

Native Messaging flow:

1. The extension calls `chrome.runtime.sendNativeMessage("de.echoscribe.nativehost", payload)`.
2. Chrome reads `HKCU\Software\Google\Chrome\NativeMessagingHosts\de.echoscribe.nativehost` or the matching registry key for another Chromium browser.
3. That registry value points to `native-host\de.echoscribe.nativehost.json`.
4. The manifest points to `native-host\EchoScribe.NativeHost.exe`.
5. Chrome starts the EXE for the request and communicates with it through stdin/stdout.

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

Install from a release package:

1. Download and unzip `EchoScribe-Windows-x64.zip`.
2. Double-click `install.cmd`.
3. In `chrome://extensions`, enable developer mode and load the `chrome-extension` folder from the unzipped package.

The installer runs per user and does not need administrator rights. It creates the Startup shortcut, starts `EchoScribe.exe`, registers the Native Messaging host for Chrome, Chromium, Edge, and Brave, and opens the extension folder.

The installer and `scripts\register-chrome-host.ps1` do not install the Chrome extension automatically. They only register the Native Messaging host so the manually loaded extension is allowed to start the local bridge executable.

Build from source:

If the .NET SDK is not installed globally, install the local SDK expected by the build scripts:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-dotnet-sdk.ps1
```

For a double-click local build, run:

```text
build-release.cmd
```

After the build completes, double-click `install.cmd` from this folder. It installs the freshly built `publish` directory.

Manual publish:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish-echoscribe.ps1
```

This creates:

- `publish\EchoScribe.exe`
- `publish\native-host\EchoScribe.NativeHost.exe`
- `publish\chrome-extension\`
- `publish\install.cmd`
- `EchoScribe-Windows-x64.zip`

Release packages use `appsettings.template.json` as `publish\appsettings.json` by default, so API keys are not bundled. For a private local-only package, pass `-IncludeLocalSettings`; never upload such a package to GitHub releases.

Register the Chrome Native Messaging host manually:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\register-chrome-host.ps1
```

For normal installs, prefer `install.cmd` from the published package because it also sets Startup and registers additional Chromium-based browsers.

After manual registration, load the extension yourself:

1. Open `chrome://extensions`.
2. Enable developer mode.
3. Click `Load unpacked`.
4. Select `publish\chrome-extension`.
