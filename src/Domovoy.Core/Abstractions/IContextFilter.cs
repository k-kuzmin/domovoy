using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Фильтрация контекста (FR-CORE-4). В промпт передаётся не полный дамп
/// состояний, а срез: сущности упомянутой комнаты, аномальные значения и
/// релевантные запросу. Жёсткий потолок — 4000 токенов на блок
/// состояний.
/// </summary>
public interface IContextFilter
{
    Task<IReadOnlyList<HaEntityState>> SelectAsync(
        AgentRequest request,
        int tokenBudget,
        CancellationToken cancellationToken);
}
