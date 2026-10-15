using Domovoy.Data;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata;

namespace Domovoy.Tests.Data;

/// <summary>
/// Схема привязки устройств по модели EF, без соединения с базой:
/// токен и код хранятся только хешем, аудит пишется в существующую
/// таблицу.
/// </summary>
public sealed class DeviceAuthSchemaTests
{
    [Theory(DisplayName = "Секрет хранится только хешем bytea с уникальным индексом")]
    [InlineData("devices", "token_hash", "token")]
    [InlineData("pairing_codes", "code_hash", "code")]
    public void DeviceTokenIsPersistedOnlyAsHash(string table, string hashColumn, string secretWord)
    {
        using DomovoyDbContext db = CreateContext();
        IEntityType entity = FindEntity(db, table);
        StoreObjectIdentifier storeObject = StoreObjectIdentifier.Table(table, entity.GetSchema());

        string[] secretColumns = entity.GetProperties()
            .Select(p => p.GetColumnName(storeObject)!)
            .Where(c => c.Contains(secretWord, StringComparison.OrdinalIgnoreCase))
            .ToArray();

        secretColumns.Should().Equal(
            [hashColumn],
            "открытого значения секрета в модели быть не может — только его хеш");

        IProperty hash = entity.GetProperties().Single(p => p.GetColumnName(storeObject) == hashColumn);
        hash.GetColumnType().Should().Be("bytea");
        hash.IsNullable.Should().BeFalse();

        entity.GetIndexes()
            .Should().Contain(i => i.IsUnique && i.Properties.Count == 1 && i.Properties[0] == hash,
                "поиск идёт по хешу, и два одинаковых хеша — ошибка");

        string script = db.Database.GenerateCreateScript();
        script.Should().Contain($"CREATE TABLE {table} (");
        script.Should().MatchRegex($@"CREATE UNIQUE INDEX \S+ ON {table} \({hashColumn}\)");
    }

    [Fact(DisplayName = "Таблица audit_entries есть в модели, источник — строкой, аргументы — jsonb")]
    public void AuditEntriesTableExistsInModel()
    {
        using DomovoyDbContext db = CreateContext();

        string script = db.Database.GenerateCreateScript();

        string auditTable = ExtractCreateTable(script, "audit_entries");
        auditTable.Should().MatchRegex(@"\bsource text NOT NULL\b");
        auditTable.Should().MatchRegex(@"\barguments jsonb NOT NULL\b");
        auditTable.Should().MatchRegex(@"\boccurred_at timestamp with time zone NOT NULL\b");
    }

    private static DomovoyDbContext CreateContext()
    {
        DbContextOptions<DomovoyDbContext> options = new DbContextOptionsBuilder<DomovoyDbContext>()
            .UseNpgsql("Host=unused")
            .Options;

        return new DomovoyDbContext(options);
    }

    private static IEntityType FindEntity(DomovoyDbContext db, string table)
    {
        IEntityType[] matches = db.Model.GetEntityTypes()
            .Where(e => e.GetTableName() == table)
            .ToArray();

        matches.Should().ContainSingle($"в модели должна быть ровно одна сущность таблицы {table}");
        return matches[0];
    }

    private static string ExtractCreateTable(string script, string table)
    {
        string header = $"CREATE TABLE {table} (";
        int start = script.IndexOf(header, StringComparison.Ordinal);
        start.Should().BeGreaterThanOrEqualTo(0, $"в скрипте создания схемы должна быть таблица {table}");

        int end = script.IndexOf(");", start, StringComparison.Ordinal);
        return script[start..end];
    }
}
