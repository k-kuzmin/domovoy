using Domovoy.Data.Entities;
using Microsoft.EntityFrameworkCore;

namespace Domovoy.Data;

/// <summary>
/// Контекст базы данных.
///
/// Схема появляется вместе с функциональностью, которая её использует:
/// привязка устройств и аудит — на этапе 1, диалоги и учёт токенов — на
/// этапе 2, долговременная память — на этапе 6. Заводить таблицы заранее
/// означает мигрировать то, что ещё не имеет формы.
///
/// Имена таблиц и колонок — snake_case, заданы явно: схема читается
/// человеком в psql, и её вид не зависит от соглашений провайдера.
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

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        ArgumentNullException.ThrowIfNull(modelBuilder);

        modelBuilder.Entity<DeviceRecord>(device =>
        {
            device.ToTable("devices");
            device.HasKey(d => d.Id).HasName("pk_devices");
            device.Property(d => d.Id).HasColumnName("id").ValueGeneratedNever();
            device.Property(d => d.Name).HasColumnName("name").HasMaxLength(DeviceRecord.NameMaxLength);
            device.Property(d => d.TokenHash).HasColumnName("token_hash").HasColumnType("bytea").IsRequired();
            device.Property(d => d.CreatedAt).HasColumnName("created_at");
            device.Property(d => d.LastSeenAt).HasColumnName("last_seen_at");
            device.Property(d => d.RevokedAt).HasColumnName("revoked_at");
            device.HasIndex(d => d.TokenHash).IsUnique().HasDatabaseName("ix_devices_token_hash");
        });

        modelBuilder.Entity<PairingCodeRecord>(code =>
        {
            code.ToTable("pairing_codes");
            code.HasKey(c => c.Id).HasName("pk_pairing_codes");
            code.Property(c => c.Id).HasColumnName("id").ValueGeneratedNever();
            code.Property(c => c.CodeHash).HasColumnName("code_hash").HasColumnType("bytea").IsRequired();
            code.Property(c => c.CreatedAt).HasColumnName("created_at");
            code.Property(c => c.ExpiresAt).HasColumnName("expires_at");
            code.Property(c => c.UsedAt).HasColumnName("used_at");
            code.Property(c => c.DeviceId).HasColumnName("device_id");
            code.HasIndex(c => c.CodeHash).IsUnique().HasDatabaseName("ix_pairing_codes_code_hash");
        });

        modelBuilder.Entity<AuditRecord>(audit =>
        {
            audit.ToTable("audit_entries");
            audit.HasKey(a => a.Id).HasName("pk_audit_entries");
            audit.Property(a => a.Id).HasColumnName("id").UseIdentityByDefaultColumn();
            audit.Property(a => a.OccurredAt).HasColumnName("occurred_at");
            audit.Property(a => a.RequestId).HasColumnName("request_id").IsRequired();
            audit.Property(a => a.Source).HasColumnName("source").HasColumnType("text").HasConversion<string>();
            audit.Property(a => a.OriginalPhrase).HasColumnName("original_phrase").IsRequired();
            audit.Property(a => a.ToolName).HasColumnName("tool_name").IsRequired();
            audit.Property(a => a.Arguments).HasColumnName("arguments").HasColumnType("jsonb").IsRequired();
            audit.Property(a => a.Success).HasColumnName("success");
            audit.Property(a => a.Error).HasColumnName("error");
        });
    }
}
