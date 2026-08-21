namespace Domovoy.Core.Abstractions;

/// <summary>Синтез речи. Опционально (FR-VOICE-4).</summary>
public interface ITextToSpeech
{
    /// <summary>
    /// Озвучить текст. Возвращает ссылку на аудиофайл, а не сам поток:
    /// клиент забирает файл отдельным запросом и может его кэшировать.
    /// </summary>
    Task<Uri> SynthesizeAsync(string text, CancellationToken cancellationToken);
}
