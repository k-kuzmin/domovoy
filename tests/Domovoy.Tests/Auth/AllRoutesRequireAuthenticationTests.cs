using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;
using FluentAssertions;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;

namespace Domovoy.Tests.Auth;

/// <summary>
/// Поведенческая проверка критерия #12: каждый зарегистрированный маршрут,
/// кроме <c>/health</c> и <c>POST /api/v1/auth/device</c>, требует
/// аутентификации.
///
/// <see cref="AnonymousEndpointsRuleTests"/> сверяет метаданные
/// <c>AllowAnonymous</c> с таблицей правила 7, но не поведение: маршрут без
/// атрибута, отвечающий без токена, он не ловит. Здесь маршруты берутся из
/// собранного приложения и каждый получает настоящий запрос.
/// </summary>
public sealed partial class AllRoutesRequireAuthenticationTests : IClassFixture<DomovoyApiFactory>
{
    private const string PairingPath = "/api/v1/auth/device";
    private const string LivenessPath = "/health";

    private readonly DomovoyApiFactory _factory;

    public AllRoutesRequireAuthenticationTests(DomovoyApiFactory factory) => _factory = factory;

    [Theory(DisplayName = "Каждый неанонимный маршрут отвечает 401 в едином формате без токена и с неизвестным токеном")]
    [InlineData(null)]
    [InlineData("unknown-device-token")]
    public async Task EveryNonAnonymousRouteRejectsMissingOrUnknownToken(string? bearer)
    {
        using HttpClient client = _factory.CreateClient();
        List<(string Method, string Path)> routes = Routes()
            .Where(route => !IsDocumentedAnonymous(route.Method, route.Path))
            .ToList();

        // Положительный контроль: пустой или усечённый обход ничего не доказывает.
        routes.Select(route => route.Path).Should().Contain(
            ["/api/v1/chat", "/api/v1/health", AuthTestApi.DevicesPath]);

        var failures = new List<string>();
        foreach ((string method, string path) in routes)
        {
            using HttpResponseMessage response = await AuthTestApi.SendAsync(client, new HttpMethod(method), path, bearer);
            string body = await response.Content.ReadAsStringAsync();

            if (response.StatusCode != HttpStatusCode.Unauthorized || ErrorCode(body) != "unauthorized")
            {
                failures.Add($"{method} {path}: {(int)response.StatusCode} {body}");
            }
        }

        failures.Should().BeEmpty($"проверено пар метод+путь: {routes.Count}");
    }

    [Fact(DisplayName = "Без токена отвечают ровно /health и POST /api/v1/auth/device")]
    public async Task AnonymousRoutesAreExactlyHealthAndPairing()
    {
        using HttpClient client = _factory.CreateClient();
        var answered = new List<(string Method, string Path)>();

        foreach ((string method, string path) in Routes())
        {
            using HttpResponseMessage response = await AuthTestApi.SendAsync(client, new HttpMethod(method), path);

            if (response.StatusCode != HttpStatusCode.Unauthorized)
            {
                answered.Add((method, path));
            }
        }

        answered.Should().OnlyContain(
            route => IsDocumentedAnonymous(route.Method, route.Path),
            "анонимный маршрут появляется только со строкой правила 7 и записью решения");
        answered.Should().Contain(route => route.Path == LivenessPath);
        answered.Should().Contain(("POST", PairingPath));
    }

    /// <summary>
    /// <c>MapHealthChecks</c> метода не объявляет, поэтому <c>/health</c>
    /// сопоставляется по пути при любом методе — как в
    /// <c>AnonymousEndpointsRule.Reconcile</c>.
    /// </summary>
    private static bool IsDocumentedAnonymous(string method, string path) =>
        path == LivenessPath || (method == "POST" && path == PairingPath);

    /// <summary>
    /// Пары метод+путь всех маршрутов собранного приложения; параметры
    /// маршрута заменены значением Guid, у маршрута без метода — GET и POST.
    /// </summary>
    private List<(string Method, string Path)> Routes()
    {
        EndpointDataSource source = _factory.Services.GetRequiredService<EndpointDataSource>();

        return source.Endpoints
            .OfType<RouteEndpoint>()
            .SelectMany(endpoint =>
            {
                string path = RouteParameter().Replace(
                    "/" + endpoint.RoutePattern.RawText!.TrimStart('/'),
                    Guid.NewGuid().ToString());
                IReadOnlyList<string> methods =
                    endpoint.Metadata.GetMetadata<HttpMethodMetadata>()?.HttpMethods is { Count: > 0 } declared
                        ? declared
                        : ["GET", "POST"];
                return methods.Select(method => (method, path));
            })
            .Distinct()
            .ToList();
    }

    private static string? ErrorCode(string body)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            JsonElement error = document.RootElement.GetProperty("error");
            return string.IsNullOrEmpty(error.GetProperty("message").GetString())
                ? null
                : error.GetProperty("code").GetString();
        }
        catch (Exception exception) when (exception is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return null;
        }
    }

    [GeneratedRegex(@"\{[^}]+\}")]
    private static partial Regex RouteParameter();
}
