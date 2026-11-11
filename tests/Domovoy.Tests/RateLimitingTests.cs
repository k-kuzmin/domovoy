using System.Collections.Concurrent;
using System.Diagnostics.Metrics;
using System.Globalization;
using System.Net;
using System.Text.Json;
using Domovoy.Tests.Auth;
using FluentAssertions;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using Serilog.Core;
using Serilog.Events;
using Serilog.Formatting.Display;

namespace Domovoy.Tests;

/// <summary>
/// Ограничение частоты запросов (#17, NFR-SEC-3): общий предел на каждый
/// маршрут по разделу (устройство, админ, анонимная конечная точка, петля),
/// более жёсткий общий на дом предел на <c>/chat</c> и <c>/voice</c>, 429 в
/// едином формате с <c>Retry-After</c>, встроенная метрика и предупреждение
/// в логе с RequestId отклонённого запроса.
///
/// Тесты видят лимитер только снаружи: через HTTP, ключи конфигурации и
/// имена встроенной метрики ASP.NET Core. Типов реализации они не
/// называют. Каждый тест поднимает свой хост с малыми пределами: лимитер
/// общий на хост, а фабрика для остальных тестов поднимает пределы так,
/// что они не срабатывают.
///
/// Окно фиксированное, минута; серия запросов занимает доли секунды, а
/// окно раздела начинается с первого запроса в нём, поэтому граница окна
/// внутри серии не оказывается.
///
/// Коллекция непараллельная по той же причине, что у
/// <see cref="RequestCorrelationLoggingTests"/>: тест лога читает события
/// логгера, общего для хостов процесса.
/// </summary>
[Collection(OutboundHttpLoggingSerialGroup.Name)]
public sealed class RateLimitingTests : IClassFixture<DomovoyApiFactory>
{
    private const string RequestsPerMinuteKey = "RateLimit:RequestsPerMinute";
    private const string LlmRequestsPerMinuteKey = "RateLimit:LlmRequestsPerMinute";

    private const string ChatPath = "/api/v1/chat";
    private const string VoicePath = "/api/v1/voice";
    private const string StatePath = "/api/v1/state";
    private const string AdminPathPrefix = "/api/v1/admin/";
    private const string UnknownPath = "/no-such-path";

    private const string RateLimitedCode = "rate_limited";

    private const string RateLimitingMeter = "Microsoft.AspNetCore.RateLimiting";
    private const string RequestsInstrument = "aspnetcore.rate_limiting.requests";
    private const string ResultTag = "aspnetcore.rate_limiting.result";
    private const string PolicyTag = "aspnetcore.rate_limiting.policy";
    private const string AcquiredResult = "acquired";

    private const string LimiterSource = "Domovoy.Api.Security.ApiRateLimits";
    private const string CompletionSource = "Serilog.AspNetCore.RequestLoggingMiddleware";

    private static readonly TimeSpan CompletionWait = TimeSpan.FromSeconds(10);

    private readonly DomovoyApiFactory _factory;

    public RateLimitingTests(DomovoyApiFactory factory) => _factory = factory;

    [Fact(DisplayName = "Каждый маршрут сверх серии в своём разделе отвечает 429 rate_limited с Retry-After")]
    public async Task EveryRouteAnswers429WithRetryAfterBeyondItsOwnSeries()
    {
        const int limit = 4;
        const int llmLimit = 2;

        List<(string Method, string Path)> routes;
        using (WebApplicationFactory<Program> inventory = Host(limit, llmLimit))
        {
            routes = RouteAuthenticationAudit.Routes(inventory.Services);
        }

        routes.Should().NotBeEmpty();

        // Свежий хост на каждый маршрут: раздел исчерпывается запросами к
        // самому проверяемому маршруту, а не наследуется исчерпанным
        // соседом — так маршрут без лимита не спрячется за чужим 429.
        var violations = new List<string>();
        foreach ((string method, string path) in routes)
        {
            using WebApplicationFactory<Program> host = Host(limit, llmLimit);
            using HttpClient client = host.CreateClient();
            string? bearer = await BearerForAsync(client, method, path);
            int allowed = IsLlmRoute(method, path) ? llmLimit : limit;

            string? violation = await SeriesViolationAsync(client, new HttpMethod(method), path, bearer, allowed);
            if (violation is not null)
            {
                violations.Add($"{method} {path}: {violation}");
            }
        }

        // Строкой, а не коллекцией: сообщение называет каждый маршрут без
        // лимита, а не первый из них.
        string.Join(Environment.NewLine, violations).Should().BeEmpty(
            "каждый маршрут ограничен: серия до предела проходит, следующий запрос — 429 в едином формате");
    }

