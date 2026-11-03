using System;
using System.Buffers.Binary;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace GraphCode.Validation.Ownership;

public static class PipeFrames
{
    public const int MaximumPayloadBytes = 2 * 1024 * 1024;
    private static readonly UTF8Encoding utf8 = new(false, true);

    public static async Task<JsonDocument?> ReadAsync(Stream stream, Deadline deadline,
        CancellationToken cancellationToken = default)
    {
        var header = new byte[4];
        if (!await ReadExactAsync(stream, header, deadline, true, cancellationToken).ConfigureAwait(false))
            return null;
        uint length = BinaryPrimitives.ReadUInt32BigEndian(header);
        if (length is 0 or > MaximumPayloadBytes) throw new InvalidDataException("Owned pipe invalid frame length.");
        var body = new byte[(int)length];
        await ReadExactAsync(stream, body, deadline, false, cancellationToken).ConfigureAwait(false);
        return MultiProjectJson.Parse(utf8.GetString(body));
    }

    public static async Task WriteAsync(Stream stream, string json, Deadline deadline,
        int fragmentBytes = 0, CancellationToken cancellationToken = default)
    {
        byte[] body = utf8.GetBytes(json);
        if (body.Length is 0 or > MaximumPayloadBytes) throw new InvalidDataException("Owned pipe invalid frame length.");
        var header = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)body.Length);
        await BoundedWriteAsync(stream, header, deadline, cancellationToken).ConfigureAwait(false);
        int chunkSize = fragmentBytes <= 0 ? body.Length : fragmentBytes;
        for (int offset = 0; offset < body.Length; offset += Math.Min(chunkSize, body.Length - offset))
            await BoundedWriteAsync(stream, body.AsMemory(offset, Math.Min(chunkSize, body.Length - offset)),
                deadline, cancellationToken).ConfigureAwait(false);
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        limit.CancelAfter(deadline.Remaining);
        await stream.FlushAsync(limit.Token).ConfigureAwait(false);
    }

    private static async Task<bool> ReadExactAsync(Stream stream, Memory<byte> buffer, Deadline deadline,
        bool cleanEofAllowed, CancellationToken cancellationToken)
    {
        int offset = 0;
        while (offset != buffer.Length)
        {
            if (deadline.Expired) throw new TimeoutException("Owned pipe original read deadline exceeded.");
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            limit.CancelAfter(deadline.Remaining);
            int count = await stream.ReadAsync(buffer[offset..], limit.Token).ConfigureAwait(false);
            if (count == 0)
            {
                if (offset == 0 && cleanEofAllowed) return false;
                throw new EndOfStreamException("Owned pipe ended within a frame.");
            }
            offset += count;
        }
        return true;
    }

    private static async Task BoundedWriteAsync(Stream stream, ReadOnlyMemory<byte> bytes,
        Deadline deadline, CancellationToken cancellationToken)
    {
        if (deadline.Expired) throw new TimeoutException("Owned pipe original write deadline exceeded.");
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        limit.CancelAfter(deadline.Remaining);
        await stream.WriteAsync(bytes, limit.Token).ConfigureAwait(false);
    }
}
