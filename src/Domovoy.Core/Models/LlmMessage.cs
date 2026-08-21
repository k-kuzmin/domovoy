namespace Domovoy.Core.Models;

/// <summary>Роль сообщения в запросе к модели.</summary>
public enum LlmRole
{
    System,
    User,
    Assistant,
    Tool,
}

/// <summary>Сообщение в запросе к модели.</summary>
public sealed record LlmMessage
{
    public required LlmRole Role { get; init; }

    public required string Content { get; init; }

    /// <summary>Заполняется для роли <see cref="LlmRole.Tool"/>.</summary>
    public string? ToolCallId { get; init; }
}
