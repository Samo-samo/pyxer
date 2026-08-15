# build.ps1 - Mini Packager (onedir, shared-runtime layout)
#
# Produces:
#   dist\<AppName>.exe                        (launcher, one per app)
#   dist\runtime\                             (shared: embeddable CPython + deps)
#     python.exe, python312.dll, python312.zip, python312._pth
#     apps\<AppName>\main.py                  (each app's sources)
#     app_version.txt                         (version stamp)
#
# The launcher derives the app name from its own file name and runs
# runtime\apps\<app>\main.py through runtime\python.exe, so several apps
# can share one runtime folder (paylasimli). Use -SkipRuntime to build an
# additional app on top of an existing runtime (no re-download/copy).
#
# Usage:
#   .\build.ps1 -AppName hello -Version 0.1
#   .\build.ps1 -AppName gir -SourceDir src_gui -Windowed
#   .\build.ps1 -AppName "myapp_a,myapp_b" -SourceDir "src_a,src_b" -NoConsole
#
# Third-party packages are discovered automatically: scan_deps.py walks each
# app's sources for top-level imports and the resulting packages (and their
# __init__-companions, e.g. shiboken6) are merged into runtime\site-packages.
# Size trimming for fat known packages (PySide6, ...) is data-driven from
# trim.json - no hard-coded PySide6 logic in build.ps1.
#
# Extra switches:
#   -Upx           compress runtime DLLs / EXEs / pyds with UPX (downloads it)
#   -NoSSL         drop libcrypto/libssl/_ssl (apps that don't use TLS)
#   -TrimPython    rewrite python312.zip without dev/std-lib extras
#   -SkipRuntime   do not (re)build the runtime; add an app to the existing dist
#   -VerboseUpx    print the full UPX log (default: summary only)
#   -Archive       zip the finished dist into releases\v<Version>\dist.zip
#   -Onefile       also build <AppName>_onefile.exe (self-extracting, standalone)
#   -Manifest      embed an asInvoker + dpiAware manifest (no UAC prompt), optional
#   -Icon <path>   embed an .ico into the launcher EXE(s), optional
#   -Checksum      write checksums (MD5+SHA256) for dist files, optional
#   -NoConsole     GUI apps: use pythonw.exe + CREATE_NO_WINDOW (no black console)
#
# Notes:
#   * -AppName accepts a comma-separated list; the first app builds the shared
#     runtime and the rest are added with -SkipRuntime automatically. If
#     -SourceDir has a single entry it is used for every app.
#   * The final summary is also appended to releases\build_log.csv
#     (timestamp, version, apps, size, duration, modes).
#
param(
    [string]$AppName = 'hello',
    [string]$Version = '0.1',
    [int]$BuildNo = 0,           # auto-incrementing build counter (0 = auto)
    [switch]$Windowed,
    [switch]$Upx,
    [switch]$NoSSL,
    [switch]$TrimPython,
    [switch]$SkipRuntime,
    [switch]$VerboseUpx,       # show the full UPX log (default: only summary)
    [switch]$Archive,          # zip the finished dist next to it
    [switch]$Onefile,          # also produce <AppName>_onefile.exe (self-extracting)
    [switch]$Manifest,         # embed asInvoker + dpiAware manifest (optional)
    [string]$Icon = '',        # optional .ico path to embed
    [switch]$Checksum,         # write checksums for dist files (optional)
    [switch]$NoConsole,        # GUI-only: suppress the console (pythonw.exe)
    [string]$SourceDir = 'src'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new() } catch { }

$buildStart = Get-Date

$root    = $PSScriptRoot
$work    = Join-Path $root 'work'
$dist    = Join-Path $root 'dist'
$releases = Join-Path $root 'releases'
$pythonVer = '3.12.7'
$embedName = "python-$pythonVer-embed-amd64.zip"
$embedDir  = Join-Path $work '_runtime_cache'
$embedZip  = Join-Path $embedDir $embedName

