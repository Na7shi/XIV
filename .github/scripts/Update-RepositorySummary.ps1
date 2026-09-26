<#
.SYNOPSIS
    複数のDalamudリポジトリを取得し、配布先を区別したまとめJSONを生成する。

.DESCRIPTION
    同じInternalNameでも配布元が違うエントリを1件にまとめず、すべて保持する。
    元の配布zip・manifestは変更せず、取得元のDownloadLinkをそのまま使用する。
    同じInternalNameはDalamud上では同一識別子になるため、重複は差分検知用に保持する。
    前回のJSONが指定された場合は、追加・更新・削除を
    repository-summary-changes.json に出力する。

.PARAMETER SourcesPath
    取得先一覧。既定値は repository-sources.json。

.PARAMETER OutputPath
    まとめJSONの出力先。既定値は repository-summary.json。

.PARAMETER PreviousPath
    前回のまとめJSON。指定時は差分検知を行う。

.PARAMETER ChangesPath
    差分JSONの出力先。既定値は repository-summary-changes.json。

.PARAMETER ExclusionsPath
    集約リポジトリから除外するInternalName一覧。既定値は
    repository-summary-exclusions.json。

.PARAMETER ForkSourcesPath
    フォーク・派生配布として別JSONへ出す取得先一覧。既定値は
    repository-summary-fork-sources.json。

.PARAMETER ForkOutputPath
    フォーク・派生配布側のまとめJSON。空欄の場合は従来どおり全件を
    OutputPathへ出力する。

.PARAMETER ForkPreviousPath
    フォーク側の前回JSON。指定時はフォーク側の差分検知を行う。

.PARAMETER ForkChangesPath
    フォーク側の差分JSON。
#>
[CmdletBinding()]
param(
    [string]$SourcesPath = '.github/config/repository-sources.json',
    [string]$OutputPath = 'repository-summary.json',
    [string]$PreviousPath = '',
    [string]$ChangesPath = 'repository-summary-changes.json',
    [string]$ExclusionsPath = '.github/config/repository-summary-exclusions.json',
    [string]$ForkSourcesPath = '.github/config/repository-summary-fork-sources.json',
    [string]$ForkOutputPath = '',
    [string]$ForkPreviousPath = '',
    [string]$ForkChangesPath = 'repository-summary-forks-changes.json',
    [int]$RetryCount = 3
)

$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDirectory)
Set-Location $repoRoot

if (-not (Test-Path -LiteralPath $SourcesPath)) {
    throw "取得先一覧が見つかりません: $SourcesPath"
}

function Get-StringValue([object]$Object, [string]$PropertyName) {
    if ($null -eq $Object) { return '' }
    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return "$($property.Value)".Trim()
}

$forkSourceIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($ForkOutputPath) {
    if (-not (Test-Path -LiteralPath $ForkSourcesPath)) {
        throw "フォーク側取得先一覧が見つかりません: $ForkSourcesPath"
    }
    $forkSourcesDocument = Get-Content -LiteralPath $ForkSourcesPath -Raw | ConvertFrom-Json
    foreach ($forkSource in @($forkSourcesDocument)) {
        $forkSourceId = Get-StringValue $forkSource 'Id'
        if ($forkSourceId) { [void]$forkSourceIds.Add($forkSourceId) }
    }
    if ($forkSourceIds.Count -eq 0) {
        throw "フォーク側取得先が1件も設定されていません: $ForkSourcesPath"
    }
}

$exclusions = @()
if (Test-Path -LiteralPath $ExclusionsPath) {
    $exclusionsDocument = Get-Content -LiteralPath $ExclusionsPath -Raw | ConvertFrom-Json
    $exclusions = @($exclusionsDocument)
}
$excludedInternalNames = @($exclusions | ForEach-Object { Get-StringValue $_ 'InternalName' } | Where-Object { $_ })

function Get-PluginEntries([object]$Document) {
    if ($null -eq $Document) { return @() }

    if ($Document -is [System.Array]) {
        return @($Document)
    }

    foreach ($propertyName in @('Plugins', 'plugins', 'Entries', 'entries', 'Manifests', 'manifests')) {
        $property = $Document.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value) {
            return @($property.Value)
        }
    }

    if ($Document.PSObject.Properties['InternalName']) {
        return @($Document)
    }

    return @()
}

