using System.Net.Http.Headers;
using System.Security.Claims;
using System.Text.Encodings.Web;
using Domovoy.Api.Endpoints;
using Domovoy.Core.Auth;
using Domovoy.Core.Models;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authorization;
using Microsoft.Extensions.Options;

namespace Domovoy.Api.Security;

/// <summary>
/// Аутентификация устройства по Bearer-токену (#12).
///
/// Каждый запрос идёт в хранилище через <see cref="DeviceAuthService"/>:
/// кэша нет, поэтому отзыв действует со следующего запроса (#13). Значение
/// токена не попадает ни в сообщение отказа, ни в лог.
///
/// Ответ пишет только challenge, и только тогда, когда его вызвала
/// авторизация защищённого маршрута: сбой хранилища не пишет в Response из
/// <see cref="HandleAuthenticateAsync"/>, а возвращается отказом
/// <see cref="DeviceStoreUnavailableException"/>, и challenge по тому же
/// закэшированному результату отвечает 503 вместо 401. Так нет ни двойной
/// записи, ни 503 на анонимных маршрутах.
/// </summary>
internal sealed class DeviceTokenAuthenticationHandler
    : AuthenticationHandler<AuthenticationSchemeOptions>
{
    private readonly DeviceAuthService _deviceAuth;

    public DeviceTokenAuthenticationHandler(
        IOptionsMonitor<AuthenticationSchemeOptions> options,
        ILoggerFactory logger,
        UrlEncoder encoder,
        DeviceAuthService deviceAuth)
        : base(options, logger, encoder)
    {
        _deviceAuth = deviceAuth;
    }

    protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        // Политика группы и FallbackPolicy аутентифицируют и анонимные
        // маршруты (/health, /auth/device): AuthorizationMiddleware
        // проверяет AllowAnonymous уже после аутентификации. Хранилище за
        // токеном на них не нужно — и его сбой не должен их касаться.
        if (Context.GetEndpoint()?.Metadata.GetMetadata<IAllowAnonymous>() is not null)
        {
            return AuthenticateResult.NoResult();
        }

        string? header = Request.Headers.Authorization;

        if (string.IsNullOrEmpty(header))
        {
            // Не «отказ», а «данных нет»: отличать нужно, чтобы
            // журнал не заполнялся отказами от анонимных проверок.
            return AuthenticateResult.NoResult();
        }

        if (!AuthenticationHeaderValue.TryParse(header, out AuthenticationHeaderValue? parsed) ||
            !string.Equals(parsed.Scheme, "Bearer", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(parsed.Parameter))
        {
            return AuthenticateResult.Fail("Некорректный заголовок Authorization.");
        }

        ActiveDevice? device;
        try
        {
            device = await _deviceAuth.AuthenticateAsync(parsed.Parameter, Context.RequestAborted);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            Logger.LogWarning(exception, "Хранилище устройств недоступно: токен устройства не проверен.");
            return AuthenticateResult.Fail(new DeviceStoreUnavailableException());
        }

        if (device is null)
        {
            return AuthenticateResult.Fail("Токен устройства не принят.");
        }

        try
        {
            await _deviceAuth.TouchLastSeenIfStaleAsync(device, Context.RequestAborted);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            // Отметка last_seen не критична: запрос остаётся
            // аутентифицированным.
            Logger.LogWarning(exception, "Не удалось обновить last_seen устройства {DeviceId}.", device.Id);
        }

        var identity = new ClaimsIdentity(
            [new Claim(ClaimTypes.NameIdentifier, device.Id.ToString())],
            Scheme.Name);

        return AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), Scheme.Name));
    }

    protected override async Task HandleChallengeAsync(AuthenticationProperties properties)
    {
        AuthenticateResult result = await HandleAuthenticateOnceSafeAsync();

        if (result.Failure is DeviceStoreUnavailableException)
        {
            await ApiErrorResults.Write(
                Context,
                StatusCodes.Status503ServiceUnavailable,
                ApiErrorResults.AuthUnavailable,
                ApiErrorResults.AuthUnavailableMessage);
            return;
        }

        // Клиент получает 401 без подсказок об устройстве системы.
        Response.Headers.WWWAuthenticate = "Bearer";
        await ApiErrorResults.Write(
            Context,
            StatusCodes.Status401Unauthorized,
            ApiErrorResults.Unauthorized,
            "Требуется действующий токен устройства.");
    }

    protected override Task HandleForbiddenAsync(AuthenticationProperties properties) =>
        ApiErrorResults.Write(
            Context,
            StatusCodes.Status403Forbidden,
            ApiErrorResults.Forbidden,
            "Недостаточно прав для этого запроса.");

    /// <summary>
    /// Отказ «хранилище недоступно» в отличие от «токен не принят». Текст
    /// нейтральный: исходное исключение остаётся только в логе.
    /// </summary>
    private sealed class DeviceStoreUnavailableException : Exception
    {
        public DeviceStoreUnavailableException()
            : base("Хранилище устройств недоступно.")
        {
        }
    }
}
