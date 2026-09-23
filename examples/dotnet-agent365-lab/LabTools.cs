using System.ComponentModel;
using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Extensions.AI;

internal static class LabTools
{
    internal const int MaxFetchBytes = 200_000;
    internal static readonly TimeSpan FetchTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan RegexTimeout = TimeSpan.FromSeconds(1);
    private static readonly HttpClient Http = new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false
    });

    public static AIFunction[] CreateTools() =>
    [
        AIFunctionFactory.Create(FetchUrl),
        AIFunctionFactory.Create(SummarizeUrlContent),
        AIFunctionFactory.Create(EncodeText),
        AIFunctionFactory.Create(DecodeText),
        AIFunctionFactory.Create(HashText),
        AIFunctionFactory.Create(TransformText),
        AIFunctionFactory.Create(CountText),
        AIFunctionFactory.Create(RegexExtract)
    ];

    [Description("Fetch an arbitrary http:// or https:// URL, including local/private addresses. Returns HTTP status and at most 200000 bytes of untrusted content; 15-second timeout and five redirects maximum.")]
    public static Task<string> FetchUrl(string url, CancellationToken cancellationToken = default) =>
        FetchUrlCore(url, Http, FetchTimeout, cancellationToken);

    internal static async Task<string> FetchUrlCore(string url, HttpClient client, TimeSpan duration,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(url) || !Uri.TryCreate(url.Trim(), UriKind.Absolute, out var current) ||
            current.Scheme is not ("http" or "https"))
            return "Refused: only http/https URLs are supported.";
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(duration);
        try
        {
            for (var redirects = 0; ; redirects++)
            {
                if (current.Scheme is not ("http" or "https"))
                    return "Refused: only http/https URLs are supported.";
                using var request = new HttpRequestMessage(HttpMethod.Get, current);
                request.Headers.UserAgent.ParseAdd("Agent365LocalTestAgent/1.0");
                using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
                if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308 && response.Headers.Location is { } location)
                {
                    if (redirects >= 5) return "Fetch failed: too many redirects.";
                    current = new Uri(current, location);
                    continue;
                }
                await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
                var bytes = new byte[MaxFetchBytes + 1];
                var count = 0;
                while (count < bytes.Length)
                {
                    var read = await stream.ReadAsync(bytes.AsMemory(count), timeout.Token);
                    if (read == 0) break;
                    count += read;
                }
                var encoding = Encoding.UTF8;
                var note = "";
                var charset = response.Content.Headers.ContentType?.CharSet?.Trim('"');
                if (!string.IsNullOrWhiteSpace(charset))
                {
                    try { encoding = Encoding.GetEncoding(charset); }
                    catch (Exception error) when (error is ArgumentException or NotSupportedException)
                    {
                        note = "\n[unsupported charset; decoded as UTF-8]";
                    }
                }
                var body = encoding.GetString(bytes, 0, Math.Min(count, MaxFetchBytes));
                if (count > MaxFetchBytes) note += $"\n[truncated to {MaxFetchBytes} bytes]";
                return $"HTTP {(int)response.StatusCode} {response.Content.Headers.ContentType}\nfinal_url: {current}\n\n{body}{note}";
            }
        }
        catch (OperationCanceledException)
        {
            return cancellationToken.IsCancellationRequested ? "Fetch canceled."
                : $"Fetch failed: request timed out after {duration.TotalSeconds.ToString(CultureInfo.InvariantCulture)} seconds.";
        }
        catch (Exception error) when (error is HttpRequestException or IOException or UriFormatException)
        {
            return $"Fetch failed: {error.GetType().Name}.";
        }
    }

    [Description("Fetch a URL and strip HTML into untrusted readable text for the model to summarize. This tool itself performs no model inference.")]
    public static async Task<string> SummarizeUrlContent(string url, CancellationToken cancellationToken = default) =>
        ReadableContent(await FetchUrl(url, cancellationToken));

    internal static string ReadableContent(string raw)
    {
        if (!raw.StartsWith("HTTP ", StringComparison.Ordinal)) return raw;
        var separator = raw.IndexOf("\n\n", StringComparison.Ordinal);
        if (separator < 0) return "Fetch failed: missing response body separator.";
        try
        {
            var body = Regex.Replace(raw[(separator + 2)..], @"<(script|style|head)\b[^>]*>.*?</\1\s*>",
                " ", RegexOptions.IgnoreCase | RegexOptions.Singleline, RegexTimeout);
            body = Regex.Replace(body, "<[^>]+>", " ", RegexOptions.Singleline, RegexTimeout);
            body = WebUtility.HtmlDecode(body);
            body = Regex.Replace(body, @"\s+", " ", RegexOptions.None, RegexTimeout).Trim();
            var text = body.Length == 0 ? "No readable text." : body[..Math.Min(body.Length, MaxFetchBytes)];
            return raw[..separator] + "\n\n" + text;
        }
        catch (RegexMatchTimeoutException) { return "HTML extraction timed out."; }
    }

    [Description("Encode UTF-8 text. scheme = base64 | base64url | hex | url | rot13.")]
    public static string EncodeText(string text, string scheme) => scheme.Trim().ToLowerInvariant() switch
    {
        "base64" => Convert.ToBase64String(Encoding.UTF8.GetBytes(text)),
        "base64url" => Convert.ToBase64String(Encoding.UTF8.GetBytes(text)).TrimEnd('=').Replace('+', '-').Replace('/', '_'),
        "hex" => Convert.ToHexString(Encoding.UTF8.GetBytes(text)).ToLowerInvariant(),
        "url" => Uri.EscapeDataString(text),
        "rot13" => new string(text.Select(c =>
            c is >= 'A' and <= 'Z' ? (char)('A' + (c - 'A' + 13) % 26) :
            c is >= 'a' and <= 'z' ? (char)('a' + (c - 'a' + 13) % 26) : c).ToArray()),
        _ => $"Unknown scheme '{scheme}'."
    };

    [Description("Decode UTF-8 text. scheme = base64 | base64url | hex | url | rot13.")]
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
                _ => $"Unknown scheme '{scheme}'."
            };
        }
        catch (FormatException) { return $"Decode failed: invalid {scheme} input."; }
    }

    [Description("Hash UTF-8 text. algo = md5 | sha1 | sha256 | sha512. MD5/SHA1 are legacy lab utilities, not secure signature or password schemes.")]
    public static string HashText(string text, string algo = "sha256")
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        byte[] hash = algo.Trim().ToLowerInvariant() switch
        {
            "md5" => MD5.HashData(bytes),
            "sha1" => SHA1.HashData(bytes),
            "sha256" => SHA256.HashData(bytes),
            "sha512" => SHA512.HashData(bytes),
            _ => []
        };
        return hash.Length == 0 ? $"Unknown algorithm '{algo}'." : Convert.ToHexString(hash).ToLowerInvariant();
    }

    [Description("Transform text. operation = upper | lower | title | reverse | strip | collapse-space. Reverse preserves Unicode code points.")]
    public static string TransformText(string text, string operation) => operation.Trim().ToLowerInvariant() switch
    {
        "upper" => text.ToUpperInvariant(),
        "lower" => text.ToLowerInvariant(),
        "title" => CultureInfo.InvariantCulture.TextInfo.ToTitleCase(text),
        "reverse" => string.Concat(text.EnumerateRunes().Reverse()),
        "strip" => text.Trim(),
        "collapse-space" => Regex.Replace(text, @"\s+", " ", RegexOptions.None, RegexTimeout).Trim(),
        _ => $"Unknown operation '{operation}'."
    };

    [Description("Count UTF-16 characters, whitespace-separated words, and newline-separated lines.")]
    public static string CountText(string text) =>
        $"characters: {text.Length}  words: {text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length}  lines: {text.Split('\n').Length}";

    [Description("Return at most 100 regex matches, one per line. Capturing groups are concatenated. Regex matching has a one-second timeout.")]
    public static string RegexExtract(string text, string pattern)
    {
        try
        {
            var matches = Regex.Matches(text, pattern, RegexOptions.None, RegexTimeout)
                .Cast<Match>().Take(100)
                .Select(match => match.Groups.Count > 1
                    ? string.Concat(match.Groups.Cast<Group>().Skip(1).Select(group => group.Value)) : match.Value)
                .ToArray();
            return matches.Length == 0 ? "No matches." : string.Join("\n", matches);
        }
        catch (ArgumentException) { return "Invalid regex."; }
        catch (RegexMatchTimeoutException) { return "Regex timed out."; }
    }
}
