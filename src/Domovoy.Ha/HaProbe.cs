using System.Net;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Ha;

/// <summary>
/// Проверка связи с Home Assistant для <c>/health</c> (NFR-OBS-3).
///
/// Реализована по-настоящему уже на этапе каркаса: <c>/health</c> —
/// единственный работающий эндпоинт, и его смысл именно в том, чтобы
/// показать состояние компонентов.
/// </summary>
internal sealed class HaProbe : IComponentProbe
{
    private readonly HttpClient _httpClient;
    private readonly HaOptions _options;
    private readonly ILogger<HaProbe> _logger;

    public HaProbe(HttpClient httpClient, IOptions<HaOptions> options, ILogger<HaProbe> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _httpClient = httpClient;
        _options = options.Value;
        _logger = logger;
    }

    public string ComponentName => "ha";

    public async Task<ComponentHealth> CheckAsync(CancellationToken cancellationToken)
    {
        if (!_options.IsConfigured)
        {
            return ComponentHealth.NotConfigured("токен служебного пользователя не задан");
        }

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, "api/");
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue(
                "Bearer",
                _options.Token);

            using HttpResponseMessage response = await _httpClient
                .SendAsync(request, cancellationToken)
                .ConfigureAwait(false);

            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                // Диагностика без значения токена: сам токен не попадает
                // ни в лог, ни в ответ.
                return ComponentHealth.Error("токен отклонён");
            }

            return response.IsSuccessStatusCode
                ? ComponentHealth.Ok("соединение установлено")
                : ComponentHealth.Unreachable($"ответ {(int)response.StatusCode}");
        }
        catch (HttpRequestException)
        {
            return ComponentHealth.Unreachable("сетевая ошибка");
        }
        catch (TaskCanceledException)
        {
            return ComponentHealth.Unreachable("таймаут");
        }
    }
}
