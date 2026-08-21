namespace Domovoy.Core.Models;

/// <summary>
/// Событие потока ответа (FR-CORE-8). Клиент отображает каждое по мере
/// поступления: распознанный текст сразу после STT, подтверждение
/// действия до готовности текста.
/// </summary>
public abstract record AgentEvent
{
    /// <summary>Имя события в SSE-потоке.</summary>
    public abstract string Name { get; }
}

/// <summary>Распознанный текст, отдаётся сразу после STT.</summary>
public sealed record RecognizedEvent(string Text) : AgentEvent
{
    public override string Name => "recognized";
}

/// <summary>
/// Выполненное действие. Отдаётся до формирования текста ответа: для
/// пути через быстрый роутер поток вырождается в action + done.
/// </summary>
public sealed record ActionEvent(string EntityId, string Action, bool Success) : AgentEvent
{
    public override string Name => "action";
}

/// <summary>Частичный текст ответа.</summary>
public sealed record TokenEvent(string Text) : AgentEvent
{
    public override string Name => "token";
}

/// <summary>
/// Требуется подтверждение вторым сообщением: замки, сигнализация,
/// ворота, газ (раздел 4.3 ТЗ, двухфазное выполнение).
/// </summary>
public sealed record ConfirmationRequiredEvent(string ActionId, string Description) : AgentEvent
{
    public override string Name => "confirmation_required";
}

/// <summary>Финал потока с метаданными запроса.</summary>
public sealed record DoneEvent(ResponseMetadata Metadata) : AgentEvent
{
    public override string Name => "done";
}

/// <summary>Ошибка, прерывающая поток. Формат совпадает с телом ошибки API.</summary>
public sealed record ErrorEvent(string Code, string Message) : AgentEvent
{
    public override string Name => "error";
}
