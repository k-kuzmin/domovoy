using System.ComponentModel.DataAnnotations;

namespace Domovoy.Core.Configuration;

/// <summary>Настройки проактивных уведомлений.</summary>
public sealed class ProactivityOptions
{
    public const string SectionName = "Proactivity";

    /// <summary>Фоновая обработка событий Home Assistant включена (FR-PRO-1).</summary>
    public bool Enabled { get; set; }

    /// <summary>Путь к файлу декларативных правил (FR-PRO-2).</summary>
    [Required]
    public string RulesPath { get; set; } = "config/proactive-rules.yaml";

    /// <summary>
    /// Антиспам-окно по умолчанию: одно правило не срабатывает повторно
    /// в течение этого интервала (FR-PRO-5). Правило может задать своё.
    /// </summary>
    [Range(1, 1440)]
    public int DefaultCooldownMinutes { get; set; } = 30;
}
