using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Ha.State;

/// <summary>
/// Кэш текущих состояний сущностей из allow-list (FR-HA-3, FR-HA-4).
///
/// Фильтр allow-list стоит на входе данных: сущность вне списка в кэш не
/// попадает ни из <c>get_states</c>, ни из события, поэтому читающим кэш
/// фильтровать уже нечего. Актуальность кэша кэш сам не знает: её выражает
/// статус соединения <c>HaConnectionState</c> — при обрыве содержимое
/// остаётся, но как актуальное не отдаётся.
///
/// События одной сущности упорядочиваются по <c>last_updated</c>: оно
/// меняется и при смене одних атрибутов, в отличие от <c>last_changed</c>.
/// </summary>
internal sealed class HaStateCache
{
    private readonly IEntityAllowList _allowList;
    private readonly object _sync = new();
    private Dictionary<string, HaEntityState> _states = new(StringComparer.Ordinal);

    public HaStateCache(IEntityAllowList allowList)
    {
        ArgumentNullException.ThrowIfNull(allowList);

        _allowList = allowList;
    }

    /// <summary>
    /// Атомарная замена содержимого: сущности вне списка отброшены, записи,
    /// которых нет в новом наборе, удалены.
    /// </summary>
    public void ReplaceAll(IEnumerable<HaEntityState> states)
    {
        ArgumentNullException.ThrowIfNull(states);

        var replacement = new Dictionary<string, HaEntityState>(StringComparer.Ordinal);
        foreach (HaEntityState state in states)
        {
            if (_allowList.Find(state.EntityId) is not null)
            {
                replacement[state.EntityId] = state;
            }
        }

        lock (_sync)
        {
            _states = replacement;
        }
    }

    /// <summary>
    /// Применить событие. <c>false</c> — сущность вне списка или событие
    /// строго старше записи; событие с равной меткой применяется.
    /// </summary>
    public bool Apply(HaStateChange change)
    {
        ArgumentNullException.ThrowIfNull(change);

        if (_allowList.Find(change.EntityId) is null)
        {
            return false;
        }

        lock (_sync)
        {
            if (_states.TryGetValue(change.EntityId, out HaEntityState? existing)
                && change.Current.LastUpdated < existing.LastUpdated)
            {
                return false;
            }

            _states[change.EntityId] = change.Current;
            return true;
        }
    }

    /// <summary>Удалить запись, если она есть. Событий не порождает.</summary>
    public void Remove(string entityId)
    {
        lock (_sync)
        {
            _states.Remove(entityId);
        }
    }

    public HaEntityState? Find(string entityId)
    {
        lock (_sync)
        {
            return _states.GetValueOrDefault(entityId);
        }
    }

    /// <summary>Копия содержимого на момент вызова.</summary>
    public IReadOnlyList<HaEntityState> Snapshot()
    {
        lock (_sync)
        {
            return _states.Values.ToArray();
        }
    }
}
