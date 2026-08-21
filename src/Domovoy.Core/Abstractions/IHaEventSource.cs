using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Поток событий Home Assistant. Постоянное WebSocket-соединение с
/// подпиской на <c>state_changed</c>; реконнект с экспоненциальной
/// задержкой, потолок 60 с (FR-HA-3, NFR-PERF-7).
/// </summary>
public interface IHaEventSource
{
    /// <summary>
    /// Изменения состояний сущностей из allow-list. Поток не
    /// завершается при разрыве соединения: реализация переподключается
    /// и продолжает отдавать события.
    /// </summary>
    IAsyncEnumerable<HaStateChange> SubscribeAsync(CancellationToken cancellationToken);
}
