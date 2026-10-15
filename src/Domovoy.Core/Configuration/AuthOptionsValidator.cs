using Microsoft.Extensions.Options;

namespace Domovoy.Core.Configuration;

/// <summary>
/// Проверка формы админ-секрета на старте.
///
/// Не настроенный секрет (пусто или плейсхолдер) — не ошибка: админ-
/// эндпоинты тогда закрыты, а <c>docker compose up</c> на примерах
/// поднимается (ТЗ 5.1.3). Настоящий, но короткий секрет — ошибка формы:
/// угадываемый секрет на публичном входе хуже закрытой админки. Сообщение
/// отказа называет ключ и порог, но не значение.
/// </summary>
public sealed class AuthOptionsValidator : IValidateOptions<AuthOptions>
{
    /// <summary>Минимальная длина настроенного админ-секрета.</summary>
    public const int MinAdminTokenLength = 32;

    public ValidateOptionsResult Validate(string? name, AuthOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        if (PlaceholderValues.IsUnset(options.AdminToken) || options.AdminToken.Length >= MinAdminTokenLength)
        {
            return ValidateOptionsResult.Success;
        }

        return ValidateOptionsResult.Fail(
            $"{AuthOptions.SectionName}:{nameof(AuthOptions.AdminToken)} задан короче "
            + $"{MinAdminTokenLength} символов. Нужна случайная строка не короче {MinAdminTokenLength} "
            + "символов либо пустое значение — тогда админ-эндпоинты закрыты.");
    }
}
