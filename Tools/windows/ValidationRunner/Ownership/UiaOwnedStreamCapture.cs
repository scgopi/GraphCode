using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace GraphCode.Validation.Ownership;

public static class UiaOwnedStreamCapture
{
    public static void RequireJobMember(IntPtr process, IntPtr job)
    {
        if (!StandaloneProcessJob.Contains(job, process))
            throw new InvalidOperationException("Published UIA target is not a member of its owned launch job.");
    }

    public static Task<string> Read(StreamReader reader, string path) => Read(reader, path, null);

    public static Task<string> Read(StreamReader reader, string path, IOwnedStreamObserver? observer)
    {
        ArgumentNullException.ThrowIfNull(reader);
        var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.ReadWrite);
        return Capture(reader, file, observer);
    }

    private static async Task<string> Capture(StreamReader reader, FileStream file, IOwnedStreamObserver? observer)
    {
        // AutoFlush preserves encoder state across a split surrogate; FlushAsync does not.
        using var writer = new StreamWriter(file, new UTF8Encoding(false, true)) { AutoFlush = true };
        var text = new StringBuilder();
        var buffer = new char[4096];
        int count;
        while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0)
        {
            text.Append(buffer, 0, count);
            await writer.WriteAsync(buffer, 0, count).ConfigureAwait(false);
            observer?.OnText(new string(buffer, 0, count));
        }
        observer?.OnEof();
        return text.ToString();
    }
}
