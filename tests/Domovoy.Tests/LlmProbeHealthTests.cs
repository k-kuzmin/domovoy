using System.Net;
using System.Text.Json;
using Domovoy.Tests.Auth;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;

namespace Domovoy.Tests;

/// <summary>
/// Проба LLM различает отказ по географии и сетевую ошибку (AR-1.3,
/// NFR-OBS-3): разные статусы с разными описаниями в <c>/api/v1/health</c>,
/// а не общий «недоступен».
///
/// <c>LlmProbe</c> — internal, поэтому проверка идёт через хост: подменяется
/// первичный обработчик именованного клиента <c>llm-probe</c>, а читается
/// проводной ответ, который видит человек.
///
/// Допущение пробы, которое тест фиксирует, а не доказывает: любой 403
/// принимается за отказ по региону; 401 — отдельный случай «ключ отклонён».
/// </summary>
public sealed class LlmProbeHealthTests : IClassFixture<DomovoyApiFactory>
{
    // Пробное значение: настоящим ключом не является и на правилах
    // gitleaks не срабатывает.
    private const string LlmApiKeyValue = "sampleLlmApiKeyValue9e2f6a";

    private readonly WebApplicationFactory<Program> _factory;

    public LlmProbeHealthTests(DomovoyApiFactory factory) => _factory = factory;

    [Fact(DisplayName = "403 провайдера LLM — статус rejected_by_geography с описанием про 403")]
    public async Task LlmForbiddenIsReportedAsGeographyRejection()
    {
        (string state, string description) = await GetLlmComponentAsync(() => new ForbiddenHandler());

        state.Should().Be("rejected_by_geography");
        description.Should().NotBeNullOrWhiteSpace()
            .And.Contain("403", "человек должен видеть, что провайдер ответил отказом, а не молчит");
    }

    [Fact(DisplayName = "Сетевая ошибка провайдера LLM — статус unreachable «сетевая ошибка»")]
    public async Task LlmNetworkErrorIsReportedAsUnreachable()
    {
        (string state, string description) = await GetLlmComponentAsync(() => new NetworkFailureHandler());

        state.Should().Be("unreachable");
        description.Should().Be("сетевая ошибка");
    }

    [Fact(DisplayName = "Отказ по географии и сетевая ошибка LLM различаются и статусом, и описанием")]
    public async Task LlmGeographyAndNetworkFailuresDiffer()
    {
        (string forbiddenState, string forbiddenDescription) =
            await GetLlmComponentAsync(() => new ForbiddenHandler());
        (string networkState, string networkDescription) =
            await GetLlmComponentAsync(() => new NetworkFailureHandler());

        forbiddenState.Should().NotBe(networkState, "AR-1.3: 403 и сетевая ошибка — разные статусы");
        forbiddenDescription.Should().NotBe(networkDescription, "у разных причин — разные сообщения");
    }

    /// <summary>
    /// Состояние и описание компонента <c>llm</c> подробного <c>/api/v1/health</c>
    /// на хосте с заданным ключом LLM и подменённым первичным обработчиком
    /// клиента <c>llm-probe</c>. Токен устройства — настоящая привязка.
    /// </summary>
    private async Task<(string State, string Description)> GetLlmComponentAsync(
        Func<HttpMessageHandler> llmHandler)
    {
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(
            _factory,
            services => services.AddHttpClient("llm-probe").ConfigurePrimaryHttpMessageHandler(llmHandler),
            new Dictionary<string, string?>(StringComparer.Ordinal) { ["Llm:ApiKey"] = LlmApiKeyValue });
        using HttpClient client = host.CreateClient();
        string token = await AuthTestApi.PairAsync(client);

        using HttpResponseMessage response = await AuthTestApi.SendAsync(
            client, HttpMethod.Get, "/api/v1/health", token);

        // Во всех тестах класса проба LLM отказывает: отчёт unhealthy, и
        // MapHealthChecks отвечает 503 с тем же телом отчёта. 401 значил бы,
        // что проверка не дошла до проб.
        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);

        using JsonDocument document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        JsonElement llm = document.RootElement.GetProperty("components").GetProperty("llm");

        return (
            llm.GetProperty("state").GetString() ?? string.Empty,
            llm.GetProperty("description").GetString() ?? string.Empty);
    }

    private sealed class ForbiddenHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden));
    }

    private sealed class NetworkFailureHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromException<HttpResponseMessage>(new HttpRequestException("пробная сетевая ошибка"));
    }
}