# Data-driven size trimming for fat packages (trim.json). Loaded once.
$trimRules = @{}
$trimFile = Join-Path $root 'trim.json'
if (Test-Path $trimFile) {
    try {
        $trimRules = Get-Content $trimFile -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Host "  (warning: trim.json ignored - $($_.Exception.Message))"
    }
}

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# Rewrite python312.zip dropping std-lib bits not needed at runtime.
function Trim-PythonZip([string]$zipPath) {
    Write-Host "Rewriting python312.zip (trimming std-lib)..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $dropPrefixes = @(
        'tkinter', 'ensurepip', 'idlelib', 'lib2to3', 'distutils',
        'unittest', 'test', 'turtle', 'turtledemo', 'pydoc_data',
        'sqlite3/test', 'email/test', 'xml/test', 'json/tests',
        'ctypes/test', 'dataclasses/test'
    )

    $tmpZip = "$zipPath.tmp"
    $src = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    $dst = [System.IO.Compression.ZipFile]::Open($tmpZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $src.Entries) {
            $name = $entry.FullName
            $drop = $false
            foreach ($p in $dropPrefixes) {
                if ($name.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { $drop = $true; break }
            }
            if ($drop) { continue }

            $new = $dst.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
            $inStream = $entry.Open()
            try {
                $outStream = $new.Open()
                try {
                    if ($entry.Length -gt 0) { $inStream.CopyTo($outStream) }
                } finally { $outStream.Dispose() }
            } finally { $inStream.Dispose() }
        }
    } finally {
        $dst.Dispose()
        $src.Dispose()
    }
    Move-Item -Path $tmpZip -Destination $zipPath -Force
    Write-Host "python312.zip rewritten."
}

# Locate a system Python we can copy third-party packages from.
function Get-SystemPython {
    $sysPy = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $sysPy) { throw 'A system Python installation is required to copy third-party packages from.' }
    return $sysPy
}

function Get-SitePackages([string]$sysPy) {
    $sp = (& $sysPy -c "import sysconfig; print(sysconfig.get_paths()['purelib'])") 2>$null
    $sp = ($sp | Select-Object -Last 1).Trim()
    if (-not $sp -or -not (Test-Path $sp)) { throw "Cannot resolve site-packages of $sysPy" }
    return $sp
}

# Scan an app for its third-party top-level imports (via scan_deps.py).
function Get-AppDeps([string]$appSrc, [string]$sysPy) {
    $scanner = Join-Path $root 'scan_deps.py'
    $deps = & $sysPy $scanner $appSrc 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "  (scan_deps failed for $appSrc)"; return @() }
    return @($deps | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
}

# Load trim rules from trim.json (data-driven package size trimming) as a
# hashtable: { '<PackageName>' = @{ keep = @('file.txt', ...); dirs = @{ 'rel/path' = @('file.dll') | '*' } } }.
# Copy-Trimmed copies a package into $dst applying a node's rule:
#   keep  -> only these top-level files are copied (plus anything in dirs)
#   dirs  -> 'rel/path' => '*' keeps the whole sub-tree, a list keeps only
#            those files directly inside that sub-directory.
# A missing rule copies everything unchanged.
function Copy-Trimmed([string]$src, [string]$dst, $rule) {
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $keep = @($rule.keep)
    if (-not $keep -or $keep -contains '*') {
        Get-ChildItem $src -Force | Copy-Item -Destination $dst -Recurse -Force
    } else {
        foreach ($name in $keep) {
            $p = Join-Path $src $name
            if (Test-Path $p -PathType Leaf) {
                Copy-Item -LiteralPath $p -Destination $dst -Force
            }
        }
    }
    foreach ($rel in @($rule.dirs.Keys)) {
        $subRule = $rule.dirs[$rel]
        $s = Join-Path $src $rel
        if (-not (Test-Path $s)) { continue }
        $d = Join-Path $dst $rel
        if ($subRule -eq '*') {
            New-Item -ItemType Directory -Force -Path (Split-Path $d) | Out-Null
            Copy-Item -Path $s -Destination $d -Recurse -Force
        } else {
            $files = @($subRule)
            if ($files -contains '*') {
                New-Item -ItemType Directory -Force -Path (Split-Path $d) | Out-Null
                Copy-Item -Path $s -Destination $d -Recurse -Force
            } elseif ($files) {
                New-Item -ItemType Directory -Force -Path $d | Out-Null
                foreach ($f in $files) {
                    $fp = Join-Path $s $f
                    if (Test-Path $fp -PathType Leaf) { Copy-Item -LiteralPath $fp -Destination $d -Force }
                }
            }
        }
    }
}

