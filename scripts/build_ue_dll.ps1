# CoACD - Build UE-friendly DLL (lib_coacd.dll) - Full mode only
# Usage examples:
#   # Full (with OpenVDB et al. statically linked), using vcpkg static-md toolchain
#   # powershell -ExecutionPolicy Bypass -File scripts/build_ue_dll.ps1 `
#   #   -VcpkgToolchain "C:\\vcpkg\\scripts\\buildsystems\\vcpkg.cmake" `
#   #   -Triplet x64-windows-static-md
#
#   # Build and copy to your UE plugin folder
#   # powershell -ExecutionPolicy Bypass -File scripts/build_ue_dll.ps1 `
#   #   -VcpkgToolchain "C:\\vcpkg\\scripts\\buildsystems\\vcpkg.cmake" `
#   #   -Triplet x64-windows-static-md -PluginDir "E:\\UE_Plugins\\CoACD"

param(
  [ValidateSet('Full')]
  [string]$Mode = 'Full',

  [string]$VcpkgToolchain = '',

  [string]$Triplet = 'x64-windows-static-md',

  [string]$Generator = 'Visual Studio 17 2022',

  [string]$Arch = 'x64',

  [ValidateSet('Debug','Release')]
  [string]$BuildType = 'Release',

  # 默认启用并行（OpenMP）。如需关闭，传 -DisableOpenMP
  [switch]$DisableOpenMP,

  [switch]$Clean,

  [string]$OutDir = '',

  # Optional: UE plugin root directory (containing .uplugin)
  [string]$PluginDir = '',

  # Skip installing deps with vcpkg (by default we install minimal feature set)
  [switch]$NoInstallDeps
)

$ErrorActionPreference = 'Stop'

function Invoke-CMake {
  param([string[]]$ArgumentList, [string]$WorkingDirectory)
  # Sanitize arguments (remove null/empty)
  $argList = @()
  foreach ($a in $ArgumentList) {
    if ($null -ne $a) {
      $s = [string]$a
      if (-not [string]::IsNullOrWhiteSpace($s)) { $argList += $s }
    }
  }
  if ($argList.Count -eq 0) { throw "Internal error: empty argument list for cmake" }
  # Quote args containing spaces or special chars to prevent splitting
  function Quote($t) {
    if ($t -match '[\s\"]') { return '"' + ($t -replace '"','\"') + '"' } else { return $t }
  }
  $argLine = ($argList | ForEach-Object { Quote $_ }) -join ' '
  Write-Host "[cmake] $argLine" -ForegroundColor Cyan
  $p = Start-Process -FilePath cmake -ArgumentList $argLine -WorkingDirectory $WorkingDirectory -NoNewWindow -PassThru -Wait
  if ($p.ExitCode -ne 0) { throw "cmake failed with exit code $($p.ExitCode)" }
}

function Ensure-Dir {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -ItemType Directory -Path $Path) }
}

function Invoke-Exe {
  param([string]$Exe, [string[]]$ArgumentList, [string]$WorkingDirectory)
  # Quote
  function Q($t) { if ($t -match '[\s\"]') { return '"' + ($t -replace '"','\"') + '"' } else { return $t } }
  $argLine = ($ArgumentList | ForEach-Object { Q $_ }) -join ' '
  Write-Host "[$Exe] $argLine" -ForegroundColor DarkCyan
  $p = Start-Process -FilePath $Exe -ArgumentList $argLine -WorkingDirectory $WorkingDirectory -NoNewWindow -PassThru -Wait
  if ($p.ExitCode -ne 0) { throw "$Exe failed with exit code $($p.ExitCode)" }
}

# Resolve repo root from this script path
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Write-Host "RepoRoot: $RepoRoot" -ForegroundColor Yellow

if ($Clean) {
  $BuildDir = Join-Path $RepoRoot ("build-ue-full")
  if (Test-Path -LiteralPath $BuildDir) {
    Write-Host "Cleaning $BuildDir" -ForegroundColor DarkYellow
    Remove-Item -LiteralPath $BuildDir -Recurse -Force
  }
}

# Build directory (full only)
$BuildDir = Join-Path $RepoRoot ("build-ue-full")
Ensure-Dir $BuildDir

# Default output directory
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  # By default drop the dll next to this script (user requested)
  $OutDir = $PSScriptRoot
}
Ensure-Dir $OutDir

# Basic checks
try { cmake --version | Out-Null } catch { throw "CMake not found in PATH." }

# Resolve vcpkg toolchain if not provided
if ([string]::IsNullOrWhiteSpace($VcpkgToolchain)) {
  if ($env:VCPKG_ROOT) {
    $Candidate = Join-Path $env:VCPKG_ROOT 'scripts/buildsystems/vcpkg.cmake'
    if (Test-Path -LiteralPath $Candidate) { $VcpkgToolchain = $Candidate }
  }
}
if ([string]::IsNullOrWhiteSpace($VcpkgToolchain)) {
  throw "Full mode requires -VcpkgToolchain path to vcpkg.cmake (or set VCPKG_ROOT)"
}
if (-not (Test-Path -LiteralPath $VcpkgToolchain)) {
  throw "Toolchain not found: $VcpkgToolchain"
}

