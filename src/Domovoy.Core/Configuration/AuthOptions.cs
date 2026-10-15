using System.ComponentModel.DataAnnotations;

namespace Domovoy.Core.Configuration;

/// <summary>Настройки аутентификации устройств и администратора.</summary>
public sealed class AuthOptions
{
    public const string SectionName = "Auth";

    /// <summary>
    /// Общий секрет админ-эндпоинтов. Приходит из user-secrets или
    /// переменной окружения, в файлах проекта не хранится и не логируется
    /// никогда. Пустое значение или плейсхолдер — админ-эндпоинты закрыты;
    /// настоящее значение короче <see cref="AuthOptionsValidator.MinAdminTokenLength"/>
    /// символов — отказ старта.
    /// </summary>
    public string AdminToken { get; set; } = "";

    /// <summary>Срок жизни кода привязки устройства.</summary>
    [Range(1, 1440)]
    public int PairingCodeLifetimeMinutes { get; set; } = 10;

    /// <summary>
    /// Предел обращений к обмену кода на токен в минуту — общий на весь
    /// эндпоинт, а не на адрес источника.
    /// </summary>
    [Range(1, 1000)]
    public int PairingAttemptsPerMinute { get; set; } = 5;
}
