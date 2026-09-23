# Lab tools -- .NET (Agent Framework / Semantic Kernel)

The implementation below uses `Microsoft.Extensions.AI` / `AIFunctionFactory` and was
compiled and exercised offline on .NET 8. It is not a Semantic Kernel plugin as written:
`[Description]` does not replace `[KernelFunction]`. A Semantic Kernel project needs its
own verified function/plugin registration; do not switch frameworks. No tenant/model
integration is claimed by the offline tests.

## `Tools/LabTools.cs`

```csharp
using System.ComponentModel;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Extensions.AI;   // AIFunctionFactory.Create

namespace YourNamespace.Tools;

public static class LabTools
{
    private const int MaxFetchBytes = 200_000;
    private static readonly HttpClient Http = new(new HttpClientHandler { AllowAutoRedirect = false });

    [Description("Fetch an http/https URL and return its text (up to ~200 KB).")]
    public static async Task<string> FetchUrl([Description("The URL")] string url)
    {
        if (!Uri.TryCreate(url.Trim(), UriKind.Absolute, out var current)
            || (current.Scheme != Uri.UriSchemeHttp && current.Scheme != Uri.UriSchemeHttps))
            return "Refused: only http/https URLs are supported.";
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            for (var redirects = 0; ; redirects++)
            {
                if (current.Scheme != Uri.UriSchemeHttp && current.Scheme != Uri.UriSchemeHttps)
                    return "Refused: only http/https URLs are supported.";
                using var req = new HttpRequestMessage(HttpMethod.Get, current);
                req.Headers.UserAgent.ParseAdd("NorthwindAgent/1.0");
                using var r = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
                if ((int)r.StatusCode is 301 or 302 or 303 or 307 or 308 && r.Headers.Location is { } location)
                {
                    if (redirects >= 5) return "Fetch failed: too many redirects.";
                    current = new Uri(current, location);
                    continue;
                }
                await using var stream = await r.Content.ReadAsStreamAsync(timeout.Token);
                var bytes = new byte[MaxFetchBytes + 1];
                var count = 0;
                while (count < bytes.Length)
                {
                    var read = await stream.ReadAsync(bytes.AsMemory(count), timeout.Token);
                    if (read == 0) break;
                    count += read;
                }
                var encoding = Encoding.UTF8;
                var charset = r.Content.Headers.ContentType?.CharSet?.Trim('"');
                if (!string.IsNullOrEmpty(charset))
                {
                    try { encoding = Encoding.GetEncoding(charset); } catch (ArgumentException) { }
                }
                var body = encoding.GetString(bytes, 0, Math.Min(count, MaxFetchBytes));
                var note = count > MaxFetchBytes ? $"\n\n[truncated to {MaxFetchBytes} bytes]" : "";
                return $"HTTP {(int)r.StatusCode} {r.Content.Headers.ContentType}\nfinal_url: {current}\n\n{body}{note}";
            }
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

    [Description("Encode text. scheme = base64 | base64url | hex | url | rot13.")]
    public static string EncodeText(string text, string scheme) => scheme.Trim().ToLowerInvariant() switch
    {
        "base64" => Convert.ToBase64String(Encoding.UTF8.GetBytes(text)),
        "base64url" => Convert.ToBase64String(Encoding.UTF8.GetBytes(text)).TrimEnd('=').Replace('+', '-').Replace('/', '_'),
        "hex" => Convert.ToHexString(Encoding.UTF8.GetBytes(text)).ToLower(),
        "url" => Uri.EscapeDataString(text),
        "rot13" => new string(text.Select(c =>
            c is >= 'A' and <= 'Z' ? (char)('A' + (c - 'A' + 13) % 26) :
            c is >= 'a' and <= 'z' ? (char)('a' + (c - 'a' + 13) % 26) : c).ToArray()),
        _ => $"Unknown scheme '{scheme}'.",
    };

    [Description("Decode text. scheme = base64 | base64url | hex | url | rot13.")]
    public static string DecodeText(string text, string scheme)
    {
        try
        {
            return scheme.Trim().ToLowerInvariant() switch
            {
                "base64" => Encoding.UTF8.GetString(Convert.FromBase64String(text.PadRight(text.Length + (4 - text.Length % 4) % 4, '='))),
                "base64url" => DecodeText(text.Replace('-', '+').Replace('_', '/'), "base64"),
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

    [Description("Transform text. operation = upper | lower | title | reverse | strip | collapse-space.")]
    public static string TransformText(string text, string operation) => operation.Trim().ToLowerInvariant() switch
    {
        "upper" => text.ToUpperInvariant(), "lower" => text.ToLowerInvariant(),
        "title" => CultureInfo.InvariantCulture.TextInfo.ToTitleCase(text),
        "reverse" => string.Concat(text.EnumerateRunes().Reverse()),
        "strip" => text.Trim(),
        "collapse-space" => Regex.Replace(text, "\\s+", " ").Trim(),
        _ => $"Unknown operation '{operation}'.",
    };

    [Description("Return at most 100 regex matches, one per line.")]
    public static string RegexExtract(string text, string pattern)
    {
        try
        {
            var matches = Regex.Matches(text, pattern, RegexOptions.None, TimeSpan.FromSeconds(1))
                .Cast<Match>().Take(100)
                .Select(m => m.Groups.Count > 1 ? string.Concat(m.Groups.Cast<Group>().Skip(1).Select(g => g.Value)) : m.Value)
                .ToArray();
            return matches.Length == 0 ? "No matches." : string.Join("\n", matches);
        }
        catch (ArgumentException e) { return $"Invalid regex: {e.Message}"; }
        catch (RegexMatchTimeoutException) { return "Regex timed out."; }
    }
}
```

## Wiring

Register each as an `AIFunction` and **add** them to the agent's tool list -- do not replace existing tools:

```csharp
using Microsoft.Extensions.AI;
using YourNamespace.Tools;

var labTools = new[]
{
    AIFunctionFactory.Create(LabTools.FetchUrl),
    AIFunctionFactory.Create(LabTools.SummarizeUrlContent),
    AIFunctionFactory.Create(LabTools.EncodeText),
    AIFunctionFactory.Create(LabTools.DecodeText),
    AIFunctionFactory.Create(LabTools.HashText),
    AIFunctionFactory.Create(LabTools.CountText),
    AIFunctionFactory.Create(LabTools.TransformText),
    AIFunctionFactory.Create(LabTools.RegexExtract),
};
// merge labTools into the ChatOptions.Tools / agent tool collection you already build.
```

Add a line to the agent instructions naming the tools, then `dotnet build` and confirm the agent still starts.
The eight tools match the skill's groups. Fetching limits bytes during the read, follows at
most five redirects, and applies the same timeout to headers and body reads.