function Get-CanonicalSourceUrl([string]$Url) {
    # GitHubの2つのraw URL表記は同じ配布先を指すため、同一フィードに正規化する。
    # それ以外のホスト・パスは、別の配布先としてそのまま扱う。
    try {
        $uri = [Uri]$Url
        $path = $uri.AbsolutePath.Trim('/')
        if ($uri.Host -ieq 'github.com' -and $path -match '^([^/]+)/([^/]+)/raw/(.+)$') {
            return "https://raw.githubusercontent.com/$($Matches[1])/$($Matches[2])/$($Matches[3])"
        }
    } catch {
        # URLの妥当性はInvoke-WebRequest側でも検証されるため、ここでは元の値を使う。
    }
    return $Url
}

function Get-SourceLabel([string]$Url, [string]$FallbackName) {
    try {
        $uri = [Uri]$Url
        $segments = @($uri.AbsolutePath.Trim('/') -split '/' | Where-Object { $_ })
        if (($uri.Host -ieq 'raw.githubusercontent.com' -or $uri.Host -ieq 'github.com') -and $segments.Count -ge 2) {
            return "GitHub: $($segments[0])/$($segments[1])"
        }
    } catch {
        # URLの妥当性はInvoke-WebRequest側でも検証されるため、フォールバックを使う。
    }
    if ($FallbackName) { return "Source: $FallbackName" }
    return "Source: $Url"
}

function Get-SourceDocument([string]$Url, [int]$Attempts) {
    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 45 -Headers @{
                'User-Agent' = 'Dalamud-WorkSpace-RepositorySummary/1.0'
            }
            if ([string]::IsNullOrWhiteSpace($response.Content)) {
                throw "レスポンスが空です"
            }
            return ($response.Content | ConvertFrom-Json)
        } catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt $Attempts) {
                Start-Sleep -Seconds ([Math]::Min(5, $attempt * 2))
            }
        }
    }
    throw "取得に失敗しました: $Url`n$lastError"
}

function Test-AbsoluteHttpUrl([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $uri = $null
    if (-not [Uri]::TryCreate($Value.Trim(), [UriKind]::Absolute, [ref]$uri)) { return $false }
    return $uri.Scheme -in @('http', 'https')
}

function Get-EntryKey([object]$Entry, [string]$SourceUrl) {
    $internalName = Get-StringValue $Entry 'InternalName'
    $install = Get-StringValue $Entry 'DownloadLinkInstall'
    $update = Get-StringValue $Entry 'DownloadLinkUpdate'
    $testing = Get-StringValue $Entry 'DownloadLinkTesting'
    $repoUrl = Get-StringValue $Entry 'RepoUrl'
    $apiLevel = Get-StringValue $Entry 'DalamudApiLevel'
    $applicable = Get-StringValue $Entry 'ApplicableVersion'

    # AssemblyVersion/LastUpdateは版更新のたびに変わるため、安定キーに含めない。
    # 同名でも配布リンクが違う場合は別物として扱う。
    $identity = @(
        $SourceUrl,
        $internalName,
        $install,
        $update,
        $testing,
        $repoUrl,
        $apiLevel,
        $applicable
    ) -join "`n"

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($identity)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function ConvertTo-ComparableJson([object]$Value) {
    if ($null -eq $Value) { return '' }
    $copy = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -eq 'DownloadCount') { continue }
        $copy[$property.Name] = $property.Value
    }
    return ([pscustomobject]$copy | ConvertTo-Json -Depth 30 -Compress)
}

$configuredSources = @(Get-Content -LiteralPath $SourcesPath -Raw | ConvertFrom-Json)
if ($configuredSources.Count -eq 0) {
    throw '取得先が1件も設定されていません。'
}

