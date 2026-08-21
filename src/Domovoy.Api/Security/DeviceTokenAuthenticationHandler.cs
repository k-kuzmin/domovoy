using System.Net.Http.Headers;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace Domovoy.Api.Security;

/// <summary>
/// Аутентификация устройства по Bearer-токену.
///
/// Каркас: токены ещё не выдаются, поэтому любой предъявленный токен
/// отклоняется. Это осознанное значение по умолчанию — схема,
/// пропускающая всех «пока не реализовано», однажды доезжает до
/// продакшена.
///
/// Реализация появляется вместе с <c>POST /auth/device</c>.
/// </summary>
internal sealed class DeviceTokenAuthenticationHandler
    : AuthenticationHandler<AuthenticationSchemeOptions>
{
    public DeviceTokenAuthenticationHandler(
        IOptionsMonitor<AuthenticationSchemeOptions> options,
        ILoggerFactory logger,
        UrlEncoder encoder)
        : base(options, logger, encoder)
    {
    }

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        string? header = Request.Headers.Authorization;

        if (string.IsNullOrEmpty(header))
        {
            // Не «отказ», а «данных нет»: отличать нужно, чтобы
            // журнал не заполнялся отказами от анонимных проверок.
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        if (!AuthenticationHeaderValue.TryParse(header, out AuthenticationHeaderValue? parsed) ||
            !string.Equals(parsed.Scheme, "Bearer", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(parsed.Parameter))
        {
            return Task.FromResult(AuthenticateResult.Fail("Некорректный заголовок Authorization."));
        }

        // Значение токена не попадает ни в сообщение, ни в лог.
        return Task.FromResult(AuthenticateResult.Fail(
            "Привязка устройств ещё не реализована: токены не выдаются."));
    }

    /// <summary>
    /// Пустая реализация нужна для явного контракта: клиент получает
    /// 401 без подсказок об устройстве системы.
    /// </summary>
    protected override Task HandleChallengeAsync(AuthenticationProperties properties)
    {
        Response.Headers.WWWAuthenticate = "Bearer";
        return base.HandleChallengeAsync(properties);
    }
}