# Copy every package in $depNames that is missing under $runtimeDest into
# runtimeDest\site-packages (a single merge point used by all apps). Only the
# package folders are copied; *.dist-info metadata stays in the build machine.
# Packages with a trim.json rule are copied through Copy-Trimmed instead.
function Add-MissingDeps([string]$runtimeDest, [string[]]$depNames, [string]$sysPy) {
    $sitePkgs = Get-SitePackages $sysPy
    $spDst = Join-Path $runtimeDest 'site-packages'
    $added  = @()

    foreach ($dep in $depNames) {
        # Already present -> skip (runtime root packages count as present).
        $rootHit = Get-ChildItem $runtimeDest -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $dep }
        if ($rootHit -or (Test-Path (Join-Path $spDst $dep))) { continue }

        $srcPkg = Join-Path $sitePkgs $dep
        if (-not (Test-Path $srcPkg)) { continue }   # stdlib-ish / unavailable
        New-Item -ItemType Directory -Force -Path $spDst | Out-Null
        $dstPkg = Join-Path $spDst $dep
        if ($trimRules.ContainsKey($dep)) {
            Copy-Trimmed $srcPkg $dstPkg $trimRules[$dep]
        } else {
            Copy-Item $srcPkg $dstPkg -Recurse -Force
        }
        # Some wheels ship C-extension DLLs in a sibling folder named
        # <pkg>.libs (numpy, scipy, matplotlib, ...). Without it the .pyd
        # files fail to load ("DLL load failed"). Copy that too when present.
        foreach ($libsDir in Get-ChildItem $sitePkgs -Directory -Filter "$dep.libs") {
            Copy-Item $libsDir.FullName (Join-Path $spDst $libsDir.Name) -Recurse -Force
            $added += $libsDir.Name
        }
        $added += $dep
    }

    if ($added) {
        Write-Host ("  merged deps into runtime site-packages: {0}" -f ($added -join ', '))
    }
    return $added
}

# Ensure the runtime ._pth lists site-packages (and anything already there).
function Sync-Pth([string]$runtimeDest) {
    $pthFile = Get-ChildItem $runtimeDest -Filter 'python*._pth' | Select-Object -First 1
    if (-not $pthFile) { return }
    $lines = @()
    $haveSite = $false
    foreach ($l in (Get-Content $pthFile.FullName)) {
        if ($l -eq 'site-packages') { $haveSite = $true }
        if ($l.Trim() -and $l.Trim() -notmatch '^#') { $lines += $l }
    }
    if (-not $haveSite) { $lines += 'site-packages' }
    Set-Content -Path $pthFile.FullName -Value ($lines -join "`n") -Encoding ASCII
}

# Copy the MSVC runtime DLLs (msvcp140/vcruntime140/concrt140) next to the
# embeddable python. Most Windows C-extensions (.pyd) link against them, and
# while the runtime usually has vcruntime140.dll already, msvcp140*.dll and
# concrt140.dll are not shipped in the embeddable bundle. Source: the build
# machine's VC redist in System32 (the bundler's own copy is the same DLL set
# redistributable apps are allowed to ship).
function Add-VcRuntime([string]$runtimeDest) {
    $sys32 = Join-Path $env:WINDIR 'System32'
    $vcDlls = @('msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll',
                'msvcp140_codecvt_ids.dll', 'concrt140.dll',
                'vcruntime140.dll', 'vcruntime140_1.dll')
    $added = @()
    foreach ($name in $vcDlls) {
        $dst = Join-Path $runtimeDest $name
        if (Test-Path $dst) { continue }
        $src = Join-Path $sys32 $name
        if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination $dst -Force; $added += $name }
    }
    if ($added) {
        Write-Host ("  VC runtime added next to python.exe: {0}" -f ($added -join ', '))
    }
}

