namespace Domovoy.Core.Models;

/// <summary>Событие <c>state_changed</c> из потока Home Assistant (FR-HA-3).</summary>
public sealed record HaStateChange
{
    public required string EntityId { get; init; }

    /// <summary>Предыдущее состояние. <c>null</c>, если сущность появилась впервые.</summary>
    public HaEntityState? Previous { get; init; }

    public required HaEntityState Current { get; init; }

    public required DateTimeOffset OccurredAt { get; init; }
}
