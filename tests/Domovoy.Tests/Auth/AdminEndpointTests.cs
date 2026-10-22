using System.Net;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Options;

namespace Domovoy.Tests.Auth;

/// <summary>
/// Админ-эндпоинты (#13) и разделение схем: токен устройства не открывает
/// админку, админ-секрет не делает запрос устройством, без настроенного
/// секрета админка закрыта.
/// </summary>
public sealed class AdminEndpointTests : IClassFixture<DomovoyApiFactory>
{
    private static readonly (HttpMethod Method, string Path)[] AdminRoutes =
    [
        (HttpMethod.Post, AuthTestApi.PairingCodesPath),
        (HttpMethod.Get, AuthTestApi.DevicesPath),
        (HttpMethod.Delete, AuthTestApi.DevicePath(Guid.NewGuid())),
    ];

    private readonly DomovoyApiFactory _factory;

    public AdminEndpointTests(DomovoyApiFactory factory) => _factory = factory;

    [Fact(DisplayName = "Админ видит привязанные устройства с last_seen и отзывает одно из них")]
    public async Task AdminListsDevicesAndRevokesOne()
    {
        // Своё хранилище: соседние тесты класса привязывают устройства в
        // общее хранилище фабрики, а список здесь проверяется целиком.
        var store = new InMemoryDeviceStore();
        using WebApplicationFactory<Program> host = AuthTestApi.WithStore(_factory, store);
        using HttpClient client = host.CreateClient();
        string kitchenToken = await AuthTestApi.PairAsync(client, "kitchen-tablet");
        string phoneToken = await AuthTestApi.PairAsync(client, "phone");

        using (HttpResponseMessage seen = await AuthTestApi.SendAsync(client, HttpMethod.Get, AuthTestApi.AuthenticatedProbePath, phoneToken))
        {
            seen.StatusCode.Should().Be(HttpStatusCode.NotImplemented);
        }

        Guid phoneId;
        using (HttpResponseMessage list = await AuthTestApi.SendAsync(
                   client, HttpMethod.Get, AuthTestApi.DevicesPath, AuthTestApi.AdminToken))
        {
            list.StatusCode.Should().Be(HttpStatusCode.OK);
            using JsonDocument body = JsonDocument.Parse(await list.Content.ReadAsStringAsync());
            List<JsonElement> devices = body.RootElement.GetProperty("devices").EnumerateArray().ToList();
            devices.Select(device => device.GetProperty("name").GetString())
                .Should().Equal(["kitchen-tablet", "phone"], "список упорядочен по времени привязки");
            devices.Should().AllSatisfy(device => device.GetProperty("id").GetGuid().Should().NotBeEmpty());

            JsonElement phone = devices.Single(device => device.GetProperty("name").GetString() == "phone");
            phone.GetProperty("last_seen_at").ValueKind.Should().Be(JsonValueKind.String, "устройство обращалось");
            phone.GetProperty("revoked_at").ValueKind.Should().Be(JsonValueKind.Null);
            phone.GetProperty("created_at").ValueKind.Should().Be(JsonValueKind.String);
            phoneId = phone.GetProperty("id").GetGuid();
        }

        using (HttpResponseMessage revoked = await AuthTestApi.SendAsync(
                   client, HttpMethod.Delete, AuthTestApi.DevicePath(phoneId), AuthTestApi.AdminToken))
        {
            revoked.StatusCode.Should().Be(HttpStatusCode.NoContent);
        }

        using (HttpResponseMessage other = await AuthTestApi.SendAsync(client, HttpMethod.Get, AuthTestApi.AuthenticatedProbePath, kitchenToken))
        {
            other.StatusCode.Should().Be(HttpStatusCode.NotImplemented, "отзыв касается только одного устройства");
        }

        using (HttpResponseMessage repeated = await AuthTestApi.SendAsync(
                   client, HttpMethod.Delete, AuthTestApi.DevicePath(phoneId), AuthTestApi.AdminToken))
        {
            repeated.StatusCode.Should().Be(HttpStatusCode.NotFound);
            (await AuthTestApi.ReadErrorCodeAsync(repeated)).Should().Be("device_not_found");
        }

        store.AuditEntries.Should().ContainSingle(
            entry => entry.Arguments["device_id"] == phoneId.ToString(),
            "успешный отзыв пишет одну строку аудита, повторный — ни одной");
    }

