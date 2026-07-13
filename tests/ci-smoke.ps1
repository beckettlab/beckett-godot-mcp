<#
.SYNOPSIS
    Cross-platform CI smoke probe for the Beckett (MCP for Godot) Lite addon.

.DESCRIPTION
    One code path shared by GitHub Actions (all three runners, shell: pwsh) and a
    local Windows PowerShell 5.1 run. Given a Godot editor binary and a port, it:

      1. boots the headless editor with the plugin autostarting on the given port
         (BECKETT_ENABLE=1, isolated BECKETT_PORT / BECKETT_RUNTIME_PORT, and
         BECKETT_AUTO_CONFIG=0 so a CI boot never rewrites the repo's .mcp.json),
      2. waits for the embedded HTTP/JSON-RPC server to answer,
      3. POSTs initialize to http://127.0.0.1:<port>/mcp and asserts the response
         carries protocolVersion + serverInfo,
      4. POSTs tools/list and asserts EXACTLY the expected Lite tool count, and
      5. ALWAYS kills the editor process on the way out (finally block).

    Compatible with BOTH Windows PowerShell 5.1 (local dev) and PowerShell 7
    (shell: pwsh on ubuntu / macos / windows runners): no ternary, no ??, no
    PS7-only cmdlet switches.

    The project generation, Godot download, caching, and per-.gd parse-check live
    in the workflow (.github/workflows/ci.yml); this script owns only the boot +
    HTTP probe so CI and a local invocation exercise identical logic.

.PARAMETER GodotExe
    Absolute path to the Godot editor binary (Linux/macOS: the raw executable;
    Windows: the *_console.exe variant so headless prints reach stdout).

.PARAMETER Port
    TCP port the embedded server binds on 127.0.0.1. The runtime bridge uses
    Port + 1. Pick a free port; CI uses 8790, local Windows validation uses 879x.

.PARAMETER ProjectPath
    Path to the Godot project root to boot (the staged Lite tree with a generated
    project.godot enabling res://addons/beckett/plugin.cfg). Defaults to the repo
    root two levels up from this script.

.PARAMETER ExpectedTools
    Expected tool count from tools/list. Default 51 (the Lite surface since v1.9's doctor).

.PARAMETER BootTimeoutSec
    How long to wait for the server to start answering before failing. Default 120
    (a cold editor import on a CI runner can be slow).

.EXAMPLE
    pwsh tests/ci-smoke.ps1 -GodotExe /opt/godot/godot -Port 8790 -ProjectPath .
    powershell -File tests\ci-smoke.ps1 -GodotExe 'E:\Godot_v4.6.2-stable_win64\Godot_v4.6.2-stable_win64_console.exe' -Port 8791 -ProjectPath C:\path\to\stage
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GodotExe,

    [int]$Port = 8790,

    [string]$ProjectPath,

    [int]$ExpectedTools = 51,

    [int]$BootTimeoutSec = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ProjectPath -or $ProjectPath -eq '') {
    # Default: repo root (this file lives in <root>/tests/).
    $ProjectPath = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
}
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path

if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot binary not found: $GodotExe" }
if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath 'project.godot'))) {
    throw "No project.godot in $ProjectPath (generate the wrapper project before probing)"
}
if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath 'addons/beckett/plugin.cfg'))) {
    throw "addons/beckett/plugin.cfg missing under $ProjectPath (is this a staged Lite tree?)"
}

$Endpoint = "http://127.0.0.1:$Port/mcp"
$fail = 0
$pass = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { $script:pass++; Write-Host "  ok   $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL $what" -ForegroundColor Red }
}

