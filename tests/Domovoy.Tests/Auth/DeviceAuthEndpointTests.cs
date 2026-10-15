using System.Globalization;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Domovoy.Core.Abstractions;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Domovoy.Tests.Auth;

/// <summary>
/// Привязка устройства и отзыв через HTTP (#12, #13): обмен кода на токен,
/// единый формат ошибок, ограничение частоты, поведение при сбое
/// хранилища.
/// </summary>
public sealed class DeviceAuthEndpointTests : IClassFixture<DomovoyApiFactory>
{
    private readonly DomovoyApiFactory _factory;

    public DeviceAuthEndpointTests(DomovoyApiFactory factory) => _factory = factory;

    [Fact(DisplayName = "Код привязки обменивается на токен один раз, токен аутентифицирует устройство")]
    public async Task PairingFlowIssuesTokenThatAuthenticates()
    {
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(_factory);
        using HttpClient client = host.CreateClient();

        using HttpResponseMessage issued = await AuthTestApi.SendAsync(
            client, HttpMethod.Post, AuthTestApi.PairingCodesPath, AuthTestApi.AdminToken);
        issued.StatusCode.Should().Be(HttpStatusCode.Created);
        using JsonDocument issuedBody = JsonDocument.Parse(await issued.Content.ReadAsStringAsync());
        string code = issuedBody.RootElement.GetProperty("code").GetString()!;
        issuedBody.RootElement.GetProperty("expires_at").GetDateTimeOffset()
            .Should().BeAfter(DateTimeOffset.UtcNow);

        using HttpResponseMessage redeemed = await AuthTestApi.RedeemAsync(client, code);
        redeemed.StatusCode.Should().Be(HttpStatusCode.OK);
        redeemed.Headers.CacheControl!.NoStore.Should().BeTrue("токен отдаётся один раз и не кэшируется");
        using JsonDocument redeemedBody = JsonDocument.Parse(await redeemed.Content.ReadAsStringAsync());
        redeemedBody.RootElement.EnumerateObject().Select(property => property.Name)
            .Should().Equal(["token"], "запись 0025: эндпоинт отдаёт токен устройства и ничего больше");
        string token = redeemedBody.RootElement.GetProperty("token").GetString()!;

        using HttpResponseMessage state = await AuthTestApi.SendAsync(client, HttpMethod.Get, "/api/v1/state", token);
        state.StatusCode.Should().Be(HttpStatusCode.NotImplemented, "501 значит: аутентификация пройдена");

        using HttpResponseMessage again = await AuthTestApi.RedeemAsync(client, code);
        again.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await AuthTestApi.ReadErrorCodeAsync(again)).Should().Be("invalid_pairing_code");
    }

    [Fact(DisplayName = "Неизвестный, просроченный и погашенный код получают одинаковый ответ")]
    public async Task InvalidExpiredAndUsedCodesGetIdenticalResponse()
    {
        var clock = new ManualTimeProvider(DateTimeOffset.UtcNow);
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(_factory, services =>
        {
            services.RemoveAll<TimeProvider>();
            services.AddSingleton<TimeProvider>(clock);
        });
        using HttpClient client = host.CreateClient();

        string used = await AuthTestApi.IssueCodeAsync(client);
        using (HttpResponseMessage first = await AuthTestApi.RedeemAsync(client, used))
        {
            first.StatusCode.Should().Be(HttpStatusCode.OK);
        }

        string expired = await AuthTestApi.IssueCodeAsync(client);
        clock.Advance(TimeSpan.FromMinutes(11));

        var responses = new List<(HttpStatusCode Status, string Body)>();
        foreach (string code in new[] { "ZZZZZZZZ", expired, used })
        {
            using HttpResponseMessage response = await AuthTestApi.RedeemAsync(client, code);
            responses.Add((response.StatusCode, await response.Content.ReadAsStringAsync()));
        }

        responses.Should().AllSatisfy(response => response.Should().Be(responses[0]),
            "ответ не подсказывает, какой код существовал");
        responses[0].Status.Should().Be(HttpStatusCode.BadRequest);
        using JsonDocument body = JsonDocument.Parse(responses[0].Body);
        body.RootElement.GetProperty("error").GetProperty("code").GetString().Should().Be("invalid_pairing_code");
        body.RootElement.GetProperty("error").GetProperty("message").GetString().Should().NotBeNullOrEmpty();
    }

    [Fact(DisplayName = "Обмены сверх предела в окне получают 429 с Retry-After в пределах окна")]
    public async Task PairingAttemptsBeyondLimitGet429()
    {
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(
            _factory,
            settings: new Dictionary<string, string?> { ["Auth:PairingAttemptsPerMinute"] = "2" });
        using HttpClient client = host.CreateClient();

        string code = await AuthTestApi.IssueCodeAsync(client);

        for (int attempt = 0; attempt < 2; attempt++)
        {
            using HttpResponseMessage allowed = await AuthTestApi.RedeemAsync(client, "ZZZZZZZZ");
            allowed.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        }

        using HttpResponseMessage limited = await AuthTestApi.RedeemAsync(client, code);

        limited.StatusCode.Should().Be(HttpStatusCode.TooManyRequests, "предел действует и на верный код");
        (await AuthTestApi.ReadErrorCodeAsync(limited)).Should().Be("rate_limited");
        limited.Headers.TryGetValues("Retry-After", out IEnumerable<string>? retryAfter).Should().BeTrue();
        int seconds = int.Parse(retryAfter!.Single(), NumberStyles.None, CultureInfo.InvariantCulture);
        seconds.Should().BeInRange(1, 60, "отказ ограничен окном в минуту");
    }

    [Fact(DisplayName = "Отозванный токен отклоняется со следующего же запроса")]
    public async Task RevokedTokenIsRejectedOnNextRequest()
    {
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(_factory);
        using HttpClient client = host.CreateClient();
        string token = await AuthTestApi.PairAsync(client, "revoked-device");

        using (HttpResponseMessage before = await AuthTestApi.SendAsync(client, HttpMethod.Get, "/api/v1/state", token))
        {
            before.StatusCode.Should().Be(HttpStatusCode.NotImplemented);
        }

        Guid id = await AuthTestApi.DeviceIdAsync(client, "revoked-device");
        using (HttpResponseMessage revoked = await AuthTestApi.SendAsync(
                   client, HttpMethod.Delete, AuthTestApi.DevicePath(id), AuthTestApi.AdminToken))
        {
            revoked.StatusCode.Should().Be(HttpStatusCode.NoContent);
        }

        using HttpResponseMessage after = await AuthTestApi.SendAsync(client, HttpMethod.Get, "/api/v1/state", token);

        after.StatusCode.Should().Be(HttpStatusCode.Unauthorized, "кэша поиска токена нет");
        (await AuthTestApi.ReadErrorCodeAsync(after)).Should().Be("unauthorized");
    }

    [Fact(DisplayName = "Сбой хранилища даёт 503 auth_unavailable без текста исключения")]
    public async Task StoreFailureYields503WithoutExceptionText()
    {
        var store = new InMemoryDeviceStore { FailFind = true };
        using WebApplicationFactory<Program> host = AuthTestApi.WithStore(_factory, store);
        using HttpClient client = host.CreateClient();

        using HttpResponseMessage response = await AuthTestApi.SendAsync(
            client, HttpMethod.Get, "/api/v1/state", "unknown-device-token");

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        string body = await response.Content.ReadAsStringAsync();
        using (JsonDocument document = JsonDocument.Parse(body))
        {
            document.RootElement.EnumerateObject().Select(property => property.Name).Should().Equal(["error"]);
            document.RootElement.GetProperty("error").GetProperty("code").GetString().Should().Be("auth_unavailable");
        }

        response.Headers.WwwAuthenticate.Should().BeEmpty("это не отказ в аутентификации, а сбой проверки");
        body.Should().NotContain(InMemoryDeviceStore.FailureMessage);
        response.Headers.Concat(response.Content.Headers)
            .SelectMany(header => header.Value)
            .Should().NotContain(value => value.Contains(InMemoryDeviceStore.FailureMessage, StringComparison.Ordinal));

        using HttpResponseMessage anonymous = await client.GetAsync(new Uri("/api/v1/state", UriKind.Relative));
        anonymous.StatusCode.Should().Be(HttpStatusCode.Unauthorized, "без токена хранилище не спрашивают");
    }

    [Fact(DisplayName = "Хранилище устройств не опрашивается вне маршрутов под токеном устройства")]
    public async Task DeviceStoreIsNotQueriedOutsideDeviceRoutes()
    {
        var store = new InMemoryDeviceStore { FailFind = true };
        using WebApplicationFactory<Program> host = AuthTestApi.WithStore(_factory, store);
        using HttpClient client = host.CreateClient();

        HttpStatusCode anonymousHealth;
        using (HttpResponseMessage health = await client.GetAsync(new Uri("/health", UriKind.Relative)))
        {
            anonymousHealth = health.StatusCode;
        }

        using (HttpResponseMessage health = await AuthTestApi.SendAsync(client, HttpMethod.Get, "/health", "any-token"))
        {
            health.StatusCode.Should().Be(anonymousHealth);
        }

        using (HttpResponseMessage pairing = await AuthTestApi.SendAsync(
                   client, HttpMethod.Post, AuthTestApi.PairingPath, "any-token", new { code = "ZZZZZZZZ" }))
        {
            pairing.StatusCode.Should().Be(HttpStatusCode.BadRequest);
            (await AuthTestApi.ReadErrorCodeAsync(pairing)).Should().Be("invalid_pairing_code");
        }

        using (HttpResponseMessage devices = await AuthTestApi.SendAsync(
                   client, HttpMethod.Get, AuthTestApi.DevicesPath, AuthTestApi.AdminToken))
        {
            devices.StatusCode.Should().Be(HttpStatusCode.OK);
        }

        store.FindCalls.Should().Be(0, "ни анонимные маршруты, ни аутентификация админа токен устройства не ищут");
    }

    [Fact(DisplayName = "Сбой обновления last_seen не роняет аутентифицированный запрос")]
    public async Task TouchFailureKeepsRequestAuthenticated()
    {
        var store = new InMemoryDeviceStore();
        using WebApplicationFactory<Program> host = AuthTestApi.WithStore(_factory, store);
        using HttpClient client = host.CreateClient();
        string token = await AuthTestApi.PairAsync(client);
        store.FailTouch = true;

        using HttpResponseMessage response = await AuthTestApi.SendAsync(client, HttpMethod.Get, "/api/v1/state", token);

        response.StatusCode.Should().Be(HttpStatusCode.NotImplemented, "отметка last_seen не критична для запроса");
    }

    [Fact(DisplayName = "Слишком длинное имя устройства — 400 invalid_request, код не тратится")]
    public async Task PairingWithTooLongNameIsInvalidRequest()
    {
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(_factory);
        using HttpClient client = host.CreateClient();
        string code = await AuthTestApi.IssueCodeAsync(client);

        using (HttpResponseMessage tooLong = await AuthTestApi.RedeemAsync(client, code, new string('n', 65)))
        {
            tooLong.StatusCode.Should().Be(HttpStatusCode.BadRequest);
            (await AuthTestApi.ReadErrorCodeAsync(tooLong)).Should().Be("invalid_request");
        }

        using HttpResponseMessage accepted = await AuthTestApi.RedeemAsync(client, code, new string('n', 64));

        accepted.StatusCode.Should().Be(HttpStatusCode.OK, "отклонённый запрос код не погасил");
    }

    [Theory(DisplayName = "Управляющий символ в имени устройства — 400 invalid_request, код не тратится")]
    [InlineData("phone\u0000")]
    [InlineData("pho\nne")]
    [InlineData("\u007f")]
    public async Task PairingWithControlCharacterInNameIsInvalidRequest(string name)
    {
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(_factory);
        using HttpClient client = host.CreateClient();
        string code = await AuthTestApi.IssueCodeAsync(client);

        using (HttpResponseMessage rejected = await AuthTestApi.RedeemAsync(client, code, name))
        {
            rejected.StatusCode.Should().Be(HttpStatusCode.BadRequest);
            (await AuthTestApi.ReadErrorCodeAsync(rejected)).Should().Be("invalid_request");
        }

        using HttpResponseMessage accepted = await AuthTestApi.RedeemAsync(client, code, "phone");

        accepted.StatusCode.Should().Be(HttpStatusCode.OK, "отклонённый запрос код не погасил");
    }
}

