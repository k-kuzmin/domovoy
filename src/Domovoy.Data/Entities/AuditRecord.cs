using System.Text.Json;
using Domovoy.Core.Models;

namespace Domovoy.Data.Entities;

/// <summary>
/// Строка аудит-лога (таблица <c>audit_entries</c>, FR-CORE-6).
/// Аргументы хранятся JSON-объектом в <c>jsonb</c>, источник — строкой.
/// </summary>
internal sealed class AuditRecord
{
    public long Id { get; set; }

    public DateTimeOffset OccurredAt { get; set; }

    public string RequestId { get; set; } = "";

    public AgentRequestSource Source { get; set; }

    public string OriginalPhrase { get; set; } = "";

    public string ToolName { get; set; } = "";

    /// <summary>Аргументы вызова, сериализованные в JSON-объект.</summary>
    public string Arguments { get; set; } = "{}";

    public bool Success { get; set; }

    public string? Error { get; set; }

    /// <summary>
    /// Единственный маппинг <see cref="AuditEntry"/> в строку таблицы: им
    /// пишут и <see cref="EfAuditLog"/>, и отзыв устройства.
    /// </summary>
    public static AuditRecord From(AuditEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);

        return new AuditRecord
        {
            OccurredAt = entry.OccurredAt,
            RequestId = entry.RequestId,
            Source = entry.Source,
            OriginalPhrase = entry.OriginalPhrase,
            ToolName = entry.ToolName,
            Arguments = JsonSerializer.Serialize(entry.Arguments),
            Success = entry.Success,
            Error = entry.Error,
        };
    }
}
