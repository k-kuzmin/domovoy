using System.ComponentModel.DataAnnotations;
using Microsoft.Extensions.Options;

namespace Domovoy.Api.Security;

/// <summary>
/// Пределы частоты запросов (NFR-SEC-3). Окно всех пределов —
/// фиксированная минута. Живут в Api, а не в ядре: лимит частоты —
/// свойство транспорта. Предел обмена кода привязки остаётся в
/// <c>Auth:PairingAttemptsPerMinute</c> (запись 0033).
/// </summary>
public sealed class RateLimitOptions
{
    public const string SectionName = "RateLimit";

    /// <summary>
    /// Общий предел запросов в минуту на раздел: устройство, администратор,
    /// петля контейнера, каждая анонимная конечная точка (запись 0035).
    /// Действует на каждый маршрут.
    /// </summary>
    [Range(1, 1_000_000)]
    public int RequestsPerMinute { get; set; } = 120;

    /// <summary>
    /// Предел запросов в минуту к <c>/chat</c> и <c>/voice</c> — один на
    /// дом, а не на устройство: бюджет токенов один (NFR-COST-2). Строго
    /// меньше <see cref="RequestsPerMinute"/>, иначе отказ старта.
    /// </summary>
    [Range(1, 1_000_000)]
    public int LlmRequestsPerMinute { get; set; } = 10;
}

/// <summary>
/// Правило между полями: предел <c>/chat</c> и <c>/voice</c> строго
/// жёстче общего. Равный или больший предел не ограничивал бы эти
/// маршруты ничем сверх общего — «отдельный, более жёсткий лимит»
/// закрепляется отказом старта, а не соглашением.
/// </summary>
public sealed class RateLimitOptionsValidator : IValidateOptions<RateLimitOptions>
{
    public ValidateOptionsResult Validate(string? name, RateLimitOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        if (options.LlmRequestsPerMinute < options.RequestsPerMinute)
        {
            return ValidateOptionsResult.Success;
        }

        return ValidateOptionsResult.Fail(
            $"{RateLimitOptions.SectionName}:{nameof(RateLimitOptions.LlmRequestsPerMinute)} "
            + $"({options.LlmRequestsPerMinute}) должен быть строго меньше "
            + $"{RateLimitOptions.SectionName}:{nameof(RateLimitOptions.RequestsPerMinute)} "
            + $"({options.RequestsPerMinute}): предел /chat и /voice жёстче общего.");
    }
}
