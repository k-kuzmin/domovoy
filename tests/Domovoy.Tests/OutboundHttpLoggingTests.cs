using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Serilog.Core;
using Serilog.Events;

namespace Domovoy.Tests;

/// <summary>
/// Секреты исходящих запросов не попадают в лог ни на каком уровне
/// (правило 3 раздела «Безопасность»).
///
/// Логирующий обработчик HttpClientFactory на уровне Trace пишет заголовки
/// запроса, а значит и <c>Authorization: Bearer …</c>. Enricher маскирования
/// видит только свойства событий, а не уже отрендеренный текст, поэтому
/// проверка идёт по поведению приложения целиком, а не по одному классу.
///
/// Класс вынесен в непараллельную коллекцию: UseSerilog без
/// preserveStaticLogger кладёт логгер в статический Log.Logger, и хосты
/// соседних тестовых классов, поднятые параллельно, перехватывают события
/// друг друга — собирающий sink увидел бы чужие запросы, а свои потерял.
/// </summary>
[Collection(OutboundHttpLoggingSerialGroup.Name)]
public sealed class OutboundHttpLoggingTests : IClassFixture<WebApplicationFactory<Program>>
{
    // Пробные значения: те же, что подставляет тяжёлый CI. Настоящими
    // секретами не являются и на правилах gitleaks не срабатывают.
    private const string HaTokenValue = "sampleHaTokenValue7f3a2b";
    private const string LlmApiKeyValue = "sampleLlmApiKeyValue4c8d1e";

    private const int RequestHeaderEventId = 102;

    private readonly WebApplicationFactory<Program> _factory;

    public OutboundHttpLoggingTests(WebApplicationFactory<Program> factory) => _factory = factory;

    [Fact(DisplayName = "Токен Home Assistant не попадает в лог даже на уровне Verbose")]
    public async Task HaTokenNeverReachesLogsAtVerbose()
    {
        var sink = new CollectingSink();
        using var haHandler = new RecordingHandler();
        using var llmHandler = new RecordingHandler();

        await RequestHealthAsync(sink, haHandler, llmHandler);

        AssertHeadersLoggedWithoutSecret(sink, "ha-probe", HaTokenValue);
    }

    [Fact(DisplayName = "Ключ LLM не попадает в лог даже на уровне Verbose")]
    public async Task LlmApiKeyNeverReachesLogsAtVerbose()
    {
        var sink = new CollectingSink();
        using var haHandler = new RecordingHandler();
        using var llmHandler = new RecordingHandler();

        await RequestHealthAsync(sink, haHandler, llmHandler);

        AssertHeadersLoggedWithoutSecret(sink, "llm-probe", LlmApiKeyValue);
    }

    [Fact(DisplayName = "Токен из IConfiguration доходит до запроса к Home Assistant")]
    public async Task HaTokenFromConfigurationIsSentToHomeAssistant()
    {
        using var haHandler = new RecordingHandler();
        using var llmHandler = new RecordingHandler();

        await RequestHealthAsync(new CollectingSink(), haHandler, llmHandler);

        haHandler.Authorizations.Should().NotBeEmpty("проба Home Assistant обязана сходить в HA на /health");

        // Сравнение без вывода значения: сообщение assertion не печатает
        // полученный заголовок, даже если он оказался чужим секретом
        // из user-secrets разработчика.
        bool allMatch = haHandler.Authorizations.All(
            value => string.Equals(value, "Bearer " + HaTokenValue, StringComparison.Ordinal));

        allMatch.Should().BeTrue(
            "в запрос к HA уходит токен из конфигурации, маскирование трогает только лог");
    }

    private async Task RequestHealthAsync(
        CollectingSink sink,
        RecordingHandler haHandler,
        RecordingHandler llmHandler)
    {
        using WebApplicationFactory<Program> factory = _factory.WithWebHostBuilder(builder =>
        {
            // Источник добавляется последним и перекрывает appsettings,
            // user-secrets и переменные окружения: в тесте не может
            // оказаться настоящий токен.
            builder.ConfigureAppConfiguration((_, configuration) =>
                configuration.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["Serilog:MinimumLevel:Default"] = "Verbose",
                    ["Ha:Token"] = HaTokenValue,
                    ["Llm:ApiKey"] = LlmApiKeyValue,
                }));

            builder.ConfigureTestServices(services =>
            {
                // Подхватывается ReadFrom.Services в конфигурации Serilog.
                services.AddSingleton<ILogEventSink>(sink);

                // Сети нет: запросы проб завершаются в заглушке.
                services.AddHttpClient("ha-probe").ConfigurePrimaryHttpMessageHandler(() => haHandler);
                services.AddHttpClient("llm-probe").ConfigurePrimaryHttpMessageHandler(() => llmHandler);
            });
        });

        using HttpClient client = factory.CreateClient();

        using HttpResponseMessage response = await client.GetAsync(new Uri("/health", UriKind.Relative));
    }

    private static void AssertHeadersLoggedWithoutSecret(CollectingSink sink, string clientName, string secret)
    {
        List<LogEvent> events = sink.Events.ToList();
        string sourcePrefix = "System.Net.Http.HttpClient." + clientName + ".";

        // Положительный контроль: без событий заголовков отсутствие
        // секрета ничего не доказывает — уровень или sink не применились.
        events.Should().Contain(
            logEvent => SourceContext(logEvent).StartsWith(sourcePrefix, StringComparison.Ordinal)
                && EventId(logEvent) == RequestHeaderEventId,
            $"на уровне Verbose клиент {clientName} пишет заголовки запроса");

        int leaks = events.Count(logEvent =>
            logEvent.RenderMessage(CultureInfo.InvariantCulture).Contains(secret, StringComparison.Ordinal)
            || logEvent.Properties.Values.Any(
                value => value.ToString().Contains(secret, StringComparison.Ordinal)));

        leaks.Should().Be(0, "значение секрета не должно встречаться ни в тексте, ни в свойствах событий");
    }

    private static string SourceContext(LogEvent logEvent) =>
        logEvent.Properties.TryGetValue("SourceContext", out LogEventPropertyValue? value)
            && value is ScalarValue { Value: string context }
            ? context
            : string.Empty;

    private static int? EventId(LogEvent logEvent)
    {
        if (!logEvent.Properties.TryGetValue("EventId", out LogEventPropertyValue? value)
            || value is not StructureValue structure)
        {
            return null;
        }

        LogEventProperty? id = structure.Properties.FirstOrDefault(property => property.Name == "Id");

        return id?.Value is ScalarValue { Value: int number } ? number : null;
    }

    private sealed class CollectingSink : ILogEventSink
    {
        private readonly ConcurrentQueue<LogEvent> _events = new();

        public IEnumerable<LogEvent> Events => _events;

        public void Emit(LogEvent logEvent) => _events.Enqueue(logEvent);
    }

    private sealed class RecordingHandler : HttpMessageHandler
    {
        private readonly ConcurrentQueue<string> _authorizations = new();

        public IReadOnlyCollection<string> Authorizations => _authorizations;

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            _authorizations.Enqueue(request.Headers.Authorization?.ToString() ?? string.Empty);

            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK));
        }
    }
}

/// <summary>
/// Коллекция без параллельного запуска для тестов, читающих события
/// логгера, общего для всех хостов процесса.
/// </summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class OutboundHttpLoggingSerialGroup
{
    public const string Name = "OutboundHttpLogging";
}
