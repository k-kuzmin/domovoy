using System.Diagnostics.CodeAnalysis;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Api.Endpoints;

/// <summary>
/// Экран «Дом» мобильного клиента: срез состояния (<c>GET /api/v1/state</c>)
/// и быстрое действие (<c>POST /api/v1/action</c>). Оба работают без LLM —
/// только слой Home Assistant и реестр сущностей.
///
/// Allow-list, белый список действий и подтверждение здесь не проверяются:
/// это делает слой Ha в одной точке (<see cref="IHaClient.CallServiceAsync"/>,
/// правило 5 «Безопасность»). Вторая проверка в эндпоинте разъехалась бы с
/// первой.
/// </summary>
internal static class HomeEndpoints
{
    /// <summary>
    /// Действие реестра «только чтение»: сервиса у него нет, кнопкой на
    /// экране оно не становится. Та же строка, что <c>HaDomainCatalog.ReadAction</c>
    /// слоя Ha (он internal и из Api не виден).
    /// </summary>
    private const string ReadAction = "read";

    private const string HaUnavailableMessage = "Home Assistant недоступен.";
    private const string InvalidActionRequestMessage =
        "Тело запроса — JSON-объект с непустыми строками entity_id и action; value — строка, число или логическое.";
    private const string InternalErrorMessage = "Действие не выполнено.";

    /// <summary>
    /// Срез состояния дома по комнатам реестра. Состояния — только сущности
    /// allow-list (фильтр в слое Ha); имена и комнаты — из реестра, а не из
    /// атрибутов HA (NFR-SEC-6). Сущность, состояния которой HA не вернул, в
    /// срез не попадает: состояние не выдумывается.
    ///
    /// <c>as_of</c> — момент, когда срез снят с источника, который слой Ha
    /// считает актуальным (REST в этом запросе или кэш живого соединения);
    /// свежесть каждой сущности несёт <c>last_updated</c> — метка HA.
    /// HA недоступен — 503 <c>ha_unavailable</c>, устаревший срез не отдаётся.
    /// </summary>
    public static async Task<IResult> GetStateAsync(
        IHaClient ha,
        IEntityAllowList allowList,
        TimeProvider timeProvider,
        CancellationToken cancellationToken)
    {
        IReadOnlyList<HaEntityState> states;
        try
        {
            states = await ha.GetStatesAsync(area: null, domain: null, cancellationToken);
        }
        catch (HaUnavailableException)
        {
            return ApiErrorResults.Result(
                StatusCodes.Status503ServiceUnavailable,
                HaErrorCodes.HaUnavailable,
                HaUnavailableMessage);
        }

        DateTimeOffset asOf = timeProvider.GetUtcNow();
        var byEntity = new Dictionary<string, HaEntityState>(StringComparer.Ordinal);
        foreach (HaEntityState state in states)
        {
            byEntity[state.EntityId] = state;
        }

        StateArea[] areas = allowList.Areas
            .Select(area => new StateArea(
                area.Id,
                area.Name,
                [
                    .. allowList.All
                        .Where(entity => string.Equals(entity.Area, area.Id, StringComparison.Ordinal))
                        .Where(entity => byEntity.ContainsKey(entity.EntityId))
                        .Select(entity => ToStateEntity(entity, byEntity[entity.EntityId])),
                ]))
            .ToArray();

        return Results.Json(new StateResponse(asOf, areas));
    }

    /// <summary>
    /// Действие над сущностью из интерфейса, минуя LLM. Домен — префикс
    /// <c>entity_id</c>; всё остальное решает слой Ha до HTTP-запроса. Отказ
    /// слоя Ha уходит в едином формате: код — <see cref="ToolResult.ErrorCode"/>
    /// как есть, сообщение — <see cref="ToolResult.Error"/>, уже обезличенное.
    /// </summary>
    public static async Task<IResult> PostActionAsync(HttpContext context, IHaClient ha)
    {
        ActionRequest? request = await ReadActionRequestAsync(context);
        if (request is null)
        {
            return ApiErrorResults.Result(
                StatusCodes.Status400BadRequest,
                ApiErrorResults.InvalidRequest,
                InvalidActionRequestMessage);
        }

        ToolResult result = await ha.CallServiceAsync(
            DomainOf(request.EntityId),
            request.Action,
            request.EntityId,
            request.Value,
            context.RequestAborted);

        if (result.Success)
        {
            return Results.Json(new ActionResponse(request.EntityId, request.Action));
        }

        (int status, string code) = result.ErrorCode switch
        {
            HaErrorCodes.EntityNotAllowed => (StatusCodes.Status403Forbidden, HaErrorCodes.EntityNotAllowed),
            HaErrorCodes.ActionNotAllowed => (StatusCodes.Status403Forbidden, HaErrorCodes.ActionNotAllowed),
            HaErrorCodes.InvalidValue => (StatusCodes.Status400BadRequest, HaErrorCodes.InvalidValue),
            HaErrorCodes.ConfirmationRequired => (StatusCodes.Status409Conflict, HaErrorCodes.ConfirmationRequired),
            HaErrorCodes.HaRejected => (StatusCodes.Status422UnprocessableEntity, HaErrorCodes.HaRejected),
            HaErrorCodes.HaUnavailable => (StatusCodes.Status503ServiceUnavailable, HaErrorCodes.HaUnavailable),
            _ => (StatusCodes.Status500InternalServerError, ApiErrorResults.InternalError),
        };

        string message = string.IsNullOrWhiteSpace(result.Error) ? InternalErrorMessage : result.Error;
        return ApiErrorResults.Result(status, code, message);
    }

