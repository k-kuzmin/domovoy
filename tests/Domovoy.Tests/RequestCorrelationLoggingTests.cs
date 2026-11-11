using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;
using Domovoy.Tests.Auth;
using Domovoy.Tests.Ha;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using NSubstitute;
using Serilog.Core;
using Serilog.Events;
using Serilog.Formatting.Display;

namespace Domovoy.Tests;

/// <summary>
/// Корреляция логов по request_id (NFR-OBS-1, #18): каждое событие пути
/// запроса — от входа через вызов Home Assistant до ответа — несёт свойство
/// <c>RequestId</c> с одним значением, и это значение стоит в тексте строки
/// лога, отрендеренной шаблоном консоли из <c>appsettings.json</c>: grep по
/// нему находит весь путь.
///
/// Свойство приходит из области логирования хостинга ASP.NET Core
/// (<c>RequestId</c> = <c>HttpContext.TraceIdentifier</c>), которую провайдер
/// Serilog переводит в свойства событий. Своего кода у механизма нет, поэтому
/// его закрепляют эти тесты, а не тесты класса.
///
/// События пути отбираются по источнику и окну времени запроса, а не по
/// свойствам той же области (<c>RequestPath</c>): событие, потерявшее
/// область целиком, иначе выпало бы из проверки и тест остался бы зелёным.
/// Фоновые источники, которые пишут вне запроса, исключаются явным списком.
///
/// Коллекция непараллельная по той же причине, что у
/// <see cref="OutboundHttpLoggingTests"/>: статический Log.Logger общий для
/// хостов процесса.
/// </summary>
[Collection(OutboundHttpLoggingSerialGroup.Name)]
public sealed class RequestCorrelationLoggingTests : IClassFixture<DomovoyApiFactory>, IAsyncLifetime
{
    private const string HaToken = "correlation-test-ha-token";
    private const string LlmApiKey = "correlation-test-llm-key";
    private const string UnreachableLlmBaseUrl = "http://127.0.0.1:9/v1";

    private const string ChatPath = "/api/v1/chat";
    private const string ComponentHealthPath = "/api/v1/health";
    private const string JsonMediaType = "application/json";
    private const string KitchenLight = "light.example_kitchen_ceiling";
    private const string TurnOnPath = "/api/services/light/turn_on";

    private const string RequestIdProperty = "RequestId";
    private const string CompletionSource = "Serilog.AspNetCore.RequestLoggingMiddleware";
    private const string HostingDiagnosticsSource = "Microsoft.AspNetCore.Hosting.Diagnostics";
    private const string ChatEndpointsSource = "Domovoy.Api.Endpoints.ChatEndpoints";
    private const string HaClientPrefix = "System.Net.Http.HttpClient.ha.";
    private const string LlmProbeClientPrefix = "System.Net.Http.HttpClient.llm-probe.";
    private const int RequestStartingEventId = 1;

    /// <summary>Источники путевых событий: код продукта, завершение запроса, клиент HA.</summary>
    private static readonly string[] PathSourcePrefixes = ["Domovoy.", "Serilog.AspNetCore.", HaClientPrefix];

    /// <summary>Фоновые источники: пишут вне запроса и RequestId нести не обязаны.</summary>
    private static readonly string[] BackgroundSources =
    [
        "Domovoy.Ha.WebSocket.HaWebSocketWorker",
        "Domovoy.Notifications.ProactivityWorker",
    ];

    private static readonly TimeSpan CompletionWait = TimeSpan.FromSeconds(10);

    private readonly DomovoyApiFactory _factory;
    private FakeHomeAssistant _fake = null!;

    public RequestCorrelationLoggingTests(DomovoyApiFactory factory) => _factory = factory;

    public async Task InitializeAsync()
    {
        _fake = await FakeHomeAssistant.StartAsync(HaToken);
        _fake.WebSocketMode = FakeWebSocketMode.Down;
        _fake.SetState(KitchenLight, "off");
    }

    public async Task DisposeAsync() => await _fake.DisposeAsync();

