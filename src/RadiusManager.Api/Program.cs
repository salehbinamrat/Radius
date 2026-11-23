using System.Data;
using System.Threading.RateLimiting;
using Npgsql;
using RadiusManager.Api;

var builder = WebApplication.CreateBuilder(args);
var adminUser = Environment.GetEnvironmentVariable("RADIUS_ADMIN_USER") ?? "admin";
var adminPassword = Environment.GetEnvironmentVariable("RADIUS_ADMIN_PASSWORD") ?? "";
var connectionString = builder.Configuration.GetConnectionString("RadiusDb");
if (adminUser.Length < 3 || adminPassword.Length < 24 || string.IsNullOrWhiteSpace(connectionString))
    throw new InvalidOperationException("Provide strong admin credentials and a database connection string.");

builder.Services.AddSingleton(NpgsqlDataSource.Create(connectionString));
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    o.AddPolicy("admin", context => RateLimitPartition.GetFixedWindowLimiter(
        partitionKey: context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        factory: _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = 120, Window = TimeSpan.FromMinutes(1), QueueLimit = 0,
            AutoReplenishment = true
        }));
});

var app = builder.Build();
app.Use(async (context, next) =>
{
    context.Response.Headers["X-Content-Type-Options"] = "nosniff";
    context.Response.Headers["X-Frame-Options"] = "DENY";
    context.Response.Headers["Cache-Control"] = "no-store";
    context.Response.Headers["Content-Security-Policy"] = "default-src 'self'; connect-src 'self'; img-src 'self' data:; script-src 'self'; style-src 'self'; base-uri 'none'; frame-ancestors 'none'";
    await next();
});
app.UseDefaultFiles();
app.UseStaticFiles();
app.UseRateLimiter();

app.MapGet("/api/health/live", () => Results.Ok(new { status = "running", phase = 1 }));
app.MapGet("/api/health/ready", async (NpgsqlDataSource dataSource, CancellationToken ct) =>
{
    try
    {
        await using var cmd = dataSource.CreateCommand("SELECT 1 FROM app_plans LIMIT 1");
        await cmd.ExecuteScalarAsync(ct);
        return Results.Ok(new { status = "ready" });
    }
    catch (NpgsqlException) { return Results.StatusCode(StatusCodes.Status503ServiceUnavailable); }
});

app.Use(async (ctx, next) =>
{
    if (ctx.Request.Path.StartsWithSegments("/api")
        && !ctx.Request.Path.StartsWithSegments("/api/health"))
    {
        if (!AdminBasicAuth.Matches(ctx.Request.Headers.Authorization.ToString(), adminUser, adminPassword))
        {
            ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
            ctx.Response.Headers.WWWAuthenticate = "Basic realm=\"Local-RADIUS-Lab\"";
            await ctx.Response.WriteAsJsonAsync(new { error = "غير مصرح" });
            return;
        }
    }
    await next();
});

var api = app.MapGroup("/api").RequireRateLimiting("admin");

api.MapGet("/summary", async (NpgsqlDataSource dataSource, CancellationToken ct) =>
{
    await using var cmd = dataSource.CreateCommand("SELECT (SELECT count(*) FROM app_plans), (SELECT count(DISTINCT username) FROM radcheck)");
    await using var reader = await cmd.ExecuteReaderAsync(ct);
    await reader.ReadAsync(ct);
    return Results.Ok(new { plans = reader.GetInt64(0), labAccounts = reader.GetInt64(1), phase = 1, accountingEnforced = false });
});

api.MapGet("/plans", async (NpgsqlDataSource dataSource, CancellationToken ct) =>
{
    var plans = new List<object>();
    await using var cmd = dataSource.CreateCommand("SELECT id,name,download_kbps,upload_kbps,quota_bytes,validity_days,active FROM app_plans ORDER BY created_at DESC LIMIT 100");
    await using var reader = await cmd.ExecuteReaderAsync(ct);
    while (await reader.ReadAsync(ct))
        plans.Add(new { id = reader.GetGuid(0), name = reader.GetString(1), downloadKbps = reader.GetInt32(2), uploadKbps = reader.GetInt32(3), quotaBytes = reader.IsDBNull(4) ? (long?)null : reader.GetInt64(4), validityDays = reader.IsDBNull(5) ? (int?)null : reader.GetInt32(5), active = reader.GetBoolean(6) });
    return Results.Ok(plans);
});