# Optionally install minimal deps with vcpkg (OpenVDB core only: no Blosc/OpenEXR)
if (-not $NoInstallDeps) {
  $VcpkgExe = ''
  if ($env:VCPKG_ROOT) {
    $cand = Join-Path $env:VCPKG_ROOT 'vcpkg.exe'
    if (Test-Path -LiteralPath $cand) { $VcpkgExe = $cand }
  }
  if ([string]::IsNullOrWhiteSpace($VcpkgExe)) { $VcpkgExe = 'vcpkg' }

  $Pkgs = @(
    "openvdb[core]",
    "tbb",
    "zlib",
    "imath",
    "spdlog"
  )

  foreach ($pkg in $Pkgs) {
    Invoke-Exe -Exe $VcpkgExe -ArgumentList @('install', ("$pkg:" + $Triplet), '--recurse') -WorkingDirectory ([string]$RepoRoot)
  }
}

# Configure CMake
$CommonArgs = @(
  '-G', $Generator,
  '-A', $Arch,
  ("-DCMAKE_BUILD_TYPE=" + $BuildType),
  '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL',
  '-DBUILD_SHARED_LIBS=OFF',
  '-DOPENVDB_CORE_SHARED=OFF',
  # Try to further slim OpenVDB usage (ignored if not applicable in consumer build)
  '-DOPENVDB_USE_BLOSC=OFF',
  '-DOPENVDB_BUILD_TOOLS=OFF',
  '-DOPENVDB_BUILD_UNITTESTS=OFF',
  '-DOPENVDB_BUILD_PYTHON_BINDINGS=OFF',
  '-DOPENVDB_BUILD_DOCS=OFF'
)

if ($BuildType -eq 'Release') {
  $CommonArgs += '-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON'
  # 最小化体积：开启 LTO、函数分区与链接裁剪
  $CommonArgs += '-DCMAKE_CXX_FLAGS_RELEASE=/O2 /GL /Gy'
  $CommonArgs += '-DCMAKE_SHARED_LINKER_FLAGS_RELEASE=/LTCG /OPT:REF /OPT:ICF'
  $CommonArgs += '-DCMAKE_EXE_LINKER_FLAGS_RELEASE=/LTCG /OPT:REF /OPT:ICF'
}

if ($DisableOpenMP) {
  $CommonArgs += '-DCMAKE_DISABLE_FIND_PACKAGE_OpenMP=ON'
}

$ModeArgs = @(
  '-DWITH_3RD_PARTY_LIBS=ON',
  ("-DCMAKE_TOOLCHAIN_FILE=" + $VcpkgToolchain),
  ("-DVCPKG_TARGET_TRIPLET=" + $Triplet)
)


# Configure using -S/-B to avoid relative path ambiguity
$CfgArgs = @('-S', [string]$RepoRoot, '-B', [string]$BuildDir) + $CommonArgs + $ModeArgs
Invoke-CMake -ArgumentList $CfgArgs -WorkingDirectory ([string]$RepoRoot)

# Build _coacd target (produces lib_coacd.dll on Windows)
$BuildArgs = @('--build', [string]$BuildDir, '--target', '_coacd', '--config', $BuildType)
Invoke-CMake -ArgumentList $BuildArgs -WorkingDirectory ([string]$RepoRoot)

# Locate the produced DLL
$Candidate = Join-Path $BuildDir (Join-Path $BuildType 'lib_coacd.dll')
if (-not (Test-Path -LiteralPath $Candidate)) {
  $Found = Get-ChildItem -LiteralPath $BuildDir -Recurse -Filter 'lib_coacd.dll' | Select-Object -First 1
  if ($Found) { $Candidate = $Found.FullName }
}

if (-not (Test-Path -LiteralPath $Candidate)) {
  throw "Build succeeded but lib_coacd.dll not found."
}

Write-Host "Found: $Candidate" -ForegroundColor Green

# Copy to output dir
$Dest = Join-Path $OutDir 'lib_coacd.dll'
Copy-Item -LiteralPath $Candidate -Destination $Dest -Force
Write-Host "Copied to: $Dest" -ForegroundColor Green

# Optional: copy to UE plugin folder
if (-not [string]::IsNullOrWhiteSpace($PluginDir)) {
  $PluginDllDir = Join-Path $PluginDir 'ThirdParty/CoACD/DLL'
  Ensure-Dir $PluginDllDir
  $PluginDllPath = Join-Path $PluginDllDir 'lib_coacd.dll'
  Copy-Item -LiteralPath $Candidate -Destination $PluginDllPath -Force
  Write-Host "Copied to Plugin: $PluginDllPath" -ForegroundColor Green
}

Write-Host "Done." -ForegroundColor Yellow


