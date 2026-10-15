using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace Domovoy.Data.Migrations;

/// <inheritdoc />
public partial class DeviceAuth : Migration
{
    /// <inheritdoc />
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.CreateTable(
            name: "audit_entries",
            columns: table => new
            {
                id = table.Column<long>(type: "bigint", nullable: false)
                    .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                occurred_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                request_id = table.Column<string>(type: "text", nullable: false),
                source = table.Column<string>(type: "text", nullable: false),
                original_phrase = table.Column<string>(type: "text", nullable: false),
                tool_name = table.Column<string>(type: "text", nullable: false),
                arguments = table.Column<string>(type: "jsonb", nullable: false),
                success = table.Column<bool>(type: "boolean", nullable: false),
                error = table.Column<string>(type: "text", nullable: true)
            },
            constraints: table =>
            {
                table.PrimaryKey("pk_audit_entries", x => x.id);
            });

        migrationBuilder.CreateTable(
            name: "devices",
            columns: table => new
            {
                id = table.Column<Guid>(type: "uuid", nullable: false),
                name = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: true),
                token_hash = table.Column<byte[]>(type: "bytea", nullable: false),
                created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                last_seen_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                revoked_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
            },
            constraints: table =>
            {
                table.PrimaryKey("pk_devices", x => x.id);
            });

        migrationBuilder.CreateTable(
            name: "pairing_codes",
            columns: table => new
            {
                id = table.Column<Guid>(type: "uuid", nullable: false),
                code_hash = table.Column<byte[]>(type: "bytea", nullable: false),
                created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                expires_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                used_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                device_id = table.Column<Guid>(type: "uuid", nullable: true)
            },
            constraints: table =>
            {
                table.PrimaryKey("pk_pairing_codes", x => x.id);
            });

        migrationBuilder.CreateIndex(
            name: "ix_devices_token_hash",
            table: "devices",
            column: "token_hash",
            unique: true);

        migrationBuilder.CreateIndex(
            name: "ix_pairing_codes_code_hash",
            table: "pairing_codes",
            column: "code_hash",
            unique: true);
    }

    /// <inheritdoc />
    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropTable(
            name: "audit_entries");

        migrationBuilder.DropTable(
            name: "devices");

        migrationBuilder.DropTable(
            name: "pairing_codes");
    }
}
