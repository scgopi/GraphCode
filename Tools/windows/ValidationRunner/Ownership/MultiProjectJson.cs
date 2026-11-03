using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace GraphCode.Validation.Ownership;

public static partial class MultiProjectJson
{
    [GeneratedRegex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", RegexOptions.CultureInvariant)]
    private static partial Regex UuidPattern();

    public static JsonDocument Parse(string json)
    {
        JsonDocument document;
        try { document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 32 }); }
        catch (JsonException failure) { throw new InvalidDataException("MULTIPROJECT_JSON: malformed JSON", failure); }
        try
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object)
                throw new InvalidDataException("MULTIPROJECT_JSON: root must be an object");
            CheckProperties(document.RootElement);
            return document;
        }
        catch { document.Dispose(); throw; }
    }

    private static void CheckProperties(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (JsonProperty property in element.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new InvalidDataException("MULTIPROJECT_JSON: duplicate field " + property.Name);
                CheckProperties(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
            foreach (JsonElement value in element.EnumerateArray()) CheckProperties(value);
    }

    public static JsonObject Object(string json)
    {
        using var document = Parse(json);
        return JsonNode.Parse(document.RootElement.GetRawText())!.AsObject();
    }

    public static JsonObject Shape(JsonNode? value, string label, params string[] keys)
    {
        if (value is not JsonObject result || result.Count != keys.Length ||
            result.Any(pair => !keys.Contains(pair.Key, StringComparer.Ordinal)))
            throw new InvalidDataException("MULTIPROJECT_SCHEMA: " + label + " has the wrong object shape");
        return result;
    }

    public static string String(JsonNode? value, string label)
    {
        if (value is not JsonValue literal || literal.GetValueKind() != JsonValueKind.String)
            throw new InvalidDataException("MULTIPROJECT_TYPE: " + label + " must be a string");
        return literal.GetValue<string>();
    }

    public static long Integer(JsonNode? value, string label)
    {
        if (value is not JsonValue literal || literal.GetValueKind() != JsonValueKind.Number ||
            !long.TryParse(literal.ToJsonString(), System.Globalization.NumberStyles.AllowLeadingSign,
                System.Globalization.CultureInfo.InvariantCulture, out long result))
            throw new InvalidDataException("MULTIPROJECT_TYPE: " + label + " must be an integer");
        return result;
    }

    public static string Uuid(JsonNode? value, string label)
    {
        string text = String(value, label);
        if (!UuidPattern().IsMatch(text))
            throw new InvalidDataException("MULTIPROJECT_UUID: " + label + " must be a lowercase version-4 UUID");
        return text;
    }

    public static string Title(JsonNode? value)
    {
        string title = String(value, "title");
        if (string.IsNullOrWhiteSpace(title)) throw new InvalidDataException("MULTIPROJECT_TITLE: title cannot be blank");
        return title;
    }

    public static string Canonical(JsonNode? value)
    {
        if (value == null) return "null";
        if (value is JsonObject obj)
            return "{" + string.Join(",", obj.OrderBy(p => p.Key, StringComparer.Ordinal)
                .Select(p => JsonSerializer.Serialize(p.Key) + ":" + Canonical(p.Value))) + "}";
        if (value is JsonArray array) return "[" + string.Join(",", array.Select(Canonical)) + "]";
        return value.ToJsonString();
    }
}
