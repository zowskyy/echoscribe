using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using UglyToad.PdfPig;

namespace EchoScribe.NativeHost;

static class Program
{
    static async Task<int> Main(string[] args)
    {
        try
        {
            _ = args;
            var request = await NativeMessaging.ReadAsync(Console.OpenStandardInput());
            var responseObject = await NativeHostApp.HandleAsync(request);
            await NativeMessaging.WriteAsync(Console.OpenStandardOutput(), responseObject);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            await NativeMessaging.WriteAsync(Console.OpenStandardOutput(), new SummaryResponse(false, "", "", "", ex.Message));
            return 1;
        }
    }
}

static class NativeHostApp
{
    public static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    private static readonly HttpClient Http = new()
    {
        Timeout = TimeSpan.FromSeconds(90)
    };

    public static Task<object> HandleAsync(JsonElement request)
    {
        var type = ReadString(request, "type");
        if (!type.Equals("summarize", StringComparison.OrdinalIgnoreCase))
        {
            return Task.FromResult<object>(new SummaryResponse(false, "", "", "", $"Unknown request type '{type}'."));
        }

        var summaryRequest = new SummaryRequest
        {
            Type = type,
            Url = ReadString(request, "url"),
            Title = ReadString(request, "title"),
            Description = ReadString(request, "description"),
            Selection = ReadString(request, "selection"),
            Text = ReadString(request, "text"),
            PdfBase64 = ReadString(request, "pdfBase64"),
            MimeType = ReadString(request, "mimeType"),
            Provider = ReadString(request, "provider"),
            TargetLanguageCode = ReadString(request, "targetLanguageCode")
        };

        return SummarizeAsync(summaryRequest).ContinueWith<object>(task => task.Result);
    }

    public static async Task<SummaryResponse> SummarizeAsync(SummaryRequest request)
    {
        try
        {
            var config = LazyConfig.Load();
            var provider = config.ResolveSummaryProvider(request.Provider);
            var model = config.SummaryModelFor(provider);
            var apiKey = provider.Equals("localai", StringComparison.OrdinalIgnoreCase)
                ? ""
                : config.ResolveApiKey(provider);
            var source = await BuildSourceTextAsync(request, config);
            var prompt = BuildPrompt(config.UrlSummaryPrompt, config.LanguageDirective(request.TargetLanguageCode), source);
            var systemPrompt = $"You are a precise summarizer. {config.LanguageDirective(request.TargetLanguageCode)} Output only the summary, with no preface or labels.";

            var summary = provider switch
            {
                "openai" => await SummarizeOpenAiAsync(apiKey, model, systemPrompt, prompt),
                "gemini" => await SummarizeGeminiAsync(apiKey, model, prompt),
                "anthropic" => await SummarizeAnthropicAsync(apiKey, model, systemPrompt, prompt),
                "xai" => await SummarizeXaiAsync(apiKey, model, systemPrompt, prompt, config.XaiReasoningEffort),
                "localai" => await SummarizeLocalAiAsync(config.LocalAiLlmUrl, model, systemPrompt, prompt),
                _ => throw new InvalidOperationException($"Unsupported summary provider '{provider}'.")
            };

            return new SummaryResponse(true, summary.Trim(), provider, model, "");
        }
        catch (Exception ex)
        {
            return new SummaryResponse(false, "", "", "", ex.Message);
        }
    }

    private static async Task<string> BuildSourceTextAsync(SummaryRequest request, LazyConfig config)
    {
        var text = FirstNonEmpty(request.Selection, request.Text);
        var title = request.Title.Trim();
        var url = request.Url.Trim();
        var description = request.Description.Trim();

        if (string.IsNullOrWhiteSpace(text) && !string.IsNullOrWhiteSpace(request.PdfBase64))
        {
            text = ExtractPdfText(Convert.FromBase64String(request.PdfBase64));
        }

        if (text.Length < 80 && config.AppFetchUrl && LooksLikeUrl(url))
        {
            try
            {
                text = await FetchUrlTextAsync(url, request.MimeType);
            }
            catch
            {
                // The extension usually sends DOM text. URL fetching is only a fallback.
            }
        }

        if (string.IsNullOrWhiteSpace(text))
        {
            text = url;
        }

        if (string.IsNullOrWhiteSpace(text))
        {
            throw new InvalidOperationException("No webpage content was provided.");
        }

        text = CollapseWhitespace(text);
        if (text.Length > 120000)
        {
            text = text[..120000];
        }

        var builder = new StringBuilder();
        if (!string.IsNullOrWhiteSpace(title)) builder.AppendLine($"Title: {title}");
        if (!string.IsNullOrWhiteSpace(url)) builder.AppendLine($"URL: {url}");
        if (!string.IsNullOrWhiteSpace(description)) builder.AppendLine($"Description: {description}");
        builder.AppendLine();
        builder.AppendLine("Content:");
        builder.AppendLine(text);
        return builder.ToString();
    }

