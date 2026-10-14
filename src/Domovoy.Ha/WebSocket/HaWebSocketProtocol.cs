using System.Buffers;
using System.Globalization;
using System.Text.Json;
using Domovoy.Core.Models;

namespace Domovoy.Ha.WebSocket;

/// <summary>
/// Формат сообщений WebSocket API Home Assistant и объекта состояния.
///
/// Объект состояния у WebSocket (<c>get_states</c>, <c>state_changed</c>) и
/// REST (<c>GET /api/states</c>) один, поэтому и разбор один —
/// <see cref="ParseState"/>.
/// </summary>
internal static class HaWebSocketProtocol
{
    public const string TypeAuthRequired = "auth_required";
    public const string TypeAuthOk = "auth_ok";
    public const string TypeAuthInvalid = "auth_invalid";
    public const string TypeResult = "result";
    public const string TypeEvent = "event";
    public const string TypePong = "pong";
    public const string EventStateChanged = "state_changed";

    /// <summary>
    /// Разобрать объект состояния HA. Атрибуты приводятся к строке: строка —
    /// как есть; число, <c>true</c>/<c>false</c>, объект и массив — сырой
    /// JSON-текст (число не зависит от культуры потока); <c>null</c> — ключ
    /// пропускается.
    /// </summary>
    /// <exception cref="JsonException">
    /// Нет обязательного поля или оно не того типа. Сообщение не цитирует
    /// содержимое объекта.
    /// </exception>
    public static HaEntityState ParseState(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new JsonException("Объект состояния HA — не объект.");
        }

        var attributes = new Dictionary<string, string>(StringComparer.Ordinal);
        if (element.TryGetProperty("attributes", out JsonElement rawAttributes)
            && rawAttributes.ValueKind == JsonValueKind.Object)
        {
            foreach (JsonProperty attribute in rawAttributes.EnumerateObject())
            {
                switch (attribute.Value.ValueKind)
                {
                    case JsonValueKind.Null:
                    case JsonValueKind.Undefined:
                        break;
                    case JsonValueKind.String:
                        attributes[attribute.Name] = attribute.Value.GetString()!;
                        break;
                    default:
                        attributes[attribute.Name] = attribute.Value.GetRawText();
                        break;
                }
            }
        }

        return new HaEntityState
        {
            EntityId = RequiredString(element, "entity_id"),
            State = RequiredString(element, "state"),
            Attributes = attributes,
            LastChanged = RequiredTimestamp(element, "last_changed"),
            LastUpdated = RequiredTimestamp(element, "last_updated"),
        };
    }

    /// <summary>Адрес WebSocket API по базовому адресу HA: http → ws, https → wss.</summary>
    public static Uri BuildWebSocketUri(string baseUrl)
    {
        var builder = new UriBuilder(new Uri(baseUrl.TrimEnd('/') + "/api/websocket"));
        builder.Scheme = string.Equals(builder.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            ? "wss"
            : "ws";
        return builder.Uri;
    }

    /// <summary>
    /// Кадр входа. Единственное место, куда попадает токен; сам кадр не
    /// логируется.
    /// </summary>
    public static byte[] Auth(string accessToken) =>
        Write(writer =>
        {
            writer.WriteString("type", "auth");
            writer.WriteString("access_token", accessToken);
        });

    public static byte[] SubscribeStateChanged(int id) =>
        Write(writer =>
        {
            writer.WriteNumber("id", id);
            writer.WriteString("type", "subscribe_events");
            writer.WriteString("event_type", EventStateChanged);
        });

    public static byte[] GetStates(int id) =>
        Write(writer =>
        {
            writer.WriteNumber("id", id);
            writer.WriteString("type", "get_states");
        });

    public static byte[] Ping(int id) =>
        Write(writer =>
        {
            writer.WriteNumber("id", id);
            writer.WriteString("type", "ping");
        });

    /// <summary>Строковое поле сообщения или <c>null</c>, если его нет или оно не строка.</summary>
    public static string? GetString(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object
        && element.TryGetProperty(name, out JsonElement value)
        && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    /// <summary>Целочисленное поле сообщения или <c>null</c>.</summary>
    public static int? GetInt32(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object
        && element.TryGetProperty(name, out JsonElement value)
        && value.ValueKind == JsonValueKind.Number
        && value.TryGetInt32(out int number)
            ? number
            : null;

    private static string RequiredString(JsonElement element, string name) =>
        GetString(element, name) ?? throw new JsonException($"В объекте состояния HA нет строкового поля {name}.");

    private static DateTimeOffset RequiredTimestamp(JsonElement element, string name)
    {
        string? raw = GetString(element, name);
        if (raw is null
            || !DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out DateTimeOffset value))
        {
            throw new JsonException($"В объекте состояния HA нет метки времени {name}.");
        }

        return value;
    }

    private static byte[] Write(Action<Utf8JsonWriter> body)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            body(writer);
            writer.WriteEndObject();
        }

        return buffer.WrittenSpan.ToArray();
    }
}
