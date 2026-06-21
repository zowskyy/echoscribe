using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using NAudio.Wave;

namespace EchoScribe;

static class Program
{
    [STAThread]
    static void Main()
    {
        using var instanceMutex = new Mutex(true, @"Local\EchoScribe.SingleInstance", out var isFirstInstance);
        if (!isFirstInstance)
        {
            MessageBox.Show("EchoScribe is already running.", "EchoScribe", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        ApplicationConfiguration.Initialize();
        Application.Run(new TrayAppContext(AppConfig.Load()));
    }
}

sealed class TrayAppContext : ApplicationContext
{
    private AppConfig config;
    private readonly FloatingStatusForm statusForm;
    private readonly NotifyIcon trayIcon;
    private HotkeyWindow hotkeyWindow;
    private KeyboardHook keyboardHook;
    private readonly System.Windows.Forms.Timer holdTimer;
    private readonly AudioRecorder recorder = new();
    private readonly TranscriptionClient transcriptionClient;
    private readonly BillingClient billingClient;
    private IntPtr previousForegroundWindow = IntPtr.Zero;
    private bool isRecording;
    private bool isTranscribing;

    public TrayAppContext(AppConfig config)
    {
        this.config = config;
        transcriptionClient = new TranscriptionClient(config);
        billingClient = new BillingClient(config);
        statusForm = new FloatingStatusForm();
        hotkeyWindow = new HotkeyWindow(config.Hotkey, BeginRecording);
        keyboardHook = new KeyboardHook(config.Hotkey, BeginRecording, EndRecording);

        trayIcon = new NotifyIcon
        {
            Icon = IconFactory.LoadAppIcon(),
            Text = "EchoScribe",
            Visible = true,
            ContextMenuStrip = BuildTrayMenu()
        };
        trayIcon.DoubleClick += (_, _) => ShowStartupMessage();

        holdTimer = new System.Windows.Forms.Timer { Interval = 40 };
        holdTimer.Tick += (_, _) =>
        {
            if (isRecording && !config.Hotkey.IsCurrentlyDown())
            {
                EndRecording();
            }
        };

        if (!hotkeyWindow.Register())
        {
            ShowTransient($"Hotkey is already in use: {config.Hotkey.Display}", StatusKind.Error, 5000);
        }
        else
        {
            keyboardHook.Start();
            ShowStartupMessage();
        }
    }

    private ContextMenuStrip BuildTrayMenu()
    {
        var menu = new ContextMenuStrip
        {
            ImageScalingSize = new Size(16, 16),
            ShowImageMargin = true
        };

        menu.Items.Add(CreateInfoMenuItem("EchoScribe", MenuIconFactory.App()));
        menu.Items.Add(CreateInfoMenuItem(GetTrayStateLabel(), MenuIconFactory.Status(isRecording, isTranscribing)));
        menu.Items.Add(new ToolStripSeparator());

        var startItem = CreateMenuItem("Start Dictation", MenuIconFactory.Mic(), (_, _) => BeginRecording());
        startItem.Enabled = !isRecording && !isTranscribing;
        menu.Items.Add(startItem);

        if (isRecording)
        {
            menu.Items.Add(CreateMenuItem("Stop Dictation", MenuIconFactory.Stop(), (_, _) => EndRecording()));
        }

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(BuildProvidersMenu());
        menu.Items.Add(BuildBrowserExtensionMenu());
        menu.Items.Add(BuildBillingMenu());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(CreateMenuItem("Settings...", MenuIconFactory.Settings(), (_, _) => OpenSettings()));
        menu.Items.Add(CreateMenuItem("Open Config", MenuIconFactory.ConfigFile(), (_, _) => OpenConfig()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(CreateMenuItem("Quit EchoScribe", MenuIconFactory.Power(), (_, _) => ExitThread()));
        return menu;
    }

    private ToolStripMenuItem BuildProvidersMenu()
    {
        var providersMenu = CreateMenuItem("Providers", MenuIconFactory.Providers());
        providersMenu.DropDownItems.Add(BuildSttProviderMenu());
        providersMenu.DropDownItems.Add(BuildSummaryProviderMenu());
        return providersMenu;
    }

    private ToolStripMenuItem BuildSttProviderMenu()
    {
        var providerMenu = CreateMenuItem("STT Provider", MenuIconFactory.Mic());
        foreach (var provider in AppConfig.SupportedProviders)
        {
            var item = CreateMenuItem(ProviderDisplayName(provider), MenuIconFactory.ProviderOption(provider), (_, _) => SwitchProvider(provider));
            item.Checked = provider.Equals(config.Provider, StringComparison.OrdinalIgnoreCase);
            providerMenu.DropDownItems.Add(item);
        }

        return providerMenu;
    }

    private ToolStripMenuItem BuildSummaryProviderMenu()
    {
        var summaryProviderMenu = CreateMenuItem("Summary Provider", MenuIconFactory.Summary());
        foreach (var provider in AppConfig.SupportedSummaryProviders)
        {
            var item = CreateMenuItem(ProviderDisplayName(provider), MenuIconFactory.ProviderOption(provider), (_, _) => SwitchSummaryProvider(provider));
            item.Checked = provider.Equals(config.SummaryProvider, StringComparison.OrdinalIgnoreCase);
            summaryProviderMenu.DropDownItems.Add(item);
        }

        return summaryProviderMenu;
    }

    private ToolStripMenuItem BuildBillingMenu()
    {
        var billingMenu = CreateMenuItem("Usage & Billing", MenuIconFactory.Billing());
        billingMenu.DropDownItems.Add(CreateMenuItem("Check Current Provider", MenuIconFactory.Status(false, false), async (_, _) => await ShowBillingInfoAsync()));
        billingMenu.DropDownItems.Add(new ToolStripSeparator());
        billingMenu.DropDownItems.Add(CreateMenuItem("Open OpenAI Usage", MenuIconFactory.ExternalLink(), (_, _) => OpenUrl("https://platform.openai.com/settings/organization/usage")));
        billingMenu.DropDownItems.Add(CreateMenuItem("Open OpenAI Billing Overview", MenuIconFactory.ExternalLink(), (_, _) => OpenUrl("https://platform.openai.com/settings/organization/billing/overview")));
        billingMenu.DropDownItems.Add(CreateMenuItem("Open ElevenLabs Subscription", MenuIconFactory.ExternalLink(), (_, _) => OpenUrl("https://elevenlabs.io/app/subscription")));
        billingMenu.DropDownItems.Add(CreateMenuItem("Open Gemini Usage & Billing", MenuIconFactory.ExternalLink(), (_, _) => OpenUrl("https://aistudio.google.com/usage")));
        billingMenu.DropDownItems.Add(CreateMenuItem("Open xAI Billing", MenuIconFactory.ExternalLink(), (_, _) => OpenUrl("https://console.x.ai/team/default/billing")));
        return billingMenu;
    }

    private ToolStripMenuItem BuildBrowserExtensionMenu()
    {
        var browserMenu = CreateMenuItem("Browser Extension", MenuIconFactory.BrowserExtension());
        browserMenu.DropDownItems.Add(CreateMenuItem("Register Browser Extensions", MenuIconFactory.BrowserExtension(), (_, _) => InstallBrowserExtension()));
        browserMenu.DropDownItems.Add(CreateMenuItem("Open Extension Folders", MenuIconFactory.ConfigFile(), (_, _) => OpenBrowserExtensionFolders()));
        browserMenu.DropDownItems.Add(new ToolStripSeparator());
        browserMenu.DropDownItems.Add(BuildBrowserSetupMenu());
        return browserMenu;
    }

    private ToolStripMenuItem BuildBrowserSetupMenu()
    {
        var setupMenu = CreateMenuItem("Open Browser Extension Page", MenuIconFactory.ExternalLink());
        var targets = BrowserExtensionInstaller.GetAvailableBrowserSetupTargets();
        if (targets.Count == 0)
        {
            setupMenu.DropDownItems.Add(new ToolStripMenuItem("No Supported Browser Found") { Enabled = false });
            return setupMenu;
        }

        foreach (var target in targets)
        {
            setupMenu.DropDownItems.Add(CreateMenuItem(target, MenuIconFactory.ExternalLink(), (_, _) => OpenBrowserSetupPage(target)));
        }

        if (targets.Count > 1)
        {
            setupMenu.DropDownItems.Add(new ToolStripSeparator());
            setupMenu.DropDownItems.Add(CreateMenuItem("Open All Detected Browsers", MenuIconFactory.ExternalLink(), (_, _) => OpenBrowserSetupPages()));
        }

        return setupMenu;
    }

    private static ToolStripMenuItem CreateMenuItem(string text, Image image)
    {
        return new ToolStripMenuItem(text, image);
    }

    private static ToolStripMenuItem CreateMenuItem(string text, Image image, EventHandler onClick)
    {
        return new ToolStripMenuItem(text, image, onClick);
    }

    private static ToolStripMenuItem CreateInfoMenuItem(string text, Image image)
    {
        return new ToolStripMenuItem(text, image)
        {
            Enabled = false
        };
    }

    private string GetTrayStateLabel()
    {
        if (isRecording)
        {
            return "Recording";
        }

        if (isTranscribing)
        {
            return "Transcribing";
        }

        return "Ready";
    }

    private static string ProviderDisplayName(string provider)
    {
        return provider.ToLowerInvariant() switch
        {
            "openai" => "OpenAI",
            "elevenlabs" => "ElevenLabs",
            "gemini" => "Gemini",
            "anthropic" => "Anthropic",
            "xai" => "xAI",
            "localai" => "Local AI",
            _ => CultureInfo.InvariantCulture.TextInfo.ToTitleCase(provider)
        };
    }

    private static void OpenConfig()
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = AppConfig.ConfigPath,
            UseShellExecute = true
        });
    }

    private void RefreshTrayMenu()
    {
        trayIcon.ContextMenuStrip = BuildTrayMenu();
    }

    private void InstallBrowserExtension()
    {
        try
        {
            var result = BrowserExtensionInstaller.Register();
            MessageBox.Show(
                $"Native hosts registered.\n\nChromium extension ID:\n{result.ChromiumExtensionId}\n\nChromium extension folder:\n{result.ChromiumExtensionDirectory}\n\nFirefox extension ID:\n{result.FirefoxExtensionId}\n\nFirefox manifest:\n{result.FirefoxExtensionManifestPath}\n\nChromium browsers: enable developer mode and load the Chromium extension folder.\nFirefox: use about:debugging and load the Firefox manifest as a temporary add-on.",
                "EchoScribe Browser Extension",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            BrowserExtensionInstaller.OpenExtensionDirectories();
            OpenBrowserSetupPages();
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                ex.Message,
                "Browser extension could not be registered",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private static void OpenBrowserExtensionFolders()
    {
        BrowserExtensionInstaller.OpenExtensionDirectories();
    }

    private static void OpenBrowserSetupPages()
    {
        var opened = BrowserExtensionInstaller.OpenBrowserSetupPages();
        if (opened.Count == 0)
        {
            MessageBox.Show(
                "No supported browser executable was found. Open the extension page manually in Chrome, Edge, Brave, Chromium, or Firefox.",
                "EchoScribe Browser Extension",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
    }

    private static void OpenBrowserSetupPage(string browserName)
    {
        if (!BrowserExtensionInstaller.OpenBrowserSetupPage(browserName))
        {
            MessageBox.Show(
                $"{browserName} was not found. Open the extension page manually.",
                "EchoScribe Browser Extension",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
    }

    private void SwitchProvider(string provider)
    {
        var current = AppConfig.Load();
        if (provider.Equals(current.Provider, StringComparison.OrdinalIgnoreCase))
        {
            ShowStartupMessage();
            return;
        }

        var apiKey = current.GetApiKeyForProvider(provider);
        if (AppConfig.RequiresApiKey(provider) &&
            string.IsNullOrWhiteSpace(apiKey) &&
            !AppConfig.HasEnvironmentApiKey(provider))
        {
            using var prompt = new ApiKeyPromptForm(provider);
            if (prompt.ShowDialog() != DialogResult.OK)
            {
                return;
            }

            apiKey = prompt.ApiKey;
        }

        var nextConfig = current.WithProvider(provider, apiKey);
        nextConfig.Save();
        ApplyConfig(nextConfig);
        ShowTransient($"STT provider changed\n{provider}", StatusKind.Success, 2400);
    }

    private void SwitchSummaryProvider(string provider)
    {
        var current = AppConfig.Load();
        if (provider.Equals(current.SummaryProvider, StringComparison.OrdinalIgnoreCase))
        {
            ShowStartupMessage();
            return;
        }

        var apiKey = current.GetApiKeyForProvider(provider);
        if (AppConfig.RequiresApiKey(provider) &&
            string.IsNullOrWhiteSpace(apiKey) &&
            !AppConfig.HasEnvironmentApiKey(provider))
        {
            using var prompt = new ApiKeyPromptForm(provider);
            if (prompt.ShowDialog() != DialogResult.OK)
            {
                return;
            }

            apiKey = prompt.ApiKey;
        }

        var nextConfig = current.WithSummaryProvider(provider, apiKey);
        nextConfig.Save();
        ApplyConfig(nextConfig);
        ShowTransient($"Summary provider changed\n{provider}", StatusKind.Success, 2400);
    }

    private void ShowStartupMessage()
    {
        config = AppConfig.Load();
        ShowTransient($"EchoScribe ready\nHotkey: {config.Hotkey.Display}\nSTT: {config.Provider}\nSummary: {config.SummaryProvider}", StatusKind.Ready, 4200);
    }

    private void OpenSettings()
    {
        hotkeyWindow.Dispose();
        keyboardHook.Dispose();
        using var form = new SettingsForm(AppConfig.Load());
        if (form.ShowDialog() != DialogResult.OK)
        {
            ApplyConfig(config);
            return;
        }

        ApplyConfig(form.Config);
        ShowTransient("Settings saved", StatusKind.Success, 2200);
    }

    private void ApplyConfig(AppConfig nextConfig)
    {
        config = nextConfig;
        transcriptionClient.UpdateConfig(nextConfig);
        billingClient.UpdateConfig(nextConfig);
        hotkeyWindow.Dispose();
        keyboardHook.Dispose();
        hotkeyWindow = new HotkeyWindow(config.Hotkey, BeginRecording);
        keyboardHook = new KeyboardHook(config.Hotkey, BeginRecording, EndRecording);

        if (!hotkeyWindow.Register())
        {
            ShowTransient($"Hotkey is already in use: {config.Hotkey.Display}", StatusKind.Error, 5000);
        }
        else
        {
            keyboardHook.Start();
        }

        RefreshTrayMenu();
    }

    private async Task ShowBillingInfoAsync()
    {
        config = AppConfig.Load();
        billingClient.UpdateConfig(config);
        ShowTransient("Checking usage", StatusKind.Transcribing, 1800);

        try
        {
            var result = await billingClient.GetSummaryAsync();
            if (result.OpenUrl is not null)
            {
                OpenUrl(result.OpenUrl);
            }

            MessageBox.Show(result.Message, "Billing / Usage", MessageBoxButtons.OK, result.IsError ? MessageBoxIcon.Warning : MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            if (ex is MissingOpenAiAdminKeyException or OpenAiUsagePermissionException)
            {
                using var dialog = new OpenAiAdminKeyHelpForm(ex.Message);
                dialog.ShowDialog();
                return;
            }

            MessageBox.Show($"[ECHOSCRIBE ERROR] {ex.Message}", "Billing / Usage", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static void OpenUrl(string url)
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = url,
            UseShellExecute = true
        });
    }

    private void BeginRecording()
    {
        if (isRecording || isTranscribing)
        {
            return;
        }

        try
        {
            previousForegroundWindow = NativeMethods.GetForegroundWindow();
            recorder.Start();
            isRecording = true;
            keyboardHook.MarkActive();
            RefreshTrayMenu();
            statusForm.ShowMessage("Recording", StatusKind.Recording);
        }
        catch (Exception ex)
        {
            PutTextIntoClipboardAndPaste($"[ECHOSCRIBE ERROR] Recording could not start: {ex.Message}", paste: false);
            ShowTransient("Recording error\nDetails copied to clipboard", StatusKind.Error, 4500);
        }
    }

    private async void EndRecording()
    {
        if (!isRecording)
        {
            return;
        }

        holdTimer.Stop();
        isRecording = false;
        keyboardHook.MarkInactive();
        isTranscribing = true;
        RefreshTrayMenu();
        statusForm.ShowMessage("Transcription", StatusKind.Transcribing);

        try
        {
            var wavPath = recorder.StopToTempWav();
            if (new FileInfo(wavPath).Length < 1024)
            {
                throw new InvalidOperationException("Recording was too short or empty.");
            }

            var text = await transcriptionClient.TranscribeAsync(wavPath);
            if (string.IsNullOrWhiteSpace(text))
            {
                text = "[ECHOSCRIBE ERROR] API returned no text.";
            }

            PutTextIntoClipboardAndPaste(text.Trim(), paste: true);
            ShowTransient("Text pasted", 1600);
            TryDelete(wavPath);
        }
        catch (Exception ex)
        {
            var errorText = $"[ECHOSCRIBE ERROR] {ex.Message}";
            PutTextIntoClipboardAndPaste(errorText, paste: true);
            ShowTransient("Error\nDetails copied to clipboard", 4500);
        }
        finally
        {
            isTranscribing = false;
            RefreshTrayMenu();
        }
    }

    private void PutTextIntoClipboardAndPaste(string text, bool paste)
    {
        Clipboard.SetText(text);

        if (!paste)
        {
            return;
        }

        config.Hotkey.WaitUntilReleased(1500);

        if (previousForegroundWindow != IntPtr.Zero)
        {
            NativeMethods.SetForegroundWindow(previousForegroundWindow);
            Thread.Sleep(180);
        }

        if (!NativeMethods.SendCtrlV())
        {
            AppLog.Write("SendInput paste failed; falling back to SendKeys.");
            SendKeys.SendWait("^v");
        }
    }

    private void ShowTransient(string message, int milliseconds)
    {
        var kind = message.StartsWith("Error", StringComparison.OrdinalIgnoreCase) ||
            message.Contains("Error", StringComparison.OrdinalIgnoreCase) ||
            message.Contains("already in use", StringComparison.OrdinalIgnoreCase)
                ? StatusKind.Error
                : message.StartsWith("Text", StringComparison.OrdinalIgnoreCase) ||
                    message.Contains("saved", StringComparison.OrdinalIgnoreCase)
                        ? StatusKind.Success
                        : StatusKind.Ready;
        ShowTransient(message, kind, milliseconds);
    }

    private void ShowTransient(string message, StatusKind kind, int milliseconds)
    {
        statusForm.ShowMessage(message, kind);
        var timer = new System.Windows.Forms.Timer { Interval = milliseconds };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            timer.Dispose();
            if (!isRecording && !isTranscribing)
            {
                statusForm.Hide();
            }
        };
        timer.Start();
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch
        {
            // Temporary audio is best-effort cleanup.
        }
    }

    protected override void ExitThreadCore()
    {
        holdTimer.Stop();
        hotkeyWindow.Dispose();
        keyboardHook.Dispose();
        trayIcon.Visible = false;
        trayIcon.Dispose();
        statusForm.Close();
        base.ExitThreadCore();
    }
}

sealed class AudioRecorder
{
    private readonly object gate = new();
    private WaveInEvent? waveIn;
    private MemoryStream? audioStream;
    private readonly WaveFormat format = new(16000, 16, 1);

    public void Start()
    {
        lock (gate)
        {
            audioStream?.Dispose();
            audioStream = new MemoryStream();
            waveIn = new WaveInEvent
            {
                WaveFormat = format,
                BufferMilliseconds = 50
            };
            waveIn.DataAvailable += (_, e) =>
            {
                lock (gate)
                {
                    audioStream?.Write(e.Buffer, 0, e.BytesRecorded);
                }
            };
            waveIn.StartRecording();
        }
    }

    public string StopToTempWav()
    {
        MemoryStream recorded;
        lock (gate)
        {
            waveIn?.StopRecording();
            waveIn?.Dispose();
            waveIn = null;

            recorded = audioStream ?? new MemoryStream();
            audioStream = null;
        }

        recorded.Position = 0;
        var path = Path.Combine(Path.GetTempPath(), $"ptt-{Guid.NewGuid():N}.wav");
        using (recorded)
        using (var writer = new WaveFileWriter(path, format))
        {
            recorded.CopyTo(writer);
        }

        return path;
    }
}

sealed class TranscriptionClient(AppConfig config)
{
    private static readonly HttpClient Http = new();
    private AppConfig config = config;

    public void UpdateConfig(AppConfig nextConfig)
    {
        config = nextConfig;
    }

    public async Task<string> TranscribeAsync(string wavPath)
    {
        config = AppConfig.Load();
        return config.Provider.ToLowerInvariant() switch
        {
            "openai" => await TranscribeOpenAiAsync(wavPath),
            "elevenlabs" => await TranscribeElevenLabsAsync(wavPath),
            "gemini" => await TranscribeGeminiAsync(wavPath),
            "anthropic" => throw new InvalidOperationException("Claude/Anthropic is available for web summaries, but EchoScribe does not support it for speech-to-text or text-to-speech."),
            "xai" => await TranscribeXaiAsync(wavPath),
            "localai" => await TranscribeLocalAiAsync(wavPath),
            _ => throw new InvalidOperationException($"Unknown provider '{config.Provider}'.")
        };
    }

    private async Task<string> TranscribeOpenAiAsync(string wavPath)
    {
        var apiKey = config.ResolveApiKey("OPENAI_API_KEY");
        using var form = new MultipartFormDataContent();
        form.Add(new StringContent(config.Model), "model");
        AddLanguageIfConfigured(form, "language");
        form.Add(new ByteArrayContent(await File.ReadAllBytesAsync(wavPath))
        {
            Headers = { ContentType = new MediaTypeHeaderValue("audio/wav") }
        }, "file", "recording.wav");

        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/audio/transcriptions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        request.Content = form;
        using var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, body);
        return JsonText(body, "text");
    }

    private async Task<string> TranscribeElevenLabsAsync(string wavPath)
    {
        var apiKey = config.ResolveApiKey("ELEVENLABS_API_KEY");
        using var form = new MultipartFormDataContent();
        form.Add(new StringContent(config.Model), "model_id");
        AddLanguageIfConfigured(form, "language_code");
        form.Add(new StringContent("false"), "tag_audio_events");
        form.Add(new ByteArrayContent(await File.ReadAllBytesAsync(wavPath))
        {
            Headers = { ContentType = new MediaTypeHeaderValue("audio/wav") }
        }, "file", "recording.wav");

        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.elevenlabs.io/v1/speech-to-text");
        request.Headers.Add("xi-api-key", apiKey);
        request.Content = form;
        using var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, body);
        return JsonText(body, "text");
    }

    private async Task<string> TranscribeGeminiAsync(string wavPath)
    {
        var apiKey = config.ResolveApiKey("GEMINI_API_KEY", "GOOGLE_API_KEY");
        var bytes = await File.ReadAllBytesAsync(wavPath);
        var startBody = JsonSerializer.Serialize(new
        {
            file = new { display_name = "ptt-recording.wav" }
        });

        using var start = new HttpRequestMessage(HttpMethod.Post, "https://generativelanguage.googleapis.com/upload/v1beta/files");
        start.Headers.Add("x-goog-api-key", apiKey);
        start.Headers.Add("X-Goog-Upload-Protocol", "resumable");
        start.Headers.Add("X-Goog-Upload-Command", "start");
        start.Headers.Add("X-Goog-Upload-Header-Content-Length", bytes.Length.ToString());
        start.Headers.Add("X-Goog-Upload-Header-Content-Type", "audio/wav");
        start.Content = new StringContent(startBody, Encoding.UTF8, "application/json");
        using var startResponse = await Http.SendAsync(start);
        var startResponseBody = await startResponse.Content.ReadAsStringAsync();
        EnsureSuccess(startResponse, startResponseBody);

        if (!startResponse.Headers.TryGetValues("X-Goog-Upload-URL", out var uploadUrls))
        {
            throw new InvalidOperationException("Gemini upload URL is missing from the API response.");
        }

        using var upload = new HttpRequestMessage(HttpMethod.Post, uploadUrls.First());
        upload.Headers.Add("X-Goog-Upload-Offset", "0");
        upload.Headers.Add("X-Goog-Upload-Command", "upload, finalize");
        upload.Content = new ByteArrayContent(bytes);
        upload.Content.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        using var uploadResponse = await Http.SendAsync(upload);
        var uploadBody = await uploadResponse.Content.ReadAsStringAsync();
        EnsureSuccess(uploadResponse, uploadBody);
        using var uploadedJson = JsonDocument.Parse(uploadBody);
        var file = uploadedJson.RootElement.GetProperty("file");
        var uri = file.GetProperty("uri").GetString() ?? throw new InvalidOperationException("Gemini file URI is missing.");
        var mimeType = file.TryGetProperty("mimeType", out var mt) ? mt.GetString() ?? "audio/wav" : "audio/wav";

        var generateBody = JsonSerializer.Serialize(new
        {
            contents = new[]
            {
                new
                {
                    parts = new object[]
                    {
                        new { file_data = new { mime_type = mimeType, file_uri = uri } },
                        new { text = $"Transcribe the speech in this audio. Return only the transcript text. {LanguagePromptInstruction()}" }
                    }
                }
            }
        });

        var model = string.IsNullOrWhiteSpace(config.Model) ? "gemini-3.5-flash" : config.Model;
        using var generate = new HttpRequestMessage(HttpMethod.Post, $"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent");
        generate.Headers.Add("x-goog-api-key", apiKey);
        generate.Content = new StringContent(generateBody, Encoding.UTF8, "application/json");
        using var generateResponse = await Http.SendAsync(generate);
        var generateResponseBody = await generateResponse.Content.ReadAsStringAsync();
        EnsureSuccess(generateResponse, generateResponseBody);
        using var json = JsonDocument.Parse(generateResponseBody);
        return json.RootElement.GetProperty("candidates")[0].GetProperty("content").GetProperty("parts")[0].GetProperty("text").GetString() ?? "";
    }

    private async Task<string> TranscribeXaiAsync(string wavPath)
    {
        var apiKey = config.ResolveApiKey("XAI_API_KEY");
        using var form = new MultipartFormDataContent();
        AddLanguageIfConfigured(form, "language");
        form.Add(new ByteArrayContent(await File.ReadAllBytesAsync(wavPath))
        {
            Headers = { ContentType = new MediaTypeHeaderValue("audio/wav") }
        }, "file", "recording.wav");

        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.x.ai/v1/stt");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        request.Content = form;
        using var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, body);
        return JsonText(body, "text");
    }

    private async Task<string> TranscribeLocalAiAsync(string wavPath)
    {
        if (!string.IsNullOrWhiteSpace(config.LocalWhisperCppExe) &&
            !string.IsNullOrWhiteSpace(config.LocalWhisperCppModelPath))
        {
            return await TranscribeWhisperCppAsync(wavPath);
        }

        if (string.IsNullOrWhiteSpace(config.LocalAiWhisperUrl))
        {
            throw new InvalidOperationException("Local AI Whisper URL is not configured.");
        }
        using var form = new MultipartFormDataContent();
        form.Add(new StringContent(string.IsNullOrWhiteSpace(config.Model) ? "whisper-1" : config.Model), "model");
        form.Add(new StringContent("json"), "response_format");
        if (!string.IsNullOrWhiteSpace(config.Language) && !config.Language.Equals("auto", StringComparison.OrdinalIgnoreCase))
        {
            form.Add(new StringContent(config.Language), "language");
        }
        form.Add(new ByteArrayContent(await File.ReadAllBytesAsync(wavPath))
        {
            Headers = { ContentType = new MediaTypeHeaderValue("audio/wav") }
        }, "file", "recording.wav");

        using var request = new HttpRequestMessage(HttpMethod.Post, config.LocalAiWhisperUrl);
        request.Content = form;
        using var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, body);
        return JsonText(body, "text");
    }

    private async Task<string> TranscribeWhisperCppAsync(string wavPath)
    {
        var exePath = config.LocalWhisperCppExe.Trim();
        var modelPath = config.LocalWhisperCppModelPath.Trim();
        if (!File.Exists(exePath))
        {
            throw new InvalidOperationException($"whisper.cpp executable was not found: {exePath}");
        }
        if (!File.Exists(modelPath))
        {
            throw new InvalidOperationException($"whisper.cpp model was not found: {modelPath}");
        }

        var outputBase = Path.Combine(Path.GetTempPath(), $"echoscribe-whisper-{Guid.NewGuid():N}");
        var processInfo = new ProcessStartInfo
        {
            FileName = exePath,
            WorkingDirectory = Path.GetDirectoryName(exePath) ?? AppContext.BaseDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        processInfo.ArgumentList.Add("-m");
        processInfo.ArgumentList.Add(modelPath);
        processInfo.ArgumentList.Add("-f");
        processInfo.ArgumentList.Add(wavPath);
        processInfo.ArgumentList.Add("-otxt");
        processInfo.ArgumentList.Add("-of");
        processInfo.ArgumentList.Add(outputBase);
        if (!string.IsNullOrWhiteSpace(config.Language) && !config.Language.Equals("auto", StringComparison.OrdinalIgnoreCase))
        {
            processInfo.ArgumentList.Add("-l");
            processInfo.ArgumentList.Add(config.Language);
        }

        using var process = new Process { StartInfo = processInfo };
        if (!process.Start())
        {
            throw new InvalidOperationException("whisper.cpp could not be started.");
        }

        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(10));
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch
            {
                // Process may have exited between timeout and Kill().
            }
            throw new TimeoutException("whisper.cpp transcription timed out after 10 minutes.");
        }

        var stdout = await stdoutTask;
        var stderr = await stderrTask;
        if (process.ExitCode != 0)
        {
            var detail = string.IsNullOrWhiteSpace(stderr) ? stdout : stderr;
            detail = detail.Length > 900 ? detail[..900] : detail;
            throw new InvalidOperationException($"whisper.cpp failed with exit code {process.ExitCode}: {detail}");
        }

        try
        {
            var outputFile = Directory
                .GetFiles(Path.GetDirectoryName(outputBase) ?? Path.GetTempPath(), $"{Path.GetFileName(outputBase)}*.txt")
                .OrderBy(path => path.Length)
                .FirstOrDefault();
            var text = outputFile is not null && File.Exists(outputFile)
                ? await File.ReadAllTextAsync(outputFile)
                : stdout;
            text = text.Trim();
            if (string.IsNullOrWhiteSpace(text))
            {
                throw new InvalidOperationException("whisper.cpp returned an empty transcript.");
            }
            return text;
        }
        finally
        {
            foreach (var file in Directory.GetFiles(Path.GetDirectoryName(outputBase) ?? Path.GetTempPath(), $"{Path.GetFileName(outputBase)}*"))
            {
                try
                {
                    File.Delete(file);
                }
                catch
                {
                    // Temporary output cleanup is best effort.
                }
            }
        }
    }

    private void AddLanguageIfConfigured(MultipartFormDataContent form, string fieldName)
    {
        if (!string.IsNullOrWhiteSpace(config.Language) &&
            !config.Language.Equals("auto", StringComparison.OrdinalIgnoreCase))
        {
            form.Add(new StringContent(config.Language), fieldName);
        }
    }

    private string LanguagePromptInstruction()
    {
        return string.IsNullOrWhiteSpace(config.Language) || config.Language.Equals("auto", StringComparison.OrdinalIgnoreCase)
            ? "Detect the spoken language automatically."
            : $"Language hint: {config.Language}.";
    }

    private static void EnsureSuccess(HttpResponseMessage response, string body)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        var detail = body.Length > 900 ? body[..900] : body;
        throw new InvalidOperationException($"API error {(int)response.StatusCode} {response.ReasonPhrase}: {detail}");
    }
    private static string JsonText(string body, string property)
    {
        using var json = JsonDocument.Parse(body);
        return json.RootElement.TryGetProperty(property, out var value) ? value.GetString() ?? "" : body;
    }
}

sealed class BillingClient(AppConfig config)
{
    private static readonly HttpClient Http = new();
    private AppConfig config = config;

    public void UpdateConfig(AppConfig nextConfig)
    {
        config = nextConfig;
    }

    public Task<BillingSummary> GetSummaryAsync()
    {
        config = AppConfig.Load();
        return config.Provider.ToLowerInvariant() switch
        {
            "elevenlabs" => GetElevenLabsSummaryAsync(),
            "openai" => GetOpenAiSummaryAsync(),
            "gemini" => Task.FromResult(new BillingSummary(
                "Gemini usage and billing are managed through Google Cloud Billing. EchoScribe will open the usage and billing page; there is no simple API-key balance endpoint for this.",
                "https://aistudio.google.com/usage")),
            "xai" => Task.FromResult(new BillingSummary(
                "xAI shows prepaid credits and usage in the console. An official balance endpoint is not documented in the REST API. EchoScribe will open the billing page.",
                "https://console.x.ai/team/default/billing")),
            "localai" => Task.FromResult(new BillingSummary(
                "Local AI runs on your own server. EchoScribe cannot read usage or billing information for it.",
                null,
                true)),
            _ => Task.FromResult(new BillingSummary($"Unknown provider '{config.Provider}'.", null, true))
        };
    }

    private async Task<BillingSummary> GetElevenLabsSummaryAsync()
    {
        var apiKey = config.ResolveApiKey("ELEVENLABS_API_KEY");
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.elevenlabs.io/v1/user/subscription");
        request.Headers.Add("xi-api-key", apiKey);

        using var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, body);

        using var json = JsonDocument.Parse(body);
        var root = json.RootElement;
        var tier = ReadString(root, "tier", "unknown");
        var status = ReadString(root, "status", "unknown");
        var used = ReadLong(root, "character_count");
        var limit = ReadLong(root, "character_limit");
        var resetUnix = ReadLong(root, "next_character_count_reset_unix");
        var currency = ReadString(root, "currency", "").ToUpperInvariant();
        var overage = "";

        if (root.TryGetProperty("current_overage", out var currentOverage))
        {
            var amount = ReadString(currentOverage, "amount", "");
            var overageCurrency = ReadString(currentOverage, "currency", currency).ToUpperInvariant();
            if (!string.IsNullOrWhiteSpace(amount) && amount != "0")
            {
                overage = $"{Environment.NewLine}Overage: {amount} {overageCurrency}";
            }
        }

        var remaining = limit > 0 ? Math.Max(0, limit - used) : 0;
        var reset = resetUnix > 0
            ? DateTimeOffset.FromUnixTimeSeconds(resetUnix).LocalDateTime.ToString("dd.MM.yyyy HH:mm", CultureInfo.CurrentCulture)
            : "unknown";
        var percent = limit > 0 ? used / (double)limit : 0;

        return new BillingSummary(
            $"ElevenLabs{Environment.NewLine}" +
            $"Plan: {tier} ({status}){Environment.NewLine}" +
            $"Used: {used:N0} / {limit:N0} credits/characters ({percent:P0}){Environment.NewLine}" +
            $"Remaining: {remaining:N0}{Environment.NewLine}" +
            $"Reset: {reset}" +
            (string.IsNullOrWhiteSpace(currency) ? "" : $"{Environment.NewLine}Currency: {currency}") +
            overage);
    }

    private async Task<BillingSummary> GetOpenAiSummaryAsync()
    {
        var adminKey = config.ResolveOpenAiAdminKey();
        var now = DateTimeOffset.UtcNow;
        var monthStart = new DateTimeOffset(now.Year, now.Month, 1, 0, 0, 0, TimeSpan.Zero);
        var url = $"https://api.openai.com/v1/organization/costs?start_time={monthStart.ToUnixTimeSeconds()}&end_time={now.ToUnixTimeSeconds()}&limit=31";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", adminKey);

        using var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        EnsureOpenAiCostsSuccess(response, body);

        using var json = JsonDocument.Parse(body);
        decimal total = 0;
        var currency = "USD";

        foreach (var bucket in json.RootElement.GetProperty("data").EnumerateArray())
        {
            if (!bucket.TryGetProperty("results", out var results))
            {
                continue;
            }

            foreach (var result in results.EnumerateArray())
            {
                if (!result.TryGetProperty("amount", out var amount))
                {
                    continue;
                }

                if (amount.TryGetProperty("value", out var value) && TryReadDecimal(value, out var decimalValue))
                {
                    total += decimalValue;
                }

                currency = ReadString(amount, "currency", currency).ToUpperInvariant();
            }
        }

        return new BillingSummary(
            $"OpenAI{Environment.NewLine}" +
            $"Cost since {monthStart.LocalDateTime:yyyy-MM-dd}: {total:N4} {currency}{Environment.NewLine}" +
            $"Note: This is the official Costs API, not your remaining prepaid balance. The remaining balance is shown in the Billing Overview.");
    }

    private static void EnsureSuccess(HttpResponseMessage response, string body)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        var detail = body.Length > 900 ? body[..900] : body;
        throw new InvalidOperationException($"API error {(int)response.StatusCode} {response.ReasonPhrase}: {detail}");
    }

