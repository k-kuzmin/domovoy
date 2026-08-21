using System.ComponentModel.DataAnnotations;

namespace Domovoy.Core.Configuration;

/// <summary>Настройки подключения к Home Assistant.</summary>
public sealed class HaOptions
{
    public const string SectionName = "Ha";

    /// <summary>
    /// Базовый адрес Home Assistant в локальной сети. Наружу Home
    /// Assistant не выставлен (NFR-SEC-2).
    /// </summary>
    [Required]
    [Url]
    public string BaseUrl { get; set; } = "http://homeassistant:8123";

    /// <summary>
    /// Long-lived access token служебного пользователя (FR-HA-2).
    /// Приходит из user-secrets или переменной окружения, в файлах
    /// проекта не хранится и не логируется никогда.
    /// </summary>
    public string? Token { get; set; }

    /// <summary>Путь к файлу реестра сущностей (allow-list).</summary>
    [Required]
    public string EntityRegistryPath { get; set; } = "config/entities.yaml";

    /// <summary>Таймаут REST-запроса.</summary>
    [Range(1, 120)]
    public int RequestTimeoutSeconds { get; set; } = 10;

    /// <summary>
    /// Потолок задержки реконнекта WebSocket. Экспоненциальный рост до
    /// этого значения (FR-HA-3, NFR-PERF-7).
    /// </summary>
    [Range(1, 60)]
    public int ReconnectMaxDelaySeconds { get; set; } = 60;

    /// <summary>Токен заполнен настоящим значением, а не плейсхолдером.</summary>
    public bool IsConfigured => !PlaceholderValues.IsUnset(Token);
}