    [Fact(DisplayName = "Порог берётся из конфигурации: в пределе — ответ, сверх него — 429")]
    public async Task RequestsWithinLimitPassAndBeyondItAreRejected()
    {
        using (WebApplicationFactory<Program> host = Host(3, 2))
        using (HttpClient client = host.CreateClient())
        {
            List<HttpStatusCode> statuses = await GetSeriesAsync(client, RouteAuthenticationAudit.LivenessPath, 5);

            statuses.Should().Equal(
                [HttpStatusCode.OK, HttpStatusCode.OK, HttpStatusCode.OK, HttpStatusCode.TooManyRequests, HttpStatusCode.TooManyRequests],
                "при RateLimit:RequestsPerMinute = 3 три запроса проходят, остальные отклоняются");
        }

        using (WebApplicationFactory<Program> host = Host(5, 2))
        using (HttpClient client = host.CreateClient())
        {
            List<HttpStatusCode> statuses = await GetSeriesAsync(client, RouteAuthenticationAudit.LivenessPath, 6);

            statuses.Take(5).Should().AllBeEquivalentTo(HttpStatusCode.OK, "при пределе 5 пятый запрос ещё проходит");
            statuses[5].Should().Be(HttpStatusCode.TooManyRequests, "шестой запрос сверх предела 5");
        }
    }

    [Fact(DisplayName = "/chat и /voice делят более жёсткий предел на дом, остальные маршруты обслуживаются")]
    public async Task ChatAndVoiceShareStricterLimitWhileOtherRoutesStillServe()
    {
        using WebApplicationFactory<Program> host = Host(20, 2);
        using HttpClient client = host.CreateClient();
        string first = await AuthTestApi.PairAsync(client, "llm-first");
        string second = await AuthTestApi.PairAsync(client, "llm-second");

        using (HttpResponseMessage chat = await AuthTestApi.SendAsync(client, HttpMethod.Post, ChatPath, first))
        {
            chat.StatusCode.Should().NotBe(HttpStatusCode.TooManyRequests, "первый запрос к llm-маршрутам в пределе");
        }

        using (HttpResponseMessage voice = await AuthTestApi.SendAsync(client, HttpMethod.Post, VoicePath, first))
        {
            voice.StatusCode.Should().NotBe(HttpStatusCode.TooManyRequests, "второй запрос к llm-маршрутам в пределе");
        }

        using (HttpResponseMessage limited = await AuthTestApi.SendAsync(client, HttpMethod.Post, ChatPath, first))
        {
            (await RejectionViolationAsync(limited)).Should().BeNull(
                "третий запрос к /chat или /voice сверх RateLimit:LlmRequestsPerMinute = 2");
        }

        using (HttpResponseMessage state = await AuthTestApi.SendAsync(client, HttpMethod.Get, StatePath, first))
        {
            state.StatusCode.Should().NotBe(HttpStatusCode.TooManyRequests, "общий предел устройства 20 не исчерпан");
        }

        using HttpResponseMessage other = await AuthTestApi.SendAsync(client, HttpMethod.Post, ChatPath, second);

        (await RejectionViolationAsync(other)).Should().BeNull("предел /chat и /voice один на дом, а не на устройство");
    }

    [Fact(DisplayName = "Предел /chat и /voice не строже общего — отказ старта с именами обоих ключей")]
    public void LlmLimitNotStricterThanGeneralFailsStart()
    {
        using (WebApplicationFactory<Program> host = Host(5, 5))
        {
            Action start = () => host.CreateClient().Dispose();

            OptionsValidationException failure = start.Should().Throw<OptionsValidationException>().Which;
            failure.Message.Should().Contain(LlmRequestsPerMinuteKey).And.Contain(RequestsPerMinuteKey);
        }

        using (WebApplicationFactory<Program> host = Host(5, 4))
        {
            Action start = () => host.CreateClient().Dispose();

            start.Should().NotThrow("предел /chat и /voice строго меньше общего");
        }
    }

