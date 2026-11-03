using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace GraphCode.Validation.TestFixtures;

public sealed class ControlledOutputReader(string prefix) : TextReader
{
    private int position;
    public string Tail = "";
    public TaskCompletionSource<int> End = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public override Task<int> ReadAsync(char[] buffer, int offset, int count)
    {
        if (position < prefix.Length)
        {
            var length = Math.Min(count, prefix.Length - position);
            prefix.CopyTo(position, buffer, offset, length);
            position += length;
            return Task.FromResult(length);
        }
        return ReadNext(buffer, offset);
    }

    private async Task<int> ReadNext(char[] buffer, int offset)
    {
        var length = await End.Task.ConfigureAwait(false);
        if (length > 0)
        {
            Tail.CopyTo(0, buffer, offset, length);
            End = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        }
        return length;
    }
}

public sealed class FailingForwardWriter : TextWriter
{
    public bool FailFlush;
    public override Encoding Encoding => Encoding.UTF8;
    public override void Write(char[] buffer, int offset, int count)
    {
        if (!FailFlush) throw new IOException("forward write failed");
    }

    public override void Flush()
    {
        if (FailFlush) throw new IOException("forward flush failed");
    }
}

public sealed class FailingRetentionSentinelWriter : TextWriter
{
    public override Encoding Encoding => Encoding.UTF8;
    public override void WriteLine(string? value) => throw new IOException("controlled sentinel write failure");
}

public sealed class FailingRetentionSentinelFlush : TextWriter
{
    public override Encoding Encoding => Encoding.UTF8;
    public override void WriteLine(string? value) { }
    public override void Flush() => throw new IOException("controlled sentinel flush failure");
}