    private static void EnsureOpenAiCostsSuccess(HttpResponseMessage response, string body)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        if ((int)response.StatusCode == 403 && body.Contains("api.usage.read", StringComparison.OrdinalIgnoreCase))
        {
            throw new OpenAiUsagePermissionException(
                "OpenAI rejected the costs request: Usage/Costs requires an OpenAI Admin API key with api.usage.read. " +
                "A regular project or service-account key is not enough, even when it shows 'All' permissions. " +
                "Create the key under Organization/Admin API Keys and enter it as the OpenAI Admin key.");
        }

        EnsureSuccess(response, body);
    }

    private static string ReadString(JsonElement root, string name, string fallback)
    {
        return root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? fallback
            : fallback;
    }

    private static long ReadLong(JsonElement root, string name)
    {
        return root.TryGetProperty(name, out var value) && value.TryGetInt64(out var result)
            ? result
            : 0;
    }

    private static bool TryReadDecimal(JsonElement value, out decimal result)
    {
        if (value.ValueKind == JsonValueKind.Number)
        {
            return value.TryGetDecimal(out result);
        }

        if (value.ValueKind == JsonValueKind.String &&
            decimal.TryParse(value.GetString(), NumberStyles.Number, CultureInfo.InvariantCulture, out result))
        {
            return true;
        }

        result = 0;
        return false;
    }
}