    [Fact(DisplayName = "Токен устройства на админ-маршрутах — 401")]
    public async Task DeviceTokenIsRejectedOnAdminRoutes()
    {
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(_factory);
        using HttpClient client = host.CreateClient();
        string token = await AuthTestApi.PairAsync(client);

        foreach ((HttpMethod method, string path) in AdminRoutes)
        {
            using HttpResponseMessage response = await AuthTestApi.SendAsync(client, method, path, token);

            response.StatusCode.Should().Be(HttpStatusCode.Unauthorized, $"{method} {path}");
            (await AuthTestApi.ReadErrorCodeAsync(response)).Should().Be("unauthorized");
        }
    }

    [Theory(DisplayName = "Админ-секрет на маршрутах устройства — 401")]
    [InlineData("/api/v1/state")]
    [InlineData("/api/v1/health")]
    public async Task AdminSecretIsRejectedOnDeviceRoutes(string path)
    {
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(_factory);
        using HttpClient client = host.CreateClient();

        using HttpResponseMessage response = await AuthTestApi.SendAsync(client, HttpMethod.Get, path, AuthTestApi.AdminToken);

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized, "админ не становится устройством");
        (await AuthTestApi.ReadErrorCodeAsync(response)).Should().Be("unauthorized");
    }

    [Fact(DisplayName = "Админ-секрет короче 32 символов останавливает старт, сообщение без значения")]
    public async Task AdminTokenShorterThanMinimumFailsStartup()
    {
        string tooShort = AuthTestApi.AdminToken[..31];

        using (WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(_factory, adminToken: tooShort))
        {
            Action start = () => host.CreateClient().Dispose();

            OptionsValidationException failure = start.Should().Throw<OptionsValidationException>().Which;
            failure.Message.Should().Contain("Auth:AdminToken").And.NotContain(tooShort);
        }

        using (WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(_factory, adminToken: AuthTestApi.AdminToken[..32]))
        using (HttpClient client = host.CreateClient())
        {
            using HttpResponseMessage response = await AuthTestApi.SendAsync(
                client, HttpMethod.Get, AuthTestApi.DevicesPath, AuthTestApi.AdminToken[..32]);
            response.StatusCode.Should().Be(HttpStatusCode.OK, "32 символа — минимально допустимый секрет");
        }

        using (WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(_factory, adminToken: "<admin-token>"))
        using (HttpClient client = host.CreateClient())
        {
            using HttpResponseMessage response = await AuthTestApi.SendAsync(
                client, HttpMethod.Get, AuthTestApi.DevicesPath, "<admin-token>");
            response.StatusCode.Should().Be(HttpStatusCode.Unauthorized, "плейсхолдер — хост стартует, админка закрыта");
        }
    }

    [Theory(DisplayName = "Без настроенного админ-секрета админ-маршруты закрыты для любого Bearer")]
    [InlineData("")]
    [InlineData("<admin-token>")]
    [InlineData("change-me")]
    public async Task AdminRoutesClosedWhenSecretIsUnset(string configured)
    {
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(_factory, adminToken: configured);
        using HttpClient client = host.CreateClient();
        string[] presented = ["<admin-token>", "change-me", AuthTestApi.AdminToken, configured];

        foreach ((HttpMethod method, string path) in AdminRoutes)
        {
            foreach (string bearer in presented.Where(value => value.Length > 0))
            {
                using HttpResponseMessage response = await AuthTestApi.SendAsync(client, method, path, bearer);

                response.StatusCode.Should().Be(HttpStatusCode.Unauthorized, $"{method} {path}");
                (await AuthTestApi.ReadErrorCodeAsync(response)).Should().Be("unauthorized");
            }

            using HttpResponseMessage empty = await AuthTestApi.SendAsync(client, method, path, "");
            empty.StatusCode.Should().Be(HttpStatusCode.Unauthorized, $"{method} {path} с пустым Bearer");
        }
    }
}