    private static async Task<string> FetchUrlTextAsync(string url, string? mimeType)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var fileUri) && fileUri.Scheme == Uri.UriSchemeFile)
        {
            var path = fileUri.LocalPath;
            if (!File.Exists(path))
            {
                throw new FileNotFoundException("The local PDF file was not found.", path);
            }

            var bytes = await File.ReadAllBytesAsync(path);
            if ((mimeType ?? "").Contains("pdf", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase))
            {
                return ExtractPdfText(bytes);
            }

            return CollapseWhitespace(Encoding.UTF8.GetString(bytes));
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36");
        using var response = await Http.SendAsync(request);
        var mediaType = response.Content.Headers.ContentType?.MediaType ?? mimeType ?? "";
        if (mediaType.Contains("pdf", StringComparison.OrdinalIgnoreCase) || url.Contains(".pdf", StringComparison.OrdinalIgnoreCase))
        {
            var bytes = await response.Content.ReadAsByteArrayAsync();
            EnsureSuccess(response, $"PDF bytes: {bytes.Length}");
            return ExtractPdfText(bytes);
        }

        var body = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, body);
        var withoutScripts = Regex.Replace(body, "<(script|style|noscript|svg)[\\s\\S]*?</\\1>", " ", RegexOptions.IgnoreCase);
        var withoutTags = Regex.Replace(withoutScripts, "<[^>]+>", " ");
        return CollapseWhitespace(WebUtility.HtmlDecode(withoutTags));
    }

    private static string ExtractPdfText(byte[] bytes)
    {
        if (bytes.Length == 0)
        {
            throw new InvalidOperationException("The PDF is empty.");
        }

        using var stream = new MemoryStream(bytes);
        using var document = PdfDocument.Open(stream);
        var builder = new StringBuilder();
        foreach (var page in document.GetPages())
        {
            var text = page.Text;
            if (!string.IsNullOrWhiteSpace(text))
            {
                builder.AppendLine(text);
                builder.AppendLine();
            }
        }

        var result = CollapseWhitespace(builder.ToString());
        if (string.IsNullOrWhiteSpace(result))
        {
            throw new InvalidOperationException("No extractable text was found in the PDF.");
        }

        return result;
    }

    private static string BuildPrompt(string configPrompt, string languageDirective, string text)
    {
        var basePrompt = string.IsNullOrWhiteSpace(configPrompt) ? DefaultUrlSummaryPrompt : configPrompt.Trim();
        return $"{basePrompt}\n\n{languageDirective}\n\nText:\n{text}";
    }

    private static async Task<string> SummarizeOpenAiAsync(string apiKey, string model, string systemPrompt, string prompt)
    {
        var payload = new
        {
            model,
            messages = new object[]
            {
                new { role = "system", content = systemPrompt },
                new { role = "user", content = prompt }
            }
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/chat/completions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        request.Content = JsonContent(payload);
        using var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, body);
        using var json = JsonDocument.Parse(body);
        return json.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString() ?? "";
    }

    private static async Task<string> SummarizeGeminiAsync(string apiKey, string model, string prompt)
    {
        var payload = new
        {
            contents = new[]
            {
                new
                {
                    role = "user",
                    parts = new[] { new { text = prompt } }
                }
            }
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, $"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent");
        request.Headers.Add("x-goog-api-key", apiKey);
        request.Content = JsonContent(payload);
        using var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, body);
        using var json = JsonDocument.Parse(body);
        var parts = json.RootElement.GetProperty("candidates")[0].GetProperty("content").GetProperty("parts");
        return string.Join("", parts.EnumerateArray().Select(part => part.TryGetProperty("text", out var text) ? text.GetString() : ""));
    }

    private static async Task<string> SummarizeAnthropicAsync(string apiKey, string model, string systemPrompt, string prompt)
    {
        var payload = new
        {
            model,
            max_tokens = 1200,
            system = systemPrompt,
            messages = new[]
            {
                new { role = "user", content = prompt }
            }
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages");
        request.Headers.Add("x-api-key", apiKey);
        request.Headers.Add("anthropic-version", "2023-06-01");
        request.Content = JsonContent(payload);
        using var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, body);
        using var json = JsonDocument.Parse(body);
        var content = json.RootElement.GetProperty("content");
        return string.Join("", content.EnumerateArray().Select(part => part.TryGetProperty("text", out var text) ? text.GetString() : ""));
    }

    private static async Task<string> SummarizeXaiAsync(string apiKey, string model, string systemPrompt, string prompt, string reasoningEffort)
    {
        var payload = new Dictionary<string, object>
        {
            ["model"] = model,
            ["messages"] = new object[]
            {
                new { role = "system", content = systemPrompt },
                new { role = "user", content = prompt }
            }
        };
        if (!string.IsNullOrWhiteSpace(reasoningEffort))
        {
            payload["reasoning_effort"] = reasoningEffort;
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.x.ai/v1/chat/completions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        request.Content = JsonContent(payload);
        using var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, body);
        using var json = JsonDocument.Parse(body);
        return json.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString() ?? "";
    }

    private static async Task<string> SummarizeLocalAiAsync(string endpoint, string model, string systemPrompt, string prompt)
    {
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            throw new InvalidOperationException("Local AI LLM URL is not configured.");
        }
        var payload = new
        {
            model,
            stream = false,
            messages = new object[]
            {
                new { role = "system", content = systemPrompt },
                new { role = "user", content = prompt }
            }
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Content = JsonContent(payload);
        using var response = await Http.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        EnsureSuccess(response, body);
        using var json = JsonDocument.Parse(body);
        return json.RootElement.GetProperty("message").GetProperty("content").GetString() ?? "";
    }

    private static StringContent JsonContent(object payload)
    {
        return new StringContent(JsonSerializer.Serialize(payload, JsonOptions), Encoding.UTF8, "application/json");
    }

    private static void EnsureSuccess(HttpResponseMessage response, string body)
    {
        if (response.IsSuccessStatusCode) return;
        var detail = body.Length > 1200 ? body[..1200] : body;
        throw new InvalidOperationException($"API error {(int)response.StatusCode} {response.ReasonPhrase}: {detail}");
    }

    private static string FirstNonEmpty(params string[] values)
    {
        return values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim() ?? "";
    }

    private static bool LooksLikeUrl(string value)
    {
        return Uri.TryCreate(value, UriKind.Absolute, out var uri)
            && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeFile);
    }

    private static string CollapseWhitespace(string value)
    {
        return Regex.Replace(value, "\\s+", " ").Trim();
    }

    private static string ReadString(JsonElement root, string name)
    {
        return root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? ""
            : "";
    }

    private const string DefaultUrlSummaryPrompt =
        "Summarize the provided webpage content.\n\n" +
        "Rules:\n" +
        "- Use ONLY information present in the content.\n" +
        "- Never guess or invent missing details.\n" +
        "- Replace vague or clickbait headlines with the specific subject described in the text.\n" +
        "- Prefer concrete facts (names, numbers, results, ingredients, products).\n" +
        "- Remove filler and marketing language.\n" +
        "- Adapt to the content type automatically.\n\n" +
        "Structure:\n" +
        "- If the content contains multiple distinct aspects (e.g. results, ingredients, steps, features, findings), you MAY organize the summary into 2-4 short sections.\n" +
        "- Each section may have a short \"##\" heading and one fitting emoji.\n" +
        "- Keep section titles very short (1-3 words).\n" +
        "- Each section should contain one concise sentence.\n" +
        "- If the content is simple, write a short paragraph instead (1-3 sentences).\n\n" +
        "If the content is missing or insufficient, state the reason or describe why a summary cannot be created.";
}

