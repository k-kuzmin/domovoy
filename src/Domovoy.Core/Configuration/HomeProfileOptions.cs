using System.ComponentModel.DataAnnotations;

namespace Domovoy.Core.Configuration;

/// <summary>Настройки профиля дома (FR-MEM-2).</summary>
public sealed class HomeProfileOptions
{
    public const string SectionName = "HomeProfile";

    /// <summary>
    /// Путь к файлу профиля. Содержимое приватнее токенов: вместе с
    /// реестром сущностей даёт планировку, состав жильцов и расписание
    /// отсутствия. В репозитории только вымышленный пример (ТЗ 5.1.3).
    /// </summary>
    [Required]
    public string Path { get; set; } = "config/home-profile.md";
}
