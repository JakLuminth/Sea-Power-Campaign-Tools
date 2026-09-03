#requires -Version 7.0

function Get-ManifestValue([object]$Object, [string]$Name, [object]$Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    return $Default
}

function Resolve-ManifestPath([string]$Value, [string]$ManifestDirectory, [string]$RepoRoot) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $normalized = $Value.Trim().Replace('/', '\')
    if ([System.IO.Path]::IsPathRooted($normalized) -or $normalized -match '^[A-Za-z]:') { return $null }
    if ($normalized -match '[\x00-\x1F]') { return $null }
    try {
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $ManifestDirectory $normalized))
        $repo = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') + '\'
        if (-not $candidate.StartsWith($repo, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        return $candidate
    } catch { return $null }
}

function Read-CampaignToolManifest([string]$Path, [string]$RepoRoot) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A campaign manifest is required. Use -Config <path>.' }
    $manifestPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $manifestDirectory = Split-Path -Parent $manifestPath
    $repo = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
    try { $raw = [System.IO.File]::ReadAllText($manifestPath); $data = $raw | ConvertFrom-Json -Depth 100 }
    catch { throw "Invalid campaign manifest '$manifestPath': $($_.Exception.Message)" }

    $schemaVersion = Get-ManifestValue $data 'schemaVersion'
    if ($null -eq $schemaVersion -or [int]$schemaVersion -ne 1) { throw "Campaign manifest schemaVersion must be 1: $manifestPath" }
    $campaign = Get-ManifestValue $data 'campaign'
    if ($null -eq $campaign) { throw "Campaign manifest is missing campaign metadata: $manifestPath" }
    $campaignId = [string](Get-ManifestValue $campaign 'id')
    $campaignName = [string](Get-ManifestValue $campaign 'displayName' $campaignId)
    $campaignRootValue = [string](Get-ManifestValue $campaign 'root')
    $campaignRoot = Resolve-ManifestPath $campaignRootValue $manifestDirectory $repo
    if ($null -eq $campaignRoot) { throw "Campaign root is invalid or outside RepoRoot: $campaignRootValue" }
    $campaignIniName = [string](Get-ManifestValue $campaign 'ini' 'campaign.ini')
    $campaignIni = Join-Path $campaignRoot $campaignIniName
    $metadataValue = [string](Get-ManifestValue $campaign 'metadata' 'mod/_info.ini')
    $metadata = Resolve-ManifestPath $metadataValue $manifestDirectory $repo
    if ($null -eq $metadata) { throw "Campaign metadata path is invalid or outside RepoRoot: $metadataValue" }
    $campaignsRootValue = [string](Get-ManifestValue $campaign 'campaignsRoot' 'mod/campaigns')
    $campaignsRoot = Resolve-ManifestPath $campaignsRootValue $manifestDirectory $repo
    if ($null -eq $campaignsRoot) { throw "Campaigns root is invalid or outside RepoRoot: $campaignsRootValue" }

    $locales = @((Get-ManifestValue $data 'locales') | ForEach-Object { [string]$_ })
    if ($locales.Count -eq 0 -or ($locales | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw 'Campaign manifest locales must contain at least one non-empty locale.' }
    $briefing = Get-ManifestValue $data 'briefing'
    if ($null -eq $briefing) { throw 'Campaign manifest is missing briefing configuration.' }
    $contentValue = [string](Get-ManifestValue $briefing 'content')
    $contentPath = Resolve-ManifestPath $contentValue $manifestDirectory $repo
    if ($null -eq $contentPath) { throw "Briefing content path is invalid or outside RepoRoot: $contentValue" }
    $requiredFields = @((Get-ManifestValue $briefing 'requiredFields') | ForEach-Object { [string]$_ })
    if ($requiredFields.Count -eq 0) { throw 'Campaign manifest briefing.requiredFields must not be empty.' }
    $headings = Get-ManifestValue $briefing 'requiredHeadings'
    if ($null -eq $headings) { throw 'Campaign manifest briefing.requiredHeadings is required.' }
    $branding = Get-ManifestValue $briefing 'branding'
    if ($null -eq $branding) { $branding = [pscustomobject]@{} }

    return [pscustomobject]@{
        ManifestPath = $manifestPath
        ManifestDirectory = $manifestDirectory
        RepoRoot = $repo
        CampaignId = $campaignId
        CampaignName = $campaignName
        CampaignRoot = $campaignRoot
        CampaignIni = $campaignIni
        MetadataPath = $metadata
        CampaignsRoot = $campaignsRoot
        CampaignsRootRelative = $campaignsRootValue.Replace('/', '\').Trim('\')
        Locales = $locales
        Briefing = $briefing
        BriefingContentPath = $contentPath
        RequiredBriefingFields = $requiredFields
        RequiredBriefingHeadings = $headings
        Branding = $branding
        Validation = (Get-ManifestValue $data 'validation' ([pscustomobject]@{}))
    }
}

function Get-ManifestList([object]$Object, [string]$Name, [object[]]$Default = @()) {
    $value = Get-ManifestValue $Object $Name
    if ($null -eq $value) { return @($Default) }
    return @($value)
}

function Get-ManifestMap([object]$Object, [string]$Name) {
    $value = Get-ManifestValue $Object $Name
    if ($null -eq $value) { return [pscustomobject]@{} }
    return $value
}

function Expand-CampaignPathPattern([string]$Pattern, [string]$CampaignId, [string]$Stem, [string]$Locale) {
    if ([string]::IsNullOrWhiteSpace($Pattern)) { return $null }
    return $Pattern.Replace('{campaignId}', $CampaignId).Replace('{stem}', $Stem).Replace('{locale}', $Locale)
}