sealed record BillingSummary(string Message, string? OpenUrl = null, bool IsError = false);

static class OpenAiLinks
{
    public const string AdminApiKeys = "https://platform.openai.com/settings/organization/admin-keys";
}

sealed class MissingOpenAiAdminKeyException(string message) : InvalidOperationException(message);

sealed class OpenAiUsagePermissionException(string message) : InvalidOperationException(message);

sealed record AppConfig(
    string Provider,
    string Model,
    string Language,
    string? ApiKey,
    string? OpenAiAdminKey,
    IReadOnlyDictionary<string, string> ProviderApiKeys,
    string SummaryProvider,
    IReadOnlyDictionary<string, string> SummaryModels,
    string UrlSummaryPrompt,
    bool AppFetchUrl,
    string LocalAiLlmUrl,
    string LocalAiWhisperUrl,
    string LocalWhisperCppExe,
    string LocalWhisperCppModelPath,
    Hotkey Hotkey)
{
    public static string ConfigPath => Path.Combine(AppContext.BaseDirectory, "appsettings.json");
    public const string DefaultLocalAiLlmUrl = "http://127.0.0.1:11434/api/chat";
    public const string DefaultLocalAiWhisperUrl = "http://127.0.0.1:8000/v1/audio/transcriptions";
    public const string DefaultUrlSummaryPrompt =
        "Summarize the provided webpage content.\n\n" +
        "Rules:\n" +
        "- Use ONLY information present in the content.\n" +
        "- Never guess or invent missing details.\n" +
        "- Replace vague or clickbait headlines with the specific subject described in the text.\n" +
        "- Prefer concrete facts (names, numbers, results, ingredients, products).\n" +
        "- Remove filler and marketing language.\n" +
        "- Adapt to the content type automatically.\n\n" +
        "Structure:\n" +
        "- If the content contains multiple distinct aspects (e.g. results, ingredients, steps, features, findings), organize the summary into 2-4 short sections.\n" +
        "- Each section heading MUST be formatted as \"## <emoji> <1-3 word title>\".\n" +
        "- Do not write a section heading without an emoji.\n" +
        "- Keep section titles very short (1-3 words).\n" +
        "- Each section should contain one concise sentence.\n" +
        "- If the content is simple, write a short paragraph instead (1-3 sentences).\n\n" +
        "If the content is missing or insufficient, state the reason or describe why a summary cannot be created.";
    public static readonly string[] SupportedProviders = ["openai", "elevenlabs", "gemini", "xai", "localai"];
    public static readonly string[] SupportedSummaryProviders = ["openai", "gemini", "anthropic", "xai", "localai"];

    public static string DefaultModelFor(string provider)
    {
        return provider.ToLowerInvariant() switch
        {
            "elevenlabs" => "scribe_v2",
            "gemini" => "gemini-3.5-flash",
            "xai" => "xai-stt",
            "localai" => "whisper-1",
            _ => "gpt-4o-mini-transcribe"
        };
    }

    public static string DefaultSummaryModelFor(string provider)
    {
        return provider.ToLowerInvariant() switch
        {
            "gemini" => "gemini-3.5-flash",
            "anthropic" => "claude-sonnet-4-6",
            "xai" => "grok-4.3",
            "localai" => "qwen2.5:7b",
            _ => "gpt-5.4-mini"
        };
    }

    public static bool RequiresApiKey(string provider) =>
        !provider.Equals("localai", StringComparison.OrdinalIgnoreCase);

    public static string[] EnvNamesFor(string provider)
    {
        return provider.ToLowerInvariant() switch
        {
            "openai" => ["OPENAI_API_KEY"],
            "elevenlabs" => ["ELEVENLABS_API_KEY"],
            "gemini" => ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
            "anthropic" => ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"],
            "xai" => ["XAI_API_KEY"],
            "localai" => [],
            _ => []
        };
    }

    public static bool HasEnvironmentApiKey(string provider)
    {
        foreach (var name in EnvNamesFor(provider))
        {
            var value = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User)
                ?? Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Process)
                ?? Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Machine);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return true;
            }
        }

        return false;
    }

    public static AppConfig Load()
    {
        if (!File.Exists(ConfigPath))
        {
            File.WriteAllText(ConfigPath, """
            {
              "provider": "openai",
              "model": "gpt-4o-mini-transcribe",
              "language": "auto",
              "apiKey": "",
              "apiKeys": {},
              "openAiAdminKey": "",
              "summaryProvider": "openai",
              "summaryModels": {},
              "urlSummaryPrompt": "",
              "appFetchUrl": true,
              "localAiLlmUrl": "http://127.0.0.1:11434/api/chat",
              "localAiWhisperUrl": "http://127.0.0.1:8000/v1/audio/transcriptions",
              "localWhisperCppExe": "",
              "localWhisperCppModelPath": "",
              "hotkey": "Alt+A"
            }
            """);
        }

        using var json = JsonDocument.Parse(File.ReadAllText(ConfigPath));
        var root = json.RootElement;
        var provider = ReadString(root, "provider", "openai");
        if (!SupportedProviders.Contains(provider, StringComparer.OrdinalIgnoreCase))
        {
            provider = "openai";
        }
        var defaultModel = DefaultModelFor(provider);
        var providerApiKeys = ReadApiKeys(root);
        var legacyApiKey = ReadString(root, "apiKey", "");
        if (!string.IsNullOrWhiteSpace(legacyApiKey) && !providerApiKeys.ContainsKey(provider.ToLowerInvariant()))
        {
            providerApiKeys[provider.ToLowerInvariant()] = legacyApiKey;
        }
        var currentApiKey = providerApiKeys.TryGetValue(provider.ToLowerInvariant(), out var providerApiKey)
            ? providerApiKey
            : legacyApiKey;

        var model = ReadString(root, "model", defaultModel);
        if (string.IsNullOrWhiteSpace(model) || (provider.ToLowerInvariant() != "openai" && model == "gpt-4o-mini-transcribe"))
        {
            model = defaultModel;
        }

        return new AppConfig(
            provider,
            model,
            ReadString(root, "language", "auto"),
            currentApiKey,
            ReadString(root, "openAiAdminKey", ""),
            providerApiKeys,
            NormalizeSummaryProvider(ReadString(root, "summaryProvider", provider.Equals("elevenlabs", StringComparison.OrdinalIgnoreCase) ? "openai" : provider)),
            ReadStringMap(root, "summaryModels"),
            FirstNonEmpty(ReadString(root, "urlSummaryPrompt", ""), DefaultUrlSummaryPrompt),
            ReadBool(root, "appFetchUrl", true),
            ReadString(root, "localAiLlmUrl", DefaultLocalAiLlmUrl),
            ReadString(root, "localAiWhisperUrl", DefaultLocalAiWhisperUrl),
            ReadString(root, "localWhisperCppExe", ""),
            ReadString(root, "localWhisperCppModelPath", ""),
            Hotkey.Parse(ReadString(root, "hotkey", "Alt+A")));
    }

    public void Save()
    {
        var providerKey = Provider.ToLowerInvariant();
        var apiKeys = new Dictionary<string, string>(ProviderApiKeys, StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(ApiKey))
        {
            apiKeys[providerKey] = ApiKey;
        }

        var payload = new
        {
            provider = Provider,
            model = Model,
            language = Language,
            apiKey = ApiKey ?? "",
            apiKeys,
            openAiAdminKey = OpenAiAdminKey ?? "",
            summaryProvider = SummaryProvider,
            summaryModels = SummaryModels,
            urlSummaryPrompt = UrlSummaryPrompt,
            appFetchUrl = AppFetchUrl,
            localAiLlmUrl = LocalAiLlmUrl,
            localAiWhisperUrl = LocalAiWhisperUrl,
            localWhisperCppExe = LocalWhisperCppExe,
            localWhisperCppModelPath = LocalWhisperCppModelPath,
            hotkey = Hotkey.Display
        };
        var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(ConfigPath, json);
    }

    public string ResolveApiKey(params string[] envNames)
    {
        var providerKey = Provider.ToLowerInvariant();
        if (ProviderApiKeys.TryGetValue(providerKey, out var providerApiKey) && !string.IsNullOrWhiteSpace(providerApiKey))
        {
            return providerApiKey;
        }

        if (!string.IsNullOrWhiteSpace(ApiKey))
        {
            return ApiKey;
        }

        foreach (var name in envNames)
        {
            var value = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User)
                ?? Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Process)
                ?? Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Machine);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        throw new InvalidOperationException($"API-Key fehlt. Trage ihn in {ConfigPath} ein oder setze {string.Join(" / ", envNames)}.");
    }

    public string GetApiKeyForProvider(string provider)
    {
        var providerKey = provider.ToLowerInvariant();
        if (ProviderApiKeys.TryGetValue(providerKey, out var providerApiKey))
        {
            return providerApiKey;
        }

        return provider.Equals(Provider, StringComparison.OrdinalIgnoreCase) ? ApiKey ?? "" : "";
    }

    public AppConfig WithProvider(string provider, string? apiKey)
    {
        var providerKey = provider.ToLowerInvariant();
        var currentProviderKey = Provider.ToLowerInvariant();
        var apiKeys = new Dictionary<string, string>(ProviderApiKeys, StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(ApiKey))
        {
            apiKeys[currentProviderKey] = ApiKey;
        }

        if (!string.IsNullOrWhiteSpace(apiKey))
        {
            apiKeys[providerKey] = apiKey;
        }

        var nextApiKey = apiKeys.TryGetValue(providerKey, out var existingKey) ? existingKey : "";
        return new AppConfig(
            provider,
            DefaultModelFor(provider),
            Language,
            nextApiKey,
            OpenAiAdminKey,
            apiKeys,
            SummaryProvider,
            SummaryModels,
            FirstNonEmpty(UrlSummaryPrompt, DefaultUrlSummaryPrompt),
            AppFetchUrl,
            LocalAiLlmUrl,
            LocalAiWhisperUrl,
            LocalWhisperCppExe,
            LocalWhisperCppModelPath,
            Hotkey);
    }

    public string SummaryModelFor(string provider)
    {
        return SummaryModels.TryGetValue(provider.ToLowerInvariant(), out var model) && !string.IsNullOrWhiteSpace(model)
            ? model
            : DefaultSummaryModelFor(provider);
    }

    public AppConfig WithSummaryProvider(string provider, string? apiKey)
    {
        var providerKey = provider.ToLowerInvariant();
        var apiKeys = new Dictionary<string, string>(ProviderApiKeys, StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(ApiKey))
        {
            apiKeys[Provider.ToLowerInvariant()] = ApiKey;
        }

        if (!string.IsNullOrWhiteSpace(apiKey))
        {
            apiKeys[providerKey] = apiKey;
        }

        var summaryModels = new Dictionary<string, string>(SummaryModels, StringComparer.OrdinalIgnoreCase);
        if (!summaryModels.ContainsKey(providerKey) || string.IsNullOrWhiteSpace(summaryModels[providerKey]))
        {
            summaryModels[providerKey] = DefaultSummaryModelFor(providerKey);
        }

        return this with
        {
            ProviderApiKeys = apiKeys,
            SummaryProvider = providerKey,
            SummaryModels = summaryModels,
            UrlSummaryPrompt = FirstNonEmpty(UrlSummaryPrompt, DefaultUrlSummaryPrompt)
        };
    }

    public string ResolveOpenAiAdminKey()
    {
        if (!string.IsNullOrWhiteSpace(OpenAiAdminKey))
        {
            return OpenAiAdminKey;
        }

        var value = Environment.GetEnvironmentVariable("OPENAI_ADMIN_KEY", EnvironmentVariableTarget.User)
            ?? Environment.GetEnvironmentVariable("OPENAI_ADMIN_KEY", EnvironmentVariableTarget.Process)
            ?? Environment.GetEnvironmentVariable("OPENAI_ADMIN_KEY", EnvironmentVariableTarget.Machine)
            ?? Environment.GetEnvironmentVariable("OPENAI_ADMIN_API_KEY", EnvironmentVariableTarget.User)
            ?? Environment.GetEnvironmentVariable("OPENAI_ADMIN_API_KEY", EnvironmentVariableTarget.Process)
            ?? Environment.GetEnvironmentVariable("OPENAI_ADMIN_API_KEY", EnvironmentVariableTarget.Machine);
        if (!string.IsNullOrWhiteSpace(value))
        {
            return value;
        }

        throw new MissingOpenAiAdminKeyException(
            $"OpenAI Admin API Key fehlt. Erstelle ihn unter Organization/Admin API Keys und trage ihn in {ConfigPath} unter openAiAdminKey ein oder setze OPENAI_ADMIN_KEY / OPENAI_ADMIN_API_KEY.");
    }

    private static string FirstNonEmpty(params string[] values)
    {
        return values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim() ?? "";
    }

    private static string ReadString(JsonElement root, string name, string fallback)
    {
        return root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? fallback
            : fallback;
    }

    private static Dictionary<string, string> ReadApiKeys(JsonElement root)
    {
        return ReadStringMap(root, "apiKeys");
    }

    private static Dictionary<string, string> ReadStringMap(JsonElement root, string name)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!root.TryGetProperty(name, out var apiKeys) || apiKeys.ValueKind != JsonValueKind.Object)
        {
            return result;
        }

        foreach (var property in apiKeys.EnumerateObject())
        {
            if (property.Value.ValueKind == JsonValueKind.String)
            {
                var value = property.Value.GetString();
                if (!string.IsNullOrWhiteSpace(value))
                {
                    result[property.Name.ToLowerInvariant()] = value;
                }
            }
        }

        return result;
    }

    private static bool ReadBool(JsonElement root, string name, bool fallback)
    {
        return root.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : fallback;
    }

    private static string NormalizeSummaryProvider(string provider)
    {
        return SupportedSummaryProviders.Contains(provider, StringComparer.OrdinalIgnoreCase)
            ? provider.ToLowerInvariant()
            : "openai";
    }
}