    [Fact(DisplayName = "RequestId из ответа /chat — в каждом событии пути до вызова HA и обратно на боевых уровнях")]
    public async Task RequestIdReachesEveryEventOnChatPathAtDefaultLevels()
    {
        var sink = new CollectingSink();
        using WebApplicationFactory<Program> host = CreateChatHost(sink, SubstituteLlm);
        using HttpClient client = host.CreateClient();
        string token = await AuthTestApi.PairAsync(client);

        DateTimeOffset started = DateTimeOffset.Now;
        using HttpResponseMessage response = await PostChatAsync(client, token);
        string raw = await response.Content.ReadAsStringAsync();
        response.StatusCode.Should().Be(HttpStatusCode.OK, raw);
        string requestId;
        using (JsonDocument body = JsonDocument.Parse(raw))
        {
            requestId = body.RootElement.GetProperty("request_id").GetString()!;
        }

        requestId.Should().NotBeNullOrWhiteSpace();
        LogEvent completion = await WaitForCompletionAsync(sink, ChatPath, started);
        List<LogEvent> pathEvents = PathEvents(sink, started, completion.Timestamp);

        // Положительный контроль: без вызова HA и события завершения в окне
        // равенство ниже ничего бы не доказывало.
        pathEvents.Should().Contain(
            logEvent => SourceContext(logEvent).StartsWith(HaClientPrefix, StringComparison.Ordinal)
                && Render(logEvent).Contains(TurnOnPath, StringComparison.Ordinal),
            "клиент ha пишет события вызова сервиса HA");
        pathEvents.Should().Contain(completion, "событие завершения запроса входит в путь");

        AssertAllCarry(pathEvents, requestId);
    }

    [Fact(DisplayName = "Предупреждение ChatEndpoints при отказе оркестратора несёт RequestId запроса")]
    public async Task RequestIdReachesProductWarningOnChatFailure()
    {
        var sink = new CollectingSink();
        using WebApplicationFactory<Program> host = CreateChatHost(sink, services =>
        {
            SubstituteLlm(services);
            services.RemoveAll<IOrchestrator>();
            services.AddSingleton<IOrchestrator>(new FailingOrchestrator());
        });
        using HttpClient client = host.CreateClient();
        string token = await AuthTestApi.PairAsync(client);

        DateTimeOffset started = DateTimeOffset.Now;
        using HttpResponseMessage response = await PostChatAsync(client, token);
        response.StatusCode.Should().Be(HttpStatusCode.InternalServerError);
        LogEvent completion = await WaitForCompletionAsync(sink, ChatPath, started);
        string requestId = CompletionRequestId(completion);

        List<LogEvent> warnings = PathEvents(sink, started, completion.Timestamp)
            .Where(logEvent => SourceContext(logEvent) == ChatEndpointsSource
                && logEvent.Level == LogEventLevel.Warning)
            .ToList();

        warnings.Should().ContainSingle("отказ оркестратора пишется одним предупреждением");
        AssertAllCarry(warnings, requestId);
    }

    [Fact(DisplayName = "RequestId доходит до событий пробы LLM на пути GET /api/v1/health")]
    public async Task RequestIdReachesProbeEventsOnHealthPath()
    {
        var sink = new CollectingSink();

        // Ha:Token не задан: WebSocket-воркер не подключается и не ходит
        // фоном клиентом ha-probe, в окно запроса чужие события не попадают.
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(
            _factory,
            services =>
            {
                services.AddSingleton<ILogEventSink>(sink);
                services.AddHttpClient("llm-probe").ConfigurePrimaryHttpMessageHandler(() => new OkHandler());
            },
            new Dictionary<string, string?> { ["Llm:ApiKey"] = LlmApiKey });
        using HttpClient client = host.CreateClient();
        DateTimeOffset pairingStarted = DateTimeOffset.Now;
        string token = await AuthTestApi.PairAsync(client);
        LogEvent pairing = await WaitForCompletionAsync(sink, AuthTestApi.PairingPath, pairingStarted);

        DateTimeOffset started = DateTimeOffset.Now;
        using HttpResponseMessage response = await AuthTestApi.SendAsync(
            client,
            HttpMethod.Get,
            ComponentHealthPath,
            token);
        response.StatusCode.Should().Be(HttpStatusCode.OK, await response.Content.ReadAsStringAsync());
        LogEvent completion = await WaitForCompletionAsync(sink, ComponentHealthPath, started);
        string requestId = CompletionRequestId(completion);

        List<LogEvent> probeEvents = EventsInWindow(sink, started, completion.Timestamp)
            .Where(logEvent => SourceContext(logEvent).StartsWith(LlmProbeClientPrefix, StringComparison.Ordinal))
            .ToList();

        probeEvents.Should().NotBeEmpty("проба LLM ходит к провайдеру клиентом llm-probe");
        AssertAllCarry(probeEvents, requestId);
        RequestId(pairing).Should().NotBe(
            requestId,
            "свойство различает запросы, а не одинаково у всех событий хоста");
    }