sealed class LazyConfig
{
    public const string DefaultLocalAiLlmUrl = "http://192.168.178.20:11434/api/chat";
    public static readonly string[] SummaryProviders = ["openai", "gemini", "anthropic", "xai", "localai"];

    public required string ConfigPath { get; init; }
    public string Provider { get; init; } = "openai";
    public string Language { get; init; } = "auto";
    public string SummaryProvider { get; init; } = "openai";
    public string UrlSummaryPrompt { get; init; } = "";
    public bool AppFetchUrl { get; init; } = true;
    public string XaiReasoningEffort { get; init; } = "none";
    public string LocalAiLlmUrl { get; init; } = DefaultLocalAiLlmUrl;
    public Dictionary<string, string> ApiKeys { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, string> SummaryModels { get; init; } = new(StringComparer.OrdinalIgnoreCase);

    public static LazyConfig Load()
    {
        var configPath = FindConfigPath();
        using var json = JsonDocument.Parse(File.ReadAllText(configPath));
        var root = json.RootElement;
        var provider = ReadString(root, "provider", "openai");
        var apiKeys = ReadStringMap(root, "apiKeys");
        var legacyKey = ReadString(root, "apiKey", "");
        if (!string.IsNullOrWhiteSpace(legacyKey) && !apiKeys.ContainsKey(provider))
        {
            apiKeys[provider] = legacyKey;
        }

        var configDirectory = Path.GetDirectoryName(configPath) ?? AppContext.BaseDirectory;
        MergeDotEnvKeys(configDirectory, apiKeys);
        var parentDirectory = Directory.GetParent(configDirectory)?.FullName;
        if (!string.IsNullOrWhiteSpace(parentDirectory))
        {
            MergeDotEnvKeys(parentDirectory, apiKeys);
        }

        return new LazyConfig
        {
            ConfigPath = configPath,
            Provider = provider,
            Language = ReadString(root, "language", "auto"),
            SummaryProvider = ReadString(root, "summaryProvider", provider.Equals("elevenlabs", StringComparison.OrdinalIgnoreCase) ? "openai" : provider),
            SummaryModels = ReadStringMap(root, "summaryModels"),
            UrlSummaryPrompt = FirstNonEmpty(ReadString(root, "urlSummaryPrompt", ""), DefaultUrlSummaryPrompt),
            AppFetchUrl = ReadBool(root, "appFetchUrl", true),
            XaiReasoningEffort = ReadString(root, "xaiReasoningEffort", "none"),
            LocalAiLlmUrl = ReadString(root, "localAiLlmUrl", DefaultLocalAiLlmUrl),
            ApiKeys = apiKeys
        };
    }

    public string ResolveSummaryProvider(string? requestedProvider)
    {
        foreach (var candidate in new[] { requestedProvider, SummaryProvider, Provider })
        {
            var normalized = (candidate ?? "").Trim().ToLowerInvariant();
            if (SummaryProviders.Contains(normalized, StringComparer.OrdinalIgnoreCase))
            {
                return normalized;
            }
        }

        var firstWithKey = SummaryProviders.FirstOrDefault(HasApiKey);
        return firstWithKey ?? "openai";
    }

    public string SummaryModelFor(string provider)
    {
        if (SummaryModels.TryGetValue(provider, out var model) && !string.IsNullOrWhiteSpace(model))
        {
            return model;
        }

        return provider switch
        {
            "gemini" => "gemini-3.5-flash",
            "anthropic" => "claude-sonnet-4-6",
            "xai" => "grok-4.3",
            "localai" => "qwen2.5:3b",
            _ => "gpt-5.4-mini"
        };
    }

    public bool HasApiKey(string provider)
    {
        return ApiKeys.TryGetValue(provider, out var value) && !string.IsNullOrWhiteSpace(value)
            || EnvNamesFor(provider).Any(name => !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(name)));
    }