api.MapPost("/plans", async (PlanInput input, NpgsqlDataSource dataSource, CancellationToken ct) =>
{
    var validation = PlanRules.Validate(input);
    if (validation is not null) return Results.BadRequest(new { error = validation });
    var id = Guid.NewGuid();
    await using var conn = await dataSource.OpenConnectionAsync(ct);
    await using var tx = await conn.BeginTransactionAsync(ct);
    try
    {
        await using (var cmd = new NpgsqlCommand("INSERT INTO app_plans (id,name,upload_kbps,download_kbps,quota_bytes,validity_days) VALUES (@id,@name,@up,@down,@quota,@days)", conn, tx))
        {
            cmd.Parameters.AddWithValue("id", id);
            cmd.Parameters.AddWithValue("name", input.Name.Trim());
            cmd.Parameters.AddWithValue("up", input.UploadKbps);
            cmd.Parameters.AddWithValue("down", input.DownloadKbps);
            cmd.Parameters.AddWithValue("quota", (object?)PlanRules.QuotaBytes(input.QuotaMb) ?? DBNull.Value);
            cmd.Parameters.AddWithValue("days", (object?)input.ValidityDays ?? DBNull.Value);
            await cmd.ExecuteNonQueryAsync(ct);
        }
        await using (var cmd = new NpgsqlCommand("INSERT INTO radgroupreply (groupname,attribute,op,value) VALUES (@group,'Mikrotik-Rate-Limit',':=',@rate)", conn, tx))
        {
            cmd.Parameters.AddWithValue("group", PlanRules.GroupName(id));
            cmd.Parameters.AddWithValue("rate", PlanRules.MikroTikRate(input.UploadKbps,input.DownloadKbps));
            await cmd.ExecuteNonQueryAsync(ct);
        }
        await tx.CommitAsync(ct);
        return Results.Created($"/api/plans/{id}", new { id, rate = PlanRules.MikroTikRate(input.UploadKbps,input.DownloadKbps), accountingEnforced = false });
    }
    catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
    {
        await tx.RollbackAsync(ct);
        return Results.Conflict(new { error = "اسم الباقة موجود مسبقا" });
    }
});

api.MapPut("/plans/{id:guid}", async (Guid id, PlanInput input, NpgsqlDataSource dataSource, CancellationToken ct) =>
{
    var validation = PlanRules.Validate(input);
    if (validation is not null) return Results.BadRequest(new { error = validation });
    await using var conn = await dataSource.OpenConnectionAsync(ct);
    await using var tx = await conn.BeginTransactionAsync(ct);
    try
    {
        await using (var cmd = new NpgsqlCommand("UPDATE app_plans SET name=@name, upload_kbps=@up,download_kbps=@down,quota_bytes=@quota,validity_days=@days,updated_at=now() WHERE id=@id", conn, tx))
        {
            cmd.Parameters.AddWithValue("id", id);
            cmd.Parameters.AddWithValue("name", input.Name.Trim());
            cmd.Parameters.AddWithValue("up", input.UploadKbps);
            cmd.Parameters.AddWithValue("down", input.DownloadKbps);
            cmd.Parameters.AddWithValue("quota", (object?)PlanRules.QuotaBytes(input.QuotaMb) ?? DBNull.Value);
            cmd.Parameters.AddWithValue("days", (object?)input.ValidityDays ?? DBNull.Value);
            if (await cmd.ExecuteNonQueryAsync(ct) == 0)
            {
                await tx.RollbackAsync(ct);
                return Results.NotFound(new { error = "الباقة غير موجودة" });
            }
        }
        await using (var cmd = new NpgsqlCommand("UPDATE radgroupreply SET value=@rate WHERE groupname=@group AND attribute='Mikrotik-Rate-Limit'",conn,tx))
        {
            cmd.Parameters.AddWithValue("rate",PlanRules.MikroTikRate(input.UploadKbps,input.DownloadKbps));
            cmd.Parameters.AddWithValue("group", PlanRules.GroupName(id));
            if (await cmd.ExecuteNonQueryAsync(ct) != 1)
                throw new DataException("RADIUS reply row missing; update rolled back.");
        }
        await tx.CommitAsync(ct);
        return Results.Ok(new { id, updated = true, accountingEnforced = false });
    }
    catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
    {
        await tx.RollbackAsync(ct);
        return Results.Conflict(new { error = "اسم الباقة موجود مسبقا" });
    }
});

// Independent laboratory voucher routes; protected by the same /api auth middleware.
app.MapLabAccountEndpoints();
app.MapLabUsageEndpoints();
app.MapLabSessionEndpoints();
app.Run();
