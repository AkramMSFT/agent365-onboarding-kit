internal sealed class DlpConversation
{
    public string CorrelationId { get; } = Guid.NewGuid().ToString();
    private long nextSequence;
    public long ReservePair() => Interlocked.Add(ref nextSequence, 2) - 2;
}

internal sealed record DlpTurnResult(string Text, bool Blocked, bool ModelInvoked, bool Unchecked);

internal static class DlpTurnGuard
{
    public static async Task<DlpTurnResult> RunAsync(PurviewDlp dlp, DlpConversation conversation, string prompt,
        Func<CancellationToken, Task<string>> model, CancellationToken cancellationToken = default)
    {
        var sequence = conversation.ReservePair();
        var upload = await dlp.EvaluateAsync("uploadText", prompt, conversation.CorrelationId, sequence, cancellationToken);
        if (upload.Blocked)
            return new(upload.PolicyBlocked ? "This request was blocked by your organisation's data policy."
                : "This request could not be checked by Purview and was blocked in fail-closed mode.", true, false, !upload.Checked);
        var reply = await model(cancellationToken);
        var download = await dlp.EvaluateAsync("downloadText", reply, conversation.CorrelationId, sequence + 1, cancellationToken);
        if (download.Blocked)
            return new(download.PolicyBlocked ? "The response was withheld by your organisation's data policy."
                : "The response could not be checked by Purview and was withheld in fail-closed mode.", true, true, !download.Checked);
        return new(reply, false, true, dlp.Enabled && (!upload.Checked || !download.Checked));
    }
}