sealed class ApiKeyPromptForm : Form
{
    private readonly string provider;
    private readonly TextBox apiKeyBox = new();

    public string ApiKey => apiKeyBox.Text.Trim();

    public ApiKeyPromptForm(string provider)
    {
        this.provider = provider;
        Text = $"API key for {provider}";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ClientSize = new Size(520, 220);
        Font = new Font("Segoe UI", 9F);

        var envNames = string.Join(" / ", AppConfig.EnvNamesFor(provider));
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
            ColumnCount = 1,
            RowCount = 4
        };
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 54));

        var label = new Label
        {
            Text = $"No API key is configured for {provider} yet.",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft
        };
        layout.Controls.Add(label, 0, 0);

        apiKeyBox.Dock = DockStyle.Fill;
        apiKeyBox.UseSystemPasswordChar = true;
        layout.Controls.Add(apiKeyBox, 0, 1);

        var hint = new Label
        {
            Text = string.IsNullOrWhiteSpace(envNames) ? "The key will be stored in appsettings.json." : $"Alternatively, set {envNames} as an environment variable.",
            ForeColor = Color.FromArgb(90, 96, 105),
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft
        };
        layout.Controls.Add(hint, 0, 2);

        var buttons = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.RightToLeft,
            Dock = DockStyle.Fill,
            Padding = new Padding(0, 10, 0, 0),
            WrapContents = false
        };
        var saveButton = new Button { Text = "Save", Width = 92, DialogResult = DialogResult.OK };
        var cancelButton = new Button { Text = "Cancel", Width = 92, DialogResult = DialogResult.Cancel };
        saveButton.Click += (_, _) => ValidateApiKey();
        buttons.Controls.Add(saveButton);
        buttons.Controls.Add(cancelButton);
        layout.Controls.Add(buttons, 0, 3);

        AcceptButton = saveButton;
        CancelButton = cancelButton;
        Controls.Add(layout);
    }

    private void ValidateApiKey()
    {
        if (!string.IsNullOrWhiteSpace(apiKeyBox.Text))
        {
            return;
        }

        DialogResult = DialogResult.None;
        MessageBox.Show(this, $"Enter an API key for {provider}.", "API key missing", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
}

sealed class OpenAiAdminKeyHelpForm : Form
{
    public OpenAiAdminKeyHelpForm(string message)
    {
        Text = "OpenAI Admin-Key";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ClientSize = new Size(560, 230);
        Font = new Font("Segoe UI", 9F);

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
            ColumnCount = 1,
            RowCount = 3
        };
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));

        var label = new Label
        {
            Text = message,
            Dock = DockStyle.Fill,
            AutoEllipsis = false
        };
        layout.Controls.Add(label, 0, 0);

        var link = new LinkLabel
        {
            Text = OpenAiLinks.AdminApiKeys,
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            LinkColor = Color.FromArgb(0, 102, 204),
            ActiveLinkColor = Color.FromArgb(0, 80, 160)
        };
        link.LinkClicked += (_, _) => OpenUrl(OpenAiLinks.AdminApiKeys);
        layout.Controls.Add(link, 0, 1);

        var buttons = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.RightToLeft,
            Dock = DockStyle.Fill,
            Padding = new Padding(0, 10, 0, 0),
            WrapContents = false
        };
        var okButton = new Button { Text = "OK", Width = 92, DialogResult = DialogResult.OK };
        var openButton = new Button { Text = "Open page", Width = 105 };
        openButton.Click += (_, _) => OpenUrl(OpenAiLinks.AdminApiKeys);
        buttons.Controls.Add(okButton);
        buttons.Controls.Add(openButton);
        layout.Controls.Add(buttons, 0, 2);

        AcceptButton = okButton;
        Controls.Add(layout);
    }

    private static void OpenUrl(string url)
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = url,
            UseShellExecute = true
        });
    }
}

