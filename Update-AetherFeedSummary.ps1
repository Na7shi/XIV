param(
    [string]$SourceUrl = 'https://raw.githubusercontent.com/Aetherfeed/aetherfeed.github.io/main/public/data/plugins.json',
    [string]$OfficialRepositoryUrl = 'https://kamori.goats.dev/Plugin/PluginMaster',
    [string]$OutputPath = 'dist/aetherfeed-summary.json',
    [string]$PreviousPath = 'previous-aetherfeed-summary.json',
    [string]$ChangesPath = 'dist/aetherfeed-summary-changes.json'
)

$ErrorActionPreference = 'Stop'

function Get-StringValue($Object, [string]$Name) {
    if ($null -eq $Object) { return '' }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return "$($property.Value)".Trim()
}

function Get-DiscoveryEntryKey($Entry, [string]$RepositoryUrl, [string]$SourcePageUrl) {
    $parts = @(
        $RepositoryUrl,
        (Get-StringValue $Entry 'InternalName'),
        (Get-StringValue $Entry 'Name'),
        (Get-StringValue $Entry 'DalamudApiLevel'),
        (Get-StringValue $Entry 'RepoUrl'),
        $SourcePageUrl
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Normalize-VersionProperty($Copy, [string]$Name) {
    if (-not $Copy.Contains($Name) -or $null -eq $Copy[$Name]) { return $false }
    $raw = "$($Copy[$Name])".Trim()
    if (-not $raw) { return $false }
    $parsed = $null
    if ([Version]::TryParse($raw, [ref]$parsed)) { return $false }

    # AetherFeed occasionally publishes placeholders such as {version}.0.
    # Dalamud deserializes these fields as System.Version, so retain the original
    # value in a side field and use a parseable sentinel for the discovery feed.
    $copy["Original$Name"] = $raw
    $copy[$Name] = '0.0.0.0'
    return $true
}

function ConvertTo-ComparableJson($Object) {
    $copy = $Object | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $copy.PSObject.Properties.Remove('DownloadCount')
    return ($copy | ConvertTo-Json -Depth 30 -Compress)
}

function Get-EntryKey($Entry) {
    $key = Get-StringValue $Entry 'RepositoryEntryKey'
    if ($key) { return $key }
    return Get-DiscoveryEntryKey $Entry (Get-StringValue $Entry 'RepositorySource') (Get-StringValue $Entry 'AetherFeedSourceUrl')
}

function Read-Array([string]$Path) {
    if (-not (Test-Path $Path)) { return @() }
    $value = Get-Content $Path -Raw | ConvertFrom-Json
    if ($null -eq $value) { return @() }
    return @($value)
}

function Test-AbsoluteHttpUrl([string]$Value) {
    if (-not $Value) { return $false }
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return $uri.Scheme -in @('http', 'https')
}

function Get-ManifestEntries($Document) {
    if ($null -eq $Document) { return @() }
    if ($Document -is [System.Array]) { return @($Document) }
    if ($Document.PSObject.Properties['plugins']) { return @($Document.plugins) }
    if ($Document.PSObject.Properties['entries']) { return @($Document.entries) }
    return @($Document)
}

function Find-ManifestEntry($AetherEntry, [object[]]$ManifestEntries) {
    $internalName = Get-StringValue $AetherEntry 'InternalName'
    $repoUrl = Get-StringValue $AetherEntry 'RepoUrl'
    $name = Get-StringValue $AetherEntry 'Name'

    $matches = @($ManifestEntries | Where-Object {
        $candidate = Get-StringValue $_ 'InternalName'
        $internalName -and $candidate -and $candidate.Equals($internalName, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($matches.Count -eq 1) { return [pscustomobject]@{ Entry = $matches[0]; Method = 'InternalName' } }

    if ($matches.Count -gt 1 -and $name) {
        $nameMatches = @($matches | Where-Object {
            (Get-StringValue $_ 'Name').Equals($name, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($nameMatches.Count -eq 1) { return [pscustomobject]@{ Entry = $nameMatches[0]; Method = 'InternalName+Name' } }
    }

    if ($repoUrl) {
        $repoMatches = @($ManifestEntries | Where-Object {
            $candidate = Get-StringValue $_ 'RepoUrl'
            $candidate -and $candidate.Equals($repoUrl, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($repoMatches.Count -eq 1) { return [pscustomobject]@{ Entry = $repoMatches[0]; Method = 'RepoUrl' } }
    }

    if ($name) {
        $nameMatches = @($ManifestEntries | Where-Object {
            $candidate = Get-StringValue $_ 'Name'
            $candidate -and $candidate.Equals($name, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($nameMatches.Count -eq 1) { return [pscustomobject]@{ Entry = $nameMatches[0]; Method = 'Name' } }
    }

    return $null
}

function Get-DistributionUrls($AetherEntry, $ManifestEntry) {
    $installUrl = Get-StringValue $ManifestEntry 'DownloadLinkInstall'
    $updateUrl = Get-StringValue $ManifestEntry 'DownloadLinkUpdate'
    $testingUrl = Get-StringValue $ManifestEntry 'DownloadLinkTesting'

    # Install and update normally point at the same release zip. If a source
    # publishes only one of them, use it for both fields so the resulting
    # metadata remains usable by Dalamud.
    if (-not (Test-AbsoluteHttpUrl $installUrl)) { $installUrl = Get-StringValue $AetherEntry 'DownloadLinkInstall' }
    if (-not (Test-AbsoluteHttpUrl $updateUrl)) { $updateUrl = Get-StringValue $AetherEntry 'DownloadLinkUpdate' }
    if (-not (Test-AbsoluteHttpUrl $installUrl) -and (Test-AbsoluteHttpUrl $updateUrl)) { $installUrl = $updateUrl }
    if (-not (Test-AbsoluteHttpUrl $updateUrl) -and (Test-AbsoluteHttpUrl $installUrl)) { $updateUrl = $installUrl }
    if (-not (Test-AbsoluteHttpUrl $testingUrl)) { $testingUrl = Get-StringValue $AetherEntry 'DownloadLinkTesting' }

    $testingExclusive = (Get-StringValue $ManifestEntry 'IsTestingExclusive').Equals('true', [StringComparison]::OrdinalIgnoreCase)
    $resolved = (Test-AbsoluteHttpUrl $installUrl) -and (Test-AbsoluteHttpUrl $updateUrl) -and -not $testingExclusive
    return [pscustomobject]@{
        Install = if (Test-AbsoluteHttpUrl $installUrl) { $installUrl } else { '' }
        Update = if (Test-AbsoluteHttpUrl $updateUrl) { $updateUrl } else { '' }
        Testing = if (Test-AbsoluteHttpUrl $testingUrl) { $testingUrl } else { '' }
        Resolved = $resolved
    }
}

function Read-OfficialInternalNames([string]$Url) {
    try {
        $document = Invoke-RestMethod -Uri $Url -Headers @{ 'User-Agent' = 'Na7shi-XIV-Repository-Summary' }
    } catch {
        throw "公式リポジトリの取得に失敗したため、AetherFeed を更新しません: $($_.Exception.Message)"
    }

    $entries = @()
    if ($document -is [System.Array]) {
        $entries = @($document)
    } elseif ($document.PSObject.Properties['plugins']) {
        $entries = @($document.plugins)
    } elseif ($document.PSObject.Properties['entries']) {
        $entries = @($document.entries)
    } else {
        $entries = @($document)
    }

    # Dalamud の InternalName 判定は大文字小文字を区別しないため、同じ規則で照合する。
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        $internalName = Get-StringValue $entry 'InternalName'
        if ($internalName) { [void]$names.Add($internalName) }
    }
    if ($names.Count -eq 0) {
        throw "公式リポジトリに InternalName がありません: $Url"
    }
    # HashSet 自体を返し、PowerShell に列挙して配列化させない。
    return ,$names
}

Write-Host "AetherFeed を取得しています: $SourceUrl"
$officialInternalNames = Read-OfficialInternalNames $OfficialRepositoryUrl
Write-Host "公式リポジトリに登録済みの InternalName $($officialInternalNames.Count) 件を除外します。"
try {
    $document = Invoke-RestMethod -Uri $SourceUrl -Headers @{ 'User-Agent' = 'Na7shi-XIV-Repository-Summary' }
} catch {
    $message = $_.Exception.Message
    Write-Warning "AetherFeed の取得に失敗しました。前回の結果を維持します: $message"
    $fallback = Read-Array $PreviousPath
    $outputDirectory = Split-Path $OutputPath -Parent
    if ($outputDirectory) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }
    $fallback | ConvertTo-Json -Depth 30 | Out-File -FilePath $OutputPath -Encoding utf8
    $changesDirectory = Split-Path $ChangesPath -Parent
    if ($changesDirectory) { New-Item -ItemType Directory -Force -Path $changesDirectory | Out-Null }
    [ordered]@{
        GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        SourceUrl = $SourceUrl
        SourceCount = 0
        EntryCount = $fallback.Count
        Added = @()
        Updated = @()
        Removed = @()
        Sources = @()
        Error = $message
    } | ConvertTo-Json -Depth 30 | Out-File -FilePath $ChangesPath -Encoding utf8
    exit 0
}

# 現在のAetherFeedはグループ配列だが、将来のラッパー形式にも対応する。
$groups = @()
if ($document -is [System.Array]) {
    $groups = @($document)
} elseif ($document.PSObject.Properties['repositories']) {
    $groups = @($document.repositories)
} elseif ($document.PSObject.Properties['groups']) {
    $groups = @($document.groups)
} else {
    $groups = @($document)
}

$entries = [System.Collections.Generic.List[object]]::new()
$sourceStats = [System.Collections.Generic.List[object]]::new()
$groupIndex = 0
$excludedOfficialEntryCount = 0
$sourceManifestResults = @()
$distributionUrlResolvedEntryCount = 0
$distributionUrlUnresolvedEntryCount = 0

# AetherFeedには多数のリポジトリがあるため、配布元マニフェストは先に
# 重複を除いて並列取得する。PowerShell 5.xで実行された場合は直列に戻す。
$manifestUrls = @(
    $groups |
        ForEach-Object { Get-StringValue $_ 'repo_url' } |
        Where-Object { Test-AbsoluteHttpUrl $_ } |
        Sort-Object -Unique
)
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $sourceManifestResults = @($manifestUrls | ForEach-Object -Parallel {
        $url = $_
        try {
            $sourceManifest = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'Na7shi-XIV-Repository-Summary' } -TimeoutSec 20
            if ($sourceManifest -is [System.Array]) {
                $sourceEntries = @($sourceManifest)
            } elseif ($sourceManifest.PSObject.Properties['plugins']) {
                $sourceEntries = @($sourceManifest.plugins)
            } elseif ($sourceManifest.PSObject.Properties['entries']) {
                $sourceEntries = @($sourceManifest.entries)
            } else {
                $sourceEntries = @($sourceManifest)
            }
            if ($sourceEntries.Count -eq 0) { throw 'マニフェストにプラグインエントリがありません' }
            [pscustomobject]@{ Url = $url; Entries = $sourceEntries; Error = '' }
        } catch {
            [pscustomobject]@{ Url = $url; Entries = @(); Error = $_.Exception.Message }
        }
    } -ThrottleLimit 12)
} else {
    foreach ($manifestUrl in $manifestUrls) {
        try {
            $sourceManifest = Invoke-RestMethod -Uri $manifestUrl -Headers @{ 'User-Agent' = 'Na7shi-XIV-Repository-Summary' } -TimeoutSec 20
            $sourceEntries = @(Get-ManifestEntries $sourceManifest)
            if ($sourceEntries.Count -eq 0) { throw 'マニフェストにプラグインエントリがありません' }
            $sourceManifestResults += [pscustomobject]@{ Url = $manifestUrl; Entries = $sourceEntries; Error = '' }
        } catch {
            $sourceManifestResults += [pscustomobject]@{ Url = $manifestUrl; Entries = @(); Error = $_.Exception.Message }
        }
    }
}
$manifestByUrl = @{}
$manifestErrors = @{}
foreach ($result in $sourceManifestResults) {
    if ($result.Error) { $manifestErrors[$result.Url] = $result.Error }
    else { $manifestByUrl[$result.Url] = @($result.Entries) }
}
$sourceManifestFetchCount = $sourceManifestResults.Count
$sourceManifestFailureCount = @($sourceManifestResults | Where-Object Error).Count
$manifestFailureSamples = @($sourceManifestResults | Where-Object Error | Select-Object -First 10)

foreach ($group in $groups) {
    $groupIndex++
    $manifestUrl = Get-StringValue $group 'repo_url'
    $sourcePageUrl = Get-StringValue $group 'repo_source_url'
    $repositoryUrl = $manifestUrl
    if (-not $repositoryUrl) { $repositoryUrl = $sourcePageUrl }
    if (-not $repositoryUrl) { $repositoryUrl = "aetherfeed://group/$groupIndex" }

    $repositoryName = Get-StringValue $group 'repo_name'
    $developerName = Get-StringValue $group 'repo_developer_name'
    $displayName = $repositoryName
    if ($sourcePageUrl -match '^https?://github\.com/([^/]+)/([^/?#]+)') {
        $displayName = "$($Matches[1])/$($Matches[2])"
    } elseif ($developerName -and $repositoryName) {
        $displayName = "$developerName/$repositoryName"
    } elseif (-not $displayName) {
        $displayName = if ($developerName) { $developerName } else { $repositoryUrl }
    }
    $sourceLabel = "AetherFeed: $displayName"
    $pluginsProperty = $group.PSObject.Properties['plugins']
    $plugins = if ($null -eq $pluginsProperty -or $null -eq $pluginsProperty.Value) { @() } else { @($pluginsProperty.Value) }

    # AetherFeed's plugin entries intentionally omit distribution links. Fetch
    # the original repository manifest once per source repository and use its
    # links instead of trying to infer a release URL from RepoUrl.
    $manifestEntries = @()
    $manifestError = ''
    if ($manifestUrl -and (Test-AbsoluteHttpUrl $manifestUrl)) {
        if ($manifestByUrl.ContainsKey($manifestUrl)) {
            $manifestEntries = @($manifestByUrl[$manifestUrl])
        } elseif ($manifestErrors.ContainsKey($manifestUrl)) {
            $manifestError = $manifestErrors[$manifestUrl]
        } else {
            $manifestError = '配布元マニフェストの取得結果がありません'
        }
    } elseif ($manifestUrl) {
        $manifestError = 'repo_url が絶対HTTP(S) URLではありません'
        $manifestErrors[$manifestUrl] = $manifestError
        $sourceManifestFailureCount++
    } else {
        $manifestError = 'AetherFeed の repo_url がありません'
        $sourceManifestFailureCount++
    }

    foreach ($plugin in $plugins) {
        $pluginInternalName = Get-StringValue $plugin 'InternalName'
        if ($pluginInternalName -and $officialInternalNames.Contains($pluginInternalName)) {
            # Dalamud は公式リポジトリのプラグインをカスタムリポジトリで
            # 差し替えることを拒否するため、探索一覧からも除外する。
            $excludedOfficialEntryCount++
            continue
        }
        $copy = [ordered]@{}
        foreach ($property in $plugin.PSObject.Properties) {
            if ($property.Name -eq 'DownloadCount') { continue }
            $copy[$property.Name] = $property.Value
        }

        $normalizedVersionFields = @(
            @('AssemblyVersion', 'TestingAssemblyVersion') |
                Where-Object { Normalize-VersionProperty $copy $_ }
        )
        if ($normalizedVersionFields.Count -gt 0) {
            $copy['RepositoryNormalizedVersionFields'] = $normalizedVersionFields
        }

        $originalAuthor = Get-StringValue $plugin 'Author'
        $copy['OriginalAuthor'] = $originalAuthor
        $copy['RepositorySource'] = $repositoryUrl
        $copy['RepositorySourceId'] = "aetherfeed:$repositoryUrl"
        $copy['RepositorySourceLabel'] = $sourceLabel
        $copy['AetherFeedRepositoryUrl'] = $repositoryUrl
        $copy['AetherFeedSourceUrl'] = $sourcePageUrl
        $copy['RepositoryDiscoveryOnly'] = $true
        $copy['DistributionUrlSource'] = $manifestUrl

        $manifestMatch = $null
        $distributionUrls = $null
        if ($manifestEntries.Count -gt 0) {
            $manifestMatch = Find-ManifestEntry $plugin $manifestEntries
            if ($null -ne $manifestMatch) {
                $distributionUrls = Get-DistributionUrls $plugin $manifestMatch.Entry
                if ($distributionUrls.Install) { $copy['DownloadLinkInstall'] = $distributionUrls.Install }
                if ($distributionUrls.Update) { $copy['DownloadLinkUpdate'] = $distributionUrls.Update }
                if ($distributionUrls.Testing) { $copy['DownloadLinkTesting'] = $distributionUrls.Testing }
                $copy['DistributionUrlMatch'] = $manifestMatch.Method
            }
        }

        $resolved = $null -ne $distributionUrls -and $distributionUrls.Resolved
        $copy['DistributionUrlResolved'] = $resolved
        if ($resolved) {
            $distributionUrlResolvedEntryCount++
        } else {
            $distributionUrlUnresolvedEntryCount++
            $copy['DistributionUrlError'] = if ($manifestError) {
                $manifestError
            } elseif ($null -eq $manifestMatch) {
                '配布元マニフェスト内で InternalName/RepoUrl/Name が一致しません'
            } else {
                '配布用の絶対HTTP(S) URLがありません'
            }
        }

        # URLを取得した後も、AetherFeedは同名プラグインの衝突を避けるため
        # 探索・確認用の非表示データとして扱う。インストール可能な公式外部
        # プラグインは repository-summary.json 側で管理する。
        $copy['IsHide'] = $true
        $copy['RepositoryEntryKey'] = Get-DiscoveryEntryKey $plugin $repositoryUrl $sourcePageUrl
        # 探索一覧でも同名エントリを見分けられるよう、Authorを配布元付きにする。
        # AetherFeedの元データは配布物ではないため、ここでの値は表示・検知用。
        $qualifiedAuthor = if ($originalAuthor) { "$originalAuthor [$sourceLabel]" } else { $sourceLabel }
        $copy['RepositoryOriginalInternalName'] = Get-StringValue $plugin 'InternalName'
        $copy['RepositoryDisplayAuthor'] = $qualifiedAuthor
        $copy['Author'] = $qualifiedAuthor
        $entries.Add([pscustomobject]$copy)
    }

    $sourceStats.Add([pscustomobject]@{
        RepositorySource = $repositoryUrl
        RepositorySourceLabel = $sourceLabel
        EntryCount = $plugins.Count
        DistributionManifestUrl = $manifestUrl
        DistributionManifestFetched = $manifestEntries.Count -gt 0
        DistributionManifestError = $manifestError
    })
}

$sortedEntries = @($entries | Sort-Object @{ Expression = { Get-StringValue $_ 'RepositorySourceId' } }, @{ Expression = { Get-StringValue $_ 'InternalName' } }, @{ Expression = { Get-StringValue $_ 'RepositoryEntryKey' } })
$outputDirectory = Split-Path $OutputPath -Parent
if ($outputDirectory) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }
$sortedEntries | ConvertTo-Json -Depth 30 | Out-File -FilePath $OutputPath -Encoding utf8

$previous = Read-Array $PreviousPath
$previousByKey = @{}
foreach ($entry in $previous) { $previousByKey[(Get-EntryKey $entry)] = $entry }
$currentByKey = @{}
foreach ($entry in $sortedEntries) { $currentByKey[(Get-EntryKey $entry)] = $entry }

$added = [System.Collections.Generic.List[object]]::new()
$updated = [System.Collections.Generic.List[object]]::new()
$removed = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $sortedEntries) {
    $key = Get-EntryKey $entry
    if (-not $previousByKey.ContainsKey($key)) {
        $added.Add($entry)
    } elseif ((ConvertTo-ComparableJson $previousByKey[$key]) -ne (ConvertTo-ComparableJson $entry)) {
        $updated.Add($entry)
    }
}
foreach ($entry in $previous) {
    $key = Get-EntryKey $entry
    if (-not $currentByKey.ContainsKey($key)) { $removed.Add($entry) }
}

$changes = [ordered]@{
    GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
    SourceUrl = $SourceUrl
    OfficialRepositoryUrl = $OfficialRepositoryUrl
    SourceCount = $groups.Count
    EntryCount = $sortedEntries.Count
    ExcludedOfficialEntryCount = $excludedOfficialEntryCount
    NormalizedVersionEntryCount = @($sortedEntries | Where-Object { $_.RepositoryNormalizedVersionFields }).Count
    SourceManifestFetchCount = $sourceManifestFetchCount
    SourceManifestFailureCount = $sourceManifestFailureCount
    DistributionUrlResolvedEntryCount = $distributionUrlResolvedEntryCount
    DistributionUrlUnresolvedEntryCount = $distributionUrlUnresolvedEntryCount
    Added = @($added)
    Updated = @($updated)
    Removed = @($removed)
    Sources = @($sourceStats | Sort-Object RepositorySource)
}
$changesDirectory = Split-Path $ChangesPath -Parent
if ($changesDirectory) { New-Item -ItemType Directory -Force -Path $changesDirectory | Out-Null }
$changes | ConvertTo-Json -Depth 30 | Out-File -FilePath $ChangesPath -Encoding utf8

Write-Host "AetherFeed: $($groups.Count) リポジトリグループ / $($sortedEntries.Count) 件"
Write-Host "配布URL: 取得 $distributionUrlResolvedEntryCount / 未取得 $distributionUrlUnresolvedEntryCount (マニフェスト取得失敗 $sourceManifestFailureCount)"
foreach ($failure in $manifestFailureSamples) {
    Write-Warning "配布元マニフェストを取得できません: $($failure.Url) ($($failure.Error))"
}
Write-Host "差分: 追加 $($added.Count) / 更新 $($updated.Count) / 削除 $($removed.Count)"
