# Lab tools -- .NET (Agent Framework / Semantic Kernel)

A port of the verified Python reference as `[KernelFunction]` / `AIFunction` tools. **Transcription, not yet run on a tenant** -- verify the function-tool attribute against your agent's SDK (`Microsoft.Agents.*` uses `AIFunctionFactory`; Semantic Kernel uses `[KernelFunction]`).

## `Tools/LabTools.cs`

```csharp
using System.ComponentModel;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.AI;   // AIFunctionFactory.Create

namespace YourNamespace.Tools;

public static class LabTools
{
    private const int MaxFetchBytes = 200_000;
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    [Description("Fetch an http/https URL and return its text (up to ~200 KB).")]
    public static async Task<string> FetchUrl([Description("The URL")] string url)
    {
        if (!url.TrimStart().StartsWith("http", StringComparison.OrdinalIgnoreCase))
            return "Refused: only http/https URLs are supported.";
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url.Trim());
            req.Headers.UserAgent.ParseAdd("NorthwindAgent/1.0");
            using var r = await Http.SendAsync(req);
            var body = await r.Content.ReadAsStringAsync();
            if (body.Length > MaxFetchBytes) body = body[..MaxFetchBytes];
            return $"HTTP {(int)r.StatusCode} {r.Content.Headers.ContentType}\n\n{body}";
        }
        catch (Exception e) { return $"Fetch failed: {e.GetType().Name}: {e.Message}"; }
    }

    [Description("Fetch a URL and return its text with HTML stripped, ready to summarise.")]
    public static async Task<string> SummarizeUrlContent([Description("The URL")] string url)
    {
        var raw = await FetchUrl(url);
        if (raw.StartsWith("Refused") || raw.StartsWith("Fetch failed")) return raw;
        var body = raw.Contains("\n\n") ? raw[(raw.IndexOf("\n\n") + 2)..] : raw;
        body = System.Text.RegularExpressions.Regex.Replace(body, "(?is)<(script|style|head).*?</\\1>", " ");
        var text = System.Text.RegularExpressions.Regex.Replace(body, "(?s)<[^>]+>", " ");
        text = System.Text.RegularExpressions.Regex.Replace(text, "\\s+", " ").Trim();
        return text.Length > MaxFetchBytes ? text[..MaxFetchBytes] : (text.Length == 0 ? "No readable text." : text);
    }

    [Description("Encode text. scheme = base64 | hex | url | rot13.")]
    public static string EncodeText(string text, string scheme) => scheme.Trim().ToLower() switch
    {
        "base64" => Convert.ToBase64String(Encoding.UTF8.GetBytes(text)),
        "hex" => Convert.ToHexString(Encoding.UTF8.GetBytes(text)).ToLower(),
        "url" => Uri.EscapeDataString(text),
        "rot13" => new string(text.Select(c => char.IsLetter(c)
            ? (char)((char.ToLower(c) <= 'm' ? c + 13 : c - 13)) : c).ToArray()),
        _ => $"Unknown scheme '{scheme}'.",
    };

    [Description("Decode text. scheme = base64 | hex | url | rot13.")]
    public static string DecodeText(string text, string scheme)
    {
        try
        {
            return scheme.Trim().ToLower() switch
            {
                "base64" => Encoding.UTF8.GetString(Convert.FromBase64String(text.PadRight(text.Length + (4 - text.Length % 4) % 4, '='))),
                "hex" => Encoding.UTF8.GetString(Convert.FromHexString(text.Trim())),
                "url" => Uri.UnescapeDataString(text),
                "rot13" => EncodeText(text, "rot13"),
                _ => $"Unknown scheme '{scheme}'.",
            };
        }
        catch (Exception e) { return $"Decode failed: {e.Message}"; }
    }

    [Description("Hash text. algo = md5 | sha1 | sha256 | sha512.")]
    public static string HashText(string text, string algo = "sha256")
    {
        var b = Encoding.UTF8.GetBytes(text);
        byte[] h = algo.Trim().ToLower() switch
        {
            "md5" => MD5.HashData(b), "sha1" => SHA1.HashData(b),
            "sha256" => SHA256.HashData(b), "sha512" => SHA512.HashData(b),
            _ => Array.Empty<byte>(),
        };
        return h.Length == 0 ? $"Unknown algorithm '{algo}'." : Convert.ToHexString(h).ToLower();
    }

    [Description("Count characters, words and lines in text.")]
    public static string CountText(string text) =>
        $"characters: {text.Length}  words: {(string.IsNullOrWhiteSpace(text) ? 0 : text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length)}  lines: {text.Split('\n').Length}";
}
```

## Wiring

Register each as an `AIFunction` and **add** them to the agent's tool list -- do not replace existing tools:

```csharp
using Microsoft.Extensions.AI;

var labTools = new[]
{
    AIFunctionFactory.Create(LabTools.FetchUrl),
    AIFunctionFactory.Create(LabTools.SummarizeUrlContent),
    AIFunctionFactory.Create(LabTools.EncodeText),
    AIFunctionFactory.Create(LabTools.DecodeText),
    AIFunctionFactory.Create(LabTools.HashText),
    AIFunctionFactory.Create(LabTools.CountText),
};
// merge labTools into the ChatOptions.Tools / agent tool collection you already build.
```

Add a line to the agent instructions naming the tools, then `dotnet build` and confirm the agent still starts.
