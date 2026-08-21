namespace Domovoy.Core.Models;

/// <summary>Роль автора сообщения в диалоге.</summary>
public enum MessageRole
{
    User,
    Assistant,
    Tool,
}

/// <summary>
/// Сообщение краткосрочной памяти. Окно скользящее: N последних
/// сообщений или M токенов (FR-MEM-1).
/// </summary>
public sealed record ConversationMessage
{
    public required string ConversationId { get; init; }

    public required MessageRole Role { get; init; }

    public required string Content { get; init; }

    public required DateTimeOffset CreatedAt { get; init; }
}
