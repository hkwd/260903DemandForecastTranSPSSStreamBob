# install-spss-clemb-mcp.ps1
# SPSS Modeler clemb.exe MCP Server (https://github.com/hkwd/spss-clemb-mcp) install script

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Config --
$RepoUrl    = "https://github.com/hkwd/spss-clemb-mcp.git"
$InstallDir = "$env:USERPROFILE\.mcp-servers\spss-clemb-mcp"
$McpJson    = "$env:USERPROFILE\.bob\settings\mcp.json"
# Workspace config alternative:
# $McpJson  = ".bob\mcp.json"

# clemb.exe default path (SPSS Modeler 19.0)
$ClembPath  = "C:\Program Files\IBM\SPSS\Modeler\19.0\bin\clemb.exe"
# ------------

function Write-Step([string]$msg) {
    Write-Host "`n>> $msg" -ForegroundColor Cyan
}

function Abort([string]$msg) {
    Write-Host "`n[ERROR] $msg" -ForegroundColor Red
    exit 1
}

# Helper: safely get property names from a PSObject (handles empty-object edge case)
function Get-PropNames($obj) {
    if ($null -eq $obj) { return @() }
    $names = $obj.PSObject.Properties | ForEach-Object { $_.Name }
    if ($null -eq $names) { return @() }
    return @($names)
}

# -- 1. Prerequisites check --
Write-Step "Checking prerequisites..."

try {
    $pyVer = python --version 2>&1
    Write-Host "  Python: $pyVer" -ForegroundColor Green
} catch {
    Abort "Python not found. Install from https://www.python.org/downloads/"
}

$pyVerNum = (python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')") -replace "`n",""
$parts = $pyVerNum -split "\."
$major = [int]$parts[0]; $minor = [int]$parts[1]
if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 10)) {
    Abort "Python 3.10+ required. Current: $pyVerNum"
}

try {
    $gitVer = git --version 2>&1
    Write-Host "  Git: $gitVer" -ForegroundColor Green
} catch {
    Abort "Git not found. Install from https://git-scm.com/downloads"
}

# clemb.exe check (warning only - not fatal)
if (Test-Path $ClembPath) {
    Write-Host "  clemb.exe: found at $ClembPath" -ForegroundColor Green
} else {
    Write-Host "  [WARN] clemb.exe not found at: $ClembPath" -ForegroundColor Yellow
    Write-Host "         SPSS Modeler 19.0 must be installed before using this MCP server." -ForegroundColor Yellow
    Write-Host "         You can still proceed and set the path later in config.json." -ForegroundColor Yellow
}

# -- 2. Clone repository --
Write-Step "Cloning repository to: $InstallDir"

if (Test-Path $InstallDir) {
    Write-Host "  Found existing folder. Running git pull..."
    Push-Location $InstallDir
    git pull
    Pop-Location
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $InstallDir) | Out-Null
    git clone $RepoUrl $InstallDir
}
Write-Host "  Done: $InstallDir" -ForegroundColor Green

# -- 3. Install Python dependencies --
Write-Step "Installing Python dependencies..."
Push-Location $InstallDir
python -m pip install -e . --quiet
Write-Host "  pip install complete" -ForegroundColor Green
Pop-Location

# -- 4. Create config.json from example --
Write-Step "Setting up config.json..."
$configDest    = "$InstallDir\config.json"
$configExample = "$InstallDir\config.example.json"

