internal sealed record ModelProviderSettings(string Provider, string Model, string ApiKey, Uri Endpoint)
{
    public static ModelProviderSettings FromEnvironment()
    {
        var provider = (Environment.GetEnvironmentVariable("MODEL_PROVIDER") ?? "mistral").Trim().ToLowerInvariant();
        var (keyName, modelName, defaultModel, endpoint) = provider switch
        {
            "mistral" => ("MISTRAL_API_KEY", "MISTRAL_MODEL", "ministral-3b-2512", "https://api.mistral.ai/v1/"),
            "openai" => ("OPENAI_API_KEY", "OPENAI_MODEL", "gpt-4.1-mini", "https://api.openai.com/v1/"),
            "gemini" => ("GEMINI_API_KEY", "GEMINI_MODEL", "gemini-2.5-flash-lite", "https://generativelanguage.googleapis.com/v1beta/openai/"),
            _ => throw new ArgumentException("MODEL_PROVIDER must be mistral, openai or gemini.")
        };
        var key = Environment.GetEnvironmentVariable(keyName)?.Trim();
        if (string.IsNullOrWhiteSpace(key)) throw new InvalidOperationException($"Set {keyName} for the selected provider; credentials from other providers are never reused.");
        var configuredModel = Environment.GetEnvironmentVariable(modelName)?.Trim();
        return new(provider, string.IsNullOrWhiteSpace(configuredModel) ? defaultModel : configuredModel, key, new Uri(endpoint));
    }
}