sealed class SettingsForm : Form
{
    private readonly ComboBox sttProviderBox = new();
    private readonly TextBox sttModelBox = new();
    private readonly TextBox localAiWhisperUrlBox = new();
    private readonly TextBox localWhisperCppExeBox = new();
    private readonly TextBox localWhisperCppModelPathBox = new();
    private readonly TextBox languageBox = new();
    private readonly ComboBox summaryProviderBox = new();
    private readonly TextBox summaryModelBox = new();
    private readonly TextBox localAiLlmUrlBox = new();
    private readonly CheckBox appFetchUrlBox = new();
    private readonly TextBox urlSummaryPromptBox = new();
    private readonly Dictionary<string, TextBox> apiKeyBoxes = new(StringComparer.OrdinalIgnoreCase);
    private readonly TextBox openAiAdminKeyBox = new();
    private readonly TextBox hotkeyBox = new();
    private readonly CheckBox showKeysBox = new();
    private readonly Label hotkeyStatusLabel = new();
    private readonly Dictionary<string, string> editedProviderApiKeys = new(StringComparer.OrdinalIgnoreCase);
    private string lastSttProvider;
    private string lastSummaryProvider;

    public AppConfig Config { get; private set; }

    public SettingsForm(AppConfig config)
    {
        Config = config;
        lastSttProvider = config.Provider;
        lastSummaryProvider = config.SummaryProvider;
        foreach (var entry in config.ProviderApiKeys)
        {
            editedProviderApiKeys[entry.Key] = entry.Value;
        }

        if (!string.IsNullOrWhiteSpace(config.ApiKey))
        {
            editedProviderApiKeys[config.Provider] = config.ApiKey;
        }

        Text = "EchoScribe Settings";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ClientSize = new Size(720, 700);
        Font = new Font("Segoe UI", 9F);

        sttProviderBox.DropDownStyle = ComboBoxStyle.DropDownList;
        sttProviderBox.Items.AddRange(AppConfig.SupportedProviders.Cast<object>().ToArray());
        sttProviderBox.SelectedItem = AppConfig.SupportedProviders.Contains(config.Provider, StringComparer.OrdinalIgnoreCase)
            ? config.Provider.ToLowerInvariant()
            : "openai";
        sttModelBox.Text = string.IsNullOrWhiteSpace(config.Model) ? AppConfig.DefaultModelFor(config.Provider) : config.Model;
        localAiWhisperUrlBox.Text = string.IsNullOrWhiteSpace(config.LocalAiWhisperUrl) ? AppConfig.DefaultLocalAiWhisperUrl : config.LocalAiWhisperUrl;
        localWhisperCppExeBox.Text = config.LocalWhisperCppExe;
        localWhisperCppModelPathBox.Text = config.LocalWhisperCppModelPath;
        languageBox.Text = config.Language;
        openAiAdminKeyBox.Text = config.OpenAiAdminKey ?? "";
        openAiAdminKeyBox.UseSystemPasswordChar = true;
        summaryProviderBox.DropDownStyle = ComboBoxStyle.DropDownList;
        summaryProviderBox.Items.AddRange(AppConfig.SupportedSummaryProviders.Cast<object>().ToArray());
        summaryProviderBox.SelectedItem = AppConfig.SupportedSummaryProviders.Contains(config.SummaryProvider, StringComparer.OrdinalIgnoreCase)
            ? config.SummaryProvider.ToLowerInvariant()
            : "openai";
        summaryModelBox.Text = config.SummaryModelFor(summaryProviderBox.SelectedItem?.ToString() ?? "openai");
        localAiLlmUrlBox.Text = string.IsNullOrWhiteSpace(config.LocalAiLlmUrl) ? AppConfig.DefaultLocalAiLlmUrl : config.LocalAiLlmUrl;
        appFetchUrlBox.Text = "Fetch webpage content locally when needed";
        appFetchUrlBox.Checked = config.AppFetchUrl;
        appFetchUrlBox.AutoSize = true;
        urlSummaryPromptBox.Text = string.IsNullOrWhiteSpace(config.UrlSummaryPrompt)
            ? AppConfig.DefaultUrlSummaryPrompt
            : config.UrlSummaryPrompt;
        urlSummaryPromptBox.Multiline = true;
        urlSummaryPromptBox.ScrollBars = ScrollBars.Vertical;
        urlSummaryPromptBox.AcceptsReturn = true;
        urlSummaryPromptBox.AcceptsTab = true;

        hotkeyBox.Text = config.Hotkey.Display;
        hotkeyBox.ReadOnly = true;
        hotkeyBox.BackColor = SystemColors.Window;
        hotkeyBox.TabStop = true;
        hotkeyBox.KeyDown += CaptureHotkey;
        hotkeyBox.GotFocus += (_, _) => hotkeyStatusLabel.Text = "Press the keyboard shortcut now";
        hotkeyBox.Click += (_, _) => hotkeyBox.SelectAll();

        sttProviderBox.SelectedIndexChanged += (_, _) =>
        {
            var provider = sttProviderBox.SelectedItem?.ToString() ?? "openai";
            var oldDefault = AppConfig.DefaultModelFor(lastSttProvider);
            if (string.IsNullOrWhiteSpace(sttModelBox.Text) || sttModelBox.Text == oldDefault)
            {
                sttModelBox.Text = AppConfig.DefaultModelFor(provider);
            }

            lastSttProvider = provider;
        };

        summaryProviderBox.SelectedIndexChanged += (_, _) =>
        {
            var provider = summaryProviderBox.SelectedItem?.ToString() ?? "openai";
            var oldDefault = AppConfig.DefaultSummaryModelFor(lastSummaryProvider);
            if (string.IsNullOrWhiteSpace(summaryModelBox.Text) || summaryModelBox.Text == oldDefault)
            {
                summaryModelBox.Text = Config.SummaryModelFor(provider);
            }

            lastSummaryProvider = provider;
        };

        hotkeyStatusLabel.Text = "Click the field and press the desired keyboard shortcut";
        hotkeyStatusLabel.ForeColor = Color.FromArgb(90, 96, 105);
        hotkeyStatusLabel.Dock = DockStyle.Fill;

        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(BuildAudioTab());
        tabs.TabPages.Add(BuildSummaryTab());
        tabs.TabPages.Add(BuildKeysTab());

        var buttons = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.RightToLeft,
            Dock = DockStyle.Fill,
            Padding = new Padding(0, 8, 0, 0),
            WrapContents = false
        };
        var saveButton = new Button { Text = "Save", Width = 92, DialogResult = DialogResult.OK };
        var cancelButton = new Button { Text = "Cancel", Width = 92, DialogResult = DialogResult.Cancel };
        saveButton.Click += (_, e) => SaveSettings(e);
        buttons.Controls.Add(saveButton);
        buttons.Controls.Add(cancelButton);

