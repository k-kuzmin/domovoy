namespace Domovoy.Core.Models;

/// <summary>
/// Home Assistant недоступен: нет соединения, истёк таймаут или ответ не
/// 2xx. Сообщение не содержит адреса, токена и текста исходного исключения:
/// его видит пользователь, а публичный домен сканируется (AR-1.2).
/// <see cref="Exception.InnerException"/> не логируется целиком.
/// </summary>
public sealed class HaUnavailableException : Exception
{
    private const string DefaultMessage = "Home Assistant недоступен.";

    public HaUnavailableException()
        : base(DefaultMessage)
    {
    }

    public HaUnavailableException(string message)
        : base(message)
    {
    }

    public HaUnavailableException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    /// <summary>Исключение с сообщением по умолчанию и исходной причиной.</summary>
    public HaUnavailableException(Exception innerException)
        : base(DefaultMessage, innerException)
    {
    }
}