    public string ResolveApiKey(string provider)
    {
        if (ApiKeys.TryGetValue(provider, out var apiKey) && !string.IsNullOrWhiteSpace(apiKey))
        {
            return apiKey;
        }

        foreach (var name in EnvNamesFor(provider))
        {
            var value = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User)
                ?? Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Process)
                ?? Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Machine);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        throw new InvalidOperationException($"API key for summary provider '{provider}' is missing.");
    }

    public string OptionalApiKey(string provider, string configured = "")
    {
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return configured;
        }

        if (ApiKeys.TryGetValue(provider, out var apiKey) && !string.IsNullOrWhiteSpace(apiKey))
        {
            return apiKey;
        }

        foreach (var name in EnvNamesFor(provider))
        {
            var value = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User)
                ?? Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Process)
                ?? Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Machine);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        return "";
    }

    public string LanguageDirective(string? requestedCode)
    {
        var code = string.IsNullOrWhiteSpace(requestedCode) ? Language : requestedCode.Trim();
        if (!string.IsNullOrWhiteSpace(code) && code != "auto")
        {
            return $"Language rule: Output MUST be in {LanguageName(code)} (\"{code}\"). Do not use any other language.";
        }

        return "Language rule: Detect the input language and write the summary strictly in that same language. If the input is German, output German; if Spanish, output Spanish. Never switch languages.";
    }

    private static string FindConfigPath()
    {
        var fromEnv = Environment.GetEnvironmentVariable("ECHOSCRIBE_CONFIG");
        if (!string.IsNullOrWhiteSpace(fromEnv) && File.Exists(fromEnv))
        {
            return fromEnv;
        }

        foreach (var start in new[] { AppContext.BaseDirectory, Environment.CurrentDirectory })
        {
            var current = new DirectoryInfo(start);
            while (current is not null)
            {
                var candidate = Path.Combine(current.FullName, "appsettings.json");
                if (File.Exists(candidate))
                {
                    return candidate;
                }

                current = current.Parent;
            }
        }

        throw new FileNotFoundException("appsettings.json was not found for EchoScribe Native Host.");
    }

    private static void MergeDotEnvKeys(string root, Dictionary<string, string> apiKeys)
    {
        foreach (var path in Directory.EnumerateFiles(root, "*.env"))
        {
            foreach (var line in File.ReadAllLines(path))
            {
                var trimmed = line.Trim();
                if (trimmed.Length == 0 || trimmed.StartsWith('#') || !trimmed.Contains('=')) continue;
                var index = trimmed.IndexOf('=');
                var name = trimmed[..index].Trim();
                var value = trimmed[(index + 1)..].Trim().Trim('"', '\'');
                if (string.IsNullOrWhiteSpace(value)) continue;
                switch (name)
                {
                    case "OPENAI_API_KEY":
                        apiKeys["openai"] = value;
                        break;
                    case "GEMINI_API_KEY":
                    case "GOOGLE_API_KEY":
                        apiKeys["gemini"] = value;
                        break;
                    case "ANTHROPIC_API_KEY":
                    case "CLAUDE_API_KEY":
                        apiKeys["anthropic"] = value;
                        break;
                    case "XAI_API_KEY":
                        apiKeys["xai"] = value;
                        break;
                    case "ELEVENLABS_API_KEY":
                        apiKeys["elevenlabs"] = value;
                        break;
                }
            }
        }
    }

    private static string[] EnvNamesFor(string provider)
    {
        return provider.ToLowerInvariant() switch
        {
            "openai" => ["OPENAI_API_KEY"],
            "gemini" => ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
            "anthropic" => ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"],
            "xai" => ["XAI_API_KEY"],
            _ => []
        };
    }

    private static string LanguageName(string code)
    {
        return code switch
        {
            "de" => "German",
            "en" => "English",
            "es" => "Spanish",
            "fr" => "French",
            "pt" => "Portuguese",
            "it" => "Italian",
            "nl" => "Dutch",
            "tr" => "Turkish",
            "ja" => "Japanese",
            "ko" => "Korean",
            "zh" => "Chinese (Simplified)",
            _ => code
        };
    }

    private static string ReadString(JsonElement root, string name, string fallback)
    {
        return root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? fallback
            : fallback;
    }

    private static Dictionary<string, string> ReadStringMap(JsonElement root, string name)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!root.TryGetProperty(name, out var map) || map.ValueKind != JsonValueKind.Object)
        {
            return result;
        }

        foreach (var property in map.EnumerateObject())
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
}