    [Fact(DisplayName = "Исчерпанный раздел не задевает петлю контейнера и другое устройство")]
    public async Task LoopbackAndOtherDevicesKeepServiceWhenOnePartitionIsExhausted()
    {
        using WebApplicationFactory<Program> host = Host(3, 2);
        using HttpClient client = host.CreateClient();

        List<HttpStatusCode> outside = await GetSeriesAsync(client, RouteAuthenticationAudit.LivenessPath, 4);
        outside[^1].Should().Be(HttpStatusCode.TooManyRequests, "раздел /health снаружи исчерпан");

        HttpContext loopback = await host.Server.SendAsync(context =>
        {
            context.Request.Method = HttpMethods.Get;
            context.Request.Path = RouteAuthenticationAudit.LivenessPath;
            context.Connection.RemoteIpAddress = IPAddress.Loopback;
        });
        loopback.Response.StatusCode.Should().Be(
            StatusCodes.Status200OK,
            "healthcheck контейнера ходит с петли и делит раздел не с внешними запросами");

        string deviceA = await AuthTestApi.PairAsync(client, "partition-a");
        string deviceB = await AuthTestApi.PairAsync(client, "partition-b");

        for (int attempt = 0; attempt < 3; attempt++)
        {
            using HttpResponseMessage allowed = await AuthTestApi.SendAsync(client, HttpMethod.Get, StatePath, deviceA);
            allowed.StatusCode.Should().NotBe(HttpStatusCode.TooManyRequests);
        }

        using (HttpResponseMessage exhausted = await AuthTestApi.SendAsync(client, HttpMethod.Get, StatePath, deviceA))
        {
            exhausted.StatusCode.Should().Be(HttpStatusCode.TooManyRequests, "раздел устройства A исчерпан");
        }

        using HttpResponseMessage other = await AuthTestApi.SendAsync(client, HttpMethod.Get, StatePath, deviceB);

        other.StatusCode.Should().NotBe(HttpStatusCode.TooManyRequests, "у устройства B свой раздел");
    }

    [Fact(DisplayName = "Поток сканера на несуществующий путь и на /health не закрывает привязку")]
    public async Task ScannerFloodDoesNotLockOutPairingOrConsumeOnUnknownPaths()
    {
        const int limit = 120;
        const int flood = 130;

        using WebApplicationFactory<Program> host = Host(limit, 10);
        using HttpClient client = host.CreateClient();

        var unknown = new List<string>();
        for (int attempt = 0; attempt < flood; attempt++)
        {
            using HttpResponseMessage response = await client.GetAsync(new Uri(UnknownPath, UriKind.Relative));
            if (response.StatusCode != HttpStatusCode.Unauthorized
                || await AuthTestApi.ReadErrorCodeAsync(response) != "unauthorized")
            {
                unknown.Add($"запрос {attempt + 1}: {(int)response.StatusCode}");
            }
        }

        unknown.Should().BeEmpty("запрос на несуществующий путь останавливает авторизация, до лимитера он не доходит");

        // Первый запрос раздела /health — сразу после потока: если поток
        // тратил общий раздел, здесь уже 429.
        var health = new List<HttpStatusCode>();
        health.AddRange(await GetSeriesAsync(client, RouteAuthenticationAudit.LivenessPath, flood));

        health[0].Should().Be(HttpStatusCode.OK, "поток на несуществующий путь раздел /health не тратит");
        health.Take(limit).Should().AllBeEquivalentTo(HttpStatusCode.OK, "в пределе 120 запросов /health обслуживаются");
        health.Skip(limit).Should().AllBeEquivalentTo(HttpStatusCode.TooManyRequests, "с 121-го запроса раздел /health исчерпан");

        using HttpResponseMessage pairing = await AuthTestApi.RedeemAsync(client, "ZZZZZZZZ");

        pairing.StatusCode.Should().NotBe(HttpStatusCode.TooManyRequests, "у обмена кода привязки свой раздел");
    }

