using System;
using System.Text;

namespace GraphCode.Validation.Ownership;

public interface IOwnedStreamObserver
{
    void OnText(string text);
    void OnEof();
}

public sealed class RetentionSignalObserver(Action observed) : IOwnedStreamObserver
{
    private readonly StringBuilder line = new();
    private bool overlong, reported;
    private const string Signal = "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven";

    public void OnText(string text)
    {
        foreach (char character in text)
        {
            if (character == '\n') { FinishLine(); continue; }
            if (overlong) continue;
            if (line.Length > Signal.Length) { overlong = true; line.Clear(); continue; }
            line.Append(character);
        }
    }

    public void OnEof() => FinishLine();

    private void FinishLine()
    {
        if (!overlong)
        {
            string value = line.ToString();
            if (value.EndsWith('\r')) value = value[..^1];
            if (!reported && value == Signal) { reported = true; observed(); }
        }
        line.Clear();
        overlong = false;
    }
}
