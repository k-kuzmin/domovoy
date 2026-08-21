using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Краткосрочная память: история диалога скользящим окном, общая между
/// устройствами одного пользователя (FR-MEM-1).
/// </summary>
public interface IConversationStore
{
    /// <summary>Последние сообщения диалога, от старых к новым.</summary>
    Task<IReadOnlyList<ConversationMessage>> GetRecentAsync(
        string conversationId,
        int maxMessages,
        CancellationToken cancellationToken);

    Task AppendAsync(ConversationMessage message, CancellationToken cancellationToken);
}