    private static StateEntity ToStateEntity(HaEntityDescriptor entity, HaEntityState state) =>
        new(
            entity.EntityId,
            entity.FriendlyName,
            entity.Domain,
            state.State,
            state.LastUpdated,
            [.. entity.AllowedActions.Where(action => !string.Equals(action, ReadAction, StringComparison.Ordinal))]);

    /// <summary>
    /// Тело читается вручную, а не привязкой параметра: при неверном JSON
    /// привязка ответила бы своим форматом, а не единым. Значение остаётся
    /// сырым текстом: число — как записано в JSON, логическое — true/false,
    /// строка — как есть; разбирает его один каталог слоя Ha, общий с
    /// быстрым путём. JSON <c>null</c> в <c>value</c> — то же, что поле
    /// не передано.
    /// </summary>
    private static async Task<ActionRequest?> ReadActionRequestAsync(HttpContext context)
    {
        if (!context.Request.HasJsonContentType())
        {
            return null;
        }

        JsonDocument document;
        try
        {
            document = await JsonDocument.ParseAsync(context.Request.Body, cancellationToken: context.RequestAborted);
        }
        catch (JsonException)
        {
            return null;
        }

        using (document)
        {
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !TryReadRequiredString(root, "entity_id", out string? entityId)
                || !TryReadRequiredString(root, "action", out string? action))
            {
                return null;
            }

            string? value = null;
            if (root.TryGetProperty("value", out JsonElement rawValue))
            {
                switch (rawValue.ValueKind)
                {
                    case JsonValueKind.Null:
                        break;
                    case JsonValueKind.String:
                        value = rawValue.GetString();
                        break;
                    case JsonValueKind.Number:
                        value = rawValue.GetRawText();
                        break;
                    case JsonValueKind.True:
                    case JsonValueKind.False:
                        value = rawValue.GetBoolean() ? "true" : "false";
                        break;
                    default:
                        return null;
                }
            }

            return new ActionRequest(entityId, action, value);
        }
    }

    private static bool TryReadRequiredString(JsonElement root, string name, [NotNullWhen(true)] out string? value)
    {
        value = root.TryGetProperty(name, out JsonElement element) && element.ValueKind == JsonValueKind.String
            ? element.GetString()
            : null;

        return !string.IsNullOrWhiteSpace(value);
    }

    /// <summary>Домен — префикс <c>entity_id</c> до точки, как в быстром пути.</summary>
    private static string DomainOf(string entityId)
    {
        int dot = entityId.IndexOf('.', StringComparison.Ordinal);
        return dot > 0 ? entityId[..dot] : string.Empty;
    }

    private sealed record ActionRequest(string EntityId, string Action, string? Value);

    private sealed record StateResponse(
        [property: JsonPropertyName("as_of")] DateTimeOffset AsOf,
        [property: JsonPropertyName("areas")] IReadOnlyList<StateArea> Areas);

    private sealed record StateArea(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("entities")] IReadOnlyList<StateEntity> Entities);

    private sealed record StateEntity(
        [property: JsonPropertyName("entity_id")] string EntityId,
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("domain")] string Domain,
        [property: JsonPropertyName("state")] string State,
        [property: JsonPropertyName("last_updated")] DateTimeOffset LastUpdated,
        [property: JsonPropertyName("actions")] IReadOnlyList<string> Actions);

    private sealed record ActionResponse(
        [property: JsonPropertyName("entity_id")] string EntityId,
        [property: JsonPropertyName("action")] string Action);
}
