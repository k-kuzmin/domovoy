using System.Runtime.CompilerServices;
using System.Threading.Channels;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Ha;

/// <summary>
/// Раздатчик событий <c>state_changed</c> подписчикам (FR-HA-3).
///
/// Соединение держит <c>HaWebSocketWorker</c>; сюда приходят только
/// события, которые кэш принял: сущность из allow-list и не старше записи.
/// У каждого подписчика свой ограниченный канал: медленный подписчик теряет
/// самые старые свои события, но не задерживает ни воркер, ни соседей.
/// Поток не завершается при обрыве соединения — только отменой подписки.
/// </summary>
internal sealed class HaEventSource : IHaEventSource
{
    /// <summary>Ёмкость канала одного подписчика.</summary>
    public const int SubscriberCapacity = 256;

    private readonly object _sync = new();
    private readonly List<Channel<HaStateChange>> _subscribers = [];

    public IAsyncEnumerable<HaStateChange> SubscribeAsync(CancellationToken cancellationToken)
    {
        // Подписка регистрируется в момент вызова, а не на первом шаге
        // перечисления: событие, опубликованное между вызовом и первым
        // MoveNextAsync, не теряется.
        Channel<HaStateChange> channel = Channel.CreateBounded<HaStateChange>(
            new BoundedChannelOptions(SubscriberCapacity)
            {
                FullMode = BoundedChannelFullMode.DropOldest,
                SingleReader = true,
                SingleWriter = false,
            });

        lock (_sync)
        {
            _subscribers.Add(channel);
        }

        // Подписку, которую отменили, так и не начав перечислять, тоже
        // нужно снять: блок finally перечисления в этом случае не выполнится.
        CancellationTokenRegistration registration = cancellationToken.Register(() => Unsubscribe(channel));

        return ReadAsync(channel, registration, cancellationToken);
    }

    /// <summary>Разослать событие, принятое кэшем, всем активным подписчикам.</summary>
    internal void Publish(HaStateChange change)
    {
        ArgumentNullException.ThrowIfNull(change);

        Channel<HaStateChange>[] subscribers;
        lock (_sync)
        {
            subscribers = [.. _subscribers];
        }

        foreach (Channel<HaStateChange> subscriber in subscribers)
        {
            // DropOldest: запись в ограниченный канал всегда успешна.
            subscriber.Writer.TryWrite(change);
        }
    }

    private async IAsyncEnumerable<HaStateChange> ReadAsync(
        Channel<HaStateChange> channel,
        CancellationTokenRegistration registration,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        try
        {
            await foreach (HaStateChange change in channel.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            {
                yield return change;
            }
        }
        finally
        {
            await registration.DisposeAsync().ConfigureAwait(false);
            Unsubscribe(channel);
        }
    }

    private void Unsubscribe(Channel<HaStateChange> channel)
    {
        lock (_sync)
        {
            _subscribers.Remove(channel);
        }

        channel.Writer.TryComplete();
    }
}
