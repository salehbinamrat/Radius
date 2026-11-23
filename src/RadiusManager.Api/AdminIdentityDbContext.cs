using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Identity.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore;

namespace RadiusManager.Api;

public sealed class AdminSession
{
    public Guid Id { get; set; }
    public string UserId { get; set; } = "";
    public string SessionTokenHash { get; set; } = "";
    public string SecurityStamp { get; set; } = "";
    public DateTime CreatedAt { get; set; }
    public DateTime LastSeenAt { get; set; }
    public DateTime IdleExpiresAt { get; set; }
    public DateTime AbsoluteExpiresAt { get; set; }
    public DateTime? RevokedAt { get; set; }
}

public sealed class AdminAuditEvent
{
    public long Id { get; set; }
    public string? ActorUserId { get; set; }
    public string Action { get; set; } = "";
    public string? SubjectKind { get; set; }
    public string? SubjectId { get; set; }
    public string Outcome { get; set; } = "denied";
    public DateTime OccurredAt { get; set; }
    public Guid CorrelationId { get; set; }
}

/// <summary>Identity is separate from FreeRADIUS subscriber tables.</summary>
public sealed class AdminIdentityDbContext : IdentityDbContext<IdentityUser, IdentityRole, string>
{
    public AdminIdentityDbContext(DbContextOptions<AdminIdentityDbContext> options) : base(options) { }
    public DbSet<AdminSession> AdminSessions => Set<AdminSession>();
    public DbSet<AdminAuditEvent> AdminAuditEvents => Set<AdminAuditEvent>();

    protected override void OnModelCreating(ModelBuilder builder)
    {
        base.OnModelCreating(builder);
        builder.Entity<AdminSession>(e =>
        {
            e.ToTable("app_admin_sessions");
            e.HasKey(s => s.Id);
            e.Property(s => s.Id).HasColumnName("id");
            e.Property(s => s.UserId).HasColumnName("user_id");
            e.Property(s => s.SessionTokenHash).HasColumnName("session_token_hash");
            e.Property(s => s.SecurityStamp).HasColumnName("security_stamp");
            e.Property(s => s.CreatedAt).HasColumnName("created_at");
            e.Property(s => s.LastSeenAt).HasColumnName("last_seen_at");
            e.Property(s => s.IdleExpiresAt).HasColumnName("idle_expires_at");
            e.Property(s => s.AbsoluteExpiresAt).HasColumnName("absolute_expires_at");
            e.Property(s => s.RevokedAt).HasColumnName("revoked_at");
        });
        builder.Entity<AdminAuditEvent>(e =>
        {
            e.ToTable("app_admin_audit_events");
            e.HasKey(a => a.Id);
            e.Property(a => a.Id).HasColumnName("id").ValueGeneratedOnAdd();
            e.Property(a => a.ActorUserId).HasColumnName("actor_user_id");
            e.Property(a => a.Action).HasColumnName("action");
            e.Property(a => a.SubjectKind).HasColumnName("subject_kind");
            e.Property(a => a.SubjectId).HasColumnName("subject_id");
            e.Property(a => a.Outcome).HasColumnName("outcome");
            e.Property(a => a.OccurredAt).HasColumnName("occurred_at");
            e.Property(a => a.CorrelationId).HasColumnName("correlation_id");
        });
    }
}
