using System.Net;
using System.Text.Json;
using Domovoy.Tests.Auth;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;

namespace Domovoy.Tests;

/// <summary>
/// Подробный статус компонентов (NFR-OBS-3).
///
/// Ответ закрыт токеном устройства, поэтому тест идёт через настоящую
/// привязку: админ выпускает код, устройство обменивает его на токен.
/// </summary>
public sealed class ComponentHealthEndpointTests : IClassFixture<DomovoyApiFactory>
{
    private readonly WebApplicationFactory<Program> _factory;

    public ComponentHealthEndpointTests(DomovoyApiFactory factory) => _factory = factory;

    [Fact(DisplayName = "Подробный /health отдаёт раздельный статус БД, Home Assistant и LLM")]
    public async Task ComponentsAreReportedSeparately()
    {
        (HttpStatusCode status, string body) = await GetDetailedHealthAsync();

        status.Should().Be(HttpStatusCode.OK);

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
        (_, string body) = await GetDetailedHealthAsync();

        using JsonDocument document = JsonDocument.Parse(body);
        JsonElement components = document.RootElement.GetProperty("components");

        // Конфигурация тестов повторяет .example: внешних учётных данных
        // нет. Именно это состояние обязано подниматься на чистой машине.
        components.GetProperty("ha").GetProperty("state").GetString()
            .Should().Be("not_configured");
        components.GetProperty("llm").GetProperty("state").GetString()
            .Should().Be("not_configured");
    }

    [Fact(DisplayName = "WebSocket-соединение с Home Assistant — отдельное поле ha_websocket рядом с ha")]
    public async Task HaWebSocketStatusIsSeparateComponent()
    {
        (_, string body) = await GetDetailedHealthAsync();

        using JsonDocument document = JsonDocument.Parse(body);
        JsonElement components = document.RootElement.GetProperty("components");

        components.TryGetProperty("ha", out _)
            .Should().BeTrue("REST-проба Home Assistant остаётся своим полем");
        components.TryGetProperty("ha_websocket", out JsonElement webSocket)
            .Should().BeTrue("NFR-OBS-3 требует раздельного статуса WebSocket-соединения с HA");

        // Конфигурация примера: токена нет, воркер не подключается.
        webSocket.GetProperty("state").GetString().Should().Be("not_configured");
        webSocket.GetProperty("description").GetString()
            .Should().NotBeNullOrWhiteSpace("описание нужно человеку, который читает ответ");
    }

    [Fact(DisplayName = "В подробном ответе нет ни адресов, ни значений секретов")]
    public async Task DetailedAnswerLeaksNothing()
    {
        (_, string body) = await GetDetailedHealthAsync();

        // Даже под токеном описание компонента — это диагностика, а не
        // дамп конфигурации: адрес базы и имя хоста в ответе не нужны.
        body.Should().NotContain("Host=");
        body.Should().NotContain("Password");
        body.Should().NotContain("Bearer");
        body.Should().NotContain("http://");
    }

    /// <summary>
    /// Подробный /health под настоящим токеном устройства: код выпускает
    /// админ-эндпоинт, токен проверяет боевой хендлер по хранилищу в памяти
    /// фабрики. Подменять схему аутентификации нельзя: политики явно
    /// называют схему устройства, и подменённая схема не вызывается.
    /// </summary>
    private async Task<(HttpStatusCode Status, string Body)> GetDetailedHealthAsync()
    {
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(_factory);
        using HttpClient client = host.CreateClient();
        string token = await AuthTestApi.PairAsync(client);

        using HttpResponseMessage response = await AuthTestApi.SendAsync(
            client, HttpMethod.Get, "/api/v1/health", token);

        return (response.StatusCode, await response.Content.ReadAsStringAsync());
    }
}
