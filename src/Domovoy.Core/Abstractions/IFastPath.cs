using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Быстрый путь целиком (FR-CORE-2, NFR-PERF-1): шаблон и прямой вызов
/// Home Assistant, без LLM.
/// </summary>
public interface IFastPath
{
    /// <summary>
    /// Обработать фразу. <see cref="FastPathOutcome.NotMatched"/> — шаблон
    /// не подошёл, Home Assistant не вызывался.
    /// </summary>
    Task<FastPathOutcome> TryHandleAsync(string text, CancellationToken cancellationToken);
}
