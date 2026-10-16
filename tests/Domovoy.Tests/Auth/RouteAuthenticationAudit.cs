using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;

namespace Domovoy.Tests.Auth;

/// <summary>
/// Обход всех маршрутов собранного приложения настоящими запросами: общий для
/// <see cref="AllRoutesRequireAuthenticationTests"/> и пробы ослабления защиты
/// <c>AuthenticationWeakeningProbeTests</c>. Проверки возвращают список
/// нарушений, а не утверждают сами: проба утверждает, что на ослабленном
/// хосте список непустой, — иначе проверка, пропускающая ослабление, прошла
/// бы незамеченной.
///
/// Элемент списка — «&lt;METHOD&gt; &lt;path&gt;: &lt;код&gt; &lt;тело&gt;».
/// </summary>
internal static partial class RouteAuthenticationAudit
{
    public const string PairingPath = "/api/v1/auth/device";
    public const string LivenessPath = "/health";

    /// <summary>
    /// Неанонимные маршруты, ответившие не 401 в едином формате
    /// (<c>error.code = unauthorized</c> при непустом <c>error.message</c>)
    /// на запрос с токеном <paramref name="bearer"/> (<c>null</c> — без токена).
    /// </summary>
    public static async Task<IReadOnlyList<string>> NonAnonymousRoutesRejectingAsync(
        IServiceProvider services, HttpClient client, string? bearer)
    {
        var failures = new List<string>();
        foreach ((string method, string path) in Routes(services).Where(route => !IsDocumentedAnonymous(route.Method, route.Path)))
        {
            using HttpResponseMessage response = await AuthTestApi.SendAsync(client, new HttpMethod(method), path, bearer);
            string body = await response.Content.ReadAsStringAsync();

            if (response.StatusCode != HttpStatusCode.Unauthorized || ErrorCode(body) != "unauthorized")
            {
                failures.Add($"{method} {path}: {(int)response.StatusCode} {body}");
            }
        }

        return failures;
    }

    /// <summary>
    /// Маршруты вне таблицы правила 7, ответившие без токена не 401.
    /// </summary>
    public static async Task<IReadOnlyList<string>> UndocumentedAnonymousRoutesAsync(
        IServiceProvider services, HttpClient client)
    {
        var answered = new List<string>();
        foreach ((string method, string path) in Routes(services))
        {
            using HttpResponseMessage response = await AuthTestApi.SendAsync(client, new HttpMethod(method), path);

            if (response.StatusCode != HttpStatusCode.Unauthorized && !IsDocumentedAnonymous(method, path))
            {
                string body = await response.Content.ReadAsStringAsync();
                answered.Add($"{method} {path}: {(int)response.StatusCode} {body}");
            }
        }

        return answered;
    }

    /// <summary>
    /// <c>MapHealthChecks</c> метода не объявляет, поэтому <c>/health</c>
    /// сопоставляется по пути при любом методе — как в
    /// <c>AnonymousEndpointsRule.Reconcile</c>.
    /// </summary>
    public static bool IsDocumentedAnonymous(string method, string path) =>
        path == LivenessPath || (method == "POST" && path == PairingPath);

    /// <summary>
    /// Пары метод+путь всех маршрутов собранного приложения; параметры
    /// маршрута заменены значением Guid, у маршрута без метода — GET и POST.
    /// </summary>
    public static List<(string Method, string Path)> Routes(IServiceProvider services)
    {
        EndpointDataSource source = services.GetRequiredService<EndpointDataSource>();

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
