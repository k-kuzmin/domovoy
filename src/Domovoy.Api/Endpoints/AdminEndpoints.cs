using System.Text.Json.Serialization;
using Domovoy.Api.Security;
using Domovoy.Core.Auth;
using Domovoy.Core.Models;

namespace Domovoy.Api.Endpoints;

/// <summary>
/// Админ-эндпоинты привязки устройств (#13, запись 0032): выпуск кода
/// привязки, список устройств, отзыв.
///
/// Группа смаплена отдельно от <c>/api/v1</c>, а не внутри неё: политики
/// группы и вложенного маршрута складываются, и админ-запрос был бы обязан
/// пройти ещё и схему устройства. Здесь действует только админ-политика.
///
/// Сбой хранилища (кроме отмены) — 503 auth_unavailable без текста
/// исключения: оно остаётся в логе.
/// </summary>
public static class AdminEndpoints
{
    public static IEndpointRouteBuilder MapAdminEndpoints(this IEndpointRouteBuilder app)
    {
        ArgumentNullException.ThrowIfNull(app);

        RouteGroupBuilder admin = app.MapGroup("/api/v1/admin")
            .RequireAuthorization(DeviceTokenDefaults.AdminPolicyName);

        admin.MapPost("/pairing-codes", IssuePairingCodeAsync)
            .WithName("admin-issue-pairing-code");

        admin.MapGet("/devices", ListDevicesAsync)
            .WithName("admin-list-devices");

        admin.MapDelete("/devices/{id:guid}", RevokeDeviceAsync)
            .WithName("admin-revoke-device");

        return app;
    }

    /// <summary>Открытое значение кода отдаётся один раз и не кэшируется.</summary>
    private static Task<IResult> IssuePairingCodeAsync(
        HttpContext context,
        DeviceAuthService deviceAuth,
        ILoggerFactory loggerFactory) =>
        GuardStoreAsync(loggerFactory, async () =>
        {
            PairingCodeIssued issued = await deviceAuth.IssuePairingCodeAsync(context.RequestAborted);
            context.Response.Headers.CacheControl = "no-store";
            return Results.Json(
                new PairingCodeResponse(issued.Code, issued.ExpiresAt),
                statusCode: StatusCodes.Status201Created);
        });

    private static Task<IResult> ListDevicesAsync(
        HttpContext context,
        DeviceAuthService deviceAuth,
        ILoggerFactory loggerFactory) =>
        GuardStoreAsync(loggerFactory, async () =>
        {
            IReadOnlyList<DeviceInfo> devices = await deviceAuth.ListDevicesAsync(context.RequestAborted);
            return Results.Json(new DeviceListResponse(devices.Select(DeviceResponse.From).ToList()));
        });

    private static Task<IResult> RevokeDeviceAsync(
        Guid id,
        HttpContext context,
        DeviceAuthService deviceAuth,
        ILoggerFactory loggerFactory) =>
        GuardStoreAsync(loggerFactory, async () =>
        {
            bool revoked = await deviceAuth.RevokeDeviceAsync(id, context.TraceIdentifier, context.RequestAborted);
            return revoked
                ? Results.NoContent()
                : ApiErrorResults.Result(
                    StatusCodes.Status404NotFound,
                    ApiErrorResults.DeviceNotFound,
                    "Устройство не найдено или уже отозвано.");
        });

    private static async Task<IResult> GuardStoreAsync(ILoggerFactory loggerFactory, Func<Task<IResult>> action)
    {
        try
        {
            return await action();
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            loggerFactory.CreateLogger(typeof(AdminEndpoints).FullName!)
                .LogWarning(exception, "Хранилище устройств недоступно: админ-действие не выполнено.");
            return ApiErrorResults.Result(
                StatusCodes.Status503ServiceUnavailable,
                ApiErrorResults.AuthUnavailable,
                ApiErrorResults.AuthUnavailableMessage);
        }
    }

    private sealed record PairingCodeResponse(
        [property: JsonPropertyName("code")] string Code,
        [property: JsonPropertyName("expires_at")] DateTimeOffset ExpiresAt);

    private sealed record DeviceListResponse(
        [property: JsonPropertyName("devices")] IReadOnlyList<DeviceResponse> Devices);

    private sealed record DeviceResponse(
        [property: JsonPropertyName("id")] Guid Id,
        [property: JsonPropertyName("name")] string? Name,
        [property: JsonPropertyName("created_at")] DateTimeOffset CreatedAt,
        [property: JsonPropertyName("last_seen_at")] DateTimeOffset? LastSeenAt,
        [property: JsonPropertyName("revoked_at")] DateTimeOffset? RevokedAt)
    {
        public static DeviceResponse From(DeviceInfo device) =>
            new(device.Id, device.Name, device.CreatedAt, device.LastSeenAt, device.RevokedAt);
    }
}
