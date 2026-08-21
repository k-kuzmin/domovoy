using System.ComponentModel.DataAnnotations;

namespace Domovoy.Core.Configuration;

/// <summary>Настройки push-уведомлений через ntfy.</summary>
public sealed class NtfyOptions
{
    public const string SectionName = "Ntfy";

    [Required]
    [Url]
    public string BaseUrl { get; set; } = "https://push.example.com";

    /// <summary>
    /// Имя топика. Функционально это пароль: знающий его читает
    /// уведомления и отправляет свои (ТЗ 5.1.3). Приходит из
    /// user-secrets или переменной окружения, не логируется никогда.
    /// </summary>
    public string? Topic { get; set; }

    [Range(1, 60)]
    public int RequestTimeoutSeconds { get; set; } = 10;

    public bool IsConfigured => !PlaceholderValues.IsUnset(Topic);
}
