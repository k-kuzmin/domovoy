using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using Domovoy.Tests.Ha;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Serilog.Core;
using Serilog.Events;

namespace Domovoy.Tests;

/// <summary>
/// В логах старта нет ни одного значения секрета (#18, правило 3 раздела
/// «Безопасность»).
///
/// Хост поднимается на уровне Verbose — и для Microsoft.AspNetCore — со
/// всеми секретами конфигурации, проходит то, что делает при старте
/// настоящий экземпляр: WebSocket-вход в Home Assistant с токеном и пробы
/// /health, уносящие токен HA и ключ LLM в заголовках. Проверяется
/// отрендеренный текст, свойства и исключения каждого события.
///
/// Класс — в непараллельной коллекции: логгер Serilog статический, и хост
/// соседнего класса, поднятый параллельно, писал бы в этот sink свои
/// события — или забирал бы наши.
/// </summary>
[Collection(OutboundHttpLoggingSerialGroup.Name)]
public sealed class StartupLogSecretsTests : IClassFixture<DomovoyApiFactory>, IAsyncLifetime
{
    // Пробные значения: настоящими секретами не являются и на правилах
    // gitleaks не срабатывают. Админ-токен не короче 32 символов — иначе
    // хост не пройдёт валидацию Auth на старте.
    private const string HaTokenValue = "sampleStartupHaTokenValue5e1c9a";
    private const string LlmApiKeyValue = "sampleStartupLlmApiKeyValue2b7d4f";
    private const string AdminTokenValue = "sampleStartupAdminTokenValue-0123456789";
    private const string NtfyTopicValue = "sample-startup-topic-8a3f";

    private const string WorkerSource = "Domovoy.Ha.WebSocket.HaWebSocketWorker";
    private const string ConnectedTemplatePrefix = "WebSocket-соединение с Home Assistant установлено";
    private const int RequestHeaderEventId = 102;

    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(10);

    private static readonly (string Name, string Value)[] Secrets =
    [
        ("Ha:Token", HaTokenValue),
        ("Llm:ApiKey", LlmApiKeyValue),
        ("Auth:AdminToken", AdminTokenValue),
        ("Ntfy:Topic", NtfyTopicValue),
    ];

    private readonly DomovoyApiFactory _factory;
    private FakeHomeAssistant _fake = null!;

    public StartupLogSecretsTests(DomovoyApiFactory factory) => _factory = factory;

    public async Task InitializeAsync() => _fake = await FakeHomeAssistant.StartAsync(HaTokenValue);

    public async Task DisposeAsync() => await _fake.DisposeAsync();

    [Fact(DisplayName = "Старт на Verbose: ни одно значение секрета не попадает в лог")]
    public async Task StartupLogsCarryNoSecretValues()
    {
        var sink = new CollectingSink();
        using var llmHandler = new OkHandler();

        using WebApplicationFactory<Program> host = _factory.WithWebHostBuilder(builder =>
        {
            // Источник добавляется последним и перекрывает appsettings.
            builder.ConfigureAppConfiguration((_, configuration) =>
                configuration.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["Serilog:MinimumLevel:Default"] = "Verbose",
                    ["Serilog:MinimumLevel:Override:Microsoft.AspNetCore"] = "Verbose",
                    ["Ha:BaseUrl"] = _fake.BaseUrl,
                    ["Ha:Token"] = HaTokenValue,
                    ["Llm:ApiKey"] = LlmApiKeyValue,
                    ["Auth:AdminToken"] = AdminTokenValue,
                    ["Ntfy:Topic"] = NtfyTopicValue,
                }));

            builder.ConfigureTestServices(services =>
            {
                // Подхватывается ReadFrom.Services в конфигурации Serilog.
                services.AddSingleton<ILogEventSink>(sink);

                // Сети нет: проба LLM завершается в заглушке.
                services.AddHttpClient("llm-probe").ConfigurePrimaryHttpMessageHandler(() => llmHandler);
            });
        });

        using HttpClient client = host.CreateClient();

        // Положительный контроль входа: без события «установлено» токен
        // HA до логируемого пути не дошёл, и отсутствие утечки ничего не
        // доказывало бы.
        bool connected = await WaitForAsync(() => sink.Events.Any(IsConnectedEvent), ConnectTimeout);
        connected.Should().BeTrue("WebSocket-воркер обязан войти в фейковый HA с токеном из конфигурации");

        using HttpResponseMessage response = await client.GetAsync(new Uri("/health", UriKind.Relative));
        response.StatusCode.Should().Be(HttpStatusCode.OK);

        List<LogEvent> events = sink.Events.ToList();

        // Положительный контроль уровня: на Verbose пробы пишут заголовки
        // запросов — те самые, в которых уходят токен HA и ключ LLM.
        events.Should().Contain(
            logEvent => SourceContext(logEvent).StartsWith("System.Net.Http.HttpClient.ha-probe.", StringComparison.Ordinal)
                && EventId(logEvent) == RequestHeaderEventId,
            "на уровне Verbose проба HA пишет заголовки запроса");
        events.Should().Contain(
            logEvent => SourceContext(logEvent).StartsWith("System.Net.Http.HttpClient.llm-probe.", StringComparison.Ordinal)
                && EventId(logEvent) == RequestHeaderEventId,
            "на уровне Verbose проба LLM пишет заголовки запроса");

        // Сообщения утверждений называют секрет по ключу конфигурации, но
        // не печатают его значение.
        foreach ((string name, string value) in Secrets)
        {
            int leaks = events.Count(logEvent => Contains(logEvent, value));

            leaks.Should().Be(0, $"значение {name} не должно встречаться ни в тексте, ни в свойствах, ни в исключениях событий");
        }
    }

    private static bool Contains(LogEvent logEvent, string secret) =>
        logEvent.RenderMessage(CultureInfo.InvariantCulture).Contains(secret, StringComparison.Ordinal)
        || logEvent.MessageTemplate.Text.Contains(secret, StringComparison.Ordinal)
        || logEvent.Properties.Values.Any(value => value.ToString().Contains(secret, StringComparison.Ordinal))
        || (logEvent.Exception?.ToString().Contains(secret, StringComparison.Ordinal) ?? false);

    private static bool IsConnectedEvent(LogEvent logEvent) =>
        SourceContext(logEvent) == WorkerSource
        && logEvent.MessageTemplate.Text.StartsWith(ConnectedTemplatePrefix, StringComparison.Ordinal);

    private static async Task<bool> WaitForAsync(Func<bool> condition, TimeSpan timeout)
    {
        using var deadline = new CancellationTokenSource(timeout);
        while (!condition())
        {
            if (deadline.IsCancellationRequested)
            {
                return false;
            }

            await Task.Delay(TimeSpan.FromMilliseconds(50));
        }

        return true;
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

    private sealed class OkHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK));
    }
}