    [Fact(DisplayName = "Отказы считает встроенный счётчик aspnetcore.rate_limiting.requests")]
    public async Task RejectionsAreCountedByBuiltInRateLimitingMeter()
    {
        // Общий предел с запасом над llm-пределом: middleware ASP.NET Core 8
        // после отказа политики повторяет захват путём ожидания и тратит
        // ещё одно разрешение общего раздела — при общем пределе 3 третий
        // /voice отклонил бы общий лимитер, а не политика llm.
        using WebApplicationFactory<Program> host = Host(5, 2);
        using HttpClient client = host.CreateClient();
        IMeterFactory meterFactory = host.Services.GetRequiredService<IMeterFactory>();

        var measurements = new ConcurrentQueue<(long Value, Dictionary<string, string?> Tags)>();
        using var listener = new MeterListener();
        listener.InstrumentPublished = (instrument, meterListener) =>
        {
            // Счётчик именно этого хоста: хосты параллельных тестов
            // публикуют тот же инструмент со своей фабрикой метров.
            if (instrument.Meter.Name == RateLimitingMeter
                && instrument.Name == RequestsInstrument
                && ReferenceEquals(instrument.Meter.Scope, meterFactory))
            {
                meterListener.EnableMeasurementEvents(instrument);
            }
        };
        listener.SetMeasurementEventCallback<long>((_, value, tags, _) =>
        {
            var copy = new Dictionary<string, string?>(StringComparer.Ordinal);
            foreach (KeyValuePair<string, object?> tag in tags)
            {
                copy[tag.Key] = tag.Value?.ToString();
            }

            measurements.Enqueue((value, copy));
        });
        listener.Start();

        string token = await AuthTestApi.PairAsync(client);

        var statuses = new List<HttpStatusCode>();
        statuses.AddRange(await GetSeriesAsync(client, RouteAuthenticationAudit.LivenessPath, 6));
        for (int attempt = 0; attempt < 3; attempt++)
        {
            using HttpResponseMessage voice = await AuthTestApi.SendAsync(client, HttpMethod.Post, VoicePath, token);
            statuses.Add(voice.StatusCode);
        }

        List<(long Value, Dictionary<string, string?> Tags)> rejected =
            [.. measurements.Where(measurement => Tag(measurement.Tags, ResultTag) != AcquiredResult)];

        rejected.Should().Contain(
            measurement => Tag(measurement.Tags, ResultTag) == "global_limiter",
            "отказ общего предела на /health виден в метрике");
        rejected.Should().Contain(
            measurement => Tag(measurement.Tags, ResultTag) == "endpoint_limiter"
                && Tag(measurement.Tags, PolicyTag) == "llm",
            "отказ /voice сверх llm-предела виден в метрике с именем политики");
        rejected.Sum(measurement => measurement.Value).Should().Be(
            statuses.Count(status => status == HttpStatusCode.TooManyRequests),
            "одно отказное измерение на каждый ответ 429");
    }

