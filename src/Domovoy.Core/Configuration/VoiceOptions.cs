using System.ComponentModel.DataAnnotations;

namespace Domovoy.Core.Configuration;

/// <summary>Настройки распознавания и синтеза речи.</summary>
public sealed class VoiceOptions
{
    public const string SectionName = "Voice";

    /// <summary>Адрес сервиса STT (faster-whisper) в локальной сети.</summary>
    [Required]
    [Url]
    public string SpeechToTextUrl { get; set; } = "http://whisper:9000";

    /// <summary>Адрес сервиса TTS. Пусто — озвучка отключена (FR-VOICE-4).</summary>
    public string? TextToSpeechUrl { get; set; }

    /// <summary>Язык распознавания.</summary>
    [Required]
    public string Language { get; set; } = "ru";

    [Range(1, 300)]
    public int RequestTimeoutSeconds { get; set; } = 60;

    /// <summary>Потолок размера загружаемого аудио.</summary>
    [Range(1, 100)]
    public int MaxAudioMegabytes { get; set; } = 10;

    public bool IsTextToSpeechEnabled => !PlaceholderValues.IsUnset(TextToSpeechUrl);
}
