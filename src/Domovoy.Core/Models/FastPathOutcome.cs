namespace Domovoy.Core.Models;

/// <summary>
/// Итог быстрого пути. <see cref="Matched"/> ложно — фраза не подошла ни к
/// одному шаблону, запрос уходит на путь через LLM; это не ошибка.
/// </summary>
public sealed record FastPathOutcome
{
    /// <summary>Нет совпадения: Home Assistant не вызывался.</summary>
    public static FastPathOutcome NotMatched { get; } = new() { Matched = false };

    public bool Matched { get; init; }

    /// <summary>Совпадение шаблона. Задано, когда <see cref="Matched"/> истинно.</summary>
    public FastRouteMatch? Match { get; init; }

    /// <summary>Результат обращения к Home Assistant. Задан, когда <see cref="Matched"/> истинно.</summary>
    public ToolResult? Result { get; init; }
}
