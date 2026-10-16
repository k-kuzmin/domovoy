using System.Globalization;
using FluentAssertions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Authorization.Policy;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Domovoy.Tests.Auth;

/// <summary>
/// Проба A12-all-routes тестом: защита ослабляется подменой в тестовом хосте,
/// а не правкой <c>src/</c>, и проверки <see cref="RouteAuthenticationAudit"/>
/// обязаны на ней отказать. Без пробы проверка, которая пропускает
/// ослабление, выглядела бы так же зелёно, как работающая.
///
/// Ослабление — декоратор поверх стандартного
/// <see cref="AuthorizationMiddlewareResultHandler"/>: после отказа
/// авторизации пропускает к обработчику ровно <c>GET /api/v1/state</c>,
/// остальное отдаёт стандартному. Пропуск проба узнаёт по статусу ответа,
/// отличному от 401 и 403, а не по телу обработчика: маршрут может получить
/// реализацию, и проба от этого не должна падать.
/// </summary>
public sealed class AuthenticationWeakeningProbeTests : IClassFixture<DomovoyApiFactory>
{
    private const string WeakenedMethod = "GET";
    private const string WeakenedPath = "/api/v1/state";
    private const string ExpectedFailurePrefix = WeakenedMethod + " " + WeakenedPath + ": ";

    private readonly DomovoyApiFactory _factory;

    public AuthenticationWeakeningProbeTests(DomovoyApiFactory factory) => _factory = factory;

    [Fact(DisplayName = "Проба: на хосте, пропускающем GET /api/v1/state без аутентификации, обе проверки маршрутов отказывают")]
    public async Task WeakenedHostFailsRouteAuthenticationAudit()
    {
        using WebApplicationFactory<Program> weakened = _factory.WithWebHostBuilder(builder =>
            builder.ConfigureTestServices(services =>
            {
                services.RemoveAll<IAuthorizationMiddlewareResultHandler>();
                services.AddSingleton<IAuthorizationMiddlewareResultHandler>(
                    new PassStateRouteResultHandler(new AuthorizationMiddlewareResultHandler()));
            }));
        using HttpClient client = weakened.CreateClient();

        IReadOnlyList<string> withoutToken =
            await RouteAuthenticationAudit.NonAnonymousRoutesRejectingAsync(weakened.Services, client, bearer: null);
        IReadOnlyList<string> unknownToken =
            await RouteAuthenticationAudit.NonAnonymousRoutesRejectingAsync(weakened.Services, client, "unknown-device-token");
        IReadOnlyList<string> undocumented =
            await RouteAuthenticationAudit.UndocumentedAnonymousRoutesAsync(weakened.Services, client);

        // Ровно один отказ: подмена ослабляет один маршрут, остальные
        // по-прежнему отвечают 401 — декоратор, а не замена обработчика.
        ShouldBeWeakenedRouteOnly(withoutToken);
        ShouldBeWeakenedRouteOnly(unknownToken);
        ShouldBeWeakenedRouteOnly(undocumented);
    }

    /// <summary>
    /// Отказ ровно один, это ослабленный маршрут, и он прошёл к обработчику:
    /// статус — не 401 и не 403. Строка отказа —
    /// <c>«{метод} {путь}: {статус} {тело}»</c> (<see cref="RouteAuthenticationAudit"/>).
    /// </summary>
    private static void ShouldBeWeakenedRouteOnly(IReadOnlyList<string> failures)
    {
        string failure = failures.Should().ContainSingle().Which;
        failure.Should().StartWith(ExpectedFailurePrefix);
        string status = failure[ExpectedFailurePrefix.Length..].Split(' ', 2)[0];
        int.TryParse(status, NumberStyles.None, CultureInfo.InvariantCulture, out int code).Should().BeTrue("за префиксом идёт код статуса: {0}", failure);
        code.Should().NotBe(StatusCodes.Status401Unauthorized).And.NotBe(StatusCodes.Status403Forbidden);
    }

    [Fact(DisplayName = "Проба: на хосте без подмены те же проверки маршрутов нарушений не находят")]
    public async Task UnweakenedHostPassesRouteAuthenticationAudit()
    {
        using HttpClient client = _factory.CreateClient();

        IReadOnlyList<string> withoutToken =
            await RouteAuthenticationAudit.NonAnonymousRoutesRejectingAsync(_factory.Services, client, bearer: null);
        IReadOnlyList<string> unknownToken =
            await RouteAuthenticationAudit.NonAnonymousRoutesRejectingAsync(_factory.Services, client, "unknown-device-token");
        IReadOnlyList<string> undocumented =
            await RouteAuthenticationAudit.UndocumentedAnonymousRoutesAsync(_factory.Services, client);

        withoutToken.Should().BeEmpty();
        unknownToken.Should().BeEmpty();
        undocumented.Should().BeEmpty();
    }

    /// <summary>
    /// Ослабление пробы: <c>GET /api/v1/state</c> проходит к обработчику
    /// маршрута при любом исходе авторизации, остальное решает стандартный
    /// обработчик.
    /// </summary>
    private sealed class PassStateRouteResultHandler(IAuthorizationMiddlewareResultHandler inner)
        : IAuthorizationMiddlewareResultHandler
    {
        public Task HandleAsync(
            RequestDelegate next,
            HttpContext context,
            AuthorizationPolicy policy,
            PolicyAuthorizationResult authorizeResult) =>
            HttpMethods.IsGet(context.Request.Method) && context.Request.Path.Equals(WeakenedPath, StringComparison.Ordinal)
                ? next(context)
                : inner.HandleAsync(next, context, policy, authorizeResult);
    }
}
