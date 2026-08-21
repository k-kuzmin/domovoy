using System.Net;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Llm;

/// <summary>
/// Проверка доступности провайдера LLM для <c>/health</c> (NFR-OBS-3).
///
/// Отдельно различает сетевую ошибку и отказ по географии: при активном
/// на хосте VPN обращения к российским провайдерам уходят с зарубежного
/// адреса и получают 403. Это требование AR-1.3 — без различения
/// диагностика показывает «недоступен» и уводит поиск причины в сторону.
/// </summary>
internal sealed class LlmProbe : IComponentProbe
{
    private readonly HttpClient _httpClient;
    private readonly LlmOptions _options;
    private readonly ILogger<LlmProbe> _logger;

    public LlmProbe(HttpClient httpClient, IOptions<LlmOptions> options, ILogger<LlmProbe> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _httpClient = httpClient;
        _options = options.Value;
        _logger = logger;
    }

    public string ComponentName => "llm";

    public async Task<ComponentHealth> CheckAsync(CancellationToken cancellationToken)
    {
        if (!_options.IsConfigured)
        {
            return ComponentHealth.NotConfigured("ключ провайдера не задан");
        }

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, "models");
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue(
                "Bearer",
                _options.ApiKey);

            using HttpResponseMessage response = await _httpClient
                .SendAsync(request, cancellationToken)
                .ConfigureAwait(false);

            if (response.IsSuccessStatusCode)
            {
                return ComponentHealth.Ok("провайдер отвечает");
            }

            // 403 при верном ключе — почти всегда отказ по географии:
            // адрес источника не из разрешённого региона.
            if (response.StatusCode == HttpStatusCode.Forbidden)
            {
                return new ComponentHealth
                {
                    State = ComponentState.RejectedByGeography,
                    Description = "провайдер ответил 403 — вероятен отказ по региону адреса источника",
                };
            }

            if (response.StatusCode == HttpStatusCode.Unauthorized)
            {
                return ComponentHealth.Error("ключ отклонён");
            }

            return ComponentHealth.Unreachable($"ответ {(int)response.StatusCode}");
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
