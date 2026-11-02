using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;

namespace GraphCode.Validation.Ownership;

public static class OwnershipRetention
{
    public const string RequiredKey = "GraphCodeValidationRootRetentionRequired";
    public const string RootsKey = "GraphCodeValidationRetainedRoots";
    public const string Sentinel = "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven";

    public static void Tag(Exception failure, string? root)
    {
        failure.Data[RequiredKey] = true;
        if (string.IsNullOrEmpty(root)) return;
        try
        {
            string full = Path.GetFullPath(root);
            if (!Directory.Exists(full)) throw new DirectoryNotFoundException(full);
            failure.Data[RootsKey] = new[] { full };
            byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(new
            {
                schemaVersion = 1,
                validationRoot = full,
                reason = "ownership_unproven"
            });
            if (bytes.Length > 4096) throw new InvalidOperationException("Ownership receipt exceeds 4096 bytes.");
            using var file = new FileStream(Path.Combine(full, "ownership-unproven.json"),
                FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            file.Write(bytes);
            file.Flush(true);
        }
        catch (Exception receiptFailure) when (receiptFailure is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or InvalidOperationException)
        {
            failure.Data["GraphCodeValidationRetentionReceiptFailure"] = receiptFailure.ToString();
        }
    }

    public static bool ReceiptRequiresRetention(string root)
    {
        string path = Path.Combine(root, "ownership-unproven.json");
        if (!File.Exists(path)) return false;
        var info = new FileInfo(path);
        if (info.Length is <= 0 or > 4096) throw new InvalidDataException("Invalid ownership receipt length.");
        byte[] bytes = File.ReadAllBytes(path);
        string json = new UTF8Encoding(false, true).GetString(bytes);
        using JsonDocument document = JsonDocument.Parse(json);
        JsonElement receipt = document.RootElement;
        if (receipt.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Ownership receipt must be an object.");
        var keys = new HashSet<string>(StringComparer.Ordinal);
        foreach (JsonProperty property in receipt.EnumerateObject())
            if (!keys.Add(property.Name)) throw new InvalidDataException("Duplicate receipt field.");
        if (keys.Count != 3 || !keys.SetEquals(["schemaVersion", "validationRoot", "reason"]) ||
            receipt.GetProperty("schemaVersion").ValueKind != JsonValueKind.Number ||
            receipt.GetProperty("schemaVersion").GetRawText() != "1" ||
            receipt.GetProperty("validationRoot").ValueKind != JsonValueKind.String ||
            !string.Equals(receipt.GetProperty("validationRoot").GetString(), Path.GetFullPath(root), StringComparison.Ordinal) ||
            receipt.GetProperty("reason").ValueKind != JsonValueKind.String ||
            receipt.GetProperty("reason").GetString() != "ownership_unproven")
            throw new InvalidDataException("Ownership receipt schema/root/reason mismatch.");
        return true;
    }
}
