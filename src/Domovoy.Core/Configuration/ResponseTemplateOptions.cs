using System.ComponentModel.DataAnnotations;

namespace Domovoy.Core.Configuration;

/// <summary>
/// Шаблоны ответов на успешные изменяющие действия (FR-CORE-7).
///
/// Файл лежит рядом с реестром сущностей и использует его падежи имён
/// комнат. Отсутствие шаблона для пары «действие + домен» — не ошибка, а
/// условие фолбэка на второй вызов модели.
/// </summary>
public sealed class ResponseTemplateOptions
{
    public const string SectionName = "ResponseTemplates";

    [Required]
    public string Path { get; set; } = "config/response-templates.yaml";
}
