# pyxer.ps1 - Command-line frontend for the pyxer packager.
#
# Thin wrapper around build.ps1 that understands *profiles* and *apps*
# declared in pyxer.config.json. It resolves "pyxer build <app>" to the
# underlying build.ps1 switches, while still letting you pass any raw
# build.ps1 argument (a raw switch wins over the profile value).
#
# Usage:
#   .\pyxer.ps1 --help                 show commands and options
#   .\pyxer.ps1 apps                   list defined apps + their profiles
#   .\pyxer.ps1 profiles               list available profiles
#   .\pyxer.ps1 build <app>            build one app with its default profile
#   .\pyxer.ps1 build <app> -p gui     build one app with an explicit profile
#   .\pyxer.ps1 build all              build every defined app (shared runtime)
#   .\pyxer.ps1 build app1,app2        build several apps in one run
#   .\pyxer.ps1 build <app> -Upx ...   raw build.ps1 switches are merged in
#
# Examples:
#   .\pyxer.ps1 build hello
#   .\pyxer.ps1 build hello_gui,hello_pygame
#   .\pyxer.ps1 build hello_gui -p gui -SkipRuntime

param(
    [Parameter(Position=0)][string]$Action = '',
    [Parameter(Position=1)][string]$Target  = '',
    [string]$p = '',                 # short form: -p <profile>
    [string]$Profile = '',           # long form:  -Profile <profile>
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$rem = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new() } catch { }

$root      = $PSScriptRoot
$configFile = Join-Path $root 'pyxer.config.json'
$build     = Join-Path $root 'build.ps1'

if ($p) { $Profile = $p }
$rawArgs = @($rem)

function Get-Config {
    if (-not (Test-Path $configFile)) { throw "config not found: $configFile" }
    return Get-Content $configFile -Raw | ConvertFrom-Json
}

function Show-Help {
    Write-Host @"
pyxer - packages small/medium Python apps (Windows only)

USAGE
  pyxer.ps1 <action> [target] [options]

ACTIONS
  build <app>     package app(s); comma-separated names or "all" for every app
  apps            list apps defined in pyxer.config.json
  profiles        list profiles defined in pyxer.config.json
  --help, -h      show this help

OPTIONS
  -p <profile>    use a named profile from pyxer.config.json
  ...             any raw build.ps1 switch is also accepted
                  (-PySide6 -Upx -NoSSL -TrimPython -NoConsole -Manifest
                   -Icon -Checksum -Onefile -SkipRuntime -Windowed ...)

EXAMPLES
  pyxer.ps1 build hello
  pyxer.ps1 build hello_gui,hello_pygame
  pyxer.ps1 build all -p gui
  pyxer.ps1 build hello_gui -SkipRuntime -Upx

PROFILES (see pyxer.config.json)
"@
    $cfg = Get-Config
    foreach ($name in ($cfg.profiles.PSObject.Properties | Sort-Object Name)) {
        $opts = ($name.Value.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '
        Write-Host ("  {0,-10} {1}" -f $name.Name, $opts)
    }
    Write-Host ""
}

function Show-Apps {
    $cfg = Get-Config
    Write-Host "Apps (source -> default profile):"
    foreach ($name in ($cfg.apps.PSObject.Properties | Sort-Object Name)) {
        $a = $name.Value
        Write-Host ("  {0,-14} {1}  -> {2}" -f $name.Name, $a.source, $a.profile)
    }
}

function Show-Profiles {
    $cfg = Get-Config
    Write-Host "Profiles:"
    foreach ($name in ($cfg.profiles.PSObject.Properties | Sort-Object Name)) {
        $opts = ($name.Value.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '
        Write-Host ("  {0,-10} {1}" -f $name.Name, $opts)
    }
}

# Merge profile switches with raw command-line switches (raw wins).
function Merge-Switches($profileSwitches, [string[]]$rawArgs) {
    $switches = [ordered]@{}
    if ($null -ne $profileSwitches) {
        foreach ($prop in $profileSwitches.PSObject.Properties) {
            $switches[$prop.Name] = $prop.Value
        }
    }
    # parse raw -Name / -Name value pairs; raw overrides profile values.
    $i = 0
    while ($i -lt $rawArgs.Count) {
        $a = $rawArgs[$i]
        if ($a -like '-*') {
            $name = $a.TrimStart('-')
            # peek next: if it looks like a value, consume it
            $next = if ($i + 1 -lt $rawArgs.Count) { $rawArgs[$i + 1] } else { $null }
            if ($null -ne $next -and $next -notlike '-*' -and $name -in @('AppName','SourceDir','Version','BuildNo','Icon','PySide6Mode')) {
                $switches[$name] = $next
                $i += 2
            } else {
                $switches[$name] = $true
                $i += 1
            }
        } else {
            $i += 1
        }
    }
    return $switches
}

# Turn the merged switch map into a splattable hashtable for build.ps1.
function Build-Splat($sw) {
    $splat = @{}
    foreach ($k in $sw.Keys) {
        $v = $sw[$k]
        if ($v -eq $true) {
            $splat[$k] = $true
        } elseif ($v -eq $false -or $null -eq $v) {
            # skip explicit false / null profile values
        } else {
            $splat[$k] = "$v"
        }
    }
    return $splat
}

# ---- dispatch -------------------------------------------------------------
$helpWanted = $Action -in @('--help', '-h', '') -or ($rem -contains '--help') -or ($rem -contains '-h')
if ($helpWanted) {
    Show-Help
    exit 0
}

$cfg = Get-Config

switch ($Action.ToLower()) {
    'apps'    { Show-Apps;    exit 0 }
    'profiles' { Show-Profiles; exit 0 }
    'build'   { }
    default   { Write-Host "Unknown action: $Action  (see pyxer.ps1 --help)"; exit 1 }
}

if (-not $Target) { Write-Host 'build needs an app name (or "all").'; Show-Help; exit 1 }

if ($Profile -and -not ($cfg.profiles.PSObject.Properties.Name -contains $Profile)) {
    Write-Host "Unknown profile: $Profile"; Show-Profiles; exit 1
}

$names = @($Target.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($names -contains 'all') {
    $names = @($cfg.apps.PSObject.Properties.Name)
}

$appNames = @(); $srcDirs = @()
foreach ($n in $names) {
    if (-not ($cfg.apps.PSObject.Properties.Name -contains $n)) {
        Write-Host "Unknown app: $n  (see pyxer.ps1 apps)"; exit 1
    }
    $appNames += $n
    $srcDirs  += (Join-Path $root $cfg.apps.$n.source)
}

# merge profile + raw switches into a single map, then append as build.ps1 args
$profileName = if ($Profile) { $Profile } else { $cfg.apps.($names[0]).profile }
$profileSw = if ($profileName) { $cfg.profiles.$profileName } else { $null }
$sw = Merge-Switches ($profileSw -as [pscustomobject]) $rawArgs
$sw['AppName']   = ($appNames -join ',')
$sw['SourceDir'] = ($srcDirs -join ',')
if (-not $sw.Contains('Version')) { $sw['Version'] = '0.1' }

$splat = Build-Splat $sw
& $build @splat
exit $LASTEXITCODE