        AcceptButton = saveButton;
        CancelButton = cancelButton;

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(12),
            ColumnCount = 1,
            RowCount = 2
        };
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 54));
        root.Controls.Add(tabs, 0, 0);
        root.Controls.Add(buttons, 0, 1);
        Controls.Add(root);
    }

    private TabPage BuildAudioTab()
    {
        var tab = new TabPage("Audio");
        var layout = CreateFormLayout(9);
        AddHeader(layout, 0, "Speech-to-Text");
        AddRow(layout, 1, "STT-Provider", sttProviderBox);
        AddRow(layout, 2, "STT model", sttModelBox);
        AddRow(layout, 3, "Local AI Whisper URL", localAiWhisperUrlBox);
        AddRow(layout, 4, "Whisper.cpp exe", localWhisperCppExeBox);
        AddRow(layout, 5, "Whisper.cpp model", localWhisperCppModelPathBox);
        AddRow(layout, 6, "Language", languageBox);
        AddRow(layout, 7, "Hotkey", hotkeyBox);
        layout.Controls.Add(new Label(), 0, 8);
        layout.Controls.Add(hotkeyStatusLabel, 1, 8);
        tab.Controls.Add(layout);
        return tab;
    }

    private TabPage BuildSummaryTab()
    {
        var tab = new TabPage("Web Summary");
        var layout = CreateFormLayout(8);
        AddHeader(layout, 0, "Browser summaries");
        AddRow(layout, 1, "Summary-Provider", summaryProviderBox);
        AddRow(layout, 2, "Summary model", summaryModelBox);
        AddRow(layout, 3, "Local AI LLM URL", localAiLlmUrlBox);
        layout.Controls.Add(new Label(), 0, 4);
        layout.Controls.Add(appFetchUrlBox, 1, 4);
        AddRow(layout, 5, "URL-Prompt", urlSummaryPromptBox);
        layout.RowStyles[5].SizeType = SizeType.Percent;
        layout.RowStyles[5].Height = 100;
        var promptButtons = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Margin = new Padding(0)
        };
        var defaultPromptButton = new Button
        {
            Text = "Default prompt",
            AutoSize = true,
            Height = 28
        };
        defaultPromptButton.Click += (_, _) => urlSummaryPromptBox.Text = AppConfig.DefaultUrlSummaryPrompt;
        promptButtons.Controls.Add(defaultPromptButton);
        layout.Controls.Add(new Label(), 0, 6);
        layout.Controls.Add(promptButtons, 1, 6);
        var hint = new Label
        {
            Text = "PoC mode: Local AI uses Ollama /api/chat for summaries. Keep it on a trusted local network or VPN.",
            ForeColor = Color.FromArgb(90, 96, 105),
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft
        };
        layout.Controls.Add(new Label(), 0, 7);
        layout.Controls.Add(hint, 1, 7);
        tab.Controls.Add(layout);
        return tab;
    }

    private TabPage BuildKeysTab()
    {
        var tab = new TabPage("API Keys");
        var layout = CreateFormLayout(9);
        AddHeader(layout, 0, "Provider keys");
        var row = 1;
        foreach (var provider in new[] { "openai", "elevenlabs", "gemini", "anthropic", "xai" })
        {
            var box = new TextBox
            {
                Text = editedProviderApiKeys.TryGetValue(provider, out var value) ? value : "",
                UseSystemPasswordChar = true,
                Dock = DockStyle.Fill
            };
            apiKeyBoxes[provider] = box;
            AddRow(layout, row++, ProviderLabel(provider), box);
        }

        AddRow(layout, row++, "OpenAI Admin key", openAiAdminKeyBox);
        showKeysBox.Text = "Show keys";
        showKeysBox.AutoSize = true;
        showKeysBox.CheckedChanged += (_, _) => SetKeyMask(!showKeysBox.Checked);
        layout.Controls.Add(new Label(), 0, row);
        layout.Controls.Add(showKeysBox, 1, row);
        tab.Controls.Add(layout);
        return tab;
    }

    private static TableLayoutPanel CreateFormLayout(int rows)
    {
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(14),
            ColumnCount = 2,
            RowCount = rows
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (var i = 0; i < rows; i++)
        {
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, i == 0 ? 38 : 42));
        }

        return layout;
    }

    private static void AddHeader(TableLayoutPanel layout, int row, string text)
    {
        var label = new Label
        {
            Text = text,
            Dock = DockStyle.Fill,
            Font = new Font("Segoe UI", 10F, FontStyle.Bold),
            TextAlign = ContentAlignment.MiddleLeft
        };
        layout.Controls.Add(label, 0, row);
        layout.SetColumnSpan(label, 2);
    }

    private void CaptureHotkey(object? sender, KeyEventArgs e)
    {
        e.SuppressKeyPress = true;
        e.Handled = true;

        if (e.KeyCode is Keys.ControlKey or Keys.ShiftKey or Keys.Menu or Keys.LWin or Keys.RWin)
        {
            hotkeyStatusLabel.Text = "Press a regular key as well";
            hotkeyStatusLabel.ForeColor = Color.FromArgb(170, 120, 20);
            return;
        }

        var candidate = Hotkey.FromPressedKeys(e.KeyCode);
        if (!candidate.HasAnyModifier)
        {
            hotkeyStatusLabel.Text = "Combine it with Win, Alt, Ctrl, or Shift";
            hotkeyStatusLabel.ForeColor = Color.FromArgb(170, 120, 20);
            return;
        }

        if (candidate.Display == Config.Hotkey.Display || HotkeyProbe.IsAvailable(candidate))
        {
            hotkeyBox.Text = candidate.Display;
            hotkeyStatusLabel.Text = "Hotkey is available";
            hotkeyStatusLabel.ForeColor = Color.FromArgb(38, 166, 91);
            return;
        }

        hotkeyStatusLabel.Text = "This shortcut is already in use";
        hotkeyStatusLabel.ForeColor = Color.FromArgb(200, 60, 60);
    }

    private static void AddRow(TableLayoutPanel layout, int row, string label, Control input, Label? labelControl = null)
    {
        labelControl ??= new Label();
        labelControl.Text = label;
        labelControl.Dock = DockStyle.Fill;
        labelControl.TextAlign = ContentAlignment.MiddleLeft;
        input.Dock = DockStyle.Fill;
        layout.Controls.Add(labelControl, 0, row);
        layout.Controls.Add(input, 1, row);
    }

    private void SetKeyMask(bool masked)
    {
        foreach (var box in apiKeyBoxes.Values)
        {
            box.UseSystemPasswordChar = masked;
        }

        openAiAdminKeyBox.UseSystemPasswordChar = masked;
    }

    private static string ProviderLabel(string provider)
    {
        return provider switch
        {
            "openai" => "OpenAI",
            "elevenlabs" => "ElevenLabs",
            "gemini" => "Gemini",
            "anthropic" => "Claude",
            "xai" => "xAI",
            "localai" => "Local AI",
            _ => provider
        };
    }

    private void SaveSettings(EventArgs e)
    {
        try
        {
            var provider = sttProviderBox.SelectedItem?.ToString() ?? "openai";
            var summaryProvider = summaryProviderBox.SelectedItem?.ToString() ?? "openai";
            var apiKeys = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in apiKeyBoxes)
            {
                var value = entry.Value.Text.Trim();
                if (!string.IsNullOrWhiteSpace(value))
                {
                    apiKeys[entry.Key] = value;
                }
            }

            var summaryModels = new Dictionary<string, string>(Config.SummaryModels, StringComparer.OrdinalIgnoreCase)
            {
                [summaryProvider] = string.IsNullOrWhiteSpace(summaryModelBox.Text)
                    ? AppConfig.DefaultSummaryModelFor(summaryProvider)
                    : summaryModelBox.Text.Trim()
            };
            var sttApiKey = apiKeys.TryGetValue(provider, out var providerApiKey) ? providerApiKey : "";

            Config = new AppConfig(
                provider,
                string.IsNullOrWhiteSpace(sttModelBox.Text) ? AppConfig.DefaultModelFor(provider) : sttModelBox.Text.Trim(),
                string.IsNullOrWhiteSpace(languageBox.Text) ? "auto" : languageBox.Text.Trim(),
                sttApiKey,
                openAiAdminKeyBox.Text.Trim(),
                apiKeys,
                summaryProvider,
                summaryModels,
                string.IsNullOrWhiteSpace(urlSummaryPromptBox.Text)
                    ? AppConfig.DefaultUrlSummaryPrompt
                    : urlSummaryPromptBox.Text.Trim(),
                appFetchUrlBox.Checked,
                string.IsNullOrWhiteSpace(localAiLlmUrlBox.Text) ? AppConfig.DefaultLocalAiLlmUrl : localAiLlmUrlBox.Text.Trim(),
                string.IsNullOrWhiteSpace(localAiWhisperUrlBox.Text) ? AppConfig.DefaultLocalAiWhisperUrl : localAiWhisperUrlBox.Text.Trim(),
                localWhisperCppExeBox.Text.Trim(),
                localWhisperCppModelPathBox.Text.Trim(),
                Hotkey.Parse(string.IsNullOrWhiteSpace(hotkeyBox.Text) ? "Alt+A" : hotkeyBox.Text.Trim()));
            Config.Save();
        }
        catch (Exception ex)
        {
            DialogResult = DialogResult.None;
            MessageBox.Show(this, ex.Message, "Settings could not be saved", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}

sealed class Hotkey
{
    public string Display { get; }
    public uint Modifiers { get; }
    public Keys Key { get; }
    public bool HasAnyModifier => (Modifiers & ~NativeMethods.ModNoRepeat) != 0;
    private readonly Keys[] keysToPoll;

    private Hotkey(string display, uint modifiers, Keys key, Keys[] keysToPoll)
    {
        Display = display;
        Modifiers = modifiers;
        Key = key;
        this.keysToPoll = keysToPoll;
    }

    public static Hotkey Parse(string value)
    {
        var parts = value.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        uint modifiers = NativeMethods.ModNoRepeat;
        var pollKeys = new List<Keys>();
        Keys mainKey = Keys.None;

        foreach (var part in parts)
        {
            switch (part.ToLowerInvariant())
            {
                case "win":
                case "windows":
                    modifiers |= NativeMethods.ModWin;
                    pollKeys.Add(Keys.LWin);
                    pollKeys.Add(Keys.RWin);
                    break;
                case "alt":
                    modifiers |= NativeMethods.ModAlt;
                    pollKeys.Add(Keys.Menu);
                    break;
                case "shift":
                    modifiers |= NativeMethods.ModShift;
                    pollKeys.Add(Keys.ShiftKey);
                    break;
                case "ctrl":
                case "control":
                    modifiers |= NativeMethods.ModControl;
                    pollKeys.Add(Keys.ControlKey);
                    break;
                default:
                    mainKey = ParseKey(part);
                    pollKeys.Add(mainKey);
                    break;
            }
        }

        if (mainKey == Keys.None)
        {
            mainKey = Keys.A;
            pollKeys.Add(mainKey);
        }

        return new Hotkey(BuildDisplay(modifiers, mainKey), modifiers, mainKey, pollKeys.ToArray());
    }

    public static Hotkey FromPressedKeys(Keys key)
    {
        uint modifiers = NativeMethods.ModNoRepeat;
        var pollKeys = new List<Keys>();

        if (NativeMethods.IsKeyDown(Keys.LWin) || NativeMethods.IsKeyDown(Keys.RWin))
        {
            modifiers |= NativeMethods.ModWin;
            pollKeys.Add(Keys.LWin);
            pollKeys.Add(Keys.RWin);
        }

        if (NativeMethods.IsKeyDown(Keys.Menu) || NativeMethods.IsKeyDown(Keys.LMenu) || NativeMethods.IsKeyDown(Keys.RMenu))
        {
            modifiers |= NativeMethods.ModAlt;
            pollKeys.Add(Keys.Menu);
        }

        if (NativeMethods.IsKeyDown(Keys.ControlKey) || NativeMethods.IsKeyDown(Keys.LControlKey) || NativeMethods.IsKeyDown(Keys.RControlKey))
        {
            modifiers |= NativeMethods.ModControl;
            pollKeys.Add(Keys.ControlKey);
        }

        if (NativeMethods.IsKeyDown(Keys.ShiftKey) || NativeMethods.IsKeyDown(Keys.LShiftKey) || NativeMethods.IsKeyDown(Keys.RShiftKey))
        {
            modifiers |= NativeMethods.ModShift;
            pollKeys.Add(Keys.ShiftKey);
        }

        pollKeys.Add(key);
        return new Hotkey(BuildDisplay(modifiers, key), modifiers, key, pollKeys.ToArray());
    }

    private static Keys ParseKey(string part)
    {
        return part.ToLowerInvariant() switch
        {
            "`" or "~" or "tilde" or "oemtilde" => Keys.Oemtilde,
            "^" or "caret" => Keys.Oemtilde,
            "space" or "leer" or "leertaste" => Keys.Space,
            "esc" => Keys.Escape,
            _ => Enum.TryParse<Keys>(part, true, out var parsed) ? parsed : Keys.A
        };
    }

    private static string BuildDisplay(uint modifiers, Keys key)
    {
        var parts = new List<string>();
        if ((modifiers & NativeMethods.ModWin) != 0)
        {
            parts.Add("Win");
        }

        if ((modifiers & NativeMethods.ModAlt) != 0)
        {
            parts.Add("Alt");
        }

        if ((modifiers & NativeMethods.ModControl) != 0)
        {
            parts.Add("Ctrl");
        }

        if ((modifiers & NativeMethods.ModShift) != 0)
        {
            parts.Add("Shift");
        }

        parts.Add(DisplayKey(key));
        return string.Join("+", parts);
    }

    private static string DisplayKey(Keys key)
    {
        return key switch
        {
            Keys.Oemtilde => "^",
            Keys.Space => "Space",
            Keys.Escape => "Esc",
            _ => key.ToString()
        };
    }

    public bool IsCurrentlyDown()
    {
        var winNeeded = (Modifiers & NativeMethods.ModWin) != 0;
        foreach (var key in keysToPoll)
        {
            if (key is Keys.LWin or Keys.RWin)
            {
                continue;
            }

            if (!NativeMethods.IsKeyDown(key))
            {
                return false;
            }
        }

        return !winNeeded || NativeMethods.IsKeyDown(Keys.LWin) || NativeMethods.IsKeyDown(Keys.RWin);
    }

    public bool MatchesPressed(IReadOnlySet<Keys> pressedKeys)
    {
        if ((Modifiers & NativeMethods.ModWin) != 0 && !ContainsAny(pressedKeys, Keys.LWin, Keys.RWin))
        {
            return false;
        }

        if ((Modifiers & NativeMethods.ModAlt) != 0 && !ContainsAny(pressedKeys, Keys.Menu, Keys.LMenu, Keys.RMenu))
        {
            return false;
        }

        if ((Modifiers & NativeMethods.ModControl) != 0 && !ContainsAny(pressedKeys, Keys.ControlKey, Keys.LControlKey, Keys.RControlKey))
        {
            return false;
        }

        if ((Modifiers & NativeMethods.ModShift) != 0 && !ContainsAny(pressedKeys, Keys.ShiftKey, Keys.LShiftKey, Keys.RShiftKey))
        {
            return false;
        }

        return ContainsEquivalentKey(pressedKeys, Key);
    }

    private static bool ContainsEquivalentKey(IReadOnlySet<Keys> pressedKeys, Keys key)
    {
        return key switch
        {
            Keys.Menu => ContainsAny(pressedKeys, Keys.Menu, Keys.LMenu, Keys.RMenu),
            Keys.ControlKey => ContainsAny(pressedKeys, Keys.ControlKey, Keys.LControlKey, Keys.RControlKey),
            Keys.ShiftKey => ContainsAny(pressedKeys, Keys.ShiftKey, Keys.LShiftKey, Keys.RShiftKey),
            _ => pressedKeys.Contains(key)
        };
    }

    private static bool ContainsAny(IReadOnlySet<Keys> pressedKeys, params Keys[] candidates)
    {
        foreach (var candidate in candidates)
        {
            if (pressedKeys.Contains(candidate))
            {
                return true;
            }
        }

        return false;
    }

    public void WaitUntilReleased(int timeoutMilliseconds)
    {
        var timeoutAt = Environment.TickCount64 + timeoutMilliseconds;
        while (Environment.TickCount64 < timeoutAt && AnyHotkeyPartDown())
        {
            Application.DoEvents();
            Thread.Sleep(25);
        }
    }

    private bool AnyHotkeyPartDown()
    {
        foreach (var key in keysToPoll)
        {
            if (key == Keys.LWin || key == Keys.RWin)
            {
                if (NativeMethods.IsKeyDown(Keys.LWin) || NativeMethods.IsKeyDown(Keys.RWin))
                {
                    return true;
                }

                continue;
            }

            if (NativeMethods.IsKeyDown(key))
            {
                return true;
            }
        }

        return false;
    }
}

sealed class KeyboardHook : IDisposable
{
    private const int WhKeyboardLl = 13;
    private const int WmKeydown = 0x0100;
    private const int WmKeyup = 0x0101;
    private const int WmSyskeydown = 0x0104;
    private const int WmSyskeyup = 0x0105;
    private readonly SynchronizationContext context;
    private readonly Action onPressed;
    private readonly Action onReleased;
    private readonly HashSet<Keys> pressedKeys = new();
    private readonly NativeMethods.LowLevelKeyboardProc callback;
    private Hotkey hotkey;
    private IntPtr hookHandle;
    private bool active;
    private bool disposed;

    public KeyboardHook(Hotkey hotkey, Action onPressed, Action onReleased)
    {
        this.hotkey = hotkey;
        this.onPressed = onPressed;
        this.onReleased = onReleased;
        context = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        callback = HandleKeyboardEvent;
    }

    public void Start()
    {
        if (hookHandle != IntPtr.Zero)
        {
            return;
        }

        hookHandle = NativeMethods.SetWindowsHookEx(WhKeyboardLl, callback, IntPtr.Zero, 0);
        if (hookHandle == IntPtr.Zero)
        {
            AppLog.Write($"SetWindowsHookEx failed; lastError={Marshal.GetLastWin32Error()}");
        }
    }

    public void MarkActive()
    {
        active = true;
    }

    public void MarkInactive()
    {
        active = false;
        pressedKeys.Clear();
    }

    private IntPtr HandleKeyboardEvent(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var vkCode = Marshal.ReadInt32(lParam);
            var key = NormalizeKey((Keys)vkCode);
            var message = wParam.ToInt32();
            var isDown = message is WmKeydown or WmSyskeydown;
            var isUp = message is WmKeyup or WmSyskeyup;

            if (isDown)
            {
                pressedKeys.Add(key);
            }
            else if (isUp)
            {
                pressedKeys.Remove(key);
                RemoveModifierAliases(key);
            }

            var matches = hotkey.MatchesPressed(pressedKeys);
            if (matches && !active)
            {
                active = true;
                context.Post(_ => onPressed(), null);
            }
            else if (!matches && active)
            {
                active = false;
                context.Post(_ => onReleased(), null);
            }
        }

        return NativeMethods.CallNextHookEx(hookHandle, nCode, wParam, lParam);
    }

    private void RemoveModifierAliases(Keys key)
    {
        if (key is Keys.LMenu or Keys.RMenu or Keys.Menu)
        {
            pressedKeys.Remove(Keys.Menu);
            pressedKeys.Remove(Keys.LMenu);
            pressedKeys.Remove(Keys.RMenu);
        }
        else if (key is Keys.LControlKey or Keys.RControlKey or Keys.ControlKey)
        {
            pressedKeys.Remove(Keys.ControlKey);
            pressedKeys.Remove(Keys.LControlKey);
            pressedKeys.Remove(Keys.RControlKey);
        }
        else if (key is Keys.LShiftKey or Keys.RShiftKey or Keys.ShiftKey)
        {
            pressedKeys.Remove(Keys.ShiftKey);
            pressedKeys.Remove(Keys.LShiftKey);
            pressedKeys.Remove(Keys.RShiftKey);
        }
    }

    private static Keys NormalizeKey(Keys key)
    {
        return key switch
        {
            Keys.ControlKey => Keys.ControlKey,
            Keys.ShiftKey => Keys.ShiftKey,
            Keys.Menu => Keys.Menu,
            _ => key
        };
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        if (hookHandle != IntPtr.Zero)
        {
            NativeMethods.UnhookWindowsHookEx(hookHandle);
            hookHandle = IntPtr.Zero;
        }

        disposed = true;
    }
}

