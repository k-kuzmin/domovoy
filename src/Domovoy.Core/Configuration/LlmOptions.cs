using System.ComponentModel.DataAnnotations;

namespace Domovoy.Core.Configuration;

/// <summary>
/// Диалект API провайдера. Определяет формат запроса внутри адаптера и
/// нигде больше: провайдер-специфичных ветвлений вне слоя адаптера нет
/// (раздел 3 ТЗ).
/// </summary>
public enum LlmDialect
{
    /// <summary>OpenAI-совместимый слой: GigaChat, Ollama.</summary>
    OpenAiCompatible,

    /// <summary>Yandex Foundation Models.</summary>
    Yandex,
}

/// <summary>Настройки провайдера LLM. Провайдер задаётся конфигурацией.</summary>
public sealed class LlmOptions
{
    public const string SectionName = "Llm";

    [Required]
    [Url]
    public string BaseUrl { get; set; } = "https://llm.example.com/v1";

    /// <summary>
    /// Ключ провайдера. Приходит из user-secrets или переменной
    /// окружения, не логируется никогда, даже на уровне Debug.
    /// </summary>
    public string? ApiKey { get; set; }

    [Required]
    public string Model { get; set; } = "placeholder-model";

    public LlmDialect Dialect { get; set; } = LlmDialect.OpenAiCompatible;

    [Range(1, 300)]
    public int RequestTimeoutSeconds { get; set; } = 60;

    /// <summary>Потолок итераций tool-цикла на один запрос (FR-CORE-3).</summary>
    [Range(1, 10)]
    public int MaxToolIterations { get; set; } = 5;

    /// <summary>Потолок токенов на блок состояний в промпте (FR-CORE-4).</summary>
    [Range(500, 32000)]
    public int StateTokenBudget { get; set; } = 4000;

    /// <summary>
    /// Месячный потолок расхода токенов. При достижении — деградация в
    /// режим «только быстрый роутер» (NFR-COST-2). Ноль отключает
    /// ограничение.
    /// </summary>
    [Range(0, int.MaxValue)]
    public int MonthlyTokenBudget { get; set; }

    /// <summary>
    /// Необязательный SOCKS-прокси для исходящих вызовов. Нужен, когда
    /// на хосте активен VPN и провайдер отклоняет запросы по географии:
    /// маршрутизация хоста при этом не меняется (AR-1.3).
    /// </summary>
    public string? Proxy { get; set; }

    public bool IsConfigured => !PlaceholderValues.IsUnset(ApiKey);
}