/// <summary>Общие шаги тестов привязки и админ-эндпоинтов.</summary>
internal static class AuthTestApi
{
    /// <summary>
    /// Пробный админ-секрет: не короче 32 символов и без маркеров
    /// плейсхолдера. Настоящим секретом не является.
    /// </summary>
    public const string AdminToken = "sampleAdminTokenValue-0123456789abcdef";

    public const string PairingPath = "/api/v1/auth/device";
    public const string PairingCodesPath = "/api/v1/admin/pairing-codes";
    public const string DevicesPath = "/api/v1/admin/devices";

    public static string DevicePath(Guid id) => DevicesPath + "/" + id.ToString();

    /// <summary>Хост фабрики с настроенным админ-секретом.</summary>
    public static WebApplicationFactory<Program> WithAdmin(
        WebApplicationFactory<Program> factory,
        Action<IServiceCollection>? services = null,
        IDictionary<string, string?>? settings = null,
        string adminToken = AdminToken)
    {
        var values = new Dictionary<string, string?>(StringComparer.Ordinal) { ["Auth:AdminToken"] = adminToken };
        foreach (KeyValuePair<string, string?> setting in settings ?? new Dictionary<string, string?>())
        {
            values[setting.Key] = setting.Value;
        }

        return factory.WithWebHostBuilder(builder =>
        {
            builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(values));
            if (services is not null)
            {
                builder.ConfigureTestServices(services);
            }
        });
    }

    /// <summary>Хост с админ-секретом и собственным хранилищем устройств.</summary>
    public static WebApplicationFactory<Program> WithStore(WebApplicationFactory<Program> factory, IDeviceStore store) =>
        WithAdmin(factory, services =>
        {
            services.RemoveAll<IDeviceStore>();
            services.AddSingleton(store);
        });

    public static async Task<HttpResponseMessage> SendAsync(
        HttpClient client,
        HttpMethod method,
        string path,
        string? bearer = null,
        object? body = null)
    {
        using var request = new HttpRequestMessage(method, new Uri(path, UriKind.Relative));
        if (bearer is not null)
        {
            request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + bearer);
        }

        if (body is not null)
        {
            request.Content = JsonContent.Create(body);
        }

        return await client.SendAsync(request);
    }

    public static Task<HttpResponseMessage> RedeemAsync(HttpClient client, string code, string? name = null) =>
        SendAsync(client, HttpMethod.Post, PairingPath, body: new { code, name });

    /// <summary>Выпускает код привязки админ-секретом.</summary>
    public static async Task<string> IssueCodeAsync(HttpClient client)
    {
        using HttpResponseMessage response = await SendAsync(client, HttpMethod.Post, PairingCodesPath, AdminToken);
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        using JsonDocument body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        return body.RootElement.GetProperty("code").GetString()!;
    }

    /// <summary>Выпускает код и обменивает его на токен.</summary>
    public static async Task<string> PairAsync(HttpClient client, string? name = null)
    {
        string code = await IssueCodeAsync(client);
        using HttpResponseMessage response = await RedeemAsync(client, code, name);
        response.StatusCode.Should().Be(HttpStatusCode.OK);
        using JsonDocument body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        return body.RootElement.GetProperty("token").GetString()!;
    }

    /// <summary>Идентификатор устройства по имени из списка администратора.</summary>
    public static async Task<Guid> DeviceIdAsync(HttpClient client, string name)
    {
        using HttpResponseMessage response = await SendAsync(client, HttpMethod.Get, DevicesPath, AdminToken);
        response.StatusCode.Should().Be(HttpStatusCode.OK);
        using JsonDocument body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        JsonElement device = body.RootElement.GetProperty("devices").EnumerateArray()
            .Single(item => item.GetProperty("name").GetString() == name);
        return device.GetProperty("id").GetGuid();
    }

    /// <summary>
    /// Код ошибки из тела единого формата; заодно проверяет, что тело —
    /// <c>{ error: { code, message } }</c> с непустым сообщением.
    /// </summary>
    public static async Task<string?> ReadErrorCodeAsync(HttpResponseMessage response)
    {
        using JsonDocument body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        JsonElement error = body.RootElement.GetProperty("error");
        error.GetProperty("message").GetString().Should().NotBeNullOrEmpty();
        return error.GetProperty("code").GetString();
    }
}