sealed class HotkeyWindow : NativeWindow, IDisposable
{
    private const int HotkeyId = 0x505454;
    private const int WmHotkey = 0x0312;
    private readonly Hotkey hotkey;
    private readonly Action onPressed;
    private bool registered;
    private bool disposed;

    public HotkeyWindow(Hotkey hotkey, Action onPressed)
    {
        this.hotkey = hotkey;
        this.onPressed = onPressed;
        CreateHandle(new CreateParams());
    }

    public bool Register()
    {
        registered = NativeMethods.RegisterHotKey(Handle, HotkeyId, hotkey.Modifiers, (uint)hotkey.Key);
        return registered;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WmHotkey)
        {
            onPressed();
        }

        base.WndProc(ref m);
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        if (registered)
        {
            NativeMethods.UnregisterHotKey(Handle, HotkeyId);
        }

        DestroyHandle();
        disposed = true;
    }
}

sealed class HotkeyProbe : NativeWindow, IDisposable
{
    private readonly int id = Random.Shared.Next(0x6000, 0x7FFF);
    private bool registered;
    private bool disposed;

    private HotkeyProbe()
    {
        CreateHandle(new CreateParams());
    }

    public static bool IsAvailable(Hotkey hotkey)
    {
        using var probe = new HotkeyProbe();
        probe.registered = NativeMethods.RegisterHotKey(probe.Handle, probe.id, hotkey.Modifiers, (uint)hotkey.Key);
        return probe.registered;
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        if (registered)
        {
            NativeMethods.UnregisterHotKey(Handle, id);
        }

        DestroyHandle();
        disposed = true;
    }
}

enum StatusKind
{
    Ready,
    Recording,
    Transcribing,
    Success,
    Error
}

sealed class FloatingStatusForm : Form
{
    private readonly StatusIconControl iconControl = new();
    private readonly Label messageLabel = new();

    public FloatingStatusForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(28, 31, 36);
        ForeColor = Color.White;
        Size = new Size(320, 90);
        Padding = new Padding(16);
        Opacity = 0.94;

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            RowCount = 1
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 44));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        iconControl.Dock = DockStyle.Fill;
        messageLabel.TextAlign = ContentAlignment.MiddleLeft;
        messageLabel.Font = new Font("Segoe UI", 11F, FontStyle.Regular);
        messageLabel.ForeColor = Color.White;
        messageLabel.Dock = DockStyle.Fill;
        layout.Controls.Add(iconControl, 0, 0);
        layout.Controls.Add(messageLabel, 1, 0);
        Controls.Add(layout);
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x00000080; // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
            return cp;
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using var path = RoundedRect(ClientRectangle, 8);
        Region = new Region(path);
        using var pen = new Pen(Color.FromArgb(80, 255, 255, 255));
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.DrawPath(pen, path);
    }

    public void ShowMessage(string message, StatusKind kind)
    {
        messageLabel.Text = message;
        iconControl.Kind = kind;
        var area = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1200, 800);
        Location = new Point(area.Right - Width - 22, area.Bottom - Height - 22);
        if (!Visible)
        {
            Show();
        }

        Invalidate();
    }

    private static GraphicsPath RoundedRect(Rectangle bounds, int radius)
    {
        var diameter = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter - 1, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter - 1, bounds.Bottom - diameter - 1, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter - 1, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

sealed class StatusIconControl : Control
{
    private StatusKind kind = StatusKind.Ready;

    public StatusKind Kind
    {
        get => kind;
        set
        {
            kind = value;
            Invalidate();
        }
    }

    public StatusIconControl()
    {
        DoubleBuffered = true;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;

        var size = Math.Min(32, Math.Min(Width, Height) - 4);
        var x = (Width - size) / 2;
        var y = (Height - size) / 2;
        var bounds = new Rectangle(x, y, size, size);
        var (bg, fg) = ColorsFor(kind);

        using var bgBrush = new SolidBrush(bg);
        using var fgPen = new Pen(fg, 2.4F) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        using var fgBrush = new SolidBrush(fg);
        e.Graphics.FillEllipse(bgBrush, bounds);

        switch (kind)
        {
            case StatusKind.Recording:
                DrawMic(e.Graphics, bounds, fgBrush, fgPen);
                break;
            case StatusKind.Transcribing:
                DrawSpinner(e.Graphics, bounds, fgPen);
                break;
            case StatusKind.Success:
                e.Graphics.DrawLines(fgPen, new[]
                {
                    new Point(bounds.Left + 8, bounds.Top + 17),
                    new Point(bounds.Left + 14, bounds.Top + 23),
                    new Point(bounds.Left + 24, bounds.Top + 10)
                });
                break;
            case StatusKind.Error:
                e.Graphics.DrawLine(fgPen, bounds.Left + 10, bounds.Top + 10, bounds.Right - 10, bounds.Bottom - 10);
                e.Graphics.DrawLine(fgPen, bounds.Right - 10, bounds.Top + 10, bounds.Left + 10, bounds.Bottom - 10);
                break;
            default:
                e.Graphics.FillEllipse(fgBrush, bounds.Left + 14, bounds.Top + 8, 4, 4);
                e.Graphics.DrawLine(fgPen, bounds.Left + 16, bounds.Top + 15, bounds.Left + 16, bounds.Top + 24);
                break;
        }
    }

    private static (Color Bg, Color Fg) ColorsFor(StatusKind kind)
    {
        return kind switch
        {
            StatusKind.Recording => (Color.FromArgb(231, 76, 60), Color.White),
            StatusKind.Transcribing => (Color.FromArgb(38, 132, 255), Color.White),
            StatusKind.Success => (Color.FromArgb(38, 166, 91), Color.White),
            StatusKind.Error => (Color.FromArgb(220, 53, 69), Color.White),
            _ => (Color.FromArgb(102, 112, 133), Color.White)
        };
    }

    private static void DrawMic(Graphics graphics, Rectangle bounds, Brush brush, Pen pen)
    {
        graphics.FillRoundedRectangle(brush, new Rectangle(bounds.Left + 12, bounds.Top + 7, 8, 13), 4);
        graphics.DrawArc(pen, bounds.Left + 8, bounds.Top + 12, 16, 12, 0, 180);
        graphics.DrawLine(pen, bounds.Left + 16, bounds.Top + 23, bounds.Left + 16, bounds.Top + 26);
        graphics.DrawLine(pen, bounds.Left + 11, bounds.Top + 26, bounds.Left + 21, bounds.Top + 26);
    }

    private static void DrawSpinner(Graphics graphics, Rectangle bounds, Pen pen)
    {
        graphics.DrawArc(pen, bounds.Left + 8, bounds.Top + 8, bounds.Width - 16, bounds.Height - 16, 210, 250);
        using var brush = new SolidBrush(pen.Color);
        graphics.FillEllipse(brush, bounds.Right - 12, bounds.Top + 8, 4, 4);
    }
}

static class MenuIconFactory
{
    private const int IconSize = 16;

    public static Image App()
    {
        using var appIcon = IconFactory.LoadAppIcon();
        using var source = appIcon.ToBitmap();
        return new Bitmap(source, new Size(IconSize, IconSize));
    }

    public static Image Status(bool recording, bool transcribing)
    {
        var color = recording
            ? Color.FromArgb(220, 56, 56)
            : transcribing
                ? Color.FromArgb(37, 99, 235)
                : Color.FromArgb(22, 163, 74);
        return Draw((graphics, _, _, _) =>
        {
            using var brush = new SolidBrush(color);
            graphics.FillEllipse(brush, 4, 4, 8, 8);
            using var pen = new Pen(Color.FromArgb(80, 0, 0, 0));
            graphics.DrawEllipse(pen, 4, 4, 8, 8);
        });
    }

    public static Image Mic()
    {
        return Draw((graphics, pen, _, accent) =>
        {
            graphics.FillRoundedRectangle(accent, new Rectangle(6, 2, 4, 8), 2);
            graphics.DrawArc(pen, 4, 6, 8, 6, 0, 180);
            graphics.DrawLine(pen, 8, 12, 8, 14);
            graphics.DrawLine(pen, 5, 14, 11, 14);
        });
    }

    public static Image Stop()
    {
        return Draw((graphics, _, _, _) =>
        {
            using var brush = new SolidBrush(Color.FromArgb(220, 56, 56));
            graphics.FillRectangle(brush, 4, 4, 8, 8);
        });
    }

    public static Image Summary()
    {
        return Draw((graphics, pen, _, accent) =>
        {
            graphics.FillRectangle(accent, 3, 4, 3, 3);
            graphics.DrawLine(pen, 7, 5, 13, 5);
            graphics.FillRectangle(accent, 3, 8, 3, 3);
            graphics.DrawLine(pen, 7, 9, 13, 9);
            graphics.DrawLine(pen, 3, 13, 13, 13);
        });
    }

    public static Image Providers()
    {
        return Draw((graphics, pen, _, accent) =>
        {
            graphics.DrawLine(pen, 3, 5, 13, 5);
            graphics.FillEllipse(accent, 5, 3, 4, 4);
            graphics.DrawLine(pen, 3, 10, 13, 10);
            graphics.FillEllipse(accent, 9, 8, 4, 4);
        });
    }

    public static Image ProviderOption(string provider)
    {
        var color = provider.ToLowerInvariant() switch
        {
            "openai" => Color.FromArgb(16, 163, 127),
            "elevenlabs" => Color.FromArgb(17, 24, 39),
            "gemini" => Color.FromArgb(99, 102, 241),
            "anthropic" => Color.FromArgb(214, 119, 59),
            "xai" => Color.FromArgb(82, 82, 91),
            "localai" => Color.FromArgb(37, 99, 235),
            _ => Color.FromArgb(80, 90, 110)
        };
        return Draw((graphics, _, _, _) =>
        {
            using var brush = new SolidBrush(color);
            graphics.FillEllipse(brush, 4, 4, 8, 8);
        });
    }

    public static Image Billing()
    {
        return Draw((graphics, pen, _, accent) =>
        {
            graphics.DrawLine(pen, 3, 13, 13, 13);
            graphics.FillRectangle(accent, 4, 9, 2, 4);
            graphics.FillRectangle(accent, 7, 6, 2, 7);
            graphics.FillRectangle(accent, 10, 3, 2, 10);
        });
    }

    public static Image BrowserExtension()
    {
        return Draw((graphics, pen, _, accent) =>
        {
            graphics.DrawRoundedRectangle(pen, new Rectangle(3, 4, 10, 9), 2);
            graphics.FillEllipse(accent, 6, 2, 4, 4);
            graphics.FillEllipse(accent, 11, 7, 3, 3);
        });
    }

    public static Image ExternalLink()
    {
        return Draw((graphics, pen, _, accent) =>
        {
            graphics.DrawRectangle(pen, 3, 6, 7, 7);
            graphics.DrawLine(pen, 8, 4, 12, 4);
            graphics.DrawLine(pen, 12, 4, 12, 8);
            using var arrowPen = new Pen(accent.Color, 2);
            graphics.DrawLine(arrowPen, 8, 8, 12, 4);
        });
    }

    public static Image Settings()
    {
        return Draw((graphics, pen, _, accent) =>
        {
            graphics.DrawEllipse(pen, 4, 4, 8, 8);
            graphics.FillEllipse(accent, 7, 7, 2, 2);
            graphics.DrawLine(pen, 8, 1, 8, 4);
            graphics.DrawLine(pen, 8, 12, 8, 15);
            graphics.DrawLine(pen, 1, 8, 4, 8);
            graphics.DrawLine(pen, 12, 8, 15, 8);
        });
    }

    public static Image ConfigFile()
    {
        return Draw((graphics, pen, _, accent) =>
        {
            graphics.DrawRectangle(pen, 4, 2, 8, 12);
            graphics.DrawLine(pen, 9, 2, 12, 5);
            graphics.DrawLine(pen, 9, 2, 9, 5);
            graphics.DrawLine(pen, 9, 5, 12, 5);
            using var linePen = new Pen(accent.Color, 2);
            graphics.DrawLine(linePen, 6, 8, 10, 8);
            graphics.DrawLine(linePen, 6, 11, 10, 11);
        });
    }

    public static Image Power()
    {
        return Draw((graphics, pen, _, accent) =>
        {
            using var powerPen = new Pen(accent.Color, 2);
            graphics.DrawArc(pen, 4, 4, 8, 8, 35, 290);
            graphics.DrawLine(powerPen, 8, 2, 8, 8);
        });
    }

    private static Bitmap Draw(Action<Graphics, Pen, SolidBrush, SolidBrush> draw)
    {
        var bitmap = new Bitmap(IconSize, IconSize);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
        graphics.Clear(Color.Transparent);
        using var pen = new Pen(Color.FromArgb(80, 88, 100), 1.3f);
        using var fill = new SolidBrush(Color.FromArgb(80, 88, 100));
        using var accent = new SolidBrush(Color.FromArgb(38, 132, 255));
        draw(graphics, pen, fill, accent);
        return bitmap;
    }
}

static class IconFactory
{
    public static Icon LoadAppIcon()
    {
        var iconPath = Path.Combine(AppContext.BaseDirectory, "app.ico");
        if (File.Exists(iconPath))
        {
            return new Icon(iconPath);
        }

        return Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? Create();
    }

    public static Icon Create()
    {
        using var bitmap = new Bitmap(32, 32);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.Clear(Color.Transparent);
        using var bg = new SolidBrush(Color.FromArgb(38, 132, 255));
        using var fg = new SolidBrush(Color.White);
        graphics.FillEllipse(bg, 2, 2, 28, 28);
        graphics.FillRoundedRectangle(fg, new Rectangle(12, 7, 8, 13), 4);
        graphics.FillRectangle(fg, 15, 18, 2, 5);
        graphics.FillRectangle(fg, 10, 23, 12, 2);
        return Icon.FromHandle(bitmap.GetHicon());
    }
}

static class GraphicsExtensions
{
    public static void DrawRoundedRectangle(this Graphics graphics, Pen pen, Rectangle bounds, int radius)
    {
        using var path = CreateRoundedRectanglePath(bounds, radius);
        graphics.DrawPath(pen, path);
    }

    public static void FillRoundedRectangle(this Graphics graphics, Brush brush, Rectangle bounds, int radius)
    {
        using var path = CreateRoundedRectanglePath(bounds, radius);
        graphics.FillPath(brush, path);
    }

    private static GraphicsPath CreateRoundedRectanglePath(Rectangle bounds, int radius)
    {
        var path = new GraphicsPath();
        var diameter = radius * 2;
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

static class NativeMethods
{
    public const uint ModAlt = 0x0001;
    public const uint ModControl = 0x0002;
    public const uint ModShift = 0x0004;
    public const uint ModWin = 0x0008;
    public const uint ModNoRepeat = 0x4000;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    public static bool IsKeyDown(Keys key) => (GetAsyncKeyState((int)key) & 0x8000) != 0;

    public static bool SendCtrlV()
    {
        ReleaseCommonModifiers();
        Thread.Sleep(30);
        var inputs = new[]
        {
            KeyInput(Keys.LControlKey, false),
            KeyInput(Keys.V, false),
            KeyInput(Keys.V, true),
            KeyInput(Keys.LControlKey, true)
        };
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent != inputs.Length)
        {
            AppLog.Write($"SendInput Ctrl+V sent {sent}/{inputs.Length}; lastError={Marshal.GetLastWin32Error()}; inputSize={Marshal.SizeOf<INPUT>()}");
            return false;
        }

        return true;
    }

    private static void ReleaseCommonModifiers()
    {
        var keyUps = new[]
        {
            KeyInput(Keys.LWin, true),
            KeyInput(Keys.RWin, true),
            KeyInput(Keys.Menu, true),
            KeyInput(Keys.LMenu, true),
            KeyInput(Keys.RMenu, true),
            KeyInput(Keys.ShiftKey, true),
            KeyInput(Keys.ControlKey, true)
        };
        var sent = SendInput((uint)keyUps.Length, keyUps, Marshal.SizeOf<INPUT>());
        if (sent != keyUps.Length)
        {
            AppLog.Write($"SendInput modifier release sent {sent}/{keyUps.Length}; lastError={Marshal.GetLastWin32Error()}; inputSize={Marshal.SizeOf<INPUT>()}");
        }
    }

    private static INPUT KeyInput(Keys key, bool keyUp)
    {
        return new INPUT
        {
            type = 1,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = (ushort)key,
                    dwFlags = keyUp ? 0x0002u : 0
                }
            }
        };
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)]
        public KEYBDINPUT ki;

        [FieldOffset(0)]
        public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
}