# Build the shared runtime part (embeddable CPython + deps + optional trims).
function Build-RuntimePart([string]$runtimeDest, [string[]]$extraDeps) {
    Expand-Archive -Path $embedZip -DestinationPath $runtimeDest -Force
    Set-Content -Path (Join-Path $runtimeDest 'app_version.txt') -Value $Version -Encoding ASCII
    Add-VcRuntime $runtimeDest

    # Generic third-party deps (whatever scan_deps found for the app):
    # copied under site-packages and registered in the ._pth. Any package
    # with a trim.json rule (PySide6, ...) is filtered at copy time.
    if ($extraDeps) {
        $sysPy = Get-SystemPython
        Add-MissingDeps $runtimeDest $extraDeps $sysPy
        Sync-Pth $runtimeDest
    }

    if ($NoSSL) {
        foreach ($f in @('libcrypto-3.dll', 'libssl-3.dll', '_ssl.pyd')) {
            Remove-Item (Join-Path $runtimeDest $f) -ErrorAction SilentlyContinue
        }
        Write-Host "Removed SSL/TLS runtime files (-NoSSL)."
    }

    if ($TrimPython) {
        Trim-PythonZip (Join-Path $runtimeDest 'python312.zip')
        if ($NoSSL) { Remove-Item (Join-Path $runtimeDest 'libcrypto-3.dll') -ErrorAction SilentlyContinue }
    }
}

# Copy app sources into runtime\apps\<AppName>, skipping stale DBs / cache.
function Copy-App([string]$srcDir, [string]$appDest) {
    if (Test-Path $appDest) { Remove-Item -Recurse -Force $appDest }
    if (Test-Path (Join-Path $srcDir 'main.py')) {
        New-Item -ItemType Directory -Force -Path $appDest | Out-Null
        & robocopy $srcDir $appDest /E /XD __pycache__ /XF *.db /NFL /NDL /NJH /NJS /NP | Out-Null
    } else {
        # A SourceDir pointing at a single main.py isn't supported here;
        # fall back to a raw copy (caller validated main.py exists first).
        Copy-Item -Path $srcDir -Destination $appDest -Recurse -Force
    }
}

