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
    if ($null -eq $schemaVersion -or [string]$schemaVersion -cne '1') { throw "Campaign manifest schemaVersion must be 1: $manifestPath" }
    $campaign = Get-ManifestValue $data 'campaign'
    if ($null -eq $campaign) { throw "Campaign manifest is missing campaign metadata: $manifestPath" }
    $campaignId = [string](Get-ManifestValue $campaign 'id')
    if ([string]::IsNullOrWhiteSpace($campaignId) -or $campaignId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Campaign manifest campaign.id must be a safe non-empty identifier: $manifestPath"
    }
    $campaignName = [string](Get-ManifestValue $campaign 'displayName' $campaignId)
    if ([string]::IsNullOrWhiteSpace($campaignName)) { throw "Campaign manifest campaign.displayName must not be empty: $manifestPath" }
    $campaignRootValue = [string](Get-ManifestValue $campaign 'root')
    $campaignRoot = Resolve-ManifestPath $campaignRootValue $manifestDirectory $repo
    if ($null -eq $campaignRoot) { throw "Campaign root is invalid or outside RepoRoot: $campaignRootValue" }
    $campaignIniName = [string](Get-ManifestValue $campaign 'ini' 'campaign.ini')
    $campaignIniReference = Join-Path $campaignRootValue $campaignIniName
    $campaignIni = Resolve-ManifestPath $campaignIniReference $manifestDirectory $repo
    $campaignRootPrefix = [System.IO.Path]::GetFullPath($campaignRoot).TrimEnd('\') + '\'
    if ($null -eq $campaignIni -or -not $campaignIni.StartsWith($campaignRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Campaign INI path is invalid or outside the campaign root: $campaignIniName"
    }
    $metadataValue = [string](Get-ManifestValue $campaign 'metadata' 'mod/_info.ini')
    $metadata = Resolve-ManifestPath $metadataValue $manifestDirectory $repo
    if ($null -eq $metadata) { throw "Campaign metadata path is invalid or outside RepoRoot: $metadataValue" }
    $campaignsRootValue = [string](Get-ManifestValue $campaign 'campaignsRoot' 'mod/campaigns')
    $campaignsRoot = Resolve-ManifestPath $campaignsRootValue $manifestDirectory $repo
    if ($null -eq $campaignsRoot) { throw "Campaigns root is invalid or outside RepoRoot: $campaignsRootValue" }

    $locales = @((Get-ManifestValue $data 'locales') | ForEach-Object { [string]$_ })
    if ($locales.Count -eq 0 -or ($locales | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw 'Campaign manifest locales must contain at least one non-empty locale.' }
    $localeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($locale in $locales) {
        if (-not $localeSet.Add($locale)) { throw "Campaign manifest locales contain a duplicate locale '$locale'." }
        if ($locale -match '[\\/:*?"<>|\x00-\x1F]') { throw "Campaign manifest locale '$locale' contains an invalid path character." }
    }
    $briefing = Get-ManifestValue $data 'briefing'
    if ($null -eq $briefing) { throw 'Campaign manifest is missing briefing configuration.' }
    $contentValue = [string](Get-ManifestValue $briefing 'content')
    $contentPath = Resolve-ManifestPath $contentValue $manifestDirectory $repo
    if ($null -eq $contentPath) { throw "Briefing content path is invalid or outside RepoRoot: $contentValue" }
    $requiredFields = @((Get-ManifestValue $briefing 'requiredFields') | ForEach-Object { [string]$_ })
    if ($requiredFields.Count -eq 0) { throw 'Campaign manifest briefing.requiredFields must not be empty.' }
    $fieldSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($field in $requiredFields) {
        if ([string]::IsNullOrWhiteSpace($field) -or $field -notmatch '^[A-Za-z][A-Za-z0-9_]*$' -or -not $fieldSet.Add($field)) {
            throw "Campaign manifest briefing.requiredFields contains an invalid or duplicate field: '$field'"
        }
    }
    $sectionFields = @((Get-ManifestValue $briefing 'sectionFields' @('situation','mission','execution','roe','friendly','support')) | ForEach-Object { [string]$_ })
    if ($sectionFields.Count -eq 0) { throw 'Campaign manifest briefing.sectionFields must not be empty.' }
    $sectionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($field in $sectionFields) {
        if (-not $fieldSet.Contains($field) -or -not $sectionSet.Add($field)) { throw "Campaign manifest briefing.sectionFields contains an unknown or duplicate field: '$field'" }
    }
    $headings = Get-ManifestValue $briefing 'requiredHeadings'
    if ($null -eq $headings) { throw 'Campaign manifest briefing.requiredHeadings is required.' }
    foreach ($locale in $locales) {
        $localeHeadings = @(Get-ManifestValue $headings $locale)
        if ($localeHeadings.Count -eq 0 -or ($localeHeadings | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
            throw "Campaign manifest briefing.requiredHeadings is missing a non-empty list for locale '$locale'."
        }
    }
    $labels = Get-ManifestValue $briefing 'labels'
    if ($null -eq $labels) { throw 'Campaign manifest briefing.labels is required.' }
    foreach ($locale in $locales) {
        $localeLabels = Get-ManifestValue $labels $locale
        foreach ($labelKey in @('brief','footer') + $sectionFields) {
            if ([string]::IsNullOrWhiteSpace([string](Get-ManifestValue $localeLabels $labelKey))) {
                throw "Campaign manifest briefing.labels.$locale.$labelKey is required."
            }
        }
    }
    $xaml = Get-ManifestValue $briefing 'xaml' ([pscustomobject]@{})
    foreach ($rootKey in @('briefingRoot','eventRoot')) {
        $rootName = [string](Get-ManifestValue $xaml $rootKey $(if ($rootKey -eq 'briefingRoot') { 'Grid' } else { 'Page' }))
        if ($rootName -notmatch '^[A-Za-z_][A-Za-z0-9_.-]*$') { throw "Campaign manifest briefing.xaml.$rootKey is not a safe XML element name." }
    }
    foreach ($namespaceKey in @('presentationNamespace','xamlNamespace')) {
        $namespace = [string](Get-ManifestValue $xaml $namespaceKey $(if ($namespaceKey -eq 'presentationNamespace') { 'http://schemas.microsoft.com/winfx/2006/xaml/presentation' } else { 'http://schemas.microsoft.com/winfx/2006/xaml' }))
        if ([string]::IsNullOrWhiteSpace($namespace) -or $namespace -match '[\x00-\x1F\s]') { throw "Campaign manifest briefing.xaml.$namespaceKey must be a non-empty namespace URI." }
    }
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
        BriefingSectionFields = $sectionFields
        RequiredBriefingHeadings = $headings
        Xaml = $xaml
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
