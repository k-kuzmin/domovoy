using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Оркестратор: единый путь обработки запроса независимо от того,
/// пришёл он текстом или голосом (FR-CORE-1).
///
/// Порядок: быстрый роутер → при отсутствии совпадения LLM с tool
/// calling, максимум 5 итераций цикла (FR-CORE-3).
/// </summary>
public interface IOrchestrator
{
    /// <summary>
    /// Обработать запрос, отдавая события по мере готовности
    /// (FR-CORE-8). Поток всегда завершается событием <c>done</c> или
    /// <c>error</c>.
    /// </summary>
    IAsyncEnumerable<AgentEvent> HandleAsync(AgentRequest request, CancellationToken cancellationToken);
}
