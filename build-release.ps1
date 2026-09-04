#requires -Version 5.1

param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
$appDirectory = Join-Path $PSScriptRoot 'app'
$versionPath = Join-Path $appDirectory 'version.json'
$resolvedRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')

if ([IO.Path]::GetDirectoryName($resolvedOutput) -ne $resolvedRoot -or [IO.Path]::GetFileName($resolvedOutput) -ne 'dist') {
    throw 'O diretório de saída precisa ser a pasta dist deste repositório.'
}
if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    throw 'app/version.json não foi encontrado.'
}

$version = [string](([IO.File]::ReadAllText($versionPath, [Text.Encoding]::UTF8) | ConvertFrom-Json).version)
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw 'A versão precisa seguir o formato X.Y.Z.'
}

$scriptPath = Join-Path $appDirectory 'fast-race-assistant.ps1'
$scriptText = [IO.File]::ReadAllText($scriptPath, [Text.Encoding]::UTF8)
$expectedVersion = '$script:AppVersion = ''' + $version + ''''
if (-not $scriptText.Contains($expectedVersion)) {
    throw 'A versão interna do aplicativo não corresponde ao version.json.'
}

$guide = [IO.File]::ReadAllText((Join-Path $appDirectory 'LEIA-ME.txt'), [Text.Encoding]::UTF8)
if (-not $guide.StartsWith("FAST Race Assistant $version")) {
    throw 'A versão do LEIA-ME.txt não corresponde ao version.json.'
}

if (Test-Path -LiteralPath $resolvedOutput) {
    Remove-Item -LiteralPath $resolvedOutput -Recurse -Force
}
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null

$stage = Join-Path $resolvedOutput 'package'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    $utf8WithBom = New-Object Text.UTF8Encoding $true
    Get-ChildItem -LiteralPath $appDirectory -File | ForEach-Object {
        $destination = Join-Path $stage $_.Name
        if ($_.Name -eq 'fast-race-assistant.ps1') {
            $content = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
            [IO.File]::WriteAllText($destination, $content, $utf8WithBom)
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
        }
    }

    $zipPath = Join-Path $resolvedOutput 'fast-race-assistant.zip'
    $packageFiles = Get-ChildItem -LiteralPath $stage -File | Select-Object -ExpandProperty FullName
    if ($packageFiles.Count -lt 7) {
        throw 'O pacote está incompleto.'
    }
    Compress-Archive -LiteralPath $packageFiles -DestinationPath $zipPath -CompressionLevel Optimal -Force
} finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = [ordered]@{
    name = 'FAST Race Assistant'
    version = $version
    url = 'https://github.com/aledsst-ai/fast-race-assistant/releases/latest/download/fast-race-assistant.zip'
    sha256 = $hash
    publishedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    author = 'Fael Verstappen'
}
$utf8NoBom = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText(
    (Join-Path $resolvedOutput 'fast-race-assistant-latest.json'),
    ($manifest | ConvertTo-Json -Compress),
    $utf8NoBom
)
[IO.File]::WriteAllText(
    (Join-Path $resolvedOutput 'SHA256SUMS.txt'),
    "$hash  fast-race-assistant.zip`r`n",
    $utf8NoBom
)

Write-Host "FAST Race Assistant $version empacotado e validado."
