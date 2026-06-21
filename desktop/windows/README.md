# EchoScribe

Windows tray app for push-to-talk transcription and local browser summaries.

Default transcription behavior:

- Hold `Alt+A` to record.
- Release the hotkey to transcribe.
- The result is copied to the clipboard and pasted into the previously active window.
- API errors are copied and pasted with the `[ECHOSCRIBE ERROR]` prefix.

Browser summary flow:

- A Chromium-based or Firefox extension reads the current page or selected text.
- The browser sends the content to `EchoScribe.NativeHost.exe` through Native Messaging.
- The native host calls the configured provider and returns the summary.
- API keys stay local in `appsettings.json`; they are not stored in the extension.
- `EchoScribe.NativeHost.exe` is not a service and does not run at Windows startup. The browser starts it only when the extension sends a Native Messaging request.

Native Messaging flow:

1. The extension calls `runtime.sendNativeMessage("de.echoscribe.nativehost", payload)`.
2. Chromium-based browsers read their `NativeMessagingHosts\de.echoscribe.nativehost` registry key; Firefox reads `HKCU\Software\Mozilla\NativeMessagingHosts\de.echoscribe.nativehost`.
3. Chromium-based browsers point to `native-host\de.echoscribe.nativehost.json`; Firefox points to `native-host\de.echoscribe.nativehost.firefox.json`.
4. The manifest points to `native-host\EchoScribe.NativeHost.exe`.
5. The browser starts the EXE for the request and communicates with it through stdin/stdout.

Configuration lives in `appsettings.json` next to the executable. The project can also import provider keys from `*.env` files in the project root.

The settings dialog is split into three tabs:

- `Audio`: STT provider/model, Local AI Whisper URL, optional Windows whisper.cpp paths, language, and hotkey.
- `Web Summary`: browser summary provider/model, Local AI LLM URL, URL extraction, and the URL summary prompt.
- `API-Keys`: cloud provider keys.

Speech-to-text providers:

- `openai`: `OPENAI_API_KEY`, default model `gpt-4o-mini-transcribe`
- `elevenlabs`: `ELEVENLABS_API_KEY`, default model `scribe_v2`
- `gemini`: `GEMINI_API_KEY` or `GOOGLE_API_KEY`, default model `gemini-3.5-flash`
- `xai`: `XAI_API_KEY`, uses `https://api.x.ai/v1/stt`
- `localai`: Local AI Whisper-compatible endpoint, or Windows whisper.cpp when configured by setup. The default HTTP URL is `http://127.0.0.1:8000/v1/audio/transcriptions`; the default HTTP model is `whisper-1`.

Summary providers:

- `openai`: Chat Completions, default summary model `gpt-5.4-mini`
- `gemini`: `generateContent`, default summary model `gemini-3.5-flash`
- `anthropic`: Messages API, default summary model `claude-sonnet-4-6`
- `xai`: OpenAI-compatible Chat Completions, default summary model `grok-4.3`
- `localai`: Ollama-compatible `/api/chat`, default URL `http://127.0.0.1:11434/api/chat`, default model `qwen2.5:7b`

Claude/Anthropic is implemented for text summaries only. This app does not support Claude speech-to-text or text-to-speech unless Anthropic ships suitable audio models and the app is extended for them.

Local AI expects an Ollama-compatible chat API with `model`, `stream: false`, `think: false`, and `messages`; EchoScribe reads `message.content`. For HTTP STT it sends multipart `file`, `model`, `response_format=json`, and optional `language`, then reads `text`. On Windows, setup can instead install Windows whisper.cpp and configure EchoScribe to call `whisper-cli.exe` directly with a local ggml model. Example Ollama models: `qwen2.5:7b`, `gemma4:e4b`, `qwen2.5:14b`, `gemma3`, `deepseek-r1`. For PoC use, keep endpoints on a trusted local network or VPN; EchoScribe does not add authentication to Local AI requests.

During `install.cmd`, the Windows installer can optionally configure Local AI:

