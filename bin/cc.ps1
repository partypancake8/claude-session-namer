# cc.ps1 - the PowerShell twin of bin/cc, for Claude Code on native Windows.
#
# Launches Claude Code with its job record already on disk, so the session's
# job-record watcher arms and the naming hook can set the prompt-bar color
# without /color being typed. bin/cc explains why the record has to exist
# before claude starts.
#
# Use it like `claude`: `cc.ps1`, `cc.ps1 --model opus`, `cc.ps1 -c`.
# install.sh adds this to your PowerShell profile, so plain `claude` comes
# through here; `claude.exe` (or `& (Get-Command claude -Type Application)`)
# still reaches the real binary:
#
#   function claude { & "$HOME\bin\cc.ps1" @args }
#
# Disable the whole thing with: New-Item ~\.claude\session-name-guard-off

$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$jobRecord = Join-Path $HOME '.claude\hooks\job_record.py'

# The real claude: an application on PATH, never a function or this script.
# An npm install puts a claude.cmd shim there; run the claude.exe it points at,
# so Ctrl+C does not stop at "Terminate batch job (Y/N)?".
function Find-Claude {
    $apps = @(Get-Command claude.exe, claude -CommandType Application -ErrorAction SilentlyContinue)
    foreach ($app in $apps) {
        $path = $app.Source
        if ($path -like '*.exe') { return $path }
        if ($path -match '\.(cmd|bat)$') {
            $hit = Select-String -Path $path -Pattern '"%dp0%\\?([^"%]+?\.exe)"' | Select-Object -First 1
            if ($hit) {
                $exe = Join-Path (Split-Path $path) $hit.Matches[0].Groups[1].Value
                if (Test-Path $exe) { return $exe }
            }
            return $path
        }
    }
    return $null
}

# A Python 3 that runs. `python3` is often the Microsoft Store stub, an alias
# in ...\WindowsApps that is on PATH but does not run, so anything there is
# tried once first (as in hooks/find_python.sh).
function Find-Python {
    if ($env:SESSION_NAME_PYTHON) { return $env:SESSION_NAME_PYTHON }
    foreach ($cand in 'python', 'python3', 'py') {
        $app = Get-Command $cand -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $app) { continue }
        if ($app.Source -like '*\WindowsApps\*') {
            & $cand -c 'import sys; sys.exit(sys.version_info[0] != 3)' 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { continue }
        }
        return $cand
    }
    return $null
}

$real = Find-Claude
if (-not $real) {
    Write-Error 'cc: claude is not on PATH'
    exit 127
}

function Invoke-Claude([string[]] $argv) {
    & $real @argv
    exit $LASTEXITCODE
}

# escape hatch and anything that is not a terminal session: just run claude
if ((Test-Path (Join-Path $claudeDir 'session-name-guard-off')) -or [Console]::IsOutputRedirected) {
    Invoke-Claude $args
}

$python = Find-Python
if (-not $python) { Invoke-Claude $args }

$sid = ''
$passthrough = $false
$resumeSeen = $false
$prev = ''
foreach ($arg in $args) {
    $arg = [string]$arg
    # headless and informational modes: nothing to name
    if ($arg -cin '-p', '--print', '-v', '--version', '-h', '--help') { $passthrough = $true }
    # modes that pick their own session: never add --session-id
    if ($arg -cin '-c', '--continue', '--fork-session', '--teleport', '--from-pr') { $passthrough = $true }
    if ($arg -cin '-r', '--resume') { $resumeSeen = $true }
    if (($prev -cin '--session-id', '--resume', '-r') -and
        ($arg -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')) {
        $sid = $arg
    }
    $prev = $arg
}

# a bare -r / --resume (the interactive picker) owns the session id
if ($resumeSeen -and -not $sid) { Invoke-Claude $args }
if ($passthrough -and -not $sid) { Invoke-Claude $args }

$cwd = (Get-Location).ProviderPath
if (-not $sid) {
    $sid = [guid]::NewGuid().ToString()
    & $python $jobRecord ensure $sid $cwd --prelaunch *> $null
    Start-Process -FilePath $python -ArgumentList "`"$jobRecord`"", 'prune' -WindowStyle Hidden
    Invoke-Claude (@('--session-id', $sid) + $args)
}

# a session id was given on the command line: just make sure its record exists
& $python $jobRecord ensure $sid $cwd --prelaunch *> $null
Invoke-Claude $args