function Invoke-Rpc([hashtable]$payload) {
    # -Compress keeps the body one line; Depth covers nested params. Works on 5.1 + 7.
    $json = $payload | ConvertTo-Json -Depth 12 -Compress
    return Invoke-RestMethod -Uri $Endpoint -Method Post -Body $json `
        -ContentType 'application/json' -TimeoutSec 20
}

# Kill a process AND its descendants. On Windows the *_console.exe launches the real
# editor (Godot_..._win64.exe) as a SEPARATE child; killing only the console wrapper
# leaves that child holding the port. We walk children via CIM and kill leaves first.
# On Linux/macOS the raw binary is the editor itself (no wrapper), and Get-CimInstance
# may be absent under pwsh, so the child walk is Windows-only; killing the root is
# enough there.
function Stop-ProcessTree([int]$RootId) {
    $onWindows = ($env:OS -eq 'Windows_NT') -or ($PSVersionTable.Platform -eq 'Win32NT') -or ($null -eq $PSVersionTable.Platform)
    if ($onWindows) {
        try {
            $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$RootId" -ErrorAction Stop)
            foreach ($ch in $children) { Stop-ProcessTree ([int]$ch.ProcessId) }
        } catch {}
    }
    try { Stop-Process -Id $RootId -Force -ErrorAction Stop } catch {}
}

Write-Host "[ci-smoke] boot + probe Beckett on $Endpoint" -ForegroundColor Cyan
Write-Host "  godot   : $GodotExe"
Write-Host "  project : $ProjectPath"
Write-Host "  expect  : $ExpectedTools tools (Lite surface)"

# Isolated, deterministic boot: enable the server, pin both ports, and never let the
# boot rewrite the repo's client config. These are read by plugin.gd / mcp_server.gd.
# BECKETT_AUTH=0 (v1.9): a CI checkout is exactly the fresh-setup case where token auth
# defaults ON — without the kill switch every probe below would 401.
$env:BECKETT_ENABLE = '1'
$env:BECKETT_PORT = "$Port"
$env:BECKETT_RUNTIME_PORT = "$($Port + 1)"
$env:BECKETT_AUTO_CONFIG = '0'
$env:BECKETT_AUTH = '0'

$logOut = Join-Path ([System.IO.Path]::GetTempPath()) "beckett-ci-$Port.out.log"
$logErr = Join-Path ([System.IO.Path]::GetTempPath()) "beckett-ci-$Port.err.log"
if (Test-Path -LiteralPath $logOut) { Remove-Item -LiteralPath $logOut -Force }
if (Test-Path -LiteralPath $logErr) { Remove-Item -LiteralPath $logErr -Force }

# --headless --editor imports the project and stays resident; the plugin autostarts
# the server in _enter_tree. Redirecting stdout/stderr both keeps the runner log clean
# and gives us the boot log to dump on failure. Start-Process is available on all OSes
# under PowerShell 7 and on Windows PowerShell 5.1.
$proc = Start-Process -FilePath $GodotExe `
    -ArgumentList @('--headless', '--editor', '--path', $ProjectPath) `
    -PassThru -RedirectStandardOutput $logOut -RedirectStandardError $logErr

try {
    # 1. Wait for the embedded server to listen. Poll ping; tolerate connection
    #    refused while the editor is still importing.
    $up = $false
    $deadline = (Get-Date).AddSeconds($BootTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) {
            Write-Host "  editor exited early (code $($proc.ExitCode)) before the server came up" -ForegroundColor Red
            break
        }
        try {
            $r = Invoke-Rpc @{ jsonrpc = '2.0'; id = 1; method = 'ping'; params = @{} }
            if ($null -ne $r) { $up = $true; break }
        } catch {
            Start-Sleep -Milliseconds 900
        }
    }
    Check $up "server answers ping within ${BootTimeoutSec}s on port $Port"
    if (-not $up) { throw "server never came up" }

    # 2. initialize: must return protocolVersion + serverInfo (name/title/version).
    $init = (Invoke-Rpc @{
            jsonrpc = '2.0'; id = 2; method = 'initialize'
            params  = @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'ci-smoke'; version = '0' } }
        }).result
    Check ($null -ne $init.protocolVersion -and "$($init.protocolVersion)" -ne '') `
        "initialize returns protocolVersion ($($init.protocolVersion))"
    Check ($null -ne $init.serverInfo) "initialize returns serverInfo"
    Check ($null -ne $init.serverInfo.name -and "$($init.serverInfo.name)" -ne '') `
        "serverInfo carries a name ($($init.serverInfo.name))"
    Check ($init.serverInfo.title -like 'Beckett*') `
        "serverInfo.title identifies Beckett ($($init.serverInfo.title))"

    # 3. tools/list: EXACTLY the Lite surface.
    $tools = (Invoke-Rpc @{ jsonrpc = '2.0'; id = 3; method = 'tools/list'; params = @{} }).result.tools
    $count = @($tools).Count
    Check ($count -eq $ExpectedTools) "tools/list advertises exactly $ExpectedTools tools (got $count)"
    if ($count -ne $ExpectedTools) {
        $names = (@($tools | ForEach-Object { $_.name }) | Sort-Object) -join ', '
        Write-Host "  tools were: $names" -ForegroundColor DarkYellow
        # Forensics: distinguish "module never registered" (file missing / loader said no)
        # from "effort-capped" (registered but filtered out of tools/list).
        Write-Host "  [diag] addons/beckett/tools/*.gd on disk:" -ForegroundColor DarkYellow
        Get-ChildItem -Path (Join-Path $ProjectPath 'addons/beckett/tools') -Filter '*.gd' -Name -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
        foreach ($setting in @('beckett/effort', 'beckett/effort_schema')) {
            try {
                $v = (Invoke-Rpc @{
                        jsonrpc = '2.0'; id = 9; method = 'tools/call'
                        params  = @{ name = 'get_project_setting'; arguments = @{ setting = $setting } }
                    }).result
                $txt = (@($v.content | Where-Object { $_.type -eq 'text' }) | Select-Object -First 1).text
                Write-Host "  [diag] $setting -> $txt" -ForegroundColor DarkYellow
            } catch {
                Write-Host "  [diag] $setting -> probe failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }
    }
}
finally {
    if ($proc) {
        # Kill the whole tree (Windows console-wrapper spawns the editor as a child).
        Stop-ProcessTree ([int]$proc.Id)
        # Give the OS a moment to release the port for the next matrix leg / retry.
        Start-Sleep -Milliseconds 500
    }
    Remove-Item Env:BECKETT_ENABLE -ErrorAction SilentlyContinue
    Remove-Item Env:BECKETT_PORT -ErrorAction SilentlyContinue
    Remove-Item Env:BECKETT_RUNTIME_PORT -ErrorAction SilentlyContinue
    Remove-Item Env:BECKETT_AUTO_CONFIG -ErrorAction SilentlyContinue
    Remove-Item Env:BECKETT_AUTH -ErrorAction SilentlyContinue
}

Write-Host ""
if ($fail -gt 0) {
    Write-Host "CI SMOKE: $fail failed, $pass passed" -ForegroundColor Red
    if (Test-Path -LiteralPath $logErr) {
        Write-Host "--- editor stderr (tail) ---" -ForegroundColor DarkGray
        Get-Content -LiteralPath $logErr -Tail 40 | Write-Host
    }
    if (Test-Path -LiteralPath $logOut) {
        Write-Host "--- editor stdout (tail) ---" -ForegroundColor DarkGray
        Get-Content -LiteralPath $logOut -Tail 40 | Write-Host
    }
    exit 1
}
Write-Host "CI SMOKE: all $pass checks passed" -ForegroundColor Green
exit 0
