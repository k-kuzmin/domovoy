using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Llm;

/// <summary>
/// Адаптер Yandex Foundation Models — резервный провайдер.
/// Переключение выполняется сменой <c>base_url</c>, ключа и диалекта в
/// конфигурации, без правок кода вне этого слоя.
///
/// Каркас: реализация появляется на этапе 2.
/// </summary>
internal sealed class YandexLlmProvider : ILlmProvider
{
    private readonly HttpClient _httpClient;
    private readonly LlmOptions _options;
    private readonly ILogger<YandexLlmProvider> _logger;

    public YandexLlmProvider(
        HttpClient httpClient,
        IOptions<LlmOptions> options,
        ILogger<YandexLlmProvider> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _httpClient = httpClient;
        _options = options.Value;
        _logger = logger;
    }

    public string Name => "yandex";

    public IAsyncEnumerable<LlmStreamChunk> CompleteAsync(
        LlmRequest request,
        CancellationToken cancellationToken) =>
        throw new NotImplementedException(
            "Этап 2: адаптер резервного провайдера.");
}
