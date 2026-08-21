using System.Net;
using System.Security.Claims;
using System.Text.Encodings.Web;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Tests;

/// <summary>
/// Подробный статус компонентов (NFR-OBS-3).
///
/// Тест существует потому, что этот ответ иначе не увидит никто: доступ
/// к нему закрыт Bearer-токеном, а выдача токенов появится только на
/// этапе 5. Без теста агрегация состояний и сериализация ответа
/// оставались бы непроверенными до тех пор.
/// </summary>
public sealed class ComponentHealthEndpointTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public ComponentHealthEndpointTests(WebApplicationFactory<Program> factory) => _factory = factory;

    [Fact(DisplayName = "Подробный /health отдаёт раздельный статус БД, Home Assistant и LLM")]
    public async Task ComponentsAreReportedSeparately()
    {
        using WebApplicationFactory<Program> authorized = WithTestAuthentication();
        using HttpClient client = authorized.CreateClient();

        using HttpResponseMessage response = await client.GetAsync(
            new Uri("/api/v1/health", UriKind.Relative));

        response.StatusCode.Should().Be(HttpStatusCode.OK);

        string body = await response.Content.ReadAsStringAsync();
        using JsonDocument document = JsonDocument.Parse(body);

        document.RootElement.GetProperty("status").GetString()
            .Should().BeOneOf("healthy", "degraded", "unhealthy");

        JsonElement components = document.RootElement.GetProperty("components");

        foreach (string component in new[] { "db", "ha", "llm" })
        {
            components.TryGetProperty(component, out JsonElement entry)
                .Should().BeTrue($"NFR-OBS-3 требует раздельного статуса {component}");

            entry.GetProperty("state").GetString()
                .Should().NotBeNullOrWhiteSpace();
            entry.GetProperty("description").GetString()
                .Should().NotBeNullOrWhiteSpace("описание нужно человеку, который читает ответ");
        }
    }

    [Fact(DisplayName = "Незаполненные секреты дают «не сконфигурировано», а не отказ")]
    public async Task UnfilledSecretsYieldNotConfigured()
    {
        using WebApplicationFactory<Program> authorized = WithTestAuthentication();
        using HttpClient client = authorized.CreateClient();

        using HttpResponseMessage response = await client.GetAsync(
            new Uri("/api/v1/health", UriKind.Relative));

        string body = await response.Content.ReadAsStringAsync();
        using JsonDocument document = JsonDocument.Parse(body);
        JsonElement components = document.RootElement.GetProperty("components");

        // Конфигурация тестов повторяет .example: внешних учётных данных
        // нет. Именно это состояние обязано подниматься на чистой машине.
        components.GetProperty("ha").GetProperty("state").GetString()
            .Should().Be("not_configured");
        components.GetProperty("llm").GetProperty("state").GetString()
            .Should().Be("not_configured");
    }

    [Fact(DisplayName = "В подробном ответе нет ни адресов, ни значений секретов")]
    public async Task DetailedAnswerLeaksNothing()
    {
        using WebApplicationFactory<Program> authorized = WithTestAuthentication();
        using HttpClient client = authorized.CreateClient();

        using HttpResponseMessage response = await client.GetAsync(
            new Uri("/api/v1/health", UriKind.Relative));
        string body = await response.Content.ReadAsStringAsync();

        // Даже под токеном описание компонента — это диагностика, а не
        // дамп конфигурации: адрес базы и имя хоста в ответе не нужны.
        body.Should().NotContain("Host=");
        body.Should().NotContain("Password");
        body.Should().NotContain("Bearer");
        body.Should().NotContain("http://");
    }

    /// <summary>
    /// Фабрика со схемой аутентификации, которая пропускает запрос.
    /// Нужна только для доступа к защищённому эндпоинту: боевая схема
    /// отклоняет всё, пока привязка устройств не реализована.
    /// </summary>
    private WebApplicationFactory<Program> WithTestAuthentication() =>
        _factory.WithWebHostBuilder(builder => builder.ConfigureTestServices(services =>
            services
                .AddAuthentication(TestAuthenticationHandler.SchemeName)
                .AddScheme<AuthenticationSchemeOptions, TestAuthenticationHandler>(
                    TestAuthenticationHandler.SchemeName,
                    configureOptions: null)));

    private sealed class TestAuthenticationHandler : AuthenticationHandler<AuthenticationSchemeOptions>
    {
        public const string SchemeName = "TestScheme";

        public TestAuthenticationHandler(
            IOptionsMonitor<AuthenticationSchemeOptions> options,
            ILoggerFactory logger,
            UrlEncoder encoder)
            : base(options, logger, encoder)
        {
        }

        protected override Task<AuthenticateResult> HandleAuthenticateAsync()
        {
            var identity = new ClaimsIdentity(
                [new Claim(ClaimTypes.NameIdentifier, "test-device")],
                SchemeName);

            return Task.FromResult(AuthenticateResult.Success(
                new AuthenticationTicket(new ClaimsPrincipal(identity), SchemeName)));
        }
    }
}
