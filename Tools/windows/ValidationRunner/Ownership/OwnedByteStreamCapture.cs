using System;
using System.IO;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Threading.Tasks;

namespace GraphCode.Validation.Ownership;

public sealed class OwnedByteStreamCapture
{
    private readonly Stream input;
    private readonly FileStream evidence;
    private readonly Decoder decoder;
    private readonly RetentionSignalObserver observer;
    private readonly StringBuilder text = new();
    private readonly byte[] prefix = new byte[3];
    private int prefixLength;
    private bool bomDetected;
    private DecoderFallbackException? decodingFailure;

    public Task RawEof { get; }
    public Task<string> Text { get; }

    public static Encoding RequireUtf8NoBom(Encoding? encoding)
    {
        Encoding selected = (Encoding)(encoding ?? new UTF8Encoding(false, true)).Clone();
        if (selected.CodePage != Encoding.UTF8.CodePage || selected.GetPreamble().Length != 0)
            throw new ArgumentException("Owned child output encoding must be UTF-8 without BOM.", nameof(encoding));
        selected.DecoderFallback = DecoderFallback.ExceptionFallback;
        return selected;
    }

    public OwnedByteStreamCapture(Stream input, string path, Encoding? encoding, RetentionSignalObserver observer)
    {
        this.input = input;
        this.observer = observer;
        var strict = (Encoding)(encoding ?? new UTF8Encoding(false, true)).Clone();
        strict.DecoderFallback = DecoderFallback.ExceptionFallback;
        decoder = strict.GetDecoder();
        evidence = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.ReadWrite, 4096, true);
        RawEof = PumpAsync();
        Text = DecodeResultAsync();
    }

    private async Task PumpAsync()
    {
        await using (evidence.ConfigureAwait(false))
        {
            var bytes = new byte[4096];
            var characters = new char[16384];
            int count;
            while ((count = await input.ReadAsync(bytes).ConfigureAwait(false)) != 0)
            {
                await evidence.WriteAsync(bytes.AsMemory(0, count)).ConfigureAwait(false);
                await evidence.FlushAsync().ConfigureAwait(false);
                observer.OnBytes(bytes.AsSpan(0, count));
                if (prefixLength < prefix.Length)
                {
                    int copied = Math.Min(count, prefix.Length - prefixLength);
                    Array.Copy(bytes, 0, prefix, prefixLength, copied);
                    prefixLength += copied;
                    if (prefixLength == prefix.Length)
                        bomDetected = prefix is [0xef, 0xbb, 0xbf];
                }
                if (decodingFailure == null)
                {
                    try
                    {
                        int decoded = decoder.GetChars(bytes, 0, count, characters, 0, false);
                        text.Append(characters, 0, decoded);
                    }
                    catch (DecoderFallbackException failure) { decodingFailure = failure; }
                }
            }
            if (decodingFailure == null)
            {
                try
                {
                    int decoded = decoder.GetChars([], 0, 0, characters, 0, true);
                    text.Append(characters, 0, decoded);
                }
                catch (DecoderFallbackException failure) { decodingFailure = failure; }
            }
            observer.OnEof();
            await evidence.FlushAsync().ConfigureAwait(false);
            evidence.Flush(true);
        }
    }

    private async Task<string> DecodeResultAsync()
    {
        await RawEof.ConfigureAwait(false);
        if (bomDetected)
            throw new InvalidDataException("Owned child output must be UTF-8 without BOM.");
        if (decodingFailure != null) ExceptionDispatchInfo.Capture(decodingFailure).Throw();
        return text.ToString();
    }
}