    [Fact(DisplayName = "Вход, вызов HA и выход /chat связаны одним RequestId при логах хостинга на Information")]
    public async Task RequestIdReachesEntryEventWhenHostingLogsEnabled()
    {
        var sink = new CollectingSink();
        using WebApplicationFactory<Program> host = CreateChatHost(
            sink,
            SubstituteLlm,
            new Dictionary<string, string?> { ["Serilog:MinimumLevel:Override:Microsoft.AspNetCore"] = "Information" });
        using HttpClient client = host.CreateClient();
        string token = await AuthTestApi.PairAsync(client);

        DateTimeOffset started = DateTimeOffset.Now;
        using HttpResponseMessage response = await PostChatAsync(client, token);
        response.StatusCode.Should().Be(HttpStatusCode.OK, await response.Content.ReadAsStringAsync());
        LogEvent completion = await WaitForCompletionAsync(sink, ChatPath, started);
        string requestId = CompletionRequestId(completion);

        List<LogEvent> window = EventsInWindow(sink, started, completion.Timestamp);
        LogEvent entry = window.Should().ContainSingle(
            logEvent => SourceContext(logEvent) == HostingDiagnosticsSource
                && EventId(logEvent) == RequestStartingEventId
                && Render(logEvent).Contains(ChatPath, StringComparison.Ordinal),
            "при Microsoft.AspNetCore на Information хостинг пишет вход запроса").Subject;
        List<LogEvent> haCalls = window
            .Where(logEvent => SourceContext(logEvent).StartsWith(HaClientPrefix, StringComparison.Ordinal))
            .ToList();
        haCalls.Should().NotBeEmpty("путь /chat вызывает HA клиентом ha");

        AssertAllCarry([entry, .. haCalls, completion], requestId);
    }

    private WebApplicationFactory<Program> CreateChatHost(
        CollectingSink sink,
        Action<IServiceCollection> services,
        IReadOnlyDictionary<string, string?>? extra = null)
    {
        var settings = new Dictionary<string, string?>(StringComparer.Ordinal)
        {
            ["Ha:BaseUrl"] = _fake.BaseUrl,
            ["Ha:Token"] = HaToken,
            ["Llm:BaseUrl"] = UnreachableLlmBaseUrl,
            ["Llm:ApiKey"] = LlmApiKey,
        };
        foreach (KeyValuePair<string, string?> setting in extra ?? new Dictionary<string, string?>())
        {
            settings[setting.Key] = setting.Value;
        }

        return AuthTestApi.WithAdmin(
            _factory,
            collection =>
            {
                // Подхватывается ReadFrom.Services в конфигурации Serilog.
                collection.AddSingleton<ILogEventSink>(sink);
                services(collection);
            },
            settings);
    }

    private static void SubstituteLlm(IServiceCollection services)
    {
        services.RemoveAll<ILlmProvider>();
        services.AddSingleton(Substitute.For<ILlmProvider>());
    }

