using System.Net;
using System.Text.Json;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Domovoy.Tests;

/// <summary>
/// Smoke-тест единственного работающего эндпоинта.
///
/// Проверяет именно то, что требует этап 0: приложение поднимается на
/// конфигурации без секретов и отвечает, а незаполненные учётные данные
/// дают состояние «не сконфигурировано», а не падение.
/// </summary>
public sealed class HealthEndpointTests : IClassFixture<DomovoyApiFactory>
{
    private readonly WebApplicationFactory<Program> _factory;

    public HealthEndpointTests(DomovoyApiFactory factory) => _factory = factory;

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

    [Fact(DisplayName = "Анонимный /health возвращается в 200, когда компонент поднялся, без перезапуска процесса")]
    public async Task LivenessRecoversWhenComponentRecovers()
    {
        // После перезагрузки хоста демон поднимает контейнеры без учёта
        // depends_on, и api может стартовать раньше базы. Вечного 503 это
        // давать не должно: проверки пересчитываются на каждом запросе.
        var probe = new SwitchableProbe(ComponentState.Unreachable);
        using WebApplicationFactory<Program> host = _factory.WithWebHostBuilder(builder =>
            builder.ConfigureTestServices(services =>
            {
                services.RemoveAll<IComponentProbe>();
                services.AddSingleton<IComponentProbe>(probe);
            }));
        using HttpClient client = host.CreateClient();

        using (HttpResponseMessage down = await client.GetAsync(new Uri("/health", UriKind.Relative)))
        {
            down.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable,
                "недоступный компонент — Unhealthy, анонимный /health отдаёт 503");
        }

        probe.State = ComponentState.Ok;

        using HttpResponseMessage up = await client.GetAsync(new Uri("/health", UriKind.Relative));

        up.StatusCode.Should().Be(HttpStatusCode.OK,
            "тот же процесс без перезапуска видит поднявшийся компонент на следующем запросе");
        string body = await up.Content.ReadAsStringAsync();
        using JsonDocument document = JsonDocument.Parse(body);
        document.RootElement.GetProperty("status").GetString().Should().Be("healthy");
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

    [Fact(DisplayName = "Неизвестный токен устройства отклоняется")]
    public async Task PresentedTokenIsRejected()
    {
        using HttpClient client = _factory.CreateClient();
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", "irrelevant-value");

        using HttpResponseMessage response = await client.GetAsync(new Uri("/api/v1/state", UriKind.Relative));

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized,
            "схема, пропускающая всех «пока не реализовано», однажды доезжает до продакшена");
    }

    /// <summary>Проба, состояние которой тест переключает между запросами.</summary>
    private sealed class SwitchableProbe : IComponentProbe
    {
        private volatile ComponentState _state;

        public SwitchableProbe(ComponentState state) => _state = state;

        public ComponentState State
        {
            get => _state;
            set => _state = value;
        }

        public string ComponentName => "db";

        public Task<ComponentHealth> CheckAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new ComponentHealth { State = _state, Description = "управляемая проба теста" });
    }
}
