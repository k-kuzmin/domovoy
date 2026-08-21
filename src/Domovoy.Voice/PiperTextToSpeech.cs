using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Voice;

/// <summary>
/// Синтез речи через Piper. Опционально (FR-VOICE-4): при пустом адресе
/// сервиса озвучка отключена.
///
/// Каркас: реализация появляется на этапе 4.
/// </summary>
internal sealed class PiperTextToSpeech : ITextToSpeech
{
    private readonly HttpClient _httpClient;
    private readonly VoiceOptions _options;
    private readonly ILogger<PiperTextToSpeech> _logger;

    public PiperTextToSpeech(
        HttpClient httpClient,
        IOptions<VoiceOptions> options,
        ILogger<PiperTextToSpeech> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _httpClient = httpClient;
        _options = options.Value;
        _logger = logger;
    }

    public Task<Uri> SynthesizeAsync(string text, CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 4: синтез речи и публикация файла.");
}
