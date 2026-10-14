using System.Collections.Frozen;
using System.Globalization;
using System.Text.Json.Nodes;

namespace Domovoy.Ha.Registry;

/// <summary>Тип значения действия.</summary>
internal enum HaValueKind
{
    /// <summary>Действие значения не принимает.</summary>
    None,

    /// <summary>Целое число в границах.</summary>
    Integer,

    /// <summary>Число с дробной частью в границах.</summary>
    Number,

    /// <summary><c>true</c> или <c>false</c>.</summary>
    Boolean,

    /// <summary>Непустая строка не длиннее предела, уходит как есть.</summary>
    String,

    /// <summary>Целое число процентов в границах, уходит в HA дробью 0..1.</summary>
    PercentAsFraction,
}

/// <summary>
/// Сервис HA, в который превращается действие реестра, и описание его
/// значения. <paramref name="ValueField"/> — <c>null</c>: сервис вызывается
/// без значения.
/// </summary>
internal sealed record HaActionSpec(
    string Service,
    string? ValueField,
    HaValueKind Kind,
    decimal? Min,
    decimal? Max,
    int? MaxLength,
    bool RequiresConfirmation);

/// <summary>
/// Закрытый каталог доменов Home Assistant — белый список сервисов
/// раздела 4.3 ТЗ.
///
/// Домен вне каталога — отказ старта на проверке реестра; действие вне
/// домена — тоже. Сервис и поле значения выводятся отсюда, а не из реестра
/// и не из фразы: модель и пользователь называют действие, а не сервис.
///
/// Инвариант: действие с полем значения описано типом и границами — у числа
/// Min и Max, у строки MaxLength. Действия замков требуют подтверждения
/// здесь, независимо от флага реестра (правило 6 раздела «Безопасность»).
/// Сигнализация, вентили и ворота в каталог этого этапа не входят.
/// </summary>
internal static class HaDomainCatalog
{
    /// <summary>Действие только читает состояние; есть в каждом домене каталога, сервиса нет.</summary>
    public const string ReadAction = "read";

    private const NumberStyles NumberFormat =
        NumberStyles.AllowLeadingWhite
        | NumberStyles.AllowTrailingWhite
        | NumberStyles.AllowLeadingSign
        | NumberStyles.AllowDecimalPoint;

    /// <summary>
    /// Домен → действие → описание. Действия <see cref="ReadAction"/> здесь нет:
    /// оно не вызывает сервис.
    /// </summary>
    public static IReadOnlyDictionary<string, IReadOnlyDictionary<string, HaActionSpec>> Actions { get; } =
        BuildCatalog();

    public static bool IsKnownDomain(string domain) => Actions.ContainsKey(domain);

    /// <summary>Действие есть в каталоге хотя бы одного домена; <see cref="ReadAction"/> — всегда.</summary>
    public static bool IsKnownAction(string action) =>
        string.Equals(action, ReadAction, StringComparison.Ordinal)
        || Actions.Values.Any(actions => actions.ContainsKey(action));

    /// <summary>Действие входит в каталог домена; <see cref="ReadAction"/> — в любом известном домене.</summary>
    public static bool IsActionAllowed(string domain, string action) =>
        Actions.TryGetValue(domain, out IReadOnlyDictionary<string, HaActionSpec>? actions)
        && (string.Equals(action, ReadAction, StringComparison.Ordinal) || actions.ContainsKey(action));

    /// <summary>
    /// Описание действия или <c>null</c>: домен или действие вне каталога, либо
    /// <see cref="ReadAction"/> — оно только читает.
    /// </summary>
    public static HaActionSpec? Resolve(string domain, string action) =>
        Actions.TryGetValue(domain, out IReadOnlyDictionary<string, HaActionSpec>? actions)
        && actions.TryGetValue(action, out HaActionSpec? spec)
            ? spec
            : null;

    /// <summary>
    /// Собрать тело вызова <c>{ entity_id, &lt;поле&gt;: значение }</c> с
    /// типизированным значением: HA строку вместо числа не приводит.
    /// Значение разбирается инвариантной культурой, запятая — как точка.
    /// <c>false</c> — значение лишнее, пропущено, не того типа или вне границ.
    /// </summary>
    public static bool TryBuildPayload(HaActionSpec spec, string entityId, string? value, out JsonObject payload)
    {
        ArgumentNullException.ThrowIfNull(spec);

        payload = [];

        if (spec.ValueField is null)
        {
            if (value is not null)
            {
                return false;
            }

            payload["entity_id"] = entityId;
            return true;
        }

        if (string.IsNullOrWhiteSpace(value) || !TryConvert(spec, value, out JsonNode? node))
        {
            return false;
        }

        payload["entity_id"] = entityId;
        payload[spec.ValueField] = node;
        return true;
    }