    private static async Task<HttpResponseMessage> PostChatAsync(HttpClient client, string token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(ChatPath, UriKind.Relative));
        request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);
        request.Headers.TryAddWithoutValidation("Accept", JsonMediaType);
        request.Content = new StringContent("""{"text":"включи свет на кухне"}""", Encoding.UTF8, JsonMediaType);
        return await client.SendAsync(request);
    }

    /// <summary>
    /// Событие завершения запроса по пути: пишется после ответа обработчика,
    /// поэтому ждётся по условию, а не паузой. Его отметка времени — верхняя
    /// граница окна событий пути.
    /// </summary>
    private static async Task<LogEvent> WaitForCompletionAsync(CollectingSink sink, string path, DateTimeOffset since)
    {
        DateTimeOffset deadline = DateTimeOffset.Now + CompletionWait;
        while (true)
        {
            LogEvent? completion = sink.Events.FirstOrDefault(logEvent =>
                logEvent.Timestamp >= since
                && SourceContext(logEvent) == CompletionSource
                && ScalarString(logEvent, "RequestPath") == path);
            if (completion is not null)
            {
                return completion;
            }

            if (DateTimeOffset.Now > deadline)
            {
                throw new TimeoutException($"событие завершения {CompletionSource} для {path} не появилось за {CompletionWait}");
            }

            await Task.Delay(TimeSpan.FromMilliseconds(20));
        }
    }

    private static List<LogEvent> EventsInWindow(CollectingSink sink, DateTimeOffset from, DateTimeOffset to) =>
        [.. sink.Events.Where(logEvent => logEvent.Timestamp >= from && logEvent.Timestamp <= to)];

    private static List<LogEvent> PathEvents(CollectingSink sink, DateTimeOffset from, DateTimeOffset to) =>
        [.. EventsInWindow(sink, from, to).Where(logEvent =>
        {
            string source = SourceContext(logEvent);
            return PathSourcePrefixes.Any(prefix => source.StartsWith(prefix, StringComparison.Ordinal))
                && !BackgroundSources.Contains(source, StringComparer.Ordinal);
        })];

    /// <summary>
    /// Каждое событие несёт свойство RequestId с ожидаемым значением, и
    /// строка, отрендеренная шаблоном консоли, содержит это значение.
    /// </summary>
    private static void AssertAllCarry(IReadOnlyCollection<LogEvent> events, string requestId)
    {
        events.Should().NotBeEmpty();

        string[] withoutProperty = [.. events
            .Where(logEvent => RequestId(logEvent) != requestId)
            .Select(Describe)];
        withoutProperty.Should().BeEmpty($"каждое событие пути несёт {RequestIdProperty} = {requestId}");

        string[] withoutText = [.. events
            .Where(logEvent => !Render(logEvent).Contains(requestId, StringComparison.Ordinal))
            .Select(Describe)];
        withoutText.Should().BeEmpty($"строка лога по шаблону консоли содержит {requestId} — её находит grep");
    }

    private static string Describe(LogEvent logEvent) =>
        $"{SourceContext(logEvent)} [{logEvent.MessageTemplate.Text}] {RequestIdProperty}={RequestId(logEvent)}";

    /// <summary>Строка лога так, как её печатает консоль: шаблон вывода из appsettings.json.</summary>
    private static string Render(LogEvent logEvent)
    {
        using var writer = new StringWriter(CultureInfo.InvariantCulture);
        ConsoleFormatter.Value.Format(logEvent, writer);
        return writer.ToString();
    }

    private static readonly Lazy<MessageTemplateTextFormatter> ConsoleFormatter = new(() =>
    {
        using JsonDocument settings = JsonDocument.Parse(
            File.ReadAllText(RepositoryLayout.Path("src", "Domovoy.Api", "appsettings.json")));
        string template = settings.RootElement
            .GetProperty("Serilog")
            .GetProperty("WriteTo")[0]
            .GetProperty("Args")
            .GetProperty("outputTemplate")
            .GetString()!;
        return new MessageTemplateTextFormatter(template, CultureInfo.InvariantCulture);
    });

    private static string? RequestId(LogEvent logEvent) => ScalarString(logEvent, RequestIdProperty);

    /// <summary>TraceIdentifier запроса — из события его завершения.</summary>
    private static string CompletionRequestId(LogEvent completion)
    {
        string? requestId = RequestId(completion);
        requestId.Should().NotBeNullOrEmpty("событие завершения несёт TraceIdentifier запроса");
        return requestId!;
    }

    private static string SourceContext(LogEvent logEvent) => ScalarString(logEvent, "SourceContext") ?? string.Empty;

    private static string? ScalarString(LogEvent logEvent, string property) =>
        logEvent.Properties.TryGetValue(property, out LogEventPropertyValue? value)
            && value is ScalarValue { Value: string text }
            ? text
            : null;

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

    /// <summary>Провайдер LLM отвечает 200 на пробу без выхода в сеть.</summary>
    private sealed class OkHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK));
    }

    /// <summary>Оркестратор, отказывающий при перечислении — там же, где отказал бы настоящий.</summary>
    private sealed class FailingOrchestrator : IOrchestrator
    {
        public async IAsyncEnumerable<AgentEvent> HandleAsync(
            AgentRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken)
        {
            await Task.Yield();
            Fail();
            yield break;
        }

        private static void Fail() => throw new InvalidOperationException("оркестратор недоступен");
    }
}
