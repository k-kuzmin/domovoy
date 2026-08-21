using System.Net;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;

namespace Domovoy.Tests;

/// <summary>
/// Smoke-тест единственного работающего эндпоинта.
///
/// Проверяет именно то, что требует этап 0: приложение поднимается на
/// конфигурации без секретов и отвечает, а незаполненные учётные данные
/// дают состояние «не сконфигурировано», а не падение.
/// </summary>
public sealed class HealthEndpointTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public HealthEndpointTests(WebApplicationFactory<Program> factory) => _factory = factory;

    [Fact(DisplayName = "Анонимный /health отвечает на конфигурации без секретов")]
    public async Task LivenessRespondsWithoutSecrets()
    {
        using HttpClient client = _factory.CreateClient();

        using HttpResponseMessage response = await client.GetAsync(new Uri("/health", UriKind.Relative));

        response.StatusCode.Should().Be(HttpStatusCode.OK,
            "незаполненный секрет — это состояние «не сконфигурировано», а не отказ сервиса");

        string body = await response.Content.ReadAsStringAsync();
        using JsonDocument document = JsonDocument.Parse(body);

        document.RootElement.GetProperty("status").GetString()
            .Should().BeOneOf("healthy", "degraded");
    }

    [Fact(DisplayName = "Анонимный /health не раскрывает состав компонентов")]
    public async Task LivenessDoesNotExposeComponents()
    {
        using HttpClient client = _factory.CreateClient();

        using HttpResponseMessage response = await client.GetAsync(new Uri("/health", UriKind.Relative));
        string body = await response.Content.ReadAsStringAsync();

        // Публичный домен индексируется и сканируется (AR-1.2):
        // устройство системы наружу не отдаётся.
        body.Should().NotContain("components");
        body.Should().NotContain("ha");
        body.Should().NotContain("llm");
    }

    [Theory(DisplayName = "Эндпоинты API требуют аутентификации")]
    [InlineData("/api/v1/health")]
    [InlineData("/api/v1/state")]
    [InlineData("/api/v1/notifications")]
    public async Task ApiRequiresAuthentication(string path)
    {
        using HttpClient client = _factory.CreateClient();

        using HttpResponseMessage response = await client.GetAsync(new Uri(path, UriKind.Relative));

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized,
            "новый эндпоинт по умолчанию требует аутентификации");
    }

    [Fact(DisplayName = "Предъявленный токен отклоняется: привязка устройств не реализована")]
    public async Task PresentedTokenIsRejected()
    {
        using HttpClient client = _factory.CreateClient();
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", "irrelevant-value");

        using HttpResponseMessage response = await client.GetAsync(new Uri("/api/v1/state", UriKind.Relative));

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized,
            "схема, пропускающая всех «пока не реализовано», однажды доезжает до продакшена");
    }
}
