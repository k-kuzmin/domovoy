namespace Domovoy.Core.Models;

/// <summary>
/// Выпущенный код привязки. Открытое значение кода отдаётся
/// администратору один раз; хранилище получает только его хеш.
/// </summary>
public sealed record PairingCodeIssued(string Code, DateTimeOffset ExpiresAt);
