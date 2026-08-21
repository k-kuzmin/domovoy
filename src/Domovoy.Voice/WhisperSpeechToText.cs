using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Voice;

/// <summary>
/// Распознавание речи через faster-whisper в контейнере.
///
/// Каркас: реализация появляется на этапе 4. Целевая латентность до
/// события <c>recognized</c> — p95 менее 1 с (NFR-PERF-4).
/// </summary>
internal sealed class WhisperSpeechToText : ISpeechToText
{
    private readonly HttpClient _httpClient;
    private readonly VoiceOptions _options;
    private readonly ILogger<WhisperSpeechToText> _logger;

    public WhisperSpeechToText(
        HttpClient httpClient,
        IOptions<VoiceOptions> options,
        ILogger<WhisperSpeechToText> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _httpClient = httpClient;
        _options = options.Value;
        _logger = logger;
    }

    public Task<string> TranscribeAsync(Stream audio, string contentType, CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 4: загрузка аудио в faster-whisper и разбор ответа.");
}