static class AppLog
{
    private static readonly string LogPath = Path.Combine(AppContext.BaseDirectory, "echoscribe.log");

    public static void Write(string message)
    {
        try
        {
            File.AppendAllText(LogPath, $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff} {message}{Environment.NewLine}");
        }
        catch
        {
            // Logging must never interfere with transcription.
        }
    }
}

sealed record BrowserExtensionInstallResult(
    string ChromiumExtensionId,
    string ChromiumExtensionDirectory,
    string FirefoxExtensionId,
    string FirefoxExtensionManifestPath,
    string ChromiumNativeHostManifestPath,
    string FirefoxNativeHostManifestPath,
    IReadOnlyList<string> RegistryKeys);

static class BrowserExtensionInstaller
{
    private const string NativeHostName = "de.echoscribe.nativehost";
    private const string FirefoxExtensionId = "echoscribe@wean.de";
    private static readonly UTF8Encoding Utf8NoBom = new(false);
    private static readonly string[] ChromiumRegistryBases =
    [
        @"Software\Google\Chrome\NativeMessagingHosts",
        @"Software\Chromium\NativeMessagingHosts",
        @"Software\Microsoft\Edge\NativeMessagingHosts",
        @"Software\BraveSoftware\Brave-Browser\NativeMessagingHosts"
    ];

    public static BrowserExtensionInstallResult Register()
    {
        var chromiumExtensionDirectory = FindChromiumExtensionDirectory();
        var firefoxExtensionDirectory = FindFirefoxExtensionDirectory();
        var firefoxExtensionManifestPath = Path.Combine(firefoxExtensionDirectory, "manifest.json");
        var extensionId = ReadExtensionId(chromiumExtensionDirectory);
        var hostPath = FindNativeHostPath();
        var nativeHostDirectory = Path.GetDirectoryName(hostPath) ?? AppContext.BaseDirectory;
        var chromiumManifestPath = Path.Combine(nativeHostDirectory, $"{NativeHostName}.json");
        var firefoxManifestPath = Path.Combine(nativeHostDirectory, $"{NativeHostName}.firefox.json");

        WriteNativeHostManifest(chromiumManifestPath, new Dictionary<string, object>
        {
            ["name"] = NativeHostName,
            ["description"] = "EchoScribe Web Summary Native Host",
            ["path"] = hostPath,
            ["type"] = "stdio",
            ["allowed_origins"] = new[] { $"chrome-extension://{extensionId}/" }
        });
        WriteNativeHostManifest(firefoxManifestPath, new Dictionary<string, object>
        {
            ["name"] = NativeHostName,
            ["description"] = "EchoScribe Web Summary Native Host",
            ["path"] = hostPath,
            ["type"] = "stdio",
            ["allowed_extensions"] = new[] { FirefoxExtensionId }
        });

        var registryKeys = new List<string>();
        foreach (var registryBase in ChromiumRegistryBases)
        {
            registryKeys.Add(RegisterNativeMessagingHost($@"{registryBase}\{NativeHostName}", chromiumManifestPath));
        }
        registryKeys.Add(RegisterNativeMessagingHost($@"Software\Mozilla\NativeMessagingHosts\{NativeHostName}", firefoxManifestPath));

        return new BrowserExtensionInstallResult(
            extensionId,
            chromiumExtensionDirectory,
            FirefoxExtensionId,
            firefoxExtensionManifestPath,
            chromiumManifestPath,
            firefoxManifestPath,
            registryKeys);
    }

    public static string FindExtensionDirectory()
    {
        return FindChromiumExtensionDirectory();
    }

    public static IReadOnlyList<string> FindExtensionDirectories()
    {
        return
        [
            FindChromiumExtensionDirectory(),
            FindFirefoxExtensionDirectory()
        ];
    }

    public static void OpenExtensionDirectories()
    {
        foreach (var directory in FindExtensionDirectories())
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = directory,
                UseShellExecute = true
            });
        }
    }

    public static IReadOnlyList<string> OpenBrowserSetupPages()
    {
        var opened = new List<string>();
        foreach (var target in BrowserTargets())
        {
            if (target.Executable is null)
            {
                continue;
            }

            var info = new ProcessStartInfo
            {
                FileName = target.Executable,
                UseShellExecute = false
            };
            info.ArgumentList.Add(target.Url);
            Process.Start(info);
            opened.Add(target.Name);
        }

        return opened;
    }

    public static IReadOnlyList<string> GetAvailableBrowserSetupTargets()
    {
        return BrowserTargets()
            .Where(target => target.Executable is not null)
            .Select(target => target.Name)
            .ToArray();
    }

    public static bool OpenBrowserSetupPage(string browserName)
    {
        var target = BrowserTargets()
            .FirstOrDefault(candidate => candidate.Name.Equals(browserName, StringComparison.OrdinalIgnoreCase));
        if (target?.Executable is null)
        {
            return false;
        }

        var info = new ProcessStartInfo
        {
            FileName = target.Executable,
            UseShellExecute = false
        };
        info.ArgumentList.Add(target.Url);
        Process.Start(info);
        return true;
    }

    private static string FindChromiumExtensionDirectory()
    {
        var candidates = CandidateRoots()
            .SelectMany(root => new[]
            {
                Path.Combine(root, "chrome-extension"),
                Path.Combine(root, "browser-extension")
            })
            .Where(path => File.Exists(Path.Combine(path, "manifest.json")))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        return candidates.FirstOrDefault()
            ?? throw new DirectoryNotFoundException("The browser-extension/chrome-extension folder was not found. Build or publish EchoScribe first.");
    }

    private static string FindFirefoxExtensionDirectory()
    {
        var candidates = CandidateRoots()
            .SelectMany(root => new[]
            {
                Path.Combine(root, "firefox-extension"),
                Path.Combine(root, "publish", "firefox-extension")
            })
            .Where(path => File.Exists(Path.Combine(path, "manifest.json")))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        return candidates.FirstOrDefault()
            ?? throw new DirectoryNotFoundException("The firefox-extension folder was not found. Build or publish EchoScribe first.");
    }

    private static string FindNativeHostPath()
    {
        var candidates = CandidateRoots()
            .SelectMany(root => new[]
            {
                Path.Combine(root, "EchoScribe.NativeHost.exe"),
                Path.Combine(root, "native-host", "EchoScribe.NativeHost.exe"),
                Path.Combine(root, "publish", "native-host", "EchoScribe.NativeHost.exe"),
                Path.Combine(root, "native-host", "bin", "Release", "net8.0", "win-x64", "publish", "EchoScribe.NativeHost.exe"),
                Path.Combine(root, "native-host", "bin", "Release", "net8.0", "EchoScribe.NativeHost.exe"),
                Path.Combine(root, "native-host", "bin", "Debug", "net8.0", "EchoScribe.NativeHost.exe")
            })
            .Where(File.Exists)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        return candidates.FirstOrDefault()
            ?? throw new FileNotFoundException("EchoScribe.NativeHost.exe was not found. Build or publish the native host first.");
    }

    private static void WriteNativeHostManifest(string path, Dictionary<string, object> payload)
    {
        var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json + Environment.NewLine, Utf8NoBom);
    }

    private static string RegisterNativeMessagingHost(string registryPath, string manifestPath)
    {
        using var key = Registry.CurrentUser.CreateSubKey(registryPath, writable: true)
            ?? throw new InvalidOperationException($"Native Messaging registry key could not be created: HKCU\\{registryPath}");
        key.SetValue("", manifestPath, RegistryValueKind.String);
        return $@"HKCU\{registryPath}";
    }

    private static IEnumerable<string> CandidateRoots()
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var start in new[] { AppContext.BaseDirectory, Environment.CurrentDirectory })
        {
            var current = new DirectoryInfo(start);
            while (current is not null)
            {
                if (seen.Add(current.FullName))
                {
                    yield return current.FullName;
                }

                current = current.Parent;
            }
        }
    }

    private static string ReadExtensionId(string extensionDirectory)
    {
        var manifestPath = Path.Combine(extensionDirectory, "manifest.json");
        using var json = JsonDocument.Parse(File.ReadAllText(manifestPath));
        if (!json.RootElement.TryGetProperty("key", out var keyElement) || keyElement.ValueKind != JsonValueKind.String)
        {
            throw new InvalidOperationException("browser-extension/manifest.json needs a 'key' field so the extension ID stays stable.");
        }

        var publicKey = Convert.FromBase64String(keyElement.GetString() ?? "");
        var hash = SHA256.HashData(publicKey);
        var id = new StringBuilder(32);
        for (var i = 0; i < 16; i++)
        {
            id.Append((char)('a' + (hash[i] >> 4)));
            id.Append((char)('a' + (hash[i] & 0x0F)));
        }

        return id.ToString();
    }

    private static IReadOnlyList<BrowserTarget> BrowserTargets()
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        return
        [
            new BrowserTarget("Google Chrome", "chrome://extensions", FirstExistingFile(
                CombineIfRoot(programFiles, @"Google\Chrome\Application\chrome.exe"),
                CombineIfRoot(programFilesX86, @"Google\Chrome\Application\chrome.exe"),
                CombineIfRoot(localAppData, @"Google\Chrome\Application\chrome.exe"))),
            new BrowserTarget("Microsoft Edge", "edge://extensions", FirstExistingFile(
                CombineIfRoot(programFiles, @"Microsoft\Edge\Application\msedge.exe"),
                CombineIfRoot(programFilesX86, @"Microsoft\Edge\Application\msedge.exe"),
                CombineIfRoot(localAppData, @"Microsoft\Edge\Application\msedge.exe"))),
            new BrowserTarget("Brave", "brave://extensions", FirstExistingFile(
                CombineIfRoot(programFiles, @"BraveSoftware\Brave-Browser\Application\brave.exe"),
                CombineIfRoot(programFilesX86, @"BraveSoftware\Brave-Browser\Application\brave.exe"),
                CombineIfRoot(localAppData, @"BraveSoftware\Brave-Browser\Application\brave.exe"))),
            new BrowserTarget("Chromium", "chrome://extensions", FirstExistingFile(
                CombineIfRoot(programFiles, @"Chromium\Application\chrome.exe"),
                CombineIfRoot(programFilesX86, @"Chromium\Application\chrome.exe"),
                CombineIfRoot(localAppData, @"Chromium\Application\chrome.exe"))),
            new BrowserTarget("Firefox", "about:debugging#/runtime/this-firefox", FirstExistingFile(
                CombineIfRoot(programFiles, @"Mozilla Firefox\firefox.exe"),
                CombineIfRoot(programFilesX86, @"Mozilla Firefox\firefox.exe"),
                CombineIfRoot(localAppData, @"Mozilla Firefox\firefox.exe")))
        ];
    }

    private static string? FirstExistingFile(params string[] paths)
    {
        return paths.FirstOrDefault(path => !string.IsNullOrWhiteSpace(path) && File.Exists(path));
    }

    private static string CombineIfRoot(string root, string relative)
    {
        return string.IsNullOrWhiteSpace(root) ? "" : Path.Combine(root, relative);
    }

    private sealed record BrowserTarget(string Name, string Url, string? Executable);
}

