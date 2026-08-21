using Microsoft.EntityFrameworkCore;

namespace Domovoy.Data;

/// <summary>
/// Контекст базы данных.
///
/// Каркас: наборов сущностей ещё нет. Схема появляется вместе с
/// функциональностью, которая её использует, — диалоги и учёт токенов на
/// этапе 2, аудит на этапе 1, долговременная память на этапе 6.
/// Заводить таблицы заранее означает мигрировать то, что ещё не имеет
/// формы.
///
/// Открытый вопрос, влияющий на схему: мультипользовательность
/// (раздел 8 ТЗ, пункт 6). Решить до этапа 2.
/// </summary>
public class DomovoyDbContext : DbContext
{
    public DomovoyDbContext(DbContextOptions<DomovoyDbContext> options)
        : base(options)
    {
    }
}
