using System.Net;
using FluentAssertions;

namespace Domovoy.Tests.Auth;

/// <summary>
/// Поведенческая проверка критерия #12: каждый зарегистрированный маршрут,
/// кроме <c>/health</c> и <c>POST /api/v1/auth/device</c>, требует
/// аутентификации.
///
/// <see cref="AnonymousEndpointsRuleTests"/> сверяет метаданные
/// <c>AllowAnonymous</c> с таблицей правила 7, но не поведение: маршрут без
/// атрибута, отвечающий без токена, он не ловит. Здесь маршруты берутся из
/// собранного приложения и каждый получает настоящий запрос — обходом
/// <see cref="RouteAuthenticationAudit"/>, тем же, что проверяет проба
/// ослабления защиты <c>AuthenticationWeakeningProbeTests</c>.
/// </summary>
public sealed class AllRoutesRequireAuthenticationTests : IClassFixture<DomovoyApiFactory>
{
    private readonly DomovoyApiFactory _factory;

    public AllRoutesRequireAuthenticationTests(DomovoyApiFactory factory) => _factory = factory;

    [Theory(DisplayName = "Каждый неанонимный маршрут отвечает 401 в едином формате без токена и с неизвестным токеном")]
    [InlineData(null)]
    [InlineData("unknown-device-token")]
    public async Task EveryNonAnonymousRouteRejectsMissingOrUnknownToken(string? bearer)
    {
        using HttpClient client = _factory.CreateClient();
        List<(string Method, string Path)> routes = RouteAuthenticationAudit.Routes(_factory.Services)
            .Where(route => !RouteAuthenticationAudit.IsDocumentedAnonymous(route.Method, route.Path))
            .ToList();

        // Положительный контроль: пустой или усечённый обход ничего не доказывает.
        routes.Select(route => route.Path).Should().Contain(
            ["/api/v1/chat", "/api/v1/health", AuthTestApi.DevicesPath]);

        IReadOnlyList<string> failures =
            await RouteAuthenticationAudit.NonAnonymousRoutesRejectingAsync(_factory.Services, client, bearer);

        failures.Should().BeEmpty($"проверено пар метод+путь: {routes.Count}");
    }

    [Fact(DisplayName = "Без токена отвечают ровно /health и POST /api/v1/auth/device")]
    public async Task AnonymousRoutesAreExactlyHealthAndPairing()
    {
        using HttpClient client = _factory.CreateClient();

        IReadOnlyList<string> undocumented =
            await RouteAuthenticationAudit.UndocumentedAnonymousRoutesAsync(_factory.Services, client);

        undocumented.Should().BeEmpty(
            "анонимный маршрут появляется только со строкой правила 7 и записью решения");

        // Положительный контроль: документированные анонимные маршруты есть в
        // обходе и действительно отвечают без токена.
        List<(string Method, string Path)> routes = RouteAuthenticationAudit.Routes(_factory.Services);
        routes.Should().Contain(route => route.Path == RouteAuthenticationAudit.LivenessPath);
        routes.Should().Contain(("POST", RouteAuthenticationAudit.PairingPath));

        var answered = new List<(string Method, string Path)>();
        foreach ((string method, string path) in routes.Where(route =>
            RouteAuthenticationAudit.IsDocumentedAnonymous(route.Method, route.Path)))
        {
            using HttpResponseMessage response = await AuthTestApi.SendAsync(client, new HttpMethod(method), path);

            if (response.StatusCode != HttpStatusCode.Unauthorized)
            {
                answered.Add((method, path));
            }
        }

        answered.Should().Contain(route => route.Path == RouteAuthenticationAudit.LivenessPath);
        answered.Should().Contain(("POST", RouteAuthenticationAudit.PairingPath));
    }
}
