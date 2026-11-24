using System.Security.Claims;
using Npgsql;
using NpgsqlTypes;

namespace RadiusManager.Api;

public enum LabMutation
{
    PlanCreated, PlanUpdated, VoucherCreated, VoucherDisabled, NasDraftCreated, NasDraftRetired
}

/// <summary>Allowlisted successful mutations; no request payloads or credential values.</summary>
public static class LabMutationAudit
{
    public static (string Action, string SubjectKind) Describe(LabMutation mutation) => mutation switch
    {
        LabMutation.PlanCreated => ("plan_created", "plan"),
        LabMutation.PlanUpdated => ("plan_updated", "plan"),
        LabMutation.VoucherCreated => ("voucher_created", "lab_account"),
        LabMutation.VoucherDisabled => ("voucher_disabled", "lab_account"),
        LabMutation.NasDraftCreated => ("nas_draft_created", "nas_draft"),
        LabMutation.NasDraftRetired => ("nas_draft_retired", "nas_draft"),
        _ => throw new ArgumentOutOfRangeException(nameof(mutation))
    };

    public static string? ActorId(ClaimsPrincipal principal, bool sessionMode)
    {
        // Basic mode is a shared laboratory credential, never an Identity actor.
        if (!sessionMode) return null;
        var ids = principal.FindAll(ClaimTypes.NameIdentifier).Select(c => c.Value).ToArray();
        if (principal.Identity?.IsAuthenticated != true || ids.Length != 1
            || !OwnershipRules.ValidOwnerId(ids[0]))
            throw new InvalidOperationException("Missing verified administrative actor");
        return ids[0];
    }

    public static async Task AppendAsync(NpgsqlConnection conn, NpgsqlTransaction tx,
        ClaimsPrincipal principal, bool sessionMode, LabMutation mutation, string subjectId, CancellationToken ct)
    {
        var (action, kind) = Describe(mutation);
        if (kind == "lab_account" ? !LabAccountRules.IsLabUsername(subjectId)
            : !Guid.TryParseExact(subjectId, "D", out var id) || id == Guid.Empty)
            throw new ArgumentException("Invalid audit subject identifier", nameof(subjectId));
        var actor = ActorId(principal, sessionMode);
        await using var cmd = new NpgsqlCommand("""
            INSERT INTO app_admin_audit_events(actor_user_id,action,subject_kind,subject_id,outcome,correlation_id)
            VALUES (@actor,@action,@kind,@subject,'success',@correlation)
            """, conn, tx);
        cmd.Parameters.AddWithValue("actor", NpgsqlDbType.Text, (object?)actor ?? DBNull.Value);
        cmd.Parameters.AddWithValue("action", action);
        cmd.Parameters.AddWithValue("kind", kind);
        cmd.Parameters.AddWithValue("subject", subjectId);
        cmd.Parameters.AddWithValue("correlation", Guid.NewGuid());
        await cmd.ExecuteNonQueryAsync(ct);
    }
}
