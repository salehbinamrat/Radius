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
// Protect authenticated, state-changing browser requests against cross-site
// form submission. The API remains usable by existing local CLI clients.
app.Use(async (ctx, next) =>
{
    if (ctx.Request.Path.StartsWithSegments("/api")
        && !RequestOriginRules.IsAllowed(
            ctx.Request.Method,
            ctx.Request.Headers["Origin"].ToString(),
            ctx.Request.Headers["Sec-Fetch-Site"].ToString(),
            ctx.Request.Scheme,
            ctx.Request.Host.Value))
    {
        ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
        await ctx.Response.WriteAsJsonAsync(new { error = "طلب من مصدر غير موثوق" });
        return;
    }
    await next();
});

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

api.MapPlanEndpoints();

// Independent laboratory voucher routes; protected by the same /api auth middleware.
app.MapLabAccountEndpoints();
app.MapLabUsageEndpoints();
app.MapLabSessionEndpoints();
// Phase 7A: metadata-only NAS drafts; no actual RADIUS client registration.
app.MapNasDraftEndpoints();
app.Run();
