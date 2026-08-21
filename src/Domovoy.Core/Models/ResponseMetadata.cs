namespace Domovoy.Core.Models;

/// <summary>
/// Путь, которым обработан запрос. Разделение нужно для метрик: целевые
/// показатели латентности у путей разные (NFR-PERF-1..3), а доля
/// запросов, закрытых без второго вызова LLM, — отдельная метрика
/// полноты покрытия шаблонов (NFR-PERF-6).
/// </summary>
public enum ResponsePath
{
    /// <summary>Детерминированный роутер, LLM не вызывалась (FR-CORE-2).</summary>
    FastRouter,

    /// <summary>LLM + шаблонный ответ, второго раунда не было (FR-CORE-7).</summary>
    LlmTemplated,

    /// <summary>LLM в два раунда: чтение, ошибка или составной сценарий.</summary>
    LlmTwoRound,

    /// <summary>Деградация по достижении месячного потолка токенов (NFR-COST-2).</summary>
    DegradedFastRouterOnly,
}

/// <summary>Метаданные ответа, отдаются в событии <c>done</c>.</summary>
public sealed record ResponseMetadata
{
    public required string RequestId { get; init; }

    public required ResponsePath Path { get; init; }

    public required TimeSpan Elapsed { get; init; }

    /// <summary>Число вызовов инструментов. Потолок — 5 итераций (FR-CORE-3).</summary>
    public int ToolCallCount { get; init; }

    /// <summary>Расход токенов. <c>null</c> для пути через быстрый роутер.</summary>
    public TokenUsage? Usage { get; init; }
}

/// <summary>Расход токенов по запросу (NFR-COST-1).</summary>
public sealed record TokenUsage(int PromptTokens, int CompletionTokens)
{
    public int TotalTokens => PromptTokens + CompletionTokens;
}