# Compile a launcher .c into launcher.exe / launcher_onefile.exe (MSVC).
function Invoke-Compile([string]$source, [string]$output, [string]$res = '', [string]$defines = '') {
    $log = Join-Path $work "cl_$([IO.Path]::GetFileNameWithoutExtension($source)).txt"
    $resArg = if ($res) { " `"$res`"" } else { '' }
    $defArg = if ($defines) { " /D $defines" } else { '' }
    $clCmd = 'call "' + $vcvars + '" && cl /nologo /O2 /MT ' + $source +
             $defArg + $resArg + ' /Fe:' + $output + ' /link "/SUBSYSTEM:' + $subsystem + '" /MACHINE:X64'
    cmd /c $clCmd > $log 2>&1
    if (-not (Test-Path $output)) {
        Get-Content $log | Write-Host
        throw "Failed to compile $source"
    }
}

# --------------------------------------------------------------------------
# Resolve apps (comma-separated) --------------------------------------------
# --------------------------------------------------------------------------
$appNames = @($AppName.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$srcDirs  = @($SourceDir.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($appNames.Count -eq 0) { throw '-AppName required.' }
if ($srcDirs.Count -eq 1) {
    $srcDirs = @(for ($i = 0; $i -lt $appNames.Count; $i++) { $srcDirs[0] })
} elseif ($srcDirs.Count -ne $appNames.Count) {
    throw 'When several apps are given, -SourceDir must be one entry or one per app.'
}

# Resolve per-app source directories (relative to $root, or absolute).
$srcAbs = @()
for ($i = 0; $i -lt $appNames.Count; $i++) {
    $s = $srcDirs[$i]
    $srcAbs += @(if ([System.IO.Path]::IsPathRooted($s)) { $s } else { Join-Path $root $s })
}

New-Item -ItemType Directory -Force -Path $work, $dist | Out-Null

if (-not $SkipRuntime -and -not (Test-Path $embedZip)) {
    New-Item -ItemType Directory -Force -Path $embedDir | Out-Null
    Write-Host "Downloading embeddable runtime..."
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/$pythonVer/$embedName" -OutFile $embedZip
} else {
    Write-Host "Runtime cache hit: $embedZip"
}

# --------------------------------------------------------------------------
# MSVC setup (once) ---------------------------------------------------------
# --------------------------------------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { $vswhere = "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe" }
if (-not (Test-Path $vswhere)) { throw 'vswhere not found (Visual Studio Build Tools required).' }

$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'MSVC (C++ build tools) not installed.' }

$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found: $vcvars" }

# --------------------------------------------------------------------------
# Optional EXE resources (icon + manifest) ----------------------------------
# --------------------------------------------------------------------------
$resFile = ''
if ($Manifest -or $Icon) {
    $rcDir = Join-Path $work '_resources'
    New-Item -ItemType Directory -Force -Path $rcDir | Out-Null

    $rc = @()
    if ($Icon) {
        if (-not (Test-Path $Icon)) { throw "-Icon not found: $Icon" }
        # copy icon into the rc dir so the .rc can reference it by base name
        $icoCopy = Join-Path $rcDir ([IO.Path]::GetFileName($Icon))
        Copy-Item -LiteralPath $Icon -Destination $icoCopy -Force
        $rc += 'IDI_APP ICON "' + ([IO.Path]::GetFileName($Icon)) + '"'
    }
    if ($Manifest) {
        $manXml = Join-Path $rcDir 'app.manifest'
        @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="1.0.0.0" processorArchitecture="*" name="MiniApp" type="win32"/>
  <description>Packaged mini app</description>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
  <asmv3:application xmlns:asmv3="urn:schemas-microsoft-com:asm.v3">
    <asmv3:windowsSettings xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">
      <dpiAware>true</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </asmv3:windowsSettings>
  </asmv3:application>
</assembly>
'@ | Set-Content -Path $manXml -Encoding UTF8
        $rc += '1 24 "app.manifest"'
    }

    $rcPath = Join-Path $rcDir 'app.rc'
    $rc | Set-Content -Path $rcPath -Encoding Default
    $resFile = Join-Path $work "_resources_app.res"
    $rcCmd = 'call "' + $vcvars + '" && rc /fo "' + $resFile + '" "' + $rcPath + '"'
    $rcLog = Join-Path $work 'rc.txt'
    cmd /c $rcCmd > $rcLog 2>&1
    if (-not (Test-Path $resFile)) {
        Get-Content $rcLog | Write-Host
        throw 'Failed to compile EXE resources (icon/manifest).'
    }
    Write-Host "Built EXE resources (icon=$([bool]$Icon) manifest=$Manifest)"
}

$subsystem = if ($Windowed -or $NoConsole) { 'WINDOWS' } else { 'CONSOLE' }
$noConDef = if ($NoConsole) { 'PKG_NoConsole' } else { '' }
Write-Host "Compiling launcher.c (subsystem: $subsystem)..."
Invoke-Compile (Join-Path $root 'launcher.c') (Join-Path $root 'launcher.exe') $resFile $noConDef

# UPX setup (lazily, so -Upx without a build doesn't fetch it)
$upxExe = $null
if ($Upx) {
    $upxCache = Join-Path $work '_upx_cache'
    $upxExe   = Join-Path $upxCache 'upx.exe'
    if (-not (Test-Path $upxExe)) {
        New-Item -ItemType Directory -Force -Path $upxCache | Out-Null
        Write-Host "Downloading UPX..."
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/upx/upx/releases/latest"
        $asset = $rel.assets | Where-Object { $_.name -match 'win64\.zip$' } | Select-Object -First 1
        $tmpZip = Join-Path $upxCache 'upx.zip'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpZip
        Expand-Archive -Path $tmpZip -DestinationPath $upxCache -Force
        $found = Get-ChildItem $upxCache -Recurse -Filter 'upx.exe' | Select-Object -First 1 -ExpandProperty FullName
        Copy-Item -Path $found -Destination $upxExe -Force
        Remove-Item $tmpZip -Force
    }
}

# --------------------------------------------------------------------------
# Per-app loop --------------------------------------------------------------
# --------------------------------------------------------------------------
$runtimeDest = Join-Path $dist 'runtime'
$builtList   = @()   # app results for the summary

for ($i = 0; $i -lt $appNames.Count; $i++) {
    $appStart  = Get-Date
    $appName   = $appNames[$i]
    $appSrc    = $srcAbs[$i]
    $isFirst   = ($i -eq 0) -and (-not $SkipRuntime)
    $useSkip   = ($i -gt 0) -or $SkipRuntime

    if (-not (Test-Path $appSrc))              { throw "Source dir not found: $appSrc" }
    if (-not (Test-Path (Join-Path $appSrc 'main.py'))) {
        throw "Source dir must contain main.py: $appSrc"
    }

    $payload = Join-Path $work "payload_$appName"
    if (Test-Path $payload) { Remove-Item -Recurse -Force $payload }
    New-Item -ItemType Directory -Force -Path $payload | Out-Null

    $runtimePayload = Join-Path $payload 'runtime'

    # Dependency scan for this app: third-party packages it needs beyond stdlib.
    $sysPy = Get-SystemPython
    $appDeps = Get-AppDeps $appSrc $sysPy

    if ($isFirst) {
        Write-Host "Building shared runtime + app '$appName' ..."
        Build-RuntimePart $runtimePayload $appDeps
    } else {
        Write-Host "Adding app '$appName' (shared runtime)..."
    }

    # App sources always land in runtime\apps\<AppName>\.
    Copy-App $appSrc (Join-Path $runtimePayload "apps\$appName")

    $targetExe = Join-Path $dist "${appName}.exe"
    Copy-Item -Path (Join-Path $root 'launcher.exe') -Destination $targetExe -Force

    if ($isFirst) {
        if (Test-Path $runtimeDest) { Remove-Item -Recurse -Force $runtimeDest }
        Copy-Item -Path $runtimePayload -Destination $runtimeDest -Recurse -Force
        Sync-Pth $runtimeDest
    } else {
        $appMerge = Join-Path $runtimeDest "apps\$appName"
        if (Test-Path $appMerge) { Remove-Item -Recurse -Force $appMerge }
        Copy-Item -Path (Join-Path $runtimePayload "apps\$appName") -Destination $appMerge -Recurse -Force

        # Merge this app's own third-party deps into the *shared* runtime so
        # every app keeps working (e.g. one app needs pygame, another PySide6).
        if ($appDeps) {
            $sysPy = Get-SystemPython
            Add-MissingDeps $runtimeDest $appDeps $sysPy
            Sync-Pth $runtimeDest
            if ($Upx) {
                Write-Host "Compressing merged deps with UPX..."
                $newTargets = @()
                $newTargets += Get-ChildItem (Join-Path $runtimeDest 'site-packages') -Recurse -Include '*.dll', '*.pyd' -File
                if ($newTargets) {
$out = & $upxExe --best --lzma $newTargets.FullName 2>&1
$m = ($out | Select-String '^Packed \d+ files' | Select-Object -First 1)
$packed = if ($m) { $m.ToString() } else { $null }
if ($VerboseUpx) { $out | ForEach-Object { Write-Host $_ } }
elseif ($packed) { Write-Host $packed }
                }
            }
        }
    }

    # Optional: UPX compression (runtime files once, then the new exe each time)
    if ($Upx) {
        if ($isFirst) {
            Write-Host "Compressing with UPX (shared runtime + $appName.exe)..."
            $targets = @()
            $targets += Get-ChildItem $runtimeDest -Recurse -Include '*.dll', '*.pyd', 'python.exe' -File
            $targets += Get-Item $targetExe
            # UPX can break Python stdlib .pyd inside the zip; those stay as-is.
$out = & $upxExe --best --lzma $targets.FullName 2>&1
$m = ($out | Select-String '^Packed \d+ files' | Select-Object -First 1)
$packed = if ($m) { $m.ToString() } else { $null }
if ($VerboseUpx) { $out | ForEach-Object { Write-Host $_ } }
elseif ($packed) { Write-Host $packed }
        } else {
            Write-Host "Compressing with UPX ($appName.exe)..."
$out = & $upxExe --best --lzma $targetExe 2>&1
$m = ($out | Select-String '^Packed \d+ files' | Select-Object -First 1)
$packed = if ($m) { $m.ToString() } else { $null }
if ($VerboseUpx) { $out | ForEach-Object { Write-Host $_ } }
elseif ($packed) { Write-Host $packed }
        }
    }

    # Optional: onefile build for this app (self-contained single exe)
    if ($Onefile) {
        $oneStart = Get-Date
        Write-Host "Building onefile: ${appName}_onefile.exe ..."
        $ofPayload = Join-Path $work 'onefile'
        $ofApp     = Join-Path $ofPayload "payload_$appName"
        if (Test-Path $ofApp) { Remove-Item -Recurse -Force $ofApp }
        New-Item -ItemType Directory -Force -Path $ofApp | Out-Null

        # Fresh runtime for the onefile (independent of shared dist).
        Build-RuntimePart (Join-Path $ofApp 'runtime') $appDeps
        Copy-App $appSrc (Join-Path $ofApp "runtime\apps\$appName")
        if ($Upx -and $isFirst) {
            Write-Host "Compressing onefile runtime with UPX..."
            $targets = Get-ChildItem (Join-Path $ofApp 'runtime') -Recurse -Include '*.dll', '*.pyd', 'python.exe' -File
$out = & $upxExe --best --lzma $targets.FullName 2>&1
$m = ($out | Select-String '^Packed \d+ files' | Select-Object -First 1)
$packed = if ($m) { $m.ToString() } else { $null }
if ($VerboseUpx) { $out | ForEach-Object { Write-Host $_ } }
elseif ($packed) { Write-Host $packed }
        }

        $ofC = Join-Path $root 'launcher_onefile.c'
        $ofExe = Join-Path $root 'launcher_onefile.exe'
        if (-not (Test-Path $ofExe) -or $resFile -or $NoConsole) {
            Write-Host "Compiling launcher_onefile.c ..."
            Invoke-Compile $ofC $ofExe $resFile $noConDef
        }

        # payload.zip = contents of runtime/
        $zip = Join-Path $ofPayload "${appName}_payload.zip"
        Remove-Item $zip -ErrorAction SilentlyContinue
        Compress-Archive -Path (Join-Path (Join-Path $ofApp 'runtime') '*') -DestinationPath $zip -CompressionLevel Optimal

        # Concatenate: launcher + zip + footer(21)
        $oneOut = Join-Path $dist "${appName}_onefile.exe"
        $exeBytes = [IO.File]::ReadAllBytes($ofExe)
        $zipBytes = [IO.File]::ReadAllBytes($zip)
        $fs = [IO.File]::Open($oneOut, [IO.FileMode]::Create, [IO.FileAccess]::Write)
        $bw = [IO.BinaryWriter]::new($fs)
        try {
            $bw.Write($exeBytes)
            $bw.Write($zipBytes)
            $bw.Write([Text.ASCIIEncoding]::ASCII.GetBytes('MINI1FEXE'))
            $bw.Write([byte[]]@(0, 0, 0, 0))                    # reserved (4 bytes)
            $bw.Write([int64]$zipBytes.Length)                  # payload size (8 bytes LE)
        } finally {
            $bw.Dispose()   # closes $fs too
        }
        $ofMb = [math]::Round((Get-Item $oneOut).Length / 1MB, 2)
        $oneSpan = [math]::Round(((Get-Date) - $oneStart).TotalSeconds, 1)
        Write-Host "onefile: ${appName}_onefile.exe  ${ofMb} MB  (${oneSpan}s)"
    }

    $appMb   = [math]::Round((Get-ChildItem $dist -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 2)
    $appSpan = [math]::Round(((Get-Date) - $appStart).TotalSeconds, 2)
    $builtList += [pscustomobject]@{
        AppName = $appName
        Mb      = $appMb
        Span    = $appSpan
        Modes   = (@(
            if ($Windowed) { 'Windowed' }
            if ($NoConsole) { 'NoConsole' }
            if ($Upx) { 'Upx' }
            if ($NoSSL) { 'NoSSL' }
            if ($TrimPython) { 'TrimPython' }
            if ($SkipRuntime -or $i -gt 0) { 'SkipRuntime' }
            if ($Onefile) { 'Onefile' }
        ) -join ' ')
    }
    Write-Host "done: $targetExe  (${appMb} MB, ${appSpan} s)"
}

$totalMb = [math]::Round((Get-ChildItem $dist -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 2)
$elapsed = (Get-Date) - $buildStart
$files   = (Get-ChildItem $dist -Recurse -File).Count

# Auto build number (shown in report + log). -BuildNo given, else log rows +1.
$logCsv = Join-Path $releases 'build_log.csv'
if ($BuildNo -lt 1) {
    if (-not (Test-Path $logCsv)) { $BuildNo = 1 } else {
        $BuildNo = (Get-Content $logCsv | Where-Object { $_ -and $_ -notmatch '^datetime;' }).Count + 1
    }
}

# --------------------------------------------------------------------------
# Final report (English) -----------------------------------------------------
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "=== BUILD REPORT ==="
Write-Host ("Build       : #{0}" -f $BuildNo)
Write-Host ("Version     : v{0}" -f $Version)
Write-Host ("Apps        : {0}" -f ($appNames -join ', '))
Write-Host ("Files       : {0}" -f $files)
Write-Host ("Size        : {0} MB total (first app runtime)" -f $totalMb)
Write-Host ("Duration    : {0} s" -f [math]::Round($elapsed.TotalSeconds, 2))
foreach ($b in $builtList) {
    Write-Host ("  {0,-16} {1,8:N2} MB   {2,6:N2} s   {3}" -f $b.AppName, $b.Mb, $b.Span, $b.Modes)
}
Write-Host "Largest 5 items:"
Get-ChildItem $dist -Recurse -File | Sort-Object Length -Descending | Select-Object -First 5 |
    ForEach-Object { Write-Host ("  {0,8:N2} MB  {1}" -f ($_.Length / 1MB), $_.FullName.Substring($dist.Length + 1)) }
Write-Host ""
Write-Host "BUILD OK: $totalMb MB total"

# --------------------------------------------------------------------------
# Optional: checksums for dist files -----------------------------------------
# --------------------------------------------------------------------------
if ($Checksum) {
    $chkDir = $dist
    $md5File  = Join-Path $chkDir 'checksums.md5'
    $shaFile  = Join-Path $chkDir 'checksums.sha256'
    $md5Lines  = @()
    $shaLines  = @()
    Get-ChildItem $chkDir -Recurse -File | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($chkDir.Length + 1)
        $md5Lines  += ('{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm MD5).Hash, $rel)
        $shaLines  += ('{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $rel)
    }
    $md5Lines  | Set-Content -Path $md5File -Encoding UTF8
    $shaLines  | Set-Content -Path $shaFile -Encoding UTF8
    Write-Host "Checksums written ($($md5Lines.Count) files) -> checksums.md5 / checksums.sha256"
}

# --------------------------------------------------------------------------
# Persist: build_log.csv (version history) ----------------------------------
# --------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $releases | Out-Null
$logCsv = Join-Path $releases 'build_log.csv'
$dateFmt = Get-Date -Format "yyyy-MM-dd HH:mm"
$logLine = '{0};{1};{2};v{3};{4};{5};{6}' -f $dateFmt, $BuildNo, ($appNames -join '+'), $Version,
           [math]::Round($totalMb, 2), [math]::Round($elapsed.TotalSeconds, 2),
           ($builtList[0].Modes -replace ',', ' ')
$header = 'datetime;build;apps;version;size_mb;duration_s;modes'
if (-not (Test-Path $logCsv)) {
    Set-Content -Path $logCsv -Value $header -Encoding UTF8
}
Add-Content -Path $logCsv -Value $logLine -Encoding UTF8
Write-Host "Logged build #$BuildNo -> $logCsv"

# --------------------------------------------------------------------------
# Optional: archive the finished dist ----------------------------------------
# --------------------------------------------------------------------------
if ($Archive) {
    $archDir = Join-Path $releases "v$Version"
    New-Item -ItemType Directory -Force -Path $archDir | Out-Null
    $archZip = Join-Path $archDir 'dist.zip'
    Remove-Item $archZip -ErrorAction SilentlyContinue
    Write-Host "Archiving dist -> $archZip"
    Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $archZip -CompressionLevel Optimal
    Write-Host "Archived: $([math]::Round((Get-Item $archZip).Length / 1MB, 2)) MB"
}

Write-Host "Tip: keep a safe copy of this build under  .\surum_al.ps1 -Etiket v$Version"