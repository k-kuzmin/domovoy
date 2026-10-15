using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Tests.Auth;

/// <summary>
/// Хранилище устройств в памяти для тестов: без Postgres, потокобезопасно
/// (один lock на всё состояние). Погашение кода и отзыв атомарны так же,
/// как в EF-реализации: под одной блокировкой.
///
/// <see cref="StoredHashes"/> копит каждое байтовое значение, попавшее в
/// хранилище, — по нему тест доказывает, что открытые токен и код сюда не
/// доходят. <see cref="FailFind"/> и <see cref="FailTouch"/> имитируют
/// сбой хранилища.
/// </summary>
public sealed class InMemoryDeviceStore : IDeviceStore
{
    /// <summary>Текст исключения имитированного сбоя: в ответе API его быть не должно.</summary>
    public const string FailureMessage = "InMemoryDeviceStore: имитированный сбой хранилища";

    private readonly object _gate = new();
    private readonly List<PairingCode> _codes = [];
    private readonly List<Device> _devices = [];
    private readonly List<byte[]> _storedHashes = [];
    private readonly List<AuditEntry> _auditEntries = [];
    private int _findCalls;

    /// <summary>Бросать из <see cref="FindActiveDeviceAsync"/>.</summary>
    public bool FailFind { get; set; }

    /// <summary>Бросать из <see cref="TouchLastSeenAsync"/>.</summary>
    public bool FailTouch { get; set; }

    /// <summary>Число вызовов <see cref="FindActiveDeviceAsync"/>.</summary>
    public int FindCalls
    {
        get
        {
            lock (_gate)
            {
                return _findCalls;
            }
        }
    }

    /// <summary>Все байтовые значения, переданные хранилищу на запись.</summary>
    public IReadOnlyList<byte[]> StoredHashes
    {
        get
        {
            lock (_gate)
            {
                return _storedHashes.Select(hash => hash.ToArray()).ToList();
            }
        }
    }

    /// <summary>Записи аудита, переданные в <see cref="RevokeDeviceAsync"/> и записанные.</summary>
    public IReadOnlyList<AuditEntry> AuditEntries
    {
        get
        {
            lock (_gate)
            {
                return _auditEntries.ToList();
            }
        }
    }

    public Task AddPairingCodeAsync(
        byte[] codeHash,
        DateTimeOffset createdAt,
        DateTimeOffset expiresAt,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(codeHash);
        lock (_gate)
        {
            _codes.Add(new PairingCode(codeHash.ToArray(), expiresAt));
            _storedHashes.Add(codeHash.ToArray());
        }

        return Task.CompletedTask;
    }

    public Task<Guid?> RedeemPairingCodeAsync(
        byte[] codeHash,
        byte[] tokenHash,
        string? deviceName,
        DateTimeOffset now,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(codeHash);
        ArgumentNullException.ThrowIfNull(tokenHash);
        lock (_gate)
        {
            PairingCode? code = _codes.Find(candidate =>
                candidate.Hash.AsSpan().SequenceEqual(codeHash) && !candidate.Used && candidate.ExpiresAt > now);
            if (code is null)
            {
                return Task.FromResult<Guid?>(null);
            }

            code.Used = true;
            var device = new Device(Guid.NewGuid(), deviceName, tokenHash.ToArray(), now);
            _devices.Add(device);
            _storedHashes.Add(tokenHash.ToArray());
            return Task.FromResult<Guid?>(device.Id);
        }
    }

    public Task<ActiveDevice?> FindActiveDeviceAsync(byte[] tokenHash, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(tokenHash);
        lock (_gate)
        {
            _findCalls++;
            if (FailFind)
            {
                throw new InvalidOperationException(FailureMessage);
            }

            Device? device = _devices.Find(candidate =>
                candidate.TokenHash.AsSpan().SequenceEqual(tokenHash) && candidate.RevokedAt is null);
            return Task.FromResult(device is null ? null : new ActiveDevice(device.Id, device.LastSeenAt));
        }
    }

    public Task TouchLastSeenAsync(Guid id, DateTimeOffset now, CancellationToken ct)
    {
        lock (_gate)
        {
            if (FailTouch)
            {
                throw new InvalidOperationException(FailureMessage);
            }

            Device? device = _devices.Find(candidate => candidate.Id == id);
            if (device is not null)
            {
                device.LastSeenAt = now;
            }
        }

        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<DeviceInfo>> ListDevicesAsync(CancellationToken ct)
    {
        lock (_gate)
        {
            IReadOnlyList<DeviceInfo> devices = _devices
                .OrderBy(device => device.CreatedAt)
                .Select(device => new DeviceInfo(
                    device.Id,
                    device.Name,
                    device.CreatedAt,
                    device.LastSeenAt,
                    device.RevokedAt))
                .ToList();
            return Task.FromResult(devices);
        }
    }

    public Task<bool> RevokeDeviceAsync(Guid id, AuditEntry audit, DateTimeOffset now, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(audit);
        lock (_gate)
        {
            Device? device = _devices.Find(candidate => candidate.Id == id && candidate.RevokedAt is null);
            if (device is null)
            {
                return Task.FromResult(false);
            }

            device.RevokedAt = now;
            _auditEntries.Add(audit);
            return Task.FromResult(true);
        }
    }

    private sealed class PairingCode(byte[] hash, DateTimeOffset expiresAt)
    {
        public byte[] Hash { get; } = hash;

        public DateTimeOffset ExpiresAt { get; } = expiresAt;

        public bool Used { get; set; }
    }

    private sealed class Device(Guid id, string? name, byte[] tokenHash, DateTimeOffset createdAt)
    {
        public Guid Id { get; } = id;

        public string? Name { get; } = name;

        public byte[] TokenHash { get; } = tokenHash;

        public DateTimeOffset CreatedAt { get; } = createdAt;

        public DateTimeOffset? LastSeenAt { get; set; }

        public DateTimeOffset? RevokedAt { get; set; }
    }
}
