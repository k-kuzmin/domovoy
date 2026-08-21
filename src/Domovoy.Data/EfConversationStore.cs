using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Data;

/// <summary>
/// Краткосрочная память в базе (FR-MEM-1).
/// Каркас: реализация появляется на этапе 2.
/// </summary>
internal sealed class EfConversationStore : IConversationStore
{
    private readonly DomovoyDbContext _db;

    public EfConversationStore(DomovoyDbContext db) => _db = db;

    public Task<IReadOnlyList<ConversationMessage>> GetRecentAsync(
        string conversationId,
        int maxMessages,
        CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 2: скользящее окно истории диалога.");

    public Task AppendAsync(ConversationMessage message, CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 2: запись сообщения в историю.");
}
