using Serilog.Core;
using Serilog.Events;

namespace Domovoy.Api.Logging;

/// <summary>
/// Маскирует значения свойств, имена которых указывают на секрет.
///
/// Правило «токены и ключи не логируются никогда, даже на уровне Debug»
/// нельзя оставлять на внимание того, кто пишет вызов логирования:
/// достаточно одного случая, чтобы секрет оказался в файле лога, а
/// оттуда в отчёте об ошибке. Enricher выполняет правило механически.
///
/// Это не замена дисциплине, а второй рубеж: осмысленно логировать
/// секрет по-прежнему нельзя.
/// </summary>
public sealed class SecretMaskingEnricher : ILogEventEnricher
{
    /// <summary>Значение, которым заменяется содержимое.</summary>
    public const string Mask = "***";

    private static readonly string[] SensitiveNameParts =
    [
        "token",
        "secret",
        "password",
        "passwd",
        "pwd",
        "apikey",
        "api_key",
        "authorization",
        "credential",
        "topic",
        "connectionstring",
    ];

    public void Enrich(LogEvent logEvent, ILogEventPropertyFactory propertyFactory)
    {
        ArgumentNullException.ThrowIfNull(logEvent);

        // Копия имён: свойства события изменяются в цикле.
        List<string> names = [.. logEvent.Properties.Keys];

        foreach (string name in names)
        {
            if (IsSensitive(name))
            {
                logEvent.AddOrUpdateProperty(new LogEventProperty(name, new ScalarValue(Mask)));
            }
        }
    }

    /// <summary>Имя свойства указывает на секрет.</summary>
    public static bool IsSensitive(string propertyName)
    {
        ArgumentNullException.ThrowIfNull(propertyName);

        string normalized = propertyName.Replace("_", string.Empty, StringComparison.Ordinal)
            .Replace("-", string.Empty, StringComparison.Ordinal)
            .ToLowerInvariant();

        return Array.Exists(SensitiveNameParts, part =>
            normalized.Contains(part.Replace("_", string.Empty, StringComparison.Ordinal), StringComparison.Ordinal));
    }
}