$sources = @()
$seenUrls = @{}
foreach ($source in $configuredSources) {
    $sourceId = Get-StringValue $source 'Id'
    $sourceName = Get-StringValue $source 'Name'
    $sourceUrl = Get-StringValue $source 'Url'
    if (-not $sourceUrl) { throw '取得先に Url がありません。' }
    if (-not $sourceId) { $sourceId = $sourceUrl }
    $canonicalUrl = Get-CanonicalSourceUrl $sourceUrl
    if ($seenUrls.ContainsKey($canonicalUrl)) {
        Write-Warning "同じ配布先を別URLで指定したためスキップします: $sourceUrl -> $canonicalUrl"
        continue
    }
    $seenUrls[$canonicalUrl] = $true
    $isFork = $forkSourceIds.Contains($sourceId)
    $sources += [pscustomobject]@{
        Id = $sourceId
        Name = $(if ($sourceName) { $sourceName } else { $sourceId })
        Url = $canonicalUrl
        Label = Get-SourceLabel $canonicalUrl $(if ($sourceName) { $sourceName } else { $sourceId })
        IsFork = $isFork
    }
}

$allEntries = @()
$invalidDownloadEntries = @()
$sourceStats = @()
foreach ($source in $sources) {
    Write-Host "取得中: $($source.Name) <$($source.Url)>" -ForegroundColor Cyan
    $document = Get-SourceDocument $source.Url $RetryCount
    $entries = @(Get-PluginEntries $document)
    $validCount = 0

    foreach ($entry in $entries) {
        $internalName = Get-StringValue $entry 'InternalName'
        if (-not $internalName) {
            Write-Warning "InternalName の無いエントリをスキップします: $($source.Url)"
            continue
        }

        $installLink = Get-StringValue $entry 'DownloadLinkInstall'
        $updateLink = Get-StringValue $entry 'DownloadLinkUpdate'
        $testingLink = Get-StringValue $entry 'DownloadLinkTesting'
        $downloadLinksValid = (Test-AbsoluteHttpUrl $installLink) -and
            (Test-AbsoluteHttpUrl $updateLink) -and
            (-not $testingLink -or (Test-AbsoluteHttpUrl $testingLink))
        if (-not $downloadLinksValid) {
            # 配布URLが不完全でも入力元のエントリ自体は失わない。テスト専用や
            # 一時的に壊れているエントリを一覧から消すと、次回復旧時の検知や
            # 配布元ごとの比較ができなくなるため、非表示で保持する。
            $invalidDownloadEntries += [pscustomobject]@{
                InternalName = $internalName
                Name = Get-StringValue $entry 'Name'
                SourceId = $source.Id
                Source = $source.Url
                DownloadLinkInstall = $installLink
                DownloadLinkUpdate = $updateLink
                DownloadLinkTesting = $testingLink
            }
        }

        $copy = [ordered]@{}
        foreach ($property in $entry.PSObject.Properties) {
            # アクセス数は取得のたびに変わるため、まとめJSONを不要に更新し続けない。
            if ($property.Name -eq 'DownloadCount') { continue }
            $copy[$property.Name] = $property.Value
        }

        # まとめJSONの一覧上で配布元を見分けられるよう、Authorに配布元を付ける。
        # 元の配布zip・manifestは変更せず、元のDownloadLinkをそのまま使用する。
        $originalAuthor = Get-StringValue $entry 'Author'
        $qualifiedAuthor = if ($originalAuthor) { "$originalAuthor [$($source.Label)]" } else { $source.Label }
        $copy['OriginalAuthor'] = $originalAuthor
        $copy['RepositorySourceLabel'] = $source.Label
        $copy['RepositoryDisplayAuthor'] = $qualifiedAuthor
        $copy['Author'] = $qualifiedAuthor

        # Dalamud標準外の情報だが、同名プラグインを配布元単位で追跡するために付与する。
        $copy['RepositorySource'] = $source.Url
        $copy['RepositorySourceId'] = $source.Id
        $entryKey = Get-EntryKey $entry $source.Url
        $copy['RepositoryEntryKey'] = $entryKey
        $copy['RepositoryOriginalInternalName'] = $internalName
        if (-not $downloadLinksValid) {
            $copy['RepositoryDownloadUrlValid'] = $false
            $copy['IsHide'] = $true
        } else {
            $copy['RepositoryDownloadUrlValid'] = $true
        }

        $allEntries += [pscustomobject]$copy
        $validCount++
    }

    $sourceStats += [pscustomobject]@{
        Id = $source.Id
        Name = $source.Name
        Url = $source.Url
        Count = $validCount
        IsFork = $source.IsFork
    }
    Write-Host "  $validCount 件" -ForegroundColor Gray
}

