using System.Security.Cryptography;
using System.Text;

namespace Domovoy.Core.Auth;

/// <summary>
/// Генерация и хеширование секретов привязки устройства.
///
/// Хеш — SHA-256, а не медленный хеш паролей: токен — 256 бит
/// случайности, перебор по словарю к нему неприменим, а быстрый
/// детерминированный хеш позволяет искать устройство по уникальному
/// индексу. Код привязки короткий, но одноразовый, живёт минуты, и его
/// перебор упирается в лимит обращений к эндпоинту (запись 0025).
/// </summary>
public static class DeviceSecrets
{
    /// <summary>Алфавит Crockford base32: без I, L, O и U.</summary>
    private const string CrockfordAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    private const int TokenBytes = 32;

    private const int PairingCodeLength = 8;

    /// <summary>Токен устройства: 32 случайных байта в base64url без выравнивания.</summary>
    public static string NewToken()
    {
        byte[] bytes = RandomNumberGenerator.GetBytes(TokenBytes);
        return Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    /// <summary>Код привязки: 8 символов Crockford base32 верхним регистром.</summary>
    public static string NewPairingCode() =>
        RandomNumberGenerator.GetString(CrockfordAlphabet, PairingCodeLength);

    /// <summary>SHA-256 от UTF-8 представления значения — 32 байта.</summary>
    public static byte[] Hash(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return SHA256.HashData(Encoding.UTF8.GetBytes(value));
    }

    /// <summary>
    /// Приводит введённый код к выпущенной форме: без пробелов по краям,
    /// верхним регистром.
    /// </summary>
    public static string NormalizePairingCode(string code)
    {
        ArgumentNullException.ThrowIfNull(code);
        return code.Trim().ToUpperInvariant();
    }
}