- Windows whisper.cpp STT: downloads the current official whisper.cpp Windows release, downloads the selected ggml Whisper model, and writes the `whisper-cli.exe` and model paths into `appsettings.json`. CPU mode is available on a normal Windows install. If an NVIDIA/CUDA-capable driver is detected, setup asks whether to use a CUDA whisper.cpp build; EchoScribe does not install NVIDIA drivers or CUDA itself.
- Advanced WSL Whisper: only shown as an explicit advanced option when a usable WSL Linux distribution already exists. Standard Windows users do not need WSL.
- Local Ollama summaries: uses or installs Ollama for Windows on `http://127.0.0.1:11434`, or uses a reachable Ollama API on another host. It detects NVIDIA GPU/VRAM and system RAM, then shows a color-coded model list for different PCs, including CPU-only/iGPU systems. The list spans smaller/faster 8B-class options through compact Gemma and stronger 14B, 26B/32B, and large 70B/72B-class models. It configures summary provider `localai`, sets `localAiLlmUrl` on port `11434`, and can download/check the selected model with `ollama pull`. Green means comfortable, yellow means tight, and red means likely too large or slow for the detected hardware. The default recommendation is `qwen2.5:7b`; larger 32B/31B models are marked as tight and 70B/72B models as likely too large.

The standard Windows install does not require WSL, CUDA, or Ollama. If you choose Local AI summaries, setup can install Ollama for Windows and pull the selected model. It does not install WSL or NVIDIA CUDA drivers/toolkits.

Install from a GitHub release:

1. Download and unzip `EchoScribe-Windows-x64-<version>.zip`, or use a source checkout.
2. Double-click `install.cmd`.
3. Keep the default install folder or choose another one in the setup TUI.
4. If setup asks to build EchoScribe, accept the build. The local .NET SDK is installed automatically when needed.
5. For Chrome, Edge, Brave, or Chromium, enable developer mode on the browser's extensions page and load the installed `chrome-extension` folder shown by setup. For Firefox, use `about:debugging#/runtime/this-firefox` and load the installed `firefox-extension\manifest.json` as a temporary add-on.

The installer runs per user and does not need administrator rights. The default install folder is `%LOCALAPPDATA%\EchoScribe`. The setup TUI lets you choose the install folder, enable or disable autostart, register the browser Native Messaging hosts, open browser extension setup pages, and start EchoScribe after installation. It also creates a per-user Start Menu shortcut under `EchoScribe\EchoScribe.lnk`.

Autostart is implemented as a per-user Startup shortcut named `EchoScribe.lnk`. During setup, old EchoScribe Startup shortcuts and old EchoScribe `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entries are removed before the current shortcut is written, so autostart points to the selected install folder. The Native Host is not started at login; browsers start it on demand when the extension sends a summary request.

To uninstall, run `uninstall.cmd`. The uninstaller lets you choose separately whether to remove EchoScribe app files, Start Menu and autostart entries, browser Native Messaging registrations, Windows whisper.cpp Local Whisper files, optional legacy WSL Local Whisper files, all local Ollama models, and Ollama itself. Ollama removal is separate because Ollama may be shared with other apps.

The installer and the compatibility-named `scripts\register-chrome-host.ps1` helper do not install browser extensions automatically. They only register the Native Messaging hosts so manually loaded extensions are allowed to start the local bridge executable.

From a source checkout, `install.cmd` is still the only required entry point. If `publish\EchoScribe.exe` does not exist yet, setup offers to build it automatically before installing. If a build already exists, setup offers an optional rebuild.

Manual developer commands:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-dotnet-sdk.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish-echoscribe.ps1
```

This creates:

- `publish\EchoScribe.exe`
- `publish\native-host\EchoScribe.NativeHost.exe`
- `publish\chrome-extension\`
- `publish\firefox-extension\`
- `publish\install.cmd`
- `publish\uninstall.cmd`
- `publish\scripts\install-echoscribe.ps1`
- `publish\scripts\uninstall-echoscribe.ps1`
- `EchoScribe-Windows-x64.zip`

Release packages use `appsettings.template.json` as `publish\appsettings.json` by default, so API keys are not bundled. For a private local-only package, pass `-IncludeLocalSettings`; never upload such a package to GitHub releases.

Register the browser Native Messaging host manually:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\register-chrome-host.ps1
```

For normal installs, prefer `install.cmd` from the published package because it also sets Startup and registers Chromium-based browsers plus Firefox.

After manual registration, load the extension paths printed by the script:

1. Chrome, Edge, Brave, or Chromium: open the browser extensions page, enable developer mode, click `Load unpacked`, and select the printed `chrome-extension` folder.
2. Firefox: open `about:debugging#/runtime/this-firefox`, click `Load Temporary Add-on`, and select the printed `firefox-extension\manifest.json`.