# プラグイン側で配布元を検証するものは、集約リポジトリから安全に起動できないため除外する。
$rawEntryCount = $allEntries.Count
$excludedEntries = @($allEntries | Where-Object { $_.InternalName -in $excludedInternalNames })
$allEntries = @($allEntries | Where-Object { $_.InternalName -notin $excludedInternalNames })

function Write-SummaryCollection {
    param(
        [object[]]$CollectionEntries,
        [object[]]$CollectionSources,
        [object[]]$CollectionExcludedEntries,
        [object[]]$CollectionInvalidEntries,
        [int]$CollectionRawEntryCount,
        [string]$CollectionName,
        [string]$CollectionOutputPath,
        [string]$CollectionPreviousPath,
        [string]$CollectionChangesPath
    )

    # 元のInternalNameを維持し、外部配布zip・manifestは変更しない。
    # 同名エントリは検知用にすべて保持するが、Dalamud上では同一InternalNameとして扱われる。
    $sortedEntries = @($CollectionEntries | Sort-Object RepositorySourceId, InternalName, RepositoryEntryKey)
    $outputDirectory = Split-Path -Parent $CollectionOutputPath
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $summaryJson = ConvertTo-Json -InputObject ([object[]]$sortedEntries) -Depth 30
    $summaryJson | Set-Content -LiteralPath $CollectionOutputPath -Encoding UTF8

    $added = @()
    $removed = @()
    $updated = @()
    if ($CollectionPreviousPath -and (Test-Path -LiteralPath $CollectionPreviousPath)) {
        $previousEntries = @(Get-Content -LiteralPath $CollectionPreviousPath -Raw | ConvertFrom-Json)
        $previousByKey = @{}
        foreach ($entry in $previousEntries) {
            $key = Get-StringValue $entry 'RepositoryEntryKey'
            if (-not $key) {
                $sourceUrl = Get-StringValue $entry 'RepositorySource'
                if ($sourceUrl) { $key = Get-EntryKey $entry $sourceUrl }
            }
            if ($key) { $previousByKey[$key] = $entry }
        }

        $currentByKey = @{}
        foreach ($entry in $sortedEntries) {
            $key = Get-StringValue $entry 'RepositoryEntryKey'
            $currentByKey[$key] = $entry
            if (-not $previousByKey.ContainsKey($key)) {
                $added += $entry
            } elseif ((ConvertTo-ComparableJson $previousByKey[$key]) -ne (ConvertTo-ComparableJson $entry)) {
                $updated += [pscustomobject]@{
                    RepositoryEntryKey = $key
                    Before = $previousByKey[$key]
                    After = $entry
                }
            }
        }
        foreach ($key in $previousByKey.Keys) {
            if (-not $currentByKey.ContainsKey($key)) {
                $removed += $previousByKey[$key]
            }
        }
    }

    $changes = [ordered]@{
        GeneratedAt = [DateTime]::UtcNow.ToString('o')
        Collection = $CollectionName
        SourceCount = @($CollectionSources).Count
        EntryCount = $sortedEntries.Count
        RawEntryCount = $CollectionRawEntryCount
        InvalidDownloadLinkEntryCount = @($CollectionInvalidEntries).Count
        InvalidDownloadLinkEntries = @($CollectionInvalidEntries)
        ExcludedEntryCount = @($CollectionExcludedEntries).Count
        ExcludedInternalNames = @($excludedInternalNames)
        DuplicateInternalNameCount = @($sortedEntries | Group-Object RepositoryOriginalInternalName | Where-Object Count -gt 1).Count
        Added = @($added)
        Updated = @($updated)
        Removed = @($removed)
        Sources = @($CollectionSources)
    }
    $changesDirectory = Split-Path -Parent $CollectionChangesPath
    if ($changesDirectory -and -not (Test-Path -LiteralPath $changesDirectory)) {
        New-Item -ItemType Directory -Path $changesDirectory -Force | Out-Null
    }
    $changes | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $CollectionChangesPath -Encoding UTF8

    Write-Host "$CollectionName まとめJSONを生成しました: $CollectionOutputPath ($($sortedEntries.Count) 件 / 除外 $(@($CollectionExcludedEntries).Count) 件 / 生データ $CollectionRawEntryCount 件 / $(@($CollectionSources).Count) 取得先)" -ForegroundColor Green
    if ($CollectionPreviousPath) {
        Write-Host "$CollectionName 差分: 追加 $($added.Count) / 更新 $($updated.Count) / 削除 $($removed.Count)" -ForegroundColor Yellow
    }
    return [pscustomobject]@{
        Name = $CollectionName
        OutputPath = $CollectionOutputPath
        ChangesPath = $CollectionChangesPath
        Entries = $sortedEntries.Count
        Added = $added.Count
        Updated = $updated.Count
        Removed = $removed.Count
    }
}

