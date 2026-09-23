internal sealed class TelemetryReceiptHandler(ExporterStatus status) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.RequestUri is not { Scheme: "https", Host: "agent365.svc.cloud.microsoft", IsDefaultPort: true })
            throw new InvalidOperationException("Telemetry transport attempted to leave the configured Microsoft endpoint.");
        var response = await base.SendAsync(request, cancellationToken);
        try
        {
            if (response.IsSuccessStatusCode)
                status.RecordReceipt(await response.Content.ReadAsStringAsync(cancellationToken));
            return response;
        }
        catch
        {
            response.Dispose();
            throw;
        }
    }
}
