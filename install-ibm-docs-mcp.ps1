# install-ibm-docs-mcp.ps1
# IBM Docs MCP Server (https://github.com/hkwd/ibm-docs-mcp) install script

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Config --
$RepoUrl    = "https://github.com/hkwd/ibm-docs-mcp.git"
$InstallDir = "$env:USERPROFILE\.mcp-servers\ibm-docs-mcp"
$McpJson    = "$env:USERPROFILE\.bob\settings\mcp.json"
# Workspace config alternative:
# $McpJson  = ".bob\mcp.json"
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
if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 12)) {
    Abort "Python 3.12+ required. Current: $pyVerNum"
}

try {
    $gitVer = git --version 2>&1
    Write-Host "  Git: $gitVer" -ForegroundColor Green
} catch {
    Abort "Git not found. Install from https://git-scm.com/downloads"
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

# -- 4. Install Playwright Chromium --
Write-Step "Installing Playwright Chromium..."
python -m playwright install chromium
Write-Host "  Playwright Chromium installed" -ForegroundColor Green
Pop-Location

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
    args    = @("-m", "ibm_docs.server")
    cwd     = $InstallDir
}

# Remove existing entry if present, then add fresh
if ((Get-PropNames $config.mcpServers) -contains "ibm-docs") {
    $config.mcpServers.PSObject.Properties.Remove("ibm-docs")
}
$config.mcpServers | Add-Member -MemberType NoteProperty -Name "ibm-docs" -Value $serverEntry

$newJson = $config | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($McpJson, $newJson, [System.Text.UTF8Encoding]::new($false))
Write-Host "  Registered successfully" -ForegroundColor Green

# -- 6. Startup test --
Write-Step "Testing server startup (will stop after 3 seconds)..."
Push-Location $InstallDir
$errFile = "$env:TEMP\ibm-docs-mcp-stderr.txt"
$proc = Start-Process -FilePath "python" -ArgumentList "-m", "ibm_docs.server" `
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
Write-Host " IBM Docs MCP Server installation complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Install path  : $InstallDir"
Write-Host "  MCP config    : $McpJson"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "  1. Restart Bob"
Write-Host "  2. Check the MCP panel - 'ibm-docs' should appear"
Write-Host ""
Write-Host "  To add/manage products, edit:"
Write-Host "  $InstallDir\config\products.yaml"
Write-Host ""