    private static bool TryConvert(HaActionSpec spec, string value, out JsonNode? node)
    {
        node = null;

        switch (spec.Kind)
        {
            case HaValueKind.Integer:
                if (TryParseNumber(spec, value, out decimal integer) && integer == decimal.Truncate(integer))
                {
                    node = JsonValue.Create((long)integer);
                    return true;
                }

                return false;

            case HaValueKind.Number:
                if (TryParseNumber(spec, value, out decimal number))
                {
                    node = JsonValue.Create(number);
                    return true;
                }

                return false;

            case HaValueKind.PercentAsFraction:
                if (TryParseNumber(spec, value, out decimal percent) && percent == decimal.Truncate(percent))
                {
                    // decimal, а не double: 30 % уходит ровно 0.3, а не 0.30000000000000004.
                    node = JsonValue.Create(decimal.Truncate(percent) / 100m);
                    return true;
                }

                return false;

            case HaValueKind.Boolean:
                if (bool.TryParse(value, out bool flag))
                {
                    node = JsonValue.Create(flag);
                    return true;
                }

                return false;

            case HaValueKind.String:
                if (spec.MaxLength is int maxLength && value.Length <= maxLength)
                {
                    node = JsonValue.Create(value);
                    return true;
                }

                return false;

            default:
                return false;
        }
    }

    private static bool TryParseNumber(HaActionSpec spec, string value, out decimal number) =>
        decimal.TryParse(value.Replace(',', '.'), NumberFormat, CultureInfo.InvariantCulture, out number)
        && spec.Min is decimal min
        && spec.Max is decimal max
        && number >= min
        && number <= max;

    private static FrozenDictionary<string, IReadOnlyDictionary<string, HaActionSpec>> BuildCatalog()
    {
        var catalog = new Dictionary<string, IReadOnlyDictionary<string, HaActionSpec>>(StringComparer.Ordinal)
        {
            ["light"] = Domain(
                Plain("turn_on"),
                Plain("turn_off"),
                Plain("toggle"),
                ("set_brightness", new HaActionSpec("turn_on", "brightness_pct", HaValueKind.Integer, 0, 100, null, false))),

            ["media_player"] = Domain(
                Plain("turn_on"),
                Plain("turn_off"),
                Plain("media_play"),
                Plain("media_pause"),
                Plain("media_stop"),
                Plain("media_next_track"),
                Plain("media_previous_track"),
                Plain("volume_up"),
                Plain("volume_down"),
                ("volume_set", new HaActionSpec("volume_set", "volume_level", HaValueKind.PercentAsFraction, 0, 100, null, false)),
                ("volume_mute", new HaActionSpec("volume_mute", "is_volume_muted", HaValueKind.Boolean, null, null, null, false)),
                ("select_source", new HaActionSpec("select_source", "source", HaValueKind.String, null, null, 100, false))),

            ["vacuum"] = Domain(
                Plain("start"),
                Plain("pause"),
                Plain("stop"),
                Plain("return_to_base"),
                Plain("locate")),

            // 7..35 — DEFAULT_MIN_TEMP и DEFAULT_MAX_TEMP
            // homeassistant/components/climate/const.py.
            ["climate"] = Domain(
                Plain("turn_on"),
                Plain("turn_off"),
                ("set_temperature", new HaActionSpec("set_temperature", "temperature", HaValueKind.Number, 7, 35, null, false))),

            ["lock"] = Domain(
                Confirmed("lock"),
                Confirmed("unlock")),

            ["sensor"] = Domain(),

            ["binary_sensor"] = Domain(),
        };

        return catalog.ToFrozenDictionary(StringComparer.Ordinal);
    }

    private static (string Action, HaActionSpec Spec) Plain(string action) =>
        (action, new HaActionSpec(action, null, HaValueKind.None, null, null, null, false));

    private static (string Action, HaActionSpec Spec) Confirmed(string action) =>
        (action, new HaActionSpec(action, null, HaValueKind.None, null, null, null, true));

    private static FrozenDictionary<string, HaActionSpec> Domain(params (string Action, HaActionSpec Spec)[] actions) =>
        actions.ToFrozenDictionary(entry => entry.Action, entry => entry.Spec, StringComparer.Ordinal);
}