if (-not $ForkOutputPath) {
    Write-SummaryCollection `
        -CollectionEntries $allEntries `
        -CollectionSources $sourceStats `
        -CollectionExcludedEntries $excludedEntries `
        -CollectionInvalidEntries $invalidDownloadEntries `
        -CollectionRawEntryCount $rawEntryCount `
        -CollectionName 'まとめ' `
        -CollectionOutputPath $OutputPath `
        -CollectionPreviousPath $PreviousPath `
        -CollectionChangesPath $ChangesPath | Out-Null
}

if ($ForkOutputPath) {
    $forkEntries = @($allEntries | Where-Object { $forkSourceIds.Contains((Get-StringValue $_ 'RepositorySourceId')) })
    $mainEntries = @($allEntries | Where-Object { -not $forkSourceIds.Contains((Get-StringValue $_ 'RepositorySourceId')) })
    $forkSources = @($sourceStats | Where-Object { $_.IsFork })
    $mainSources = @($sourceStats | Where-Object { -not $_.IsFork })
    $forkExcludedEntries = @($excludedEntries | Where-Object { $forkSourceIds.Contains((Get-StringValue $_ 'RepositorySourceId')) })
    $mainExcludedEntries = @($excludedEntries | Where-Object { -not $forkSourceIds.Contains((Get-StringValue $_ 'RepositorySourceId')) })
    $forkInvalidEntries = @($invalidDownloadEntries | Where-Object { $forkSourceIds.Contains((Get-StringValue $_ 'SourceId')) })
    $mainInvalidEntries = @($invalidDownloadEntries | Where-Object { -not $forkSourceIds.Contains((Get-StringValue $_ 'SourceId')) })
    $forkRawEntryCount = (@($forkSources | ForEach-Object Count | Measure-Object -Sum).Sum)
    $mainRawEntryCount = (@($mainSources | ForEach-Object Count | Measure-Object -Sum).Sum)
    if ($null -eq $forkRawEntryCount) { $forkRawEntryCount = 0 }
    if ($null -eq $mainRawEntryCount) { $mainRawEntryCount = 0 }

    Write-SummaryCollection `
        -CollectionEntries $mainEntries `
        -CollectionSources $mainSources `
        -CollectionExcludedEntries $mainExcludedEntries `
        -CollectionInvalidEntries $mainInvalidEntries `
        -CollectionRawEntryCount $mainRawEntryCount `
        -CollectionName '通常側' `
        -CollectionOutputPath $OutputPath `
        -CollectionPreviousPath $PreviousPath `
        -CollectionChangesPath $ChangesPath | Out-Null

    Write-SummaryCollection `
        -CollectionEntries $forkEntries `
        -CollectionSources $forkSources `
        -CollectionExcludedEntries $forkExcludedEntries `
        -CollectionInvalidEntries $forkInvalidEntries `
        -CollectionRawEntryCount $forkRawEntryCount `
        -CollectionName 'フォーク側' `
        -CollectionOutputPath $ForkOutputPath `
        -CollectionPreviousPath $ForkPreviousPath `
        -CollectionChangesPath $ForkChangesPath | Out-Null
}