    [Fact(DisplayName = "Предупреждение об отказе несёт RequestId отклонённого запроса и не несёт токена")]
    public async Task RejectionWarningCarriesRequestIdOfRejectedRequest()
    {
        var sink = new CollectingSink();
        using WebApplicationFactory<Program> host = Host(
            2,
            1,
            services => services.AddSingleton<ILogEventSink>(sink)); // Подхватывается ReadFrom.Services.
        using HttpClient client = host.CreateClient();
        string token = await AuthTestApi.PairAsync(client);

        DateTimeOffset started = DateTimeOffset.Now;
        var statuses = new List<HttpStatusCode>();
        for (int attempt = 0; attempt < 3; attempt++)
        {
            using HttpResponseMessage state = await AuthTestApi.SendAsync(client, HttpMethod.Get, StatePath, token);
            statuses.Add(state.StatusCode);
        }

        statuses.AddRange(await GetSeriesAsync(client, RouteAuthenticationAudit.LivenessPath, 3));

        int rejectedCount = statuses.Count(status => status == HttpStatusCode.TooManyRequests);
        rejectedCount.Should().Be(2, "третий запрос к /state и третий к /health — сверх предела 2");

        List<LogEvent> completions = await WaitForRejectedCompletionsAsync(sink, started, rejectedCount);
        List<LogEvent> warnings = [.. sink.Events.Where(logEvent =>
            logEvent.Timestamp >= started
            && SourceContext(logEvent) == LimiterSource
            && logEvent.Level == LogEventLevel.Warning)];

        warnings.Should().HaveCount(rejectedCount, "на каждый 429 — ровно одно предупреждение лимитера");
        foreach (LogEvent completion in completions)
        {
            string? requestId = ScalarString(completion, "RequestId");
            requestId.Should().NotBeNullOrEmpty("событие завершения несёт TraceIdentifier запроса");
            warnings.Should().ContainSingle(
                warning => ScalarString(warning, "RequestId") == requestId,
                "предупреждение связано с отклонённым запросом его RequestId");
        }

        warnings.Select(warning => ScalarString(warning, "RateLimitPartition")).Should().BeEquivalentTo(
            ["device", "anonymous"],
            "лог называет вид раздела, а не идентификатор устройства");
        warnings.Should().OnlyContain(warning => !string.IsNullOrEmpty(ScalarString(warning, "RateLimitEndpoint")));

        sink.Events.Select(Render).Should().NotContain(
            line => line.Contains(token, StringComparison.Ordinal),
            "токен устройства не логируется никогда");
    }

    /// <summary>
    /// Хост фабрики с админ-секретом и пределами лимитера. Оба предела
    /// задаются всегда: фабрика поднимает их для остальных тестов, и
    /// заданный здесь общий предел без llm-предела оказался бы меньше
    /// фабричного llm-предела.
    /// </summary>
    private WebApplicationFactory<Program> Host(
        int requestsPerMinute,
        int llmRequestsPerMinute,
        Action<IServiceCollection>? services = null) =>
        AuthTestApi.WithAdmin(
            _factory,
            services,
            new Dictionary<string, string?>(StringComparer.Ordinal)
            {
                [RequestsPerMinuteKey] = requestsPerMinute.ToString(CultureInfo.InvariantCulture),
                [LlmRequestsPerMinuteKey] = llmRequestsPerMinute.ToString(CultureInfo.InvariantCulture),
            });

    private static bool IsLlmRoute(string method, string path) =>
        method == HttpMethods.Post && (path == ChatPath || path == VoicePath);

    /// <summary>
    /// Учётные данные раздела маршрута: анонимные из таблицы правила 7 — без
    /// токена, админка — админ-секрет, остальное — токен нового устройства.
    /// </summary>
    private static async Task<string?> BearerForAsync(HttpClient client, string method, string path)
    {
        if (RouteAuthenticationAudit.IsDocumentedAnonymous(method, path))
        {
            return null;
        }

        return path.StartsWith(AdminPathPrefix, StringComparison.Ordinal)
            ? AuthTestApi.AdminToken
            : await AuthTestApi.PairAsync(client);
    }

    /// <summary>
    /// Серия к одному маршруту: <paramref name="allowed"/> запросов не 429,
    /// следующий — 429 в едином формате. Нарушение — строка, иначе <c>null</c>.
    /// </summary>
    private static async Task<string?> SeriesViolationAsync(
        HttpClient client, HttpMethod method, string path, string? bearer, int allowed)
    {
        for (int attempt = 1; attempt <= allowed; attempt++)
        {
            using HttpResponseMessage response = await AuthTestApi.SendAsync(client, method, path, bearer);
            if (response.StatusCode == HttpStatusCode.TooManyRequests)
            {
                return $"429 уже на запросе {attempt} из {allowed} разрешённых";
            }
        }

        using HttpResponseMessage beyond = await AuthTestApi.SendAsync(client, method, path, bearer);
        string? violation = await RejectionViolationAsync(beyond);

        return violation is null ? null : $"запрос {allowed + 1}: {violation}";
    }

