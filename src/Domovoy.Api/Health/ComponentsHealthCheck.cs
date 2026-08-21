using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace Domovoy.Api.Health;

/// <summary>
/// Раздельная проверка внешних компонентов: БД, Home Assistant,
/// провайдер LLM (NFR-OBS-3).
///
/// Незаполненный секрет даёт <see cref="HealthStatus.Degraded"/>, а не
/// <see cref="HealthStatus.Unhealthy"/>: на <c>.example</c>-конфигурации
/// внешних учётных данных нет, и <c>docker compose up</c> на чистой
/// машине обязан подниматься (ТЗ 5.1.3).
/// </summary>
internal sealed class ComponentsHealthCheck : IHealthCheck
{
    private readonly IEnumerable<IComponentProbe> _probes;
    private readonly ILogger<ComponentsHealthCheck> _logger;

    public ComponentsHealthCheck(IEnumerable<IComponentProbe> probes, ILogger<ComponentsHealthCheck> logger)
    {
        _probes = probes;
        _logger = logger;
    }

    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context,
        CancellationToken cancellationToken = default)
    {
        var data = new Dictionary<string, object>(StringComparer.Ordinal);
        HealthStatus worst = HealthStatus.Healthy;

        foreach (IComponentProbe probe in _probes)
        {
            ComponentHealth health = await Check(probe, cancellationToken).ConfigureAwait(false);

            data[probe.ComponentName] = new
            {
                state = ToWireValue(health.State),
                description = health.Description,
            };

            HealthStatus status = ToHealthStatus(health.State);
            if (status < worst)
            {
                worst = status;
            }
        }

        return new HealthCheckResult(worst, description: null, exception: null, data: data);
    }

    private async Task<ComponentHealth> Check(IComponentProbe probe, CancellationToken cancellationToken)
    {
        try
        {
            return await probe.CheckAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Отказ диагностики не имеет права уронить /health: иначе
            // healthcheck контейнера перезапускает сервис из-за
            // недоступности внешней системы.
            _logger.LogWarning(ex, "Проверка компонента {Component} завершилась ошибкой.", probe.ComponentName);
            return ComponentHealth.Error("проверка завершилась ошибкой");
        }
    }

    private static HealthStatus ToHealthStatus(ComponentState state) => state switch
    {
        ComponentState.Ok => HealthStatus.Healthy,
        ComponentState.NotConfigured => HealthStatus.Degraded,
        _ => HealthStatus.Unhealthy,
    };

    /// <summary>
    /// Имя состояния в ответе. Задано явно, а не через
    /// <c>ToString</c>: имя элемента перечисления — деталь реализации,
    /// а это часть контракта API.
    /// </summary>
    private static string ToWireValue(ComponentState state) => state switch
    {
        ComponentState.Ok => "ok",
        ComponentState.NotConfigured => "not_configured",
        ComponentState.Unreachable => "unreachable",
        ComponentState.RejectedByGeography => "rejected_by_geography",
        _ => "error",
    };
}
