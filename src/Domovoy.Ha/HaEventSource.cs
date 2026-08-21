using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Ha;

/// <summary>
/// Постоянное WebSocket-соединение к Home Assistant с подпиской на
/// <c>state_changed</c> (FR-HA-3).
///
/// Каркас: реализация появляется на этапе 1. Реконнект —
/// экспоненциальная задержка с потолком
/// <see cref="HaOptions.ReconnectMaxDelaySeconds"/> (NFR-PERF-7).
/// </summary>
internal sealed class HaEventSource : IHaEventSource
{
    private readonly HaOptions _options;
    private readonly ILogger<HaEventSource> _logger;

    public HaEventSource(IOptions<HaOptions> options, ILogger<HaEventSource> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _options = options.Value;
        _logger = logger;
    }

    public IAsyncEnumerable<HaStateChange> SubscribeAsync(CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 1: WebSocket-подписка с реконнектом.");
}
