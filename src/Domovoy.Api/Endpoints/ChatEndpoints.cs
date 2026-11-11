using System.Diagnostics.CodeAnalysis;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Api.Endpoints;

/// <summary>
/// Текстовый запрос <c>POST /api/v1/chat</c> (раздел 5 ТЗ). Ответ
/// собирается только из событий <see cref="IOrchestrator"/>: поток SSE
/// этапа 2 и единое тело должны совпадать по содержанию, поэтому полей в
/// обход событий здесь нет.
///
/// Режим ответа выбирает <c>Accept</c>. Единое тело — только когда клиент
/// явно перечислил <c>application/json</c>; режим по умолчанию — SSE
/// (FR-CORE-8), его ещё нет, и такой запрос получает 501, а не JSON: иначе
/// на этапе 2 тот же клиент молча получил бы другой формат ответа.
/// </summary>
internal static class ChatEndpoints
{
    /// <summary>Предел длины фразы: запрос — реплика, а не документ.</summary>
    private const int MaxTextLength = 2000;

    /// <summary>Предел длины идентификатора диалога.</summary>
    private const int MaxConversationIdLength = 128;

    private const string JsonMediaType = "application/json";

    private const string InvalidChatRequestMessage =
        "Тело запроса — JSON-объект с непустой строкой text не длиннее 2000 символов; conversation_id — строка не длиннее 128 символов.";

    private const string StreamNotImplementedMessage =
        "Поток SSE — этап 2. Ответ единым телом — с заголовком Accept: application/json.";

    /// <summary>
    /// Сообщение 500 и замена пустого сообщения отказа: без текста исключения
    /// и без значений запроса.
    /// </summary>
    private const string InternalErrorMessage = "Запрос не выполнен.";

    public static async Task<IResult> PostChatAsync(
        HttpContext context,
        IOrchestrator orchestrator,
        ILoggerFactory loggerFactory)
    {
        if (!AcceptsJson(context.Request))
        {
            return ApiErrorResults.Result(
                StatusCodes.Status501NotImplemented,
                ApiErrorResults.NotImplemented,
                StreamNotImplementedMessage);
        }

        ChatRequest? chat = await ReadChatRequestAsync(context);
        if (chat is null)
        {
            return ApiErrorResults.Result(
                StatusCodes.Status400BadRequest,
                ApiErrorResults.InvalidRequest,
                InvalidChatRequestMessage);
        }

        ILogger logger = loggerFactory.CreateLogger(typeof(ChatEndpoints).FullName!);

        // Маршрут под токеном устройства: claim кладёт обработчик
        // аутентификации. Его отсутствие — ошибка конфигурации, а не клиента.
        string? deviceId = context.User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (string.IsNullOrEmpty(deviceId))
        {
            logger.LogWarning("Запрос /chat без идентификатора устройства в учётных данных.");
            return InternalError();
        }

        var request = new AgentRequest
        {
            RequestId = context.TraceIdentifier,
            DeviceId = deviceId,
            Text = chat.Text,
            Source = AgentRequestSource.Text,
            ConversationId = chat.ConversationId,
        };

        var text = new StringBuilder();
        var actions = new List<ChatAction>();
        bool done = false;

        try
        {
            await foreach (AgentEvent agentEvent in orchestrator.HandleAsync(request, context.RequestAborted))
            {
                switch (agentEvent)
                {
                    case ActionEvent action:
                        actions.Add(new ChatAction(action.EntityId, action.Action, action.Success));
                        break;
                    case TokenEvent token:
                        text.Append(token.Text);
                        break;
                    case ErrorEvent error:
                        (int status, string code) = ApiErrorResults.ForHaErrorCode(error.Code);
                        string message = string.IsNullOrWhiteSpace(error.Message) ? InternalErrorMessage : error.Message;
                        return ApiErrorResults.Result(status, code, message);
                    case DoneEvent:
                        done = true;
                        break;
                }

                if (done)
                {
                    break;
                }
            }
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            logger.LogWarning(exception, "Оркестратор не выполнил запрос /chat {RequestId}.", request.RequestId);
            return InternalError();
        }

        if (!done)
        {
            // Контракт порта: поток завершается done или error.
            logger.LogWarning("Поток оркестратора для запроса /chat {RequestId} оборвался без done.", request.RequestId);
            return InternalError();
        }

        return Results.Json(new ChatResponse(request.RequestId, text.ToString(), actions));
    }

    /// <summary>
    /// Единое тело — только если <c>Accept</c> явно перечисляет
    /// <c>application/json</c> с ненулевым весом. Отсутствующий заголовок,
    /// <c>*/*</c> и <c>application/*</c> — режим по умолчанию, то есть SSE.
    /// </summary>
    private static bool AcceptsJson(HttpRequest request) =>
        request.GetTypedHeaders().Accept.Any(value =>
            value.MediaType.Equals(JsonMediaType, StringComparison.OrdinalIgnoreCase)
            && (value.Quality is null || value.Quality > 0));

    /// <summary>
    /// Тело читается вручную, а не привязкой параметра: при неверном JSON
    /// привязка ответила бы своим форматом, а не единым. Невалидный UTF-8 —
    /// тоже 400, а не 500: вне строк его отвергает парсер, внутри строки —
    /// только чтение значения (<see cref="TryReadString"/>).
    /// </summary>
    private static async Task<ChatRequest?> ReadChatRequestAsync(HttpContext context)
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
                || !root.TryGetProperty("text", out JsonElement rawText)
                || !TryReadString(rawText, out string? text)
                || string.IsNullOrWhiteSpace(text)
                || text.Length > MaxTextLength)
            {
                return null;
            }

            string? conversationId = null;
            if (root.TryGetProperty("conversation_id", out JsonElement rawConversation))
            {
                switch (rawConversation.ValueKind)
                {
                    case JsonValueKind.Null:
                        break;
                    case JsonValueKind.String:
                        if (!TryReadString(rawConversation, out conversationId)
                            || conversationId.Length > MaxConversationIdLength)
                        {
                            return null;
                        }

                        break;
                    default:
                        return null;
                }
            }

            return new ChatRequest(text, conversationId);
        }
    }

    /// <summary>
    /// Строковое значение JSON. Парсер не проверяет UTF-8 внутри строк:
    /// невалидная последовательность всплывает только здесь, исключением
    /// <see cref="InvalidOperationException"/> из <see cref="JsonElement.GetString"/>.
    /// </summary>
    private static bool TryReadString(JsonElement element, [NotNullWhen(true)] out string? value)
    {
        value = null;
        if (element.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        try
        {
            value = element.GetString();
        }
        catch (InvalidOperationException)
        {
            return false;
        }

        return value is not null;
    }

    private static IResult InternalError() =>
        ApiErrorResults.Result(
            StatusCodes.Status500InternalServerError,
            ApiErrorResults.InternalError,
            InternalErrorMessage);

    private sealed record ChatRequest(string Text, string? ConversationId);

    private sealed record ChatResponse(
        [property: JsonPropertyName("request_id")] string RequestId,
        [property: JsonPropertyName("text")] string Text,
        [property: JsonPropertyName("actions")] IReadOnlyList<ChatAction> Actions);

    private sealed record ChatAction(
        [property: JsonPropertyName("entity_id")] string EntityId,
        [property: JsonPropertyName("action")] string Action,
        [property: JsonPropertyName("success")] bool Success);
}