sealed class SummaryRequest
{
    public string Type { get; init; } = "";
    public string Url { get; init; } = "";
    public string Title { get; init; } = "";
    public string Description { get; init; } = "";
    public string Selection { get; init; } = "";
    public string Text { get; init; } = "";
    public string PdfBase64 { get; init; } = "";
    public string MimeType { get; init; } = "";
    public string? Provider { get; init; }
    public string? TargetLanguageCode { get; init; }
}

sealed record SummaryResponse(bool Ok, string Summary, string Provider, string Model, string Error);

static class NativeMessaging
{
    public static async Task<JsonElement> ReadAsync(Stream input)
    {
        var lengthBytes = await ReadExactAsync(input, 4);
        if (lengthBytes.Length != 4)
        {
            throw new EndOfStreamException("Native message length prefix is missing.");
        }

        var length = BitConverter.ToInt32(lengthBytes, 0);
        if (length <= 0 || length > 64 * 1024 * 1024)
        {
            throw new InvalidOperationException($"Invalid native message length: {length}.");
        }

        var payload = await ReadExactAsync(input, length);
        using var document = JsonDocument.Parse(payload);
        return document.RootElement.Clone();
    }

    public static async Task WriteAsync(Stream output, object value)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(value, NativeHostApp.JsonOptions);
        if (payload.Length > 1024 * 1024)
        {
            throw new InvalidOperationException("Native message response exceeds Chrome's 1 MB limit.");
        }

        await output.WriteAsync(BitConverter.GetBytes(payload.Length));
        await output.WriteAsync(payload);
        await output.FlushAsync();
    }

    private static async Task<byte[]> ReadExactAsync(Stream input, int length)
    {
        var buffer = new byte[length];
        var offset = 0;
        while (offset < length)
        {
            var read = await input.ReadAsync(buffer.AsMemory(offset, length - offset));
            if (read == 0) break;
            offset += read;
        }

        if (offset == length) return buffer;
        Array.Resize(ref buffer, offset);
        return buffer;
    }
}
