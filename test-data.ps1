<#
.SYNOPSIS
    Adds or removes demo chickens for UI testing.
.NOTES
    Add/reset demo data: .\test-data.ps1
    Remove demo data:    .\test-data.ps1 -Action clear
#>

param(
    [ValidateSet("reset", "seed", "clear")]
    [string]$Action = "reset",

    [ValidateRange(1, 500)]
    [int]$Count = 100
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path $ScriptDir ".env"

function Read-EnvValue {
    param(
        [string]$Name,
        [string]$Default
    )

    if (-not (Test-Path $EnvFile)) {
        return $Default
    }

    $line = Get-Content $EnvFile | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
    if (-not $line) {
        return $Default
    }

    $value = ($line -replace "^$Name=", "").Trim()
    if ($value) { return $value }
    return $Default
}

$PostgresUser = Read-EnvValue "POSTGRES_USER" "chicken"
$PostgresDb = Read-EnvValue "POSTGRES_DB" "chicken_monitor"
$DemoGroup1Sql = "U&'\0414\0435\043C\043E \0437\0430\0433\043E\043D 1'"
$DemoGroup2Sql = "U&'\0414\0435\043C\043E \0437\0430\0433\043E\043D 2'"

function Invoke-PostgresSql {
    param([string]$Sql)

    Set-Location $ScriptDir
    $Sql | docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U $PostgresUser -d $PostgresDb
}

$ClearSql = @"
BEGIN;
DELETE FROM temperature_readings WHERE chicken_id LIKE 'TEST%';
DELETE FROM aggregated_readings WHERE chicken_id LIKE 'TEST%';
DELETE FROM chickens WHERE chicken_id LIKE 'TEST%';
DELETE FROM "groups" g
WHERE g.name IN ($DemoGroup1Sql, $DemoGroup2Sql, 'Test sensors')
   OR (
        g.name LIKE '?%'
        AND NOT EXISTS (
            SELECT 1 FROM chickens c WHERE c.group_id = g.id
        )
   );
COMMIT;
"@

if ($Action -eq "clear") {
    Invoke-PostgresSql $ClearSql
    Write-Host "Demo data removed. Real chickens were not touched." -ForegroundColor Green
    exit 0
}

$SeedSql = @"
BEGIN;

INSERT INTO "groups" (name)
SELECT name
FROM (VALUES ($DemoGroup1Sql), ($DemoGroup2Sql)) AS demo(name)
WHERE NOT EXISTS (
    SELECT 1 FROM "groups" g WHERE g.name = demo.name
);

INSERT INTO chickens (chicken_id, last_temperature, voltage, last_seen, group_id)
SELECT
    'TEST' || lpad(n::text, 3, '0') AS chicken_id,
    CASE
        WHEN n <= CEIL($Count * 0.20) THEN 39.2 + (n % 5) * 0.1
        WHEN n <= CEIL($Count * 0.40) THEN 43.3 + (n % 6) * 0.1
        WHEN n <= CEIL($Count * 0.60) THEN 42.2 + (n % 5) * 0.1
        ELSE 40.2 + (n % 16) * 0.1
    END AS last_temperature,
    2.55 + (n % 5) * 0.1 AS voltage,
    now() - (($Count + 1 - n) * interval '10 seconds') AS last_seen,
    CASE
        WHEN n <= CEIL($Count * 0.60) THEN (SELECT id FROM "groups" WHERE name = $DemoGroup1Sql LIMIT 1)
        ELSE (SELECT id FROM "groups" WHERE name = $DemoGroup2Sql LIMIT 1)
    END AS group_id
FROM generate_series(1, $Count) AS s(n)
ON CONFLICT (chicken_id) DO UPDATE SET
    last_temperature = EXCLUDED.last_temperature,
    voltage = EXCLUDED.voltage,
    last_seen = EXCLUDED.last_seen,
    group_id = EXCLUDED.group_id;

INSERT INTO temperature_readings (chicken_id, temperature, voltage, recorded_at)
SELECT chicken_id, last_temperature, voltage, last_seen
FROM chickens
WHERE chicken_id LIKE 'TEST%';

COMMIT;
"@

if ($Action -eq "reset") {
    Invoke-PostgresSql $ClearSql
}

Invoke-PostgresSql $SeedSql

Write-Host "Demo data ready: $Count TEST chickens added." -ForegroundColor Green
Write-Host "Open http://localhost:8000 and press Ctrl+F5." -ForegroundColor Cyan
