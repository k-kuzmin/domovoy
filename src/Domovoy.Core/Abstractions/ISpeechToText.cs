namespace Domovoy.Core.Abstractions;

/// <summary>
/// Распознавание речи. Одна реализация на все клиенты: STT живёт на
/// сервере (раздел 3 ТЗ).
/// </summary>
public interface ISpeechToText
{
    /// <summary>
    /// Распознать аудио. Целевая латентность до события
    /// <c>recognized</c> — p95 менее 1 с после конца записи
    /// (NFR-PERF-4).
    /// </summary>
    Task<string> TranscribeAsync(Stream audio, string contentType, CancellationToken cancellationToken);
}
