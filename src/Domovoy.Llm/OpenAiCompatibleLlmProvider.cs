using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Llm;

/// <summary>
/// Адаптер OpenAI-совместимого слоя: GigaChat, Ollama и любой
/// провайдер с тем же контрактом.
///
/// Провайдер задаётся конфигурацией — <c>base_url</c>, <c>api_key</c>,
/// <c>model</c>. Провайдер-специфичных ветвлений вне этого класса нет.
///
/// Каркас: реализация появляется на этапе 2.
/// </summary>
internal sealed class OpenAiCompatibleLlmProvider : ILlmProvider
{
    private readonly HttpClient _httpClient;
    private readonly LlmOptions _options;
    private readonly ILogger<OpenAiCompatibleLlmProvider> _logger;

    public OpenAiCompatibleLlmProvider(
        HttpClient httpClient,
        IOptions<LlmOptions> options,
        ILogger<OpenAiCompatibleLlmProvider> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _httpClient = httpClient;
        _options = options.Value;
        _logger = logger;
    }

    public string Name => "openai-compatible";

    public IAsyncEnumerable<LlmStreamChunk> CompleteAsync(
        LlmRequest request,
        CancellationToken cancellationToken) =>
        throw new NotImplementedException(
            "Этап 2: tool calling и потоковый разбор ответа. Схемы инструментов плоские, максимум 2 уровня.");
}