if (Test-Path $configDest) {
    Write-Host "  config.json already exists. Skipping." -ForegroundColor Yellow
} elseif (Test-Path $configExample) {
    Copy-Item $configExample $configDest
    $configContent = Get-Content $configDest -Raw -Encoding UTF8
    $clembEscaped  = $ClembPath -replace "\\", "\\\\"
    $configContent = $configContent -replace '"clemb_path":\s*"[^"]*"', "`"clemb_path`": `"$clembEscaped`""
    [System.IO.File]::WriteAllText($configDest, $configContent, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Created config.json (clemb_path set to: $ClembPath)" -ForegroundColor Green
    Write-Host "  Edit $configDest to configure server connection if needed." -ForegroundColor Cyan
} else {
    Write-Host "  config.example.json not found. Creating minimal config.json..." -ForegroundColor Yellow
    $clembEscaped = $ClembPath -replace "\\", "\\\\"
    $minimalConfig = "{`n  `"clemb_path`": `"$clembEscaped`"`n}`n"
    [System.IO.File]::WriteAllText($configDest, $minimalConfig, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Created minimal config.json" -ForegroundColor Green
}

# -- 5. Register in mcp.json --
Write-Step "Updating MCP config: $McpJson"

if (-not (Test-Path $McpJson)) {
    New-Item -ItemType File -Force -Path $McpJson | Out-Null
    Set-Content -Path $McpJson -Value '{"mcpServers":{}}' -Encoding UTF8
}

$raw    = Get-Content -Path $McpJson -Raw -Encoding UTF8
$config = $raw | ConvertFrom-Json

# Ensure mcpServers exists
if ((Get-PropNames $config) -notcontains "mcpServers") {
    $config | Add-Member -MemberType NoteProperty -Name "mcpServers" -Value ([PSCustomObject]@{})
}

# Ensure mcpServers is a PSCustomObject (not null/empty)
if ($null -eq $config.mcpServers) {
    $config.mcpServers = [PSCustomObject]@{}
}

$serverEntry = [PSCustomObject]@{
    command = "python"
    args    = @("-m", "spss_clemb_mcp.server")
    cwd     = $InstallDir
}

# Remove existing entry if present, then add fresh
if ((Get-PropNames $config.mcpServers) -contains "spss-clemb-mcp") {
    $config.mcpServers.PSObject.Properties.Remove("spss-clemb-mcp")
}
$config.mcpServers | Add-Member -MemberType NoteProperty -Name "spss-clemb-mcp" -Value $serverEntry

$newJson = $config | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($McpJson, $newJson, [System.Text.UTF8Encoding]::new($false))
Write-Host "  Registered successfully" -ForegroundColor Green

# -- 6. Startup test --
Write-Step "Testing server startup (will stop after 3 seconds)..."
Push-Location $InstallDir
$errFile = "$env:TEMP\spss-clemb-mcp-stderr.txt"
$proc = Start-Process -FilePath "python" -ArgumentList "-m", "spss_clemb_mcp.server" `
        -PassThru -NoNewWindow -RedirectStandardError $errFile
Start-Sleep -Seconds 3
if (-not $proc.HasExited) {
    $proc.Kill()
    Write-Host "  Server started successfully" -ForegroundColor Green
} else {
    $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    Write-Host "  [WARN] Server exited early. Error:" -ForegroundColor Yellow
    Write-Host $stderr -ForegroundColor Yellow
}
Pop-Location

# -- Done --
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " SPSS Modeler clemb.exe MCP Server installation complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Install path  : $InstallDir"
Write-Host "  MCP config    : $McpJson"
Write-Host "  Server config : $InstallDir\config.json"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "  1. Edit config.json if you need server connection settings"
Write-Host "     (hostname, port, username, password for SPSS Modeler Server)"
Write-Host "  2. Restart Bob"
Write-Host "  3. Check the MCP panel - 'spss-clemb-mcp' should appear"
Write-Host ""
Write-Host "  Alternatively, set environment variables instead of config.json:"
Write-Host "    SPSS_MODELER_CLEMB_PATH"
Write-Host "    SPSS_MODELER_SERVER_HOSTNAME"
Write-Host "    SPSS_MODELER_SERVER_PORT"
Write-Host "    SPSS_MODELER_SERVER_USERNAME"
Write-Host "    SPSS_MODELER_SERVER_PASSWORD"
Write-Host ""