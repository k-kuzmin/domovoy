using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Провайдер LLM. Задаётся конфигурацией: <c>base_url</c>,
/// <c>api_key</c>, <c>model</c>, <c>dialect</c>. Провайдер-специфичных
/// ветвлений вне слоя адаптера нет (раздел 3 ТЗ).
/// </summary>
public interface ILlmProvider
{
    /// <summary>Имя провайдера для логов и метрик. Не содержит ключа и адреса.</summary>
    string Name { get; }

    /// <summary>
    /// Потоковый вызов модели. Streaming-режим обязателен: провайдер без
    /// его поддержки эмулируется адаптером одним фрагментом (FR-CORE-8).
    /// </summary>
    IAsyncEnumerable<LlmStreamChunk> CompleteAsync(
        LlmRequest request,
        CancellationToken cancellationToken);
}
