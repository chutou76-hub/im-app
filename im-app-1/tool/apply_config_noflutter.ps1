# Apply app config WITHOUT Flutter/Dart - Windows PowerShell only.
# Mirrors tool/apply_config.dart (text parts only): name / package /
# iOS package / version / api endpoints. Icon & splash generation are
# NOT possible here (needs flutter_launcher_icons) - they run in the
# cloud via codemagic.yaml (dart run tool/apply_config.dart) or locally
# with build_app.bat.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tool\apply_config_noflutter.ps1
#        (cwd must be the im-app folder)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Read-Text([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  return [System.IO.File]::ReadAllText((Resolve-Path $path))
}

function Write-Text([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText((Join-Path (Get-Location).Path $path), $text, $utf8)
}

# First-occurrence regex replace. Returns 1 if changed, 0 if not/missing.
function Replace-Once([string]$path, [string]$pattern, [string]$replacement, [string]$label) {
  $src = Read-Text $path
  if ($null -eq $src) { Write-Host "  [SKIP] file not found: $path ($label)"; return 0 }
  $rx = [regex]$pattern
  $out = $rx.Replace($src, $replacement, 1)
  if ($out -ceq $src) { Write-Host "  [ok] unchanged: $label"; return 0 }
  Write-Text $path $out
  Write-Host "  [DONE] $label"
  return 1
}

if (-not (Test-Path 'config\app_build.json')) {
  Write-Host "ERROR: config\app_build.json not found (run from im-app folder)."
  exit 1
}
$cfg = Get-Content 'config\app_build.json' -Raw -Encoding UTF8 | ConvertFrom-Json

$appName = [string]$cfg.appName
$pkg     = [string]$cfg.packageName
$iosPkg  = [string]$cfg.iosPackageName
if (-not $iosPkg.Trim()) { $iosPkg = $pkg }
$verName = [string]$cfg.versionName
$verCode = [string]$cfg.versionCode
$apiBase = [string]$cfg.apiBase
$wsBase  = [string]$cfg.wsBase
$jpush   = [string]$cfg.jpushAppKey

Write-Host "config/app_build.json:"
Write-Host "  appName   : $appName"
Write-Host "  package   : $pkg"
if ($iosPkg -ne $pkg) { Write-Host "  iOS pkg   : $iosPkg" }
Write-Host "  version   : $verName (code $verCode)"
Write-Host "  apiBase   : $apiBase"
Write-Host "  wsBase    : $wsBase"
Write-Host ""

$changed = 0

# ---------- 1) app name -> AndroidManifest + iOS Info.plist ----------
if ($appName) {
  $changed += Replace-Once 'android/app/src/main/AndroidManifest.xml' `
    'android:label="[^"]*"' ("android:label=`"$appName`"") 'app name -> AndroidManifest'

  $plist = 'ios/Runner/Info.plist'
  $changed += Replace-Once $plist `
    '<key>CFBundleDisplayName</key>\s*<string>[^<]*</string>' `
    ("<key>CFBundleDisplayName</key>`n`t`t<string>$appName</string>") `
    'app name -> Info.plist CFBundleDisplayName'
  $changed += Replace-Once $plist `
    '<key>CFBundleName</key>\s*<string>[^<]*</string>' `
    ("<key>CFBundleName</key>`n`t`t<string>$appName</string>") `
    'app name -> Info.plist CFBundleName'
}

# ---------- 2) Android package -> gradle + Kotlin source migration ----------
$gradle = 'android/app/build.gradle.kts'
if (-not (Test-Path $gradle)) { $gradle = 'android/app/build.gradle' }
$gradleSrc = Read-Text $gradle
$oldPkg = $null
if ($null -ne $gradleSrc) {
  $m = [regex]::Match($gradleSrc, 'namespace\s*=\s*"([^"]*)"')
  if ($m.Success) { $oldPkg = $m.Groups[1].Value }
}

$kroot = Join-Path (Get-Location) 'android/app/src/main/kotlin'

function Move-KotlinSources([string]$fromPkg, [string]$toPkg) {
  $oldDir = Join-Path $kroot ($fromPkg.Replace('.', '\'))
  $newDir = Join-Path $kroot ($toPkg.Replace('.', '\'))
  if (Test-Path $oldDir) {
    New-Item -ItemType Directory -Force $newDir | Out-Null
    $count = 0
    $oldDirFull = (Resolve-Path $oldDir).Path
    Get-ChildItem $oldDirFull -Recurse -File | ForEach-Object {
      $rel = $_.FullName.Substring($oldDirFull.Length + 1)
      $text = [System.IO.File]::ReadAllText($_.FullName)
      if ($rel.EndsWith('.kt')) {
        $text = [regex]::Replace($text, "(?m)^package\s+$([regex]::Escape($fromPkg))\s*$", "package $toPkg")
      }
      $target = Join-Path $newDir $rel
      New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
      [System.IO.File]::WriteAllText($target, $text, $utf8)
      Remove-Item $_.FullName -Force
      $count++
    }
    # climb up deleting now-empty dirs (stop at kotlin root)
    $d = Get-Item $oldDirFull
    while (($d.FullName -ne $kroot) -and ((Get-ChildItem $d.FullName).Count -eq 0)) {
      $parent = Split-Path $d.FullName
      Remove-Item $d.FullName -Force
      $d = Get-Item $parent
    }
    Write-Host "  [DONE] Kotlin sources moved: $fromPkg -> $toPkg ($count files)"
  }
}

if ($pkg -and $oldPkg -and ($oldPkg -ne $pkg)) {
  Move-KotlinSources $oldPkg $pkg
}
if ($pkg) {
  $changed += Replace-Once $gradle 'applicationId\s*=\s*"[^"]*"' ("applicationId = `"$pkg`"") 'package -> applicationId'
  $changed += Replace-Once $gradle 'namespace\s*=\s*"[^"]*"' ("namespace = `"$pkg`"") 'package -> namespace'
  # safety net: make sure kotlin/<pkg>/MainActivity.kt declares the right package
  $mainKt = Join-Path $kroot ($pkg.Replace('.', '\') + '\MainActivity.kt')
  if (Test-Path $mainKt) {
    $src = [System.IO.File]::ReadAllText($mainKt)
    if (-not $src.StartsWith("package $pkg")) {
      $out = [regex]::Replace($src, '(?m)^package\s+[\w.]+', "package $pkg")
      [System.IO.File]::WriteAllText($mainKt, $out, $utf8)
      Write-Host "  [DONE] MainActivity.kt package -> $pkg"
      $changed++
    }
  } else {
    Write-Host "  [WARN] MainActivity.kt not found under kotlin/$($pkg.Replace('.', '/'))/"
    Write-Host "         create it with first line: package $pkg  (or the APK will crash on start)"
  }
}

# ---------- 2.5) iOS package -> project.pbxproj (all occurrences) ----------
if ($iosPkg) {
  $pbx = 'ios/Runner.xcodeproj/project.pbxproj'
  $src = Read-Text $pbx
  if ($null -eq $src) {
    Write-Host "  [SKIP] file not found: $pbx"
  } else {
    $eval = [System.Text.RegularExpressions.MatchEvaluator]{
      param($m)
      $sfx = ''
      if ($m.Groups[1].Value.EndsWith('.RunnerTests')) { $sfx = '.RunnerTests' }
      return 'PRODUCT_BUNDLE_IDENTIFIER = "' + $iosPkg + $sfx + '";'
    }
    $out = [regex]::Replace($src, 'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([^";]+)"?\s*;', $eval)
    if ($out -cne $src) {
      Write-Text $pbx $out
      Write-Host "  [DONE] iOS package -> $pbx ($iosPkg)"
      $changed++
    } else {
      Write-Host "  [ok] unchanged: iOS package (already $iosPkg)"
    }
  }
}

# ---------- 3) version -> pubspec.yaml + update_service ----------
if ($verName) {
  $changed += Replace-Once 'pubspec.yaml' '(?m)^version:\s*\S+' ("version: $verName+$verCode") 'version -> pubspec'
  $changed += Replace-Once 'lib/services/update_service.dart' `
    "static const currentVersion = '[^']*';" `
    "static const currentVersion = '$verName';" `
    'version -> update_service (update check baseline)'
}

# ---------- 4) api endpoints -> runtime config ----------
# build the JSON manually with a FIXED key order, byte-identical to what
# tool/apply_config.dart writes (ConvertTo-Json would reorder keys and
# create a pointless git diff every run)
$rtPath = 'assets/config/app_config.json'
$rtJson = '{"apiBase":"' + $apiBase + '","wsBase":"' + $wsBase + '"}'
if ($jpush) { $rtJson = '{"apiBase":"' + $apiBase + '","wsBase":"' + $wsBase + '","jpushAppKey":"' + $jpush + '"}' }
$old = Read-Text $rtPath
if ($null -eq $old) {
  New-Item -ItemType Directory -Force (Split-Path (Join-Path (Get-Location) $rtPath)) | Out-Null
}
if ($old -ne $rtJson) {
  Write-Text $rtPath "$rtJson`n"
  Write-Host "  [DONE] api endpoints -> $rtPath"
  $changed++
} else {
  Write-Host "  [ok] unchanged: api endpoints"
}

Write-Host ''
if ($changed -gt 0) {
  Write-Host "OK - $changed file(s) updated. No APK/IPA built."
} else {
  Write-Host 'OK - config already up to date.'
}
Write-Host ''
Write-Host 'Reminders:'
Write-Host ' - icons/splash are NOT generated here (needs Flutter). They are'
Write-Host '   auto-generated in the cloud: codemagic.yaml runs'
Write-Host '   "dart run tool/apply_config.dart". To change the icon, replace'
Write-Host '   assets\icon\app_icon.png (and splash_logo.png) and push.'
Write-Host ' - changed packageName? JPush AppKey is bound to it (recreate app in'
Write-Host '   JPush console). Old installs cannot upgrade over it.'
Write-Host ' - changed iosPackageName? sync codemagic.yaml bundle_identifier and'
Write-Host '   regenerate the Apple provisioning profile.'
exit 0
