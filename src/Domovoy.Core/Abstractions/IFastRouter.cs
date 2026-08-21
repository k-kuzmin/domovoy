using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Детерминированный роутер до LLM (FR-CORE-2).
///
/// Распознаёт типовые команды по шаблонам и вызывает Home Assistant
/// напрямую, минуя LLM. Цель — покрыть 60–70 % бытовых обращений с
/// латентностью менее 500 мс (NFR-PERF-1).
/// </summary>
public interface IFastRouter
{
    /// <summary>
    /// Подобрать вызов инструмента по шаблону. <c>null</c> означает
    /// «шаблон не подошёл» — это не ошибка, а условие перехода на путь
    /// через LLM.
    /// </summary>
    ToolCall? TryMatch(string text);
}