    /// <summary>
    /// Ответ — отказ лимитера: 429, <c>error.code = rate_limited</c> с
    /// непустым <c>error.message</c>, <c>Retry-After</c> — целое число секунд
    /// в [1, 60]. Нарушение — строка, иначе <c>null</c>.
    /// </summary>
    private static async Task<string?> RejectionViolationAsync(HttpResponseMessage response)
    {
        string body = await response.Content.ReadAsStringAsync();
        if (response.StatusCode != HttpStatusCode.TooManyRequests)
        {
            // Тело — только начало: список админки или состав компонентов
            // заслонил бы в сообщении остальные маршруты.
            return $"ожидался 429, получен {(int)response.StatusCode} {body[..Math.Min(body.Length, 120)]}";
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            JsonElement error = document.RootElement.GetProperty("error");
            if (error.GetProperty("code").GetString() != RateLimitedCode
                || string.IsNullOrEmpty(error.GetProperty("message").GetString()))
            {
                return $"тело не в едином формате rate_limited: {body}";
            }
        }
        catch (Exception exception) when (exception is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return $"тело не в едином формате: {body}";
        }

        if (!response.Headers.TryGetValues("Retry-After", out IEnumerable<string>? values))
        {
            return "нет заголовка Retry-After";
        }

        string retryAfter = string.Join(",", values);

        return int.TryParse(retryAfter, NumberStyles.None, CultureInfo.InvariantCulture, out int seconds)
            && seconds is >= 1 and <= 60
            ? null
            : $"Retry-After «{retryAfter}» — не целое число секунд в [1, 60]";
    }

    private static async Task<List<HttpStatusCode>> GetSeriesAsync(HttpClient client, string path, int count)
    {
        var statuses = new List<HttpStatusCode>(count);
        for (int attempt = 0; attempt < count; attempt++)
        {
            using HttpResponseMessage response = await client.GetAsync(new Uri(path, UriKind.Relative));
            statuses.Add(response.StatusCode);
        }

        return statuses;
    }

    private static string? Tag(Dictionary<string, string?> tags, string name) =>
        tags.TryGetValue(name, out string? value) ? value : null;

    /// <summary>
    /// События завершения запросов со статусом 429: пишутся после ответа,
    /// поэтому ждутся по условию, а не паузой.
    /// </summary>
    private static async Task<List<LogEvent>> WaitForRejectedCompletionsAsync(
        CollectingSink sink, DateTimeOffset since, int expected)
    {
        DateTimeOffset deadline = DateTimeOffset.Now + CompletionWait;
        while (true)
        {
            List<LogEvent> completions = [.. sink.Events.Where(logEvent =>
                logEvent.Timestamp >= since
                && SourceContext(logEvent) == CompletionSource
                && logEvent.Properties.TryGetValue("StatusCode", out LogEventPropertyValue? status)
                && status is ScalarValue { Value: int code }
                && code == StatusCodes.Status429TooManyRequests)];
            if (completions.Count >= expected)
            {
                return completions;
            }

            if (DateTimeOffset.Now > deadline)
            {
                throw new TimeoutException(
                    $"событий завершения с 429 от {CompletionSource}: {completions.Count} из {expected} за {CompletionWait}");
            }

            await Task.Delay(TimeSpan.FromMilliseconds(20));
        }
    }

    private static string SourceContext(LogEvent logEvent) => ScalarString(logEvent, "SourceContext") ?? string.Empty;

    private static string? ScalarString(LogEvent logEvent, string property) =>
        logEvent.Properties.TryGetValue(property, out LogEventPropertyValue? value)
            && value is ScalarValue { Value: string text }
            ? text
            : null;

    /// <summary>Событие целиком: сообщение, все свойства и исключение.</summary>
    private static string Render(LogEvent logEvent)
    {
        using var writer = new StringWriter(CultureInfo.InvariantCulture);
        FullFormatter.Format(logEvent, writer);
        return writer.ToString();
    }

    private static readonly MessageTemplateTextFormatter FullFormatter =
        new("{Message:lj} {Properties:j} {Exception}", CultureInfo.InvariantCulture);

    private sealed class CollectingSink : ILogEventSink
    {
        private readonly ConcurrentQueue<LogEvent> _events = new();

        public IEnumerable<LogEvent> Events => _events;

        public void Emit(LogEvent logEvent) => _events.Enqueue(logEvent);
    }
}
