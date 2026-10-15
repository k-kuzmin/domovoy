using System.Net.Http.Headers;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text.Encodings.Web;
using Domovoy.Api.Endpoints;
using Domovoy.Core.Auth;
using Domovoy.Core.Configuration;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace Domovoy.Api.Security;

/// <summary>
/// Аутентификация администратора по общему секрету <c>Auth:AdminToken</c>
/// (запись 0032). Схема своя, отдельная от схемы устройства: админ-секрет
/// не делает запрос устройством, токен устройства не открывает админку.
///
/// Секрет читается на каждом запросе через <see cref="IOptionsMonitor{TOptions}"/>,
/// а не захватывается при старте. Не настроен (пусто или плейсхолдер) —
/// отказ всегда. Сравнение — SHA-256 обоих значений за постоянное время:
/// время ответа не подсказывает совпавший префикс, а хеши равной длины
/// снимают зависимость от длины секрета. Неудачная попытка — Warning без
/// предъявленного значения.
/// </summary>
internal sealed class AdminTokenAuthenticationHandler
    : AuthenticationHandler<AuthenticationSchemeOptions>
{
    private readonly IOptionsMonitor<AuthOptions> _authOptions;

    public AdminTokenAuthenticationHandler(
        IOptionsMonitor<AuthenticationSchemeOptions> options,
        ILoggerFactory logger,
        UrlEncoder encoder,
        IOptionsMonitor<AuthOptions> authOptions)
        : base(options, logger, encoder)
    {
        _authOptions = authOptions;
    }

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        string? header = Request.Headers.Authorization;

        if (string.IsNullOrEmpty(header))
        {
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        if (!AuthenticationHeaderValue.TryParse(header, out AuthenticationHeaderValue? parsed) ||
            !string.Equals(parsed.Scheme, "Bearer", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(parsed.Parameter))
        {
            return Task.FromResult(AuthenticateResult.Fail("Некорректный заголовок Authorization."));
        }

        string configured = _authOptions.CurrentValue.AdminToken;

        if (PlaceholderValues.IsUnset(configured))
        {
            Logger.LogWarning("Запрос к админ-эндпоинту отклонён: админ-секрет не настроен.");
            return Task.FromResult(AuthenticateResult.Fail("Админ-эндпоинты закрыты."));
        }

        if (!CryptographicOperations.FixedTimeEquals(
                DeviceSecrets.Hash(parsed.Parameter),
                DeviceSecrets.Hash(configured)))
        {
            Logger.LogWarning("Запрос к админ-эндпоинту отклонён: админ-секрет не совпал.");
            return Task.FromResult(AuthenticateResult.Fail("Админ-секрет не принят."));
        }

        var identity = new ClaimsIdentity([new Claim(ClaimTypes.Role, "admin")], Scheme.Name);

        return Task.FromResult(
            AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), Scheme.Name)));
    }

    protected override Task HandleChallengeAsync(AuthenticationProperties properties)
    {
        Response.Headers.WWWAuthenticate = "Bearer";
        return ApiErrorResults.Write(
            Context,
            StatusCodes.Status401Unauthorized,
            ApiErrorResults.Unauthorized,
            "Требуется админ-секрет.");
    }

    protected override Task HandleForbiddenAsync(AuthenticationProperties properties) =>
        ApiErrorResults.Write(
            Context,
            StatusCodes.Status403Forbidden,
            ApiErrorResults.Forbidden,
            "Недостаточно прав для этого запроса.");
}
