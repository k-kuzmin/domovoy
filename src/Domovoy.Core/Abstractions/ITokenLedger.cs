using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Учёт расхода токенов (NFR-COST-1) и месячный потолок (NFR-COST-2).
/// При достижении потолка система деградирует в режим «только быстрый
/// роутер» с уведомлением владельца, а не отказывает в обслуживании.
/// </summary>
public interface ITokenLedger
{
    Task RecordAsync(string requestId, string provider, TokenUsage usage, CancellationToken cancellationToken);

    /// <summary>Расход за текущий календарный месяц.</summary>
    Task<int> GetMonthlyTotalAsync(CancellationToken cancellationToken);

    /// <summary>Месячный потолок достигнут — вызовы LLM запрещены.</summary>
    Task<bool> IsBudgetExhaustedAsync(CancellationToken cancellationToken);
}
