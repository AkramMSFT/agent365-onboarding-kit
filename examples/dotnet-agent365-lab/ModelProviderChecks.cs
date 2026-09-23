internal static class ModelProviderChecks
{
    public static void Run()
    {
        var names = new[] { "MODEL_PROVIDER", "MISTRAL_API_KEY", "MISTRAL_MODEL", "OPENAI_API_KEY", "OPENAI_MODEL", "GEMINI_API_KEY", "GEMINI_MODEL" };
        var original = names.ToDictionary(name => name, Environment.GetEnvironmentVariable);
        try
        {
            foreach (var name in names) Environment.SetEnvironmentVariable(name, null);
            foreach (var (provider, prefix, host) in new[]
            {
                ("mistral", "MISTRAL", "api.mistral.ai"),
                ("openai", "OPENAI", "api.openai.com"),
                ("gemini", "GEMINI", "generativelanguage.googleapis.com")
            })
            {
                Environment.SetEnvironmentVariable("MODEL_PROVIDER", provider);
                Environment.SetEnvironmentVariable(prefix + "_API_KEY", "offline-" + provider);
                Environment.SetEnvironmentVariable(prefix + "_MODEL", "  offline-model  ");
                var settings = ModelProviderSettings.FromEnvironment();
                if (settings.Endpoint.Host != host || settings.ApiKey != "offline-" + provider || settings.Model != "offline-model")
                    throw new InvalidOperationException("Provider/key/endpoint selection is inconsistent.");
            }
            Environment.SetEnvironmentVariable("MODEL_PROVIDER", "openai");
            Environment.SetEnvironmentVariable("OPENAI_API_KEY", null);
            try { ModelProviderSettings.FromEnvironment(); throw new Exception("Provider credentials leaked across providers."); }
            catch (InvalidOperationException) { }
        }
        finally { foreach (var entry in original) Environment.SetEnvironmentVariable(entry.Key, entry.Value); }
        Console.WriteLine("Provider/key/endpoint isolation verified offline.");
    }
}
