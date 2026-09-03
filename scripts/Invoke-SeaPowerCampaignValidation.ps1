#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Sea Power',
    [Parameter(Mandatory = $true)]
    [string]$Config,
    [switch]$VerticalSlice,
    [switch]$Implemented
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CampaignTools.Common.ps1')
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error 'PowerShell 7 or newer is required.'
    exit 1
}

try {
    $manifest = Read-CampaignToolManifest $Config $RepoRoot
    $RepoRoot = $manifest.RepoRoot
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

function Add-Failure([string]$Message) { [void]$script:failures.Add($Message) }
function Add-Warning([string]$Message) { [void]$script:warnings.Add($Message) }

function Require-File([string]$Path, [string]$Description) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Failure "Missing $Description`: $Path"
        return $false
    }
    return $true
}

function Convert-CampaignPath([string]$Path, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $normalized = $Path.Trim()
    if ($normalized.Length -ge 2 -and $normalized[0] -eq '"' -and $normalized[$normalized.Length - 1] -eq '"') {
        $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
    } elseif ($normalized.Contains('"')) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }
    $normalized = $normalized.Replace('/', '\')

    # Campaign references are package-relative paths. Accept only the exact
    # prefixes emitted by the game/mod layout; stripping arbitrary leading
    # dots or separators would turn traversal and malformed paths into valid
    # references before they are checked.
    if ([System.IO.Path]::IsPathRooted($normalized) -or $normalized -match '^[A-Za-z]:') { return $null }
    if ($normalized -match '[\x00-\x1F]') { return $null }
    $prefixes = @('.\mod\campaigns\', '.\campaigns\', 'mod\campaigns\', 'campaigns\')
    $relative = $null
    foreach ($prefix in $prefixes) {
        if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relative = $normalized.Substring($prefix.Length)
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($relative)) { return $null }

    $segments = @($relative -split '\\')
    if ($segments.Count -eq 0 -or ($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') -or $_ -match '[<>:"|?*]' })) { return $null }
    try {
        $campaignsRoot = [System.IO.Path]::GetFullPath($manifest.CampaignsRoot).TrimEnd('\') + '\'
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $campaignsRoot ($segments -join '\')))
        if (-not $candidate.StartsWith($campaignsRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        return $candidate
    } catch {
        return $null
    }
}

# DynamicUnitGeneration resolves a non-rooted roster name beside the mission
# INI, so keep the validation rooted inside this campaign package.
function Convert-MissionRelativePath([string]$Path, [string]$MissionDirectory, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($MissionDirectory)) { return $null }
    $normalized = $Path.Trim()
    if ($normalized.Length -ge 2 -and $normalized[0] -eq '"' -and $normalized[$normalized.Length - 1] -eq '"') {
        $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
    } elseif ($normalized.Contains('"')) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }
    $normalized = $normalized.Replace('/', '\')
    if ([System.IO.Path]::IsPathRooted($normalized) -or $normalized -match '[\x00-\x1F]') { return $null }
    try {
        $campaignRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $MissionDirectory $normalized))
        if (-not $candidate.StartsWith($campaignRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        return $candidate
    } catch {
        return $null
    }
}

function Read-IniFile([string]$Path) {
    $sections = [ordered]@{}
    $duplicates = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Path = $Path; Text = ''; Sections = $sections; DuplicateSections = $duplicates }
    }
    $text = Get-Content -Raw -LiteralPath $Path
    $section = $null
    foreach ($raw in (Get-Content -LiteralPath $Path)) {
        $line = $raw.Trim()
        if ($line -match '^\[([^\]\r\n]+)\]\s*$') {
            $section = $Matches[1]
            if ($sections.Contains($section)) {
                [void]$duplicates.Add($section)
            } else {
                $sections[$section] = [System.Collections.Generic.List[string]]::new()
            }
            continue
        }
        if ($null -ne $section -and $line -and -not $line.StartsWith(';') -and -not $line.StartsWith('#')) {
            [void]$sections[$section].Add($line)
        }
    }
    return [pscustomobject]@{ Path = $Path; Text = $text; Sections = $sections; DuplicateSections = $duplicates }
}

# Keep this helper accepting the List[string] returned by Read-IniFile.  A
# previous version passed that list to Regex.Match, which silently skipped the
# briefing reference check.  Reading key/value data belongs here instead.
function Get-IniValue([System.Collections.IEnumerable]$Lines, [string]$Key) {
    if ($null -eq $Lines) { return $null }
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*=(.*)$'
    foreach ($line in $Lines) {
        if ([string]$line -match $pattern) { return $Matches[1].Trim() }
    }
    return $null
}

function Get-IniKeys([System.Collections.IEnumerable]$Lines) {
    $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $Lines) { return $keys }
    foreach ($line in $Lines) {
        if ([string]$line -match '^\s*([^=]+?)\s*=') { [void]$keys.Add($Matches[1].Trim()) }
    }
    return $keys
}

function Get-SectionNames([object]$Ini, [string]$Pattern) {
    $names = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Ini -or $null -eq $Ini.Sections) { return $names }
    foreach ($name in $Ini.Sections.Keys) {
        if ($name -match $Pattern) { [void]$names.Add($name) }
    }
    return $names
}

function Get-Number([string]$Value, [string]$Description, [double]$Min = [double]::NegativeInfinity, [double]$Max = [double]::PositiveInfinity) {
    $number = 0.0
    $parsed = $false
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $parsed = [double]::TryParse($Value.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)
    }
    if (-not $parsed -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        Add-Failure "$Description must be a finite number; found '$Value'."
        return $null
    }
    if ($number -lt $Min -or $number -gt $Max) { Add-Failure "$Description is outside [$Min,$Max]: '$Value'." }
    return $number
}

function Get-Integer([string]$Value, [string]$Description, [int]$Min = [int]::MinValue, [int]$Max = [int]::MaxValue) {
    $number = 0
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [int]::TryParse($Value.Trim(), [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        Add-Failure "$Description must be an integer; found '$Value'."
        return $null
    }
    if ($number -lt $Min -or $number -gt $Max) { Add-Failure "$Description is outside [$Min,$Max]: '$Value'." }
    return $number
}

function Test-Boolean([string]$Value, [string]$Description) {
    if ($Value -notmatch '^(?i:true|false)$') {
        Add-Failure "$Description must be True or False; found '$Value'."
        return $false
    }
    return $true
}

function Get-NumericVector([string]$Value, [string]$Description) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        Add-Failure "$Description must contain three finite coordinates."
        return $null
    }
    $parts = @($Value.Trim() -split ',')
    if ($parts.Count -ne 3) {
        Add-Failure "$Description must contain three comma-separated coordinates; found '$Value'."
        return $null
    }
    $numbers = [double[]]::new(3)
    for ($i = 0; $i -lt 3; $i++) {
        $number = 0.0
        if (-not [double]::TryParse($parts[$i].Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            Add-Failure "$Description contains a non-finite coordinate; found '$Value'."
            return $null
        }
        $numbers[$i] = $number
    }
    return $numbers
}

function Get-RelativeVector([string]$Value, [string]$Description) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        Add-Failure "$Description must contain three coordinates."
        return $null
    }
    $parts = @($Value.Trim() -split ',')
    if ($parts.Count -ne 3) {
        Add-Failure "$Description must contain three comma-separated coordinates; found '$Value'."
        return $null
    }
    $coordinates = [double[]]::new(2)
    foreach ($index in @(0, 2)) {
        $number = 0.0
        if (-not [double]::TryParse($parts[$index].Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            Add-Failure "$Description has a non-finite horizontal coordinate; found '$Value'."
            return $null
        }
        $coordinateIndex = if ($index -eq 0) { 0 } else { 1 }
        $coordinates[$coordinateIndex] = $number
    }
    $depth = $parts[1].Trim()
    if ([string]::IsNullOrWhiteSpace($depth)) {
        Add-Failure "$Description has an empty depth coordinate."
        return $null
    }
    if ($depth -match '^(?i)[+-]?(?:NaN|Infinity)$') {
        Add-Failure "$Description has a non-finite depth coordinate; found '$Value'."
        return $null
    }
    $depthNumber = 0.0
    if ([double]::TryParse($depth, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$depthNumber) -and ([double]::IsNaN($depthNumber) -or [double]::IsInfinity($depthNumber))) {
        Add-Failure "$Description has a non-finite depth coordinate; found '$Value'."
        return $null
    }
    return $coordinates
}

function Get-ReferencedNames([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split '[,|]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-XmlDocument([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $raw = Get-Content -Raw -LiteralPath $Path
        $hasReplacement = $raw.Contains([string][char]0xFFFD)
        if ($hasReplacement) { Add-Failure "$Description contains U+FFFD: $Path" }
        $document = [System.Xml.XmlDocument]::new()
        $document.PreserveWhitespace = $true
        $document.XmlResolver = $null
        $document.LoadXml($raw)
        if (-not $hasReplacement -and $document.DocumentElement.InnerText.Contains([string][char]0xFFFD)) {
            Add-Failure "$Description contains U+FFFD: $Path"
        }
        return $document
    } catch {
        Add-Failure "Invalid XML for $Description`: $Path ($($_.Exception.Message))"
        return $null
    }
}

function Test-XamlDocument([System.Xml.XmlDocument]$Document, [string]$Path, [string]$Description, [string]$RootName) {
    if ($null -eq $Document -or $null -eq $Document.DocumentElement) { return $false }
    $root = $Document.DocumentElement
    $presentationNamespace = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
    $xamlNamespace = 'http://schemas.microsoft.com/winfx/2006/xaml'
    $valid = $true
    if ($root.LocalName -ne $RootName) { Add-Failure "$Description must use <$RootName> as its root: $Path"; $valid = $false }
    if ($root.NamespaceURI -ne $presentationNamespace) { Add-Failure "$Description has the wrong presentation namespace: $Path"; $valid = $false }
    if ($root.GetNamespaceOfPrefix('x') -ne $xamlNamespace -or $root.GetAttribute('xmlns:x') -ne $xamlNamespace) {
        Add-Failure "$Description must declare xmlns:x=${xamlNamespace}: $Path"
        $valid = $false
    }
    return $valid
}

function Get-XmlText([System.Xml.XmlDocument]$Document) {
    if ($null -eq $Document -or $null -eq $Document.DocumentElement) { return '' }
    return [regex]::Replace($Document.DocumentElement.InnerText, '\s+', ' ').Trim()
}

function Test-ContiguousSections([object]$Ini, [string]$PrefixPattern, [int]$ExpectedCount, [string]$Description) {
    $numbers = [System.Collections.Generic.List[int]]::new()
    $pattern = '^' + $PrefixPattern + '(\d+)$'
    foreach ($name in $Ini.Sections.Keys) {
        if ($name -match $pattern) { [void]$numbers.Add([int]$Matches[1]) }
    }
    $unique = @($numbers | Sort-Object -Unique)
    if ($numbers.Count -ne $unique.Count) { Add-Failure "$Description contains duplicate section indices." }
    if ($unique.Count -ne $ExpectedCount) { Add-Failure "$Description declares $ExpectedCount but contains $($unique.Count) slot(s)." }
    for ($index = 1; $index -le $ExpectedCount; $index++) {
        if ($index -notin $unique) { Add-Failure "$Description is missing contiguous slot $index." }
    }
}

function Get-UnitSectionPattern([string]$Key) {
    switch -Regex ($Key) {
        '^NumberOfTaskforce(\d+)Submarines$' { return '^Taskforce' + $Matches[1] + 'Submarine' }
        '^NumberOfTaskforce(\d+)Vessels$' { return '^Taskforce' + $Matches[1] + 'Vessel' }
        '^NumberOfTaskforce(\d+)Aircraft$' { return '^Taskforce' + $Matches[1] + 'Aircraft' }
        '^NumberOfTaskforce(\d+)LandUnits$' { return '^Taskforce' + $Matches[1] + 'LandUnit' }
        '^NumberOfNeutralVessels$' { return '^NeutralVessel' }
        '^NumberOfNeutralBiologics$' { return '^NeutralBiologic' }
        default { return $null }
    }
}

function Get-UnitSectionNames([object]$Ini) {
    return @(Get-SectionNames $Ini '^(?:Taskforce\d+(?:Submarine|Vessel|Aircraft|LandUnit)|Neutral(?:Vessel|Biologic))\d+$')
}

function Get-UnitTokens([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $pattern = '(?<![A-Za-z0-9_])(?:Taskforce\d+(?:Submarine|Vessel|Aircraft|LandUnit)\d+|Neutral(?:Vessel|Biologic)\d+)(?![A-Za-z0-9_])'
    return @([regex]::Matches($Text, $pattern) | ForEach-Object { $_.Value })
}

function Get-MissionSequenceNumber([string]$Sequence) {
    $pattern = $mainSequencePattern
    $match = [regex]::Match($Sequence, '(?i)' + $pattern + '\s*$')
    if ($match.Success) { return [int]$match.Groups[1].Value }
    return $null
}

function Is-OptionalMission([object]$Record) {
    if ($null -eq $Record) { return $false }
    $pattern = [string](Get-ManifestValue $missionRules 'optionalStemPattern' '^(?i)o\d')
    return ($Record.Sequence -match '(?i)OPTIONAL' -or $Record.Optional -or $Record.Stem -match $pattern)
}

$repo = $manifest.RepoRoot
$campaignRoot = $manifest.CampaignRoot
$campaignPath = $manifest.CampaignIni
$campaignsRoot = $manifest.CampaignsRoot
$locales = @($manifest.Locales)
$requiredBriefingHeadings = Get-ManifestMap $manifest.Briefing 'requiredHeadings'
$validation = $manifest.Validation
$campaignRules = Get-ManifestMap $validation 'campaign'
$missionRules = Get-ManifestMap $validation 'missions'
$operationRules = Get-ManifestMap $validation 'operations'
$unitRules = Get-ManifestMap $validation 'units'
$environmentRules = Get-ManifestMap $validation 'environment'
$variableRules = Get-ManifestMap $validation 'variables'
$inventoryRules = Get-ManifestMap $validation 'inventory'
$expectedMissionCount = [int](Get-ManifestValue $campaignRules 'missionCount' 0)
$campaignType = [string](Get-ManifestValue $campaignRules 'type' 'Linear')
$campaignLength = [string](Get-ManifestValue $campaignRules 'length' '')
$missionSectionCount = [string](Get-ManifestValue $campaignRules 'numberOfMissions' '')
$playerTaskforceName = [string](Get-ManifestValue $unitRules 'playerTaskforce' 'Taskforce1')
$enemyTaskforceName = [string](Get-ManifestValue $unitRules 'enemyTaskforce' 'Taskforce2')
$playerUnitPrefix = [string](Get-ManifestValue $unitRules 'playerUnitPrefix' ($playerTaskforceName))
$enemyUnitPrefix = [string](Get-ManifestValue $unitRules 'enemyUnitPrefix' ($enemyTaskforceName))
$playerSubmarinePattern = [string](Get-ManifestValue $unitRules 'playerSubmarinePattern' '^Taskforce1Submarine\d+$')
$playerSubmarineTypePattern = [string](Get-ManifestValue $unitRules 'playerSubmarineTypePattern' '^(?i)usn_')
$playerDeploymentZone = [string](Get-ManifestValue $unitRules 'playerDeploymentZone' 'Zone_PlayerDeployment')
$playerObjectivesSection = [string](Get-ManifestValue $unitRules 'playerObjectivesSection' ($playerTaskforceName + '_Objectives'))
$dynamicRosterKey = [string](Get-ManifestValue $unitRules 'dynamicRosterKey' 'Taskforce2RosterFile')
$dynamicFormationPrefix = [string](Get-ManifestValue $unitRules 'formationPrefix' 'Formation_')
$replenishSequences = @(Get-ManifestList $unitRules 'replenishSequences')
$persistentSlotRules = @(Get-ManifestList $unitRules 'persistentSlotRules')
$variablePattern = [string](Get-ManifestValue $variableRules 'namePattern' '^[A-Za-z][A-Za-z0-9_]*$')
$minimumDynamicUnits = [int](Get-ManifestValue $unitRules 'dynamicAnchorMinUnits' 1)
$maximumDynamicUnits = [int](Get-ManifestValue $unitRules 'dynamicAnchorMaxUnits' 1)
$mainSequencePattern = [string](Get-ManifestValue $missionRules 'mainSequencePattern' '^MISSION\s+(\d+)$')
$optionalSequencePattern = [string](Get-ManifestValue $missionRules 'optionalSequencePattern' '^OPTIONAL\s+(\d+)$')
$briefingPathPattern = [string](Get-ManifestValue $manifest.Briefing 'pathPattern' 'campaigns/{campaignId}/missions/{stem}_briefing/BriefingText_{locale}.xml')

if (-not (Require-File $campaignPath 'campaign definition')) { exit 1 }
if (-not (Require-File $manifest.MetadataPath 'mod metadata')) { exit 1 }
$enemyRosterValue = [string](Get-ManifestValue $validation 'enemyRoster' '')
$enemyRosterPath = if ($enemyRosterValue) { Resolve-ManifestPath $enemyRosterValue $manifest.ManifestDirectory $repo } else { Join-Path $campaignRoot 'enemy_theater_roster.ini' }
$enemyRosterIni = if ($null -ne $enemyRosterPath -and (Require-File $enemyRosterPath 'enemy DUG roster')) { Read-IniFile $enemyRosterPath } else { $null }
$formationDefinitions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($formationSection in (Get-SectionNames $enemyRosterIni ([string](Get-ManifestValue $unitRules 'formationSectionPattern' '^Formation_.+')))) {
    $formationPrefix = [string](Get-ManifestValue $unitRules 'formationPrefix' 'Formation_')
    [void]$formationDefinitions.Add($formationSection.Substring($formationPrefix.Length))
}

foreach ($obsoleteFile in (Get-ManifestList $campaignRules 'obsoleteFiles')) {
    $obsoletePath = Join-Path $campaignRoot $obsoleteFile
    if (Test-Path -LiteralPath $obsoletePath -PathType Leaf) { Add-Failure "Obsolete Task Force file remains: $obsoletePath" }
}

$campaignIni = Read-IniFile $campaignPath
foreach ($duplicate in $campaignIni.DuplicateSections) { Add-Failure "campaign.ini repeats section [$duplicate]." }
$campaign = $campaignIni.Sections['Campaign']
$missionsSection = $campaignIni.Sections['Missions']
if ($null -eq $campaign) { Add-Failure 'campaign.ini is missing [Campaign].' }
if ($null -eq $missionsSection) { Add-Failure 'campaign.ini is missing [Missions].' }
if ((Get-IniValue $campaign 'Type') -ne $campaignType) { Add-Failure "Campaign Type must be $campaignType." }
if ($campaignLength -and (Get-IniValue $campaign 'Length') -ne $campaignLength) { Add-Failure "Campaign Length must be $campaignLength." }
if ($missionSectionCount -and (Get-IniValue $missionsSection 'NumberOfMissions') -ne $missionSectionCount) { Add-Failure "Campaign NumberOfMissions must be $missionSectionCount." }
$forbiddenCampaignKeys = @(Get-ManifestList $campaignRules 'forbiddenKeys')
foreach ($forbiddenKey in $forbiddenCampaignKeys) {
    if ($campaignIni.Sections.Contains([string]$forbiddenKey) -or $campaignIni.Text -match ('(?im)^\s*' + [regex]::Escape([string]$forbiddenKey) + '(?:=|\s*$)')) { Add-Failure "Campaign must not define $forbiddenKey." }
}

foreach ($locale in $locales) {
    $language = $campaignIni.Sections["Language_$locale"]
    if ($null -eq $language) { Add-Failure "Campaign is missing Language_$locale."; continue }
    foreach ($key in @('Name','Description')) {
        if ([string]::IsNullOrWhiteSpace((Get-IniValue $language $key))) { Add-Failure "Campaign Language_$locale is missing $key." }
    }
}

$missionRecords = [System.Collections.Generic.List[object]]::new()
foreach ($sectionName in (Get-SectionNames $campaignIni '^Mission\d+$')) {
    $number = [int]([regex]::Match($sectionName, '\d+').Value)
    $block = $campaignIni.Sections[$sectionName]
    $type = Get-IniValue $block 'Type'
    $sequence = Get-IniValue $block 'MissionSequenceName_en'
    $fileValue = Get-IniValue $block 'MissionFile'
    $optional = ($sequence -match '(?i)OPTIONAL' -or $fileValue -match '(?i)(^|[\\/])O\d')
    [void]$missionRecords.Add([pscustomobject]@{
        Id = $number
        Section = $sectionName
        Block = $block
        Type = $type
        Sequence = $sequence
        Optional = $optional
        Stem = if ($fileValue) { [System.IO.Path]::GetFileNameWithoutExtension($fileValue.Replace('/', '\')) } else { '' }
        MissionFileValue = $fileValue
        MissionFile = $null
    })
}
$missionRecords = @($missionRecords | Sort-Object Id)
if ($expectedMissionCount -gt 0 -and $missionRecords.Count -ne $expectedMissionCount) { Add-Failure "Campaign must contain $expectedMissionCount Mission sections; found $($missionRecords.Count)." }
for ($id = 1; $id -le $expectedMissionCount; $id++) {
    if (-not ($missionRecords | Where-Object Id -eq $id)) { Add-Failure "Campaign is missing Mission$id." }
}

$recordById = @{}
foreach ($record in $missionRecords) {
    if ($recordById.ContainsKey($record.Id)) { Add-Failure "Campaign repeats Mission$($record.Id)." } else { $recordById[$record.Id] = $record }
}

$parentsById = @{}
$expiryById = @{}
foreach ($record in $missionRecords) {
    $parents = @(Get-ReferencedNames (Get-IniValue $record.Block 'Parents'))
    $parentIds = [System.Collections.Generic.List[int]]::new()
    foreach ($parent in $parents) {
        $parentId = Get-Integer $parent "Mission$($record.Id) parent" 1 $expectedMissionCount
        if ($null -ne $parentId) { [void]$parentIds.Add($parentId) }
    }
    $parentsById[$record.Id] = @($parentIds)
    $expiry = Get-IniValue $record.Block 'ExpiresAfterMissionComplete'
    if (-not [string]::IsNullOrWhiteSpace($expiry)) {
        $expiryId = Get-Integer $expiry "Mission$($record.Id) expiry" 1 $expectedMissionCount
        if ($null -ne $expiryId) {
            $expiryById[$record.Id] = $expiryId
            if ($expiryId -eq $record.Id) { Add-Failure "Mission$($record.Id) expiry cannot reference itself." }
            if (-not $recordById.ContainsKey($expiryId)) { Add-Failure "Mission$($record.Id) expiry references missing Mission$expiryId." }
        }
    } elseif ($record.Type -eq 'Mission' -and (Is-OptionalMission $record)) {
        Add-Failure "Optional Mission$($record.Id) must declare ExpiresAfterMissionComplete."
    }
    foreach ($parentId in $parentIds) {
        if (-not $recordById.ContainsKey($parentId)) { Add-Failure "Mission$($record.Id) parent references missing Mission$parentId." }
        if ($parentId -eq $record.Id) { Add-Failure "Mission$($record.Id) cannot parent itself." }
    }
}

function Visit-CampaignNode([int]$Id, [hashtable]$Graph, [hashtable]$State) {
    if ($State.ContainsKey($Id) -and $State[$Id] -eq 1) { Add-Failure "Campaign parent graph contains a cycle at Mission$Id."; return }
    if ($State.ContainsKey($Id) -and $State[$Id] -eq 2) { return }
    $State[$Id] = 1
    foreach ($parent in @($Graph[$Id])) {
        if ($Graph.ContainsKey($parent)) { Visit-CampaignNode $parent $Graph $State }
    }
    $State[$Id] = 2
}
$visitState = @{}
foreach ($record in $missionRecords) { Visit-CampaignNode $record.Id $parentsById $visitState }

function Test-OptionalAncestor([int]$Id, [hashtable]$Graph, [hashtable]$Optional, [hashtable]$Memo, [hashtable]$Path) {
    if ($Memo.ContainsKey($Id)) { return [bool]$Memo[$Id] }
    if ($Path.ContainsKey($Id)) { return $false }
    $Path[$Id] = $true
    foreach ($parent in @($Graph[$Id])) {
        if ($Optional.ContainsKey($parent) -and $Optional[$parent]) { $Memo[$Id] = $true; [void]$Path.Remove($Id); return $true }
        if ($Graph.ContainsKey($parent) -and (Test-OptionalAncestor $parent $Graph $Optional $Memo $Path)) { $Memo[$Id] = $true; [void]$Path.Remove($Id); return $true }
    }
    [void]$Path.Remove($Id)
    $Memo[$Id] = $false
    return $false
}
$optionalById = @{}
foreach ($record in $missionRecords) { $optionalById[$record.Id] = (Is-OptionalMission $record) }
$optionalMemo = @{}
foreach ($record in $missionRecords) {
    if ($record.Type -eq 'Mission' -and -not $optionalById[$record.Id] -and (Test-OptionalAncestor $record.Id $parentsById $optionalById $optionalMemo @{})) {
        Add-Failure "Main Mission$($record.Id) is gated by an optional mission ancestor."
    }
}

$selectedRecords = @($missionRecords | Where-Object {
    $modeRules = if ($VerticalSlice) { Get-ManifestMap $validation 'verticalSlice' } elseif ($Implemented) { Get-ManifestMap $validation 'implemented' } else { $null }
    if ($null -ne $modeRules) {
        $ids = @(Get-ManifestList $modeRules 'missionIds')
        if ($ids.Count -gt 0) { $_.Id -in $ids } else { $_.Type -eq 'Mission' }
    } else { $true }
})

$eventCount = 0
$operationCount = 0
$eventBodyByText = @{}
$eventAssetPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$eventReferencedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$operationReferencedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$briefingAssetPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($record in $selectedRecords) {
    if ($record.Type -notin @('Mission','FreeEvent')) { Add-Failure "Mission$($record.Id) has unsupported Type=$($record.Type)."; continue }
    if ($record.Type -eq 'FreeEvent') {
        $eventCount++
        foreach ($locale in $locales) {
            if ([string]::IsNullOrWhiteSpace((Get-IniValue $record.Block "Name_$locale"))) { Add-Failure "Mission$($record.Id) event is missing Name_$locale." }
            $eventValue = Get-IniValue $record.Block "FilePath_$locale"
            if ([string]::IsNullOrWhiteSpace($eventValue)) { Add-Failure "Mission$($record.Id) event is missing FilePath_$locale."; continue }
            $eventPath = Convert-CampaignPath $eventValue $repo
            if ($null -eq $eventPath) { Add-Failure "Mission$($record.Id) event $locale has an invalid campaign path."; continue }
            if (Require-File $eventPath "Mission$($record.Id) event $locale") {
                [void]$eventReferencedFiles.Add($eventPath)
                $eventDocument = Get-XmlDocument $eventPath "Mission$($record.Id) event $locale"
                [void](Test-XamlDocument $eventDocument $eventPath "Mission$($record.Id) event $locale" 'Page')
                if ($locale -eq 'en' -and $null -ne $eventDocument) {
                    $body = Get-XmlText $eventDocument
                    if ([string]::IsNullOrWhiteSpace($body)) { Add-Failure "Mission$($record.Id) English event body is empty: $eventPath" }
                    elseif ($eventBodyByText.ContainsKey($body)) { Add-Failure "Mission$($record.Id) duplicates the English event body used by Mission$($eventBodyByText[$body]): $eventPath" }
                    else { $eventBodyByText[$body] = $record.Id }
                }
            }
            $assetsValue = Get-IniValue $record.Block "AssetsPath_$locale"
            if ([string]::IsNullOrWhiteSpace($assetsValue)) { Add-Failure "Mission$($record.Id) event is missing AssetsPath_$locale." }
            else {
                $assetsPath = Convert-CampaignPath $assetsValue $repo
                if ($null -eq $assetsPath) { Add-Failure "Mission$($record.Id) event $locale has an invalid assets campaign path." }
                elseif (-not (Test-Path -LiteralPath $assetsPath -PathType Container)) { Add-Failure "Missing Mission$($record.Id) event $locale assets directory: $assetsPath" }
                else { [void]$eventAssetPaths.Add($assetsPath) }
            }
        }
        continue
    }

    $operationCount++
    if ([string]::IsNullOrWhiteSpace($record.MissionFileValue)) { Add-Failure "Mission$($record.Id) has no MissionFile."; continue }
    $missionPath = Convert-CampaignPath $record.MissionFileValue $repo
    $record.MissionFile = $missionPath
    if ($null -eq $missionPath) { Add-Failure "Mission$($record.Id) has an invalid MissionFile path."; continue }
    [void]$operationReferencedFiles.Add($missionPath)
    if (-not (Require-File $missionPath "Mission$($record.Id) definition")) { continue }
}

$allMissionFiles = @()
$missionDirectory = Join-Path $campaignRoot 'missions'
if (Test-Path -LiteralPath $missionDirectory -PathType Container) {
    $allMissionFiles = @(Get-ChildItem -LiteralPath $missionDirectory -Filter '*.ini' -File | Sort-Object Name)
} else { Add-Failure "Missing authored missions directory: $missionDirectory" }

# Every authored mission INI carries one briefing reference per configured locale.
# This deliberately scans the directory as well as campaign.ini references so
# an orphaned or newly-added operation cannot bypass the locale check.
$operationInfos = [System.Collections.Generic.List[object]]::new()
foreach ($file in $allMissionFiles) {
    $ini = Read-IniFile $file.FullName
    foreach ($duplicate in $ini.DuplicateSections) { Add-Failure "$($file.Name) repeats section [$duplicate]." }
    $stem = $file.BaseName
    $campaignRecord = $missionRecords | Where-Object { $_.Type -eq 'Mission' -and $_.Stem -eq $stem } | Select-Object -First 1
    $sequence = if ($null -ne $campaignRecord) { $campaignRecord.Sequence } else { '' }
    $optionalStemPattern = [string](Get-ManifestValue $missionRules 'optionalStemPattern' '^(?i)o\d')
    $optional = if ($null -ne $campaignRecord) { Is-OptionalMission $campaignRecord } else { $stem -match $optionalStemPattern }
    [void]$operationInfos.Add([pscustomobject]@{ File = $file; Ini = $ini; Stem = $stem; Record = $campaignRecord; Sequence = $sequence; Optional = $optional })

    foreach ($locale in $locales) {
        $language = $ini.Sections["Language_$locale"]
        if ($null -eq $language) { Add-Failure "$stem is missing Language_$locale."; continue }
        foreach ($key in @('Name','Description','MissionBriefingLeftPane')) {
            if ([string]::IsNullOrWhiteSpace((Get-IniValue $language $key))) { Add-Failure "$stem Language_$locale is missing $key." }
        }
        $briefingValue = Get-IniValue $language 'MissionBriefingLeftPane'
        if ([string]::IsNullOrWhiteSpace($briefingValue)) { continue }
        $expected = Expand-CampaignPathPattern $briefingPathPattern $manifest.CampaignId $stem $locale
        if ($briefingValue.Replace('\\', '/') -ine $expected.Replace('\\', '/')) { Add-Failure "$stem briefing for $locale references an unexpected operation or locale." }
        $briefingPath = Convert-CampaignPath $briefingValue $repo
        if ($null -eq $briefingPath) { Add-Failure "$stem briefing for $locale has an invalid campaign path."; continue }
        if (-not (Require-File $briefingPath "$stem briefing $locale")) { continue }
        [void]$briefingAssetPaths.Add($briefingPath)
        $briefingDocument = Get-XmlDocument $briefingPath "$stem $locale briefing"
        if ($null -eq $briefingDocument) { continue }
        [void](Test-XamlDocument $briefingDocument $briefingPath "$stem $locale briefing" 'Grid')
        $briefingBody = $briefingDocument.DocumentElement.InnerText
        foreach ($heading in $requiredBriefingHeadings[$locale]) {
            if ($briefingBody -notmatch ('(?im)^\s*' + [regex]::Escape($heading) + '\s*$')) { Add-Failure "$stem $locale briefing is missing military-sim section '$heading'." }
        }
    }
    $briefingDirectory = Join-Path $missionDirectory ($stem + '_briefing')
    if (-not (Test-Path -LiteralPath $briefingDirectory -PathType Container)) {
        Add-Failure "Missing briefing directory for $stem`: $briefingDirectory"
    } else {
        $briefingFiles = @(Get-ChildItem -LiteralPath $briefingDirectory -Filter 'BriefingText_*.xml' -File)
        if ($briefingFiles.Count -ne $locales.Count) { Add-Failure "$stem briefing directory must contain $($locales.Count) locale assets; found $($briefingFiles.Count)." }
        foreach ($locale in $locales) {
            $expectedPath = Join-Path $briefingDirectory ('BriefingText_' + $locale + '.xml')
            if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) { Add-Failure "$stem briefing directory is missing BriefingText_$locale.xml." }
        }
    }
}

$defaultCounts = Get-ManifestMap $operationRules 'defaultCounts'
$selectedCountRules = if ($VerticalSlice) { Get-ManifestMap $operationRules 'verticalSlice' } elseif ($Implemented) { Get-ManifestMap $operationRules 'implemented' } else { $defaultCounts }
$expectedEventCount = [int](Get-ManifestValue $selectedCountRules 'eventCount' 0)
$expectedOperationCount = [int](Get-ManifestValue $selectedCountRules 'operationCount' 0)
if ($expectedEventCount -gt 0 -and $eventCount -ne $expectedEventCount) { Add-Failure "Expected $expectedEventCount timeline events, found $eventCount." }
if ($expectedOperationCount -gt 0 -and $operationCount -ne $expectedOperationCount) { Add-Failure "Expected $expectedOperationCount operations, found $operationCount." }
if (-not ($VerticalSlice -or $Implemented)) {
    $expectedBriefingAssets = [int](Get-ManifestValue $selectedCountRules 'briefingAssetCount' ($operationCount * $locales.Count))
    $expectedEventAssets = [int](Get-ManifestValue $selectedCountRules 'eventAssetCount' ($eventCount * $locales.Count))
    if ($expectedBriefingAssets -gt 0 -and $briefingAssetPaths.Count -ne $expectedBriefingAssets) { Add-Failure "Expected $expectedBriefingAssets briefing assets, found $($briefingAssetPaths.Count)." }
    if ($expectedEventAssets -gt 0 -and $eventReferencedFiles.Count -ne $expectedEventAssets) { Add-Failure "Expected $expectedEventAssets event assets, found $($eventReferencedFiles.Count)." }
}

$persistentByIndex = @{}
function Get-ExpectedPersistentSlots([int]$SequenceNumber) {
    foreach ($rule in $persistentSlotRules) {
        $through = Get-ManifestValue $rule 'through'
        $slots = Get-ManifestValue $rule 'slots'
        if ($null -ne $through -and $SequenceNumber -le [int]$through) { return [int]$slots }
    }
    return $null
}
$mainOperations = @($operationInfos | Where-Object { $null -ne $_.Record -and -not $_.Optional } | Sort-Object { Get-MissionSequenceNumber $_.Sequence })
$optionalOperations = @($operationInfos | Where-Object { $null -ne $_.Record -and $_.Optional } | Sort-Object { Get-MissionSequenceNumber $_.Sequence })
$targetReferencesByFile = @{}

foreach ($info in $operationInfos) {
    $file = $info.File
    $ini = $info.Ini
    $text = $ini.Text
    $missionLabel = if ($null -ne $info.Record) { "Mission$($info.Record.Id)" } else { $info.Stem }
    $mission = $ini.Sections['Mission']
    if ($null -eq $mission) { Add-Failure "$missionLabel has no [Mission] section."; continue }
    foreach ($key in @('Difficulty','PlayerTaskforce','EnemyTaskforce')) {
        if ([string]::IsNullOrWhiteSpace((Get-IniValue $mission $key))) { Add-Failure "$missionLabel [Mission] is missing $key." }
    }
    if ((Get-IniValue $mission 'PlayerTaskforce') -ne $playerTaskforceName) { Add-Failure "$missionLabel PlayerTaskforce must be $playerTaskforceName." }
    if ((Get-IniValue $mission 'EnemyTaskforce') -ne $enemyTaskforceName) { Add-Failure "$missionLabel EnemyTaskforce must be $enemyTaskforceName." }

    $unitNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($unitName in (Get-UnitSectionNames $ini)) { [void]$unitNames.Add($unitName) }
    $unitsByName = @{}
    foreach ($unitName in $unitNames) { $unitsByName[$unitName] = $ini.Sections[$unitName] }
    if (-not ($unitNames | Where-Object { $_ -match $playerSubmarinePattern })) { Add-Failure "$missionLabel has no player submarine slot." }
    $nonSubmarinePlayerPattern = '^' + [regex]::Escape($playerUnitPrefix) + '(?:Vessel|Aircraft|LandUnit)\d+$'
    if ($unitNames | Where-Object { $_ -match $nonSubmarinePlayerPattern }) { Add-Failure "$missionLabel exposes a non-submarine player slot." }

    $dynamicUnitNames = @($unitNames | Where-Object { (Get-IniValue $unitsByName[$_] 'DynamicGenerationSlot') -match '^(?i:true)$' })
    if ($dynamicUnitNames.Count -gt 0) {
        $dynamicGeneration = $ini.Sections['DynamicUnitGeneration']
        $rosterValue = if ($null -ne $dynamicGeneration) { Get-IniValue $dynamicGeneration $dynamicRosterKey } else { $null }
        if ([string]::IsNullOrWhiteSpace($rosterValue)) {
            Add-Failure "$missionLabel dynamic generation is missing $dynamicRosterKey."
        } else {
            $rosterPath = Convert-MissionRelativePath $rosterValue $file.DirectoryName $campaignRoot
            if ($null -eq $rosterPath) {
                Add-Failure "$missionLabel has an invalid $dynamicRosterKey path: '$rosterValue'."
            } else {
                [void](Require-File $rosterPath "$missionLabel dynamic roster")
            }
        }
    }

    foreach ($countLine in $mission) {
        if ([string]$countLine -match '^\s*(NumberOf(?:Taskforce\d+(?:Submarines|Vessels|Aircraft|LandUnits)|Neutral(?:Vessels|Biologics)))\s*=\s*(.*)$') {
            $countKey = $Matches[1]
            $count = Get-Integer $Matches[2] "$missionLabel $countKey" 0 999
            if ($null -ne $count) {
                $prefix = Get-UnitSectionPattern $countKey
                if ($null -ne $prefix) { Test-ContiguousSections $ini $prefix $count "$missionLabel $countKey sections" }
            }
        }
    }
    $unitKinds = @(Get-ManifestList $unitRules 'unitKinds' @('Submarine','Vessel','Aircraft','LandUnit'))
    $unitGroups = [System.Collections.Generic.List[object]]::new()
    foreach ($taskforce in @($playerUnitPrefix, $enemyUnitPrefix)) {
        foreach ($kind in $unitKinds) {
            $plural = if ([string]$kind -eq 'Biologic') { 'Biologics' } elseif ([string]$kind -match 's$') { [string]$kind } else { [string]$kind + 's' }
            [void]$unitGroups.Add(@{ Prefix = '^' + [regex]::Escape($taskforce) + [string]$kind; Key = 'NumberOf' + $taskforce + $plural })
        }
    }
    foreach ($neutralKind in (Get-ManifestList $unitRules 'neutralUnitKinds' @('Vessel','Biologic'))) {
        $plural = if ([string]$neutralKind -eq 'Biologic') { 'Biologics' } else { [string]$neutralKind + 's' }
        [void]$unitGroups.Add(@{ Prefix = '^Neutral' + [string]$neutralKind; Key = 'NumberOfNeutral' + $plural })
    }
    foreach ($unitGroup in $unitGroups) {
        $actual = @($unitNames | Where-Object { $_ -match ($unitGroup.Prefix + '\d+$') }).Count
        $declared = Get-IniValue $mission $unitGroup.Key
        if ($actual -gt 0 -and [string]::IsNullOrWhiteSpace($declared)) { Add-Failure "$missionLabel has $actual $($unitGroup.Key) slot(s) but no declaration." }
    }

    $objectiveSection = $ini.Sections[$playerObjectivesSection]
    if ($null -eq $objectiveSection) { Add-Failure "$missionLabel has no $playerObjectivesSection section." }
    $objectiveNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in (Get-IniKeys $objectiveSection)) { [void]$objectiveNames.Add($key) }
    if ($null -eq $ini.Sections['Zones']) { Add-Failure "$missionLabel has no Zones section." }
    if ($null -eq $ini.Sections[$playerDeploymentZone]) { Add-Failure "$missionLabel has no player deployment zone." }

    $zones = $ini.Sections['Zones']
    $zoneNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $zones) {
        $zoneCount = Get-Integer (Get-IniValue $zones 'NumberOfZones') "$missionLabel NumberOfZones" 0 999
        if ($null -ne $zoneCount) {
            $declaredZoneValues = [System.Collections.Generic.List[string]]::new()
            foreach ($line in $zones) {
                if ([string]$line -match '^Zone(\d+)\s*=\s*(.+)$') {
                    [void]$declaredZoneValues.Add($Matches[2].Trim())
                    [void]$zoneNames.Add($Matches[2].Trim())
                }
            }
            if ($declaredZoneValues.Count -ne $zoneCount) { Add-Failure "$missionLabel Zones declares $zoneCount but has $($declaredZoneValues.Count) ZoneN entries." }
            for ($index = 1; $index -le $zoneCount; $index++) {
                if (-not ($zones | Where-Object { [string]$_ -match ('^Zone' + $index + '\s*=') })) { Add-Failure "$missionLabel Zones is missing contiguous Zone$index declaration." }
            }
            $actualZoneSections = @(Get-SectionNames $ini '^Zone_.+')
            if ($actualZoneSections.Count -ne $zoneCount) { Add-Failure "$missionLabel declares $zoneCount zones but defines $($actualZoneSections.Count) zone sections." }
            foreach ($zoneName in $zoneNames) {
                if (-not $ini.Sections.Contains($zoneName)) { Add-Failure "$missionLabel references missing zone section [$zoneName]." }
            }
            foreach ($zoneName in $actualZoneSections) {
                $zone = $ini.Sections[$zoneName]
                foreach ($key in @('Type','Shape')) { if ([string]::IsNullOrWhiteSpace((Get-IniValue $zone $key))) { Add-Failure "$missionLabel [$zoneName] is missing $key." } }
                if ($null -ne (Get-IniValue $zone 'LockPosition')) { [void](Test-Boolean (Get-IniValue $zone 'LockPosition') "$missionLabel [$zoneName] LockPosition") }
            }
        }
    }

    $mapSymbols = $ini.Sections['MapSymbols']
    $mapSymbolNames = @(Get-SectionNames $ini '^MapSymbol_.+')
    $symbolByLabel = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $mapSymbols) {
        $symbolCount = Get-Integer (Get-IniValue $mapSymbols 'NumberOfSymbols') "$missionLabel NumberOfSymbols" 0 999
        if ($null -ne $symbolCount) {
            $declaredSymbols = [System.Collections.Generic.List[string]]::new()
            foreach ($line in $mapSymbols) {
                if ([string]$line -match '^Symbol(\d+)\s*=\s*(.+)$') { [void]$declaredSymbols.Add($Matches[2].Trim()) }
            }
            if ($declaredSymbols.Count -ne $symbolCount) { Add-Failure "$missionLabel MapSymbols declares $symbolCount but has $($declaredSymbols.Count) SymbolN entries." }
            if ($mapSymbolNames.Count -ne $symbolCount) { Add-Failure "$missionLabel declares $symbolCount symbols but defines $($mapSymbolNames.Count) map symbol sections." }
            for ($index = 1; $index -le $symbolCount; $index++) {
                if (-not ($mapSymbols | Where-Object { [string]$_ -match ('^Symbol' + $index + '\s*=') })) { Add-Failure "$missionLabel MapSymbols is missing contiguous Symbol$index declaration." }
            }
            foreach ($symbolName in $declaredSymbols) {
                if (-not $ini.Sections.Contains($symbolName)) { Add-Failure "$missionLabel references missing map symbol [$symbolName]." }
            }
        }
    } elseif ($mapSymbolNames.Count -gt 0) { Add-Failure "$missionLabel defines map symbols without [MapSymbols]." }
    foreach ($symbolName in $mapSymbolNames) {
        $symbol = $ini.Sections[$symbolName]
        $labelKey = Get-IniValue $symbol 'LabelKey'
        if (-not [string]::IsNullOrWhiteSpace($labelKey)) { $symbolByLabel[$labelKey] = $symbolName }
        $relative = Get-IniValue $symbol 'RelativePositionInNM'
        if (-not [string]::IsNullOrWhiteSpace($relative)) { [void](Get-NumericVector $relative "$missionLabel [$symbolName] RelativePositionInNM") }
        $radius = Get-IniValue $symbol 'RadiusNm'
        if (-not [string]::IsNullOrWhiteSpace($radius)) { [void](Get-Number $radius "$missionLabel [$symbolName] RadiusNm" 0 100000) }
    }

    $triggerCount = Get-Integer (Get-IniValue $mission 'NumberOfTriggers') "$missionLabel NumberOfTriggers" 0 999
    $triggerNames = @(Get-SectionNames $ini '^Trigger\d+$')
    $triggerByName = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($triggerName in $triggerNames) { [void]$triggerByName.Add($triggerName) }
    if ($null -ne $triggerCount) { Test-ContiguousSections $ini '^Trigger' $triggerCount "$missionLabel trigger sections" }
    $enabledBy = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $targetReferences = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($triggerName in $triggerNames) {
        $trigger = $ini.Sections[$triggerName]
        if ([string]::IsNullOrWhiteSpace((Get-IniValue $trigger 'Name'))) { Add-Failure "$missionLabel [$triggerName] has no Name." }
        $conditionNumbers = [System.Collections.Generic.List[int]]::new()
        foreach ($line in $trigger) {
            if ([string]$line -match '^Condition_Condition(\d+)_Type\s*=\s*(.*)$') {
                [void]$conditionNumbers.Add([int]$Matches[1])
                if ([string]::IsNullOrWhiteSpace($Matches[2])) { Add-Failure "$missionLabel [$triggerName] has an empty condition type." }
            }
            if ([string]$line -match '^ConditionsCompleted\s*=\s*(.*)$') {
                foreach ($conditionRef in [regex]::Matches($Matches[1], '<Condition(\d+)>')) {
                    $conditionKey = 'Condition_Condition' + $conditionRef.Groups[1].Value + '_Type'
                    if ($null -eq (Get-IniValue $trigger $conditionKey)) { Add-Failure "$missionLabel [$triggerName] references missing $conditionKey." }
                }
            }
            if ([string]$line -match '^Action_EnableTriggers\s*=\s*(.*)$') {
                foreach ($enabledName in (Get-ReferencedNames $Matches[1])) {
                    if (-not $triggerByName.Contains($enabledName)) { Add-Failure "$missionLabel [$triggerName] enables missing $enabledName." }
                    else { [void]$enabledBy.Add($enabledName) }
                }
            }
            if ([string]$line -match '^Action_EndMission\s*=\s*(.*)$') { [void](Test-Boolean $Matches[1] "$missionLabel [$triggerName] Action_EndMission") }
            if ([string]$line -match '^Action_Victory\s*=\s*(.*)$' -and $Matches[1] -notin @($playerTaskforceName, $enemyTaskforceName)) { Add-Failure "$missionLabel [$triggerName] Action_Victory must name $playerTaskforceName or $enemyTaskforceName." }
            if ([string]$line -match '^Action_Objectives(?:Completed|Failed|Cancel)\s*=\s*(.*)$') {
                foreach ($objective in (Get-ReferencedNames $Matches[1])) { if (-not $objectiveNames.Contains($objective)) { Add-Failure "$missionLabel [$triggerName] references unknown objective '$objective'." } }
            }
            if ([string]$line -match '^Condition_Condition\d+_Units\s*=\s*(.*)$') {
                foreach ($unitName in (Get-ReferencedNames $Matches[1])) {
                    if (-not $unitNames.Contains($unitName)) { Add-Failure "$missionLabel [$triggerName] references missing unit $unitName." }
                    else { [void]$targetReferences.Add($unitName) }
                }
            }
            if ([string]$line -match '^Condition_Condition\d+_PositionNM\s*=\s*(.*)$') { [void](Get-NumericVector $Matches[1] "$missionLabel [$triggerName] Condition PositionNM") }
            if ([string]$line -match '^Condition_Condition\d+_AreaRadiusNM\s*=\s*(.*)$') { [void](Get-Number $Matches[1] "$missionLabel [$triggerName] Condition AreaRadiusNM" 0 100000) }
            if ([string]$line -match '^Condition_Condition(\d+)_AreaLabel\s*=\s*(.*)$') {
                $conditionNumber = $Matches[1]
                $label = $Matches[2].Trim()
                $symbolName = if ($symbolByLabel.ContainsKey($label)) { $symbolByLabel[$label] } elseif ($label -match '^(.+)Label$' -and $ini.Sections.Contains($Matches[1])) { $Matches[1] } else { $null }
                if ($null -eq $symbolName) { Add-Failure "$missionLabel [$triggerName] AreaLabel '$label' has no matching MapSymbol LabelKey." }
                else {
                    $symbol = $ini.Sections[$symbolName]
                    $markerPosition = Get-IniValue $symbol 'RelativePositionInNM'
                    $markerRadius = Get-IniValue $symbol 'RadiusNm'
                    $conditionPosition = Get-IniValue $trigger ('Condition_Condition' + $conditionNumber + '_PositionNM')
                    $conditionRadius = Get-IniValue $trigger ('Condition_Condition' + $conditionNumber + '_AreaRadiusNM')
                    if ([string]::IsNullOrWhiteSpace($markerPosition)) { Add-Failure "$missionLabel [$symbolName] must declare RelativePositionInNM for its area trigger." }
                    if ([string]::IsNullOrWhiteSpace($markerRadius)) { Add-Failure "$missionLabel [$symbolName] must declare RadiusNm for its area trigger." }
                    if (-not [string]::IsNullOrWhiteSpace($markerPosition) -and -not [string]::IsNullOrWhiteSpace($conditionPosition)) {
                        $markerVector = Get-NumericVector $markerPosition "$missionLabel [$symbolName] RelativePositionInNM"
                        $conditionVector = Get-NumericVector $conditionPosition "$missionLabel [$triggerName] Condition PositionNM"
                        if ($null -ne $markerVector -and $null -ne $conditionVector -and ([Math]::Abs($markerVector[0] - $conditionVector[0]) -gt 0.01 -or [Math]::Abs($markerVector[2] - $conditionVector[2]) -gt 0.01)) { Add-Failure "$missionLabel [$triggerName] geographic marker position disagrees with [$symbolName]." }
                    }
                    if (-not [string]::IsNullOrWhiteSpace($markerRadius) -and -not [string]::IsNullOrWhiteSpace($conditionRadius)) {
                        $mRadius = Get-Number $markerRadius "$missionLabel [$symbolName] RadiusNm" 0 100000
                        $cRadius = Get-Number $conditionRadius "$missionLabel [$triggerName] AreaRadiusNM" 0 100000
                        if ($null -ne $mRadius -and $null -ne $cRadius -and [Math]::Abs($mRadius - $cRadius) -gt 0.01) { Add-Failure "$missionLabel [$triggerName] geographic marker radius disagrees with [$symbolName]." }
                    }
                }
            }
        }
        $uniqueConditions = @($conditionNumbers | Sort-Object -Unique)
        if ($conditionNumbers.Count -eq 0) { Add-Failure "$missionLabel [$triggerName] has no conditions." }
        for ($conditionIndex = 1; $conditionIndex -le $uniqueConditions.Count; $conditionIndex++) { if ($conditionIndex -notin $uniqueConditions) { Add-Failure "$missionLabel [$triggerName] condition indices are not contiguous." } }
        if (-not (@($trigger | Where-Object { [string]$_ -match '^Action_[^=]+=' }).Count)) { Add-Failure "$missionLabel [$triggerName] has no actions." }
        $disabled = Get-IniValue $trigger 'Disabled'
        if ($null -ne $disabled) { [void](Test-Boolean $disabled "$missionLabel [$triggerName] Disabled") }
    }
    # Check this after the complete trigger set has been read.  A trigger may
    # enable a later or earlier numbered trigger, so checking while iterating
    # would make the result depend on section order.
    foreach ($triggerName in $triggerNames) {
        $disabled = Get-IniValue $ini.Sections[$triggerName] 'Disabled'
        if ($disabled -match '^(?i:true)$' -and -not $enabledBy.Contains($triggerName)) {
            Add-Failure "$missionLabel [$triggerName] is disabled but no enabled trigger points to it."
        }
    }
    $targetReferencesByFile[$file.FullName] = $targetReferences

    foreach ($line in $ini.Text -split "`r?`n") {
        foreach ($unitToken in (Get-UnitTokens $line)) { if (-not $unitNames.Contains($unitToken)) { Add-Failure "$missionLabel references missing unit $unitToken." } }
        if ($line -match '^\s*(?:Disabled|DynamicGeneration(?:Slot|Persistent)|SetSelected|UnlimitedFuel|TowedArrayDeployed|CampaignRearm|CampaignRepair|LockPosition|IsUnlocked|IsComplete|RadarsActive|ActiveSonarsEnabled|Action_EndMission)\s*=\s*(.*)$') { [void](Test-Boolean $Matches[1] "$missionLabel boolean flag") }
    }

    foreach ($unitName in $unitNames) {
        $unit = $unitsByName[$unitName]
        $unitType = Get-IniValue $unit 'Type'
        $variant = Get-IniValue $unit 'VariantReference'
        if ([string]::IsNullOrWhiteSpace($unitType)) { Add-Failure "$missionLabel [$unitName] is missing Type." }
        if ([string]::IsNullOrWhiteSpace($variant)) { Add-Failure "$missionLabel [$unitName] is missing VariantReference." }
        $tag = Get-IniValue $unit 'CampaignTag'
        if ($unitName -match $playerSubmarinePattern) {
            if ($unitType -notmatch $playerSubmarineTypePattern) { Add-Failure "$missionLabel [$unitName] is not an allowed player submarine type: $unitType" }
            foreach ($key in @('UnlimitedFuel','TowedArrayDeployed','RelativePositionInNM','Heading','Waypoints')) {
                if ([string]::IsNullOrWhiteSpace((Get-IniValue $unit $key))) { Add-Failure "$missionLabel [$unitName] is missing $key." }
            }
            [void](Get-RelativeVector (Get-IniValue $unit 'RelativePositionInNM') "$missionLabel [$unitName] RelativePositionInNM")
            [void](Get-Number (Get-IniValue $unit 'Heading') "$missionLabel [$unitName] Heading" -360 360)
        }
        if (-not [string]::IsNullOrWhiteSpace($tag)) {
            $tagOwners = @($unitNames | Where-Object { (Get-IniValue $unitsByName[$_] 'CampaignTag') -eq $tag })
            if ($tagOwners.Count -gt 1) { Add-Failure "$missionLabel repeats CampaignTag=$tag within authored unit slots." }
        }
        $dynamic = Get-IniValue $unit 'DynamicGenerationSlot'
        if ($dynamic -match '^(?i:true)$') {
            if ([string]::IsNullOrWhiteSpace((Get-IniValue $unit 'DynamicGenerationRoster'))) { Add-Failure "$missionLabel [$unitName] dynamic slot lacks DynamicGenerationRoster." }
            $spawnZone = Get-IniValue $unit 'DynamicGenerationSpawnZone'
            if ([string]::IsNullOrWhiteSpace($spawnZone)) { Add-Failure "$missionLabel [$unitName] dynamic slot lacks DynamicGenerationSpawnZone." }
            elseif ($null -ne $zones -and -not $zoneNames.Contains($spawnZone)) { Add-Failure "$missionLabel [$unitName] references missing spawn zone $spawnZone." }
            foreach ($key in @('DynamicGenerationMinUnits','DynamicGenerationMaxUnits')) {
                $value = Get-IniValue $unit $key
                if (-not [string]::IsNullOrWhiteSpace($value)) { [void](Get-Integer $value "$missionLabel [$unitName] $key" 1 999) }
            }
        }
        $formation = Get-IniValue $unit 'DynamicGenerationFormation'
        if ($null -ne $formation) {
            if ([string]::IsNullOrWhiteSpace($formation)) { Add-Failure "$missionLabel [$unitName] DynamicGenerationFormation is empty." }
            elseif (-not $formationDefinitions.Contains($formation)) { Add-Failure "$missionLabel [$unitName] references missing formation definition [$formation]." }
        }
    }

    if ($null -ne $info.Record -and -not $info.Optional) {
        $sequenceNumber = Get-MissionSequenceNumber $info.Sequence
        if ($null -ne $sequenceNumber) {
            $expectedSlots = Get-ExpectedPersistentSlots $sequenceNumber
            $playerSlots = @($unitNames | Where-Object { $_ -match $playerSubmarinePattern } | Sort-Object { [int]([regex]::Match($_, '\d+$').Value) })
            if ($null -ne $expectedSlots -and $playerSlots.Count -ne $expectedSlots) { Add-Failure "$missionLabel must contain $expectedSlots persistent player submarine slot(s); found $($playerSlots.Count)." }
            for ($slotIndex = 0; $slotIndex -lt $playerSlots.Count; $slotIndex++) {
                $slotName = $playerSlots[$slotIndex]
                $slot = $unitsByName[$slotName]
                $tag = Get-IniValue $slot 'CampaignTag'
                if ([string]::IsNullOrWhiteSpace($tag)) { Add-Failure "$missionLabel [$slotName] is missing CampaignTag." }
                $selected = Get-IniValue $slot 'SetSelected'
                if ($slotIndex -eq 0 -and $selected -notmatch '^(?i:true)$') { Add-Failure "$missionLabel [$slotName] must set SetSelected=True." }
                if ($slotIndex -gt 0 -and $selected -match '^(?i:true)$') { Add-Failure "$missionLabel [$slotName] must not set SetSelected=True." }
                if (-not $persistentByIndex.ContainsKey($slotIndex + 1)) { $persistentByIndex[$slotIndex + 1] = [pscustomobject]@{ Type = Get-IniValue $slot 'Type'; Variant = Get-IniValue $slot 'VariantReference'; Tag = $tag } }
                else {
                    $canonical = $persistentByIndex[$slotIndex + 1]
                    foreach ($property in @('Type','Variant','Tag')) {
                        $currentValue = if ($property -eq 'Type') { Get-IniValue $slot 'Type' } elseif ($property -eq 'Variant') { Get-IniValue $slot 'VariantReference' } else { $tag }
                        if ($currentValue -ine $canonical.$property) { Add-Failure "$missionLabel [$slotName] breaks persistent player $property continuity." }
                    }
                }
                $rearm = Get-IniValue $slot 'CampaignRearm'
                $repair = Get-IniValue $slot 'CampaignRepair'
                $shouldReplenish = $sequenceNumber -in $replenishSequences
                if ($shouldReplenish -and ($rearm -notmatch '^(?i:true)$' -or $repair -notmatch '^(?i:true)$')) { Add-Failure "$missionLabel [$slotName] must enable CampaignRearm=True and CampaignRepair=True." }
                if (-not $shouldReplenish -and (($rearm -match '^(?i:true)$') -or ($repair -match '^(?i:true)$'))) { Add-Failure "$missionLabel must not rearm or repair player boats at this interval." }
            }
        }
    }
    if ($null -ne $info.Record -and $info.Optional) {
        $optionalNumberMatch = [regex]::Match($info.Sequence, '(?i)' + $optionalSequencePattern + '\s*$')
        if ($optionalNumberMatch.Success) {
            $expectedOptionalSlots = [int]$optionalNumberMatch.Groups[1].Value
            $optionalSlots = @($unitNames | Where-Object { $_ -match $playerSubmarinePattern } | Sort-Object { [int]([regex]::Match($_, '\d+$').Value) })
            $actualOptionalSlots = $optionalSlots.Count
            if ($actualOptionalSlots -ne $expectedOptionalSlots) { Add-Failure "$missionLabel must contain $expectedOptionalSlots persistent player submarine slot(s); found $actualOptionalSlots." }
            for ($slotIndex = 0; $slotIndex -lt $optionalSlots.Count; $slotIndex++) {
                $slotName = $optionalSlots[$slotIndex]
                $slot = $unitsByName[$slotName]
                $tag = Get-IniValue $slot 'CampaignTag'
                if ([string]::IsNullOrWhiteSpace($tag)) { Add-Failure "$missionLabel [$slotName] is missing CampaignTag." }
                $selected = Get-IniValue $slot 'SetSelected'
                if ($slotIndex -eq 0 -and $selected -notmatch '^(?i:true)$') { Add-Failure "$missionLabel [$slotName] must set SetSelected=True." }
                if ($slotIndex -gt 0 -and $selected -match '^(?i:true)$') { Add-Failure "$missionLabel [$slotName] must not set SetSelected=True." }
                if ($persistentByIndex.ContainsKey($slotIndex + 1)) {
                    $canonical = $persistentByIndex[$slotIndex + 1]
                    $currentValues = @{
                        Type = Get-IniValue $slot 'Type'
                        Variant = Get-IniValue $slot 'VariantReference'
                        Tag = $tag
                    }
                    foreach ($property in @('Type','Variant','Tag')) {
                        if ($currentValues[$property] -ine $canonical.$property) { Add-Failure "$missionLabel [$slotName] breaks persistent player $property continuity." }
                    }
                }
                if ((Get-IniValue $slot 'CampaignRearm') -match '^(?i:true)$' -or (Get-IniValue $slot 'CampaignRepair') -match '^(?i:true)$') {
                    Add-Failure "$missionLabel must not rearm or repair player boats in an optional operation."
                }
            }
        }
    }
}

# Dynamic target anchors must remain one-for-one whenever the authored trigger
# refers to them.  This uses the actual trigger and map/unit names rather than
# hard-coding a particular contact name.
foreach ($info in $operationInfos) {
    $targetReferences = $targetReferencesByFile[$info.File.FullName]
    if ($null -eq $targetReferences) { continue }
    $ini = $info.Ini
    foreach ($targetName in $targetReferences) {
        if (-not $targetName -or -not $targetName.StartsWith($enemyUnitPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not $ini.Sections.Contains($targetName)) { continue }
        $unit = $ini.Sections[$targetName]
        $tag = Get-IniValue $unit 'CampaignTag'
        if ([string]::IsNullOrWhiteSpace($tag)) { continue }
        $dynamic = Get-IniValue $unit 'DynamicGenerationSlot'
        if ($dynamic -notmatch '^(?i:true)$') { Add-Failure "$($info.Stem) target $targetName with CampaignTag must be a DynamicGenerationSlot."; continue }
        $min = Get-IniValue $unit 'DynamicGenerationMinUnits'
        $max = Get-IniValue $unit 'DynamicGenerationMaxUnits'
        if ([string]::IsNullOrWhiteSpace($min) -or [string]::IsNullOrWhiteSpace($max)) { Add-Failure "$($info.Stem) target $targetName must declare exact dynamic generation bounds." }
        else {
            if ((Get-Integer $min "$($info.Stem) $targetName DynamicGenerationMinUnits" 1 999) -ne $minimumDynamicUnits) { Add-Failure "$($info.Stem) target $targetName is outside the configured minimum dynamic-unit bound." }
            if ((Get-Integer $max "$($info.Stem) $targetName DynamicGenerationMaxUnits" 1 999) -ne $maximumDynamicUnits) { Add-Failure "$($info.Stem) target $targetName is outside the configured maximum dynamic-unit bound." }
        }
        $allowed = Get-ReferencedNames (Get-IniValue $unit 'DynamicGenerationAllowedTypes')
        $unitType = Get-IniValue $unit 'Type'
        $variant = Get-IniValue $unit 'VariantReference'
        if ($allowed.Count -gt 0 -and ($allowed -notcontains $unitType -or $allowed -notcontains $variant)) { Add-Failure "$($info.Stem) target $targetName DynamicGenerationAllowedTypes must include its authored Type and VariantReference." }
    }
}

# Environments are required for the configured main operations.  Their values are
# parsed with invariant culture so malformed, NaN, and Infinity data cannot
# pass through a locale dependent conversion.  M1-M3 retain the pre-existing
# environment contract; the later authored environments add the explicit
# conversion/background/wind fields.  Weather is intentionally descriptive
# and is not a required field.
foreach ($info in $mainOperations) {
    $ini = $info.Ini
    $label = $info.Stem
    $environment = $ini.Sections['Environment']
    if ($null -eq $environment) { Add-Failure "$label is missing [Environment]."; continue }
    $date = Get-IniValue $environment 'Date'
    $dateMatch = [regex]::Match($date, '^(\d{4}),(\d{1,2}),(\d{1,2})$')
    if (-not $dateMatch.Success) { Add-Failure "$label Environment Date must be YYYY,M,D." }
    else {
        $year = Get-Integer $dateMatch.Groups[1].Value "$label Environment Date year" 1 9999
        $month = Get-Integer $dateMatch.Groups[2].Value "$label Environment Date month" 1 12
        $day = Get-Integer $dateMatch.Groups[3].Value "$label Environment Date day" 1 31
        $yearRule = Get-ManifestValue $environmentRules 'year'
        if ($null -ne $yearRule -and $year -ne [int]$yearRule) { Add-Failure "$label Environment Date must be in $yearRule." }
        if ($null -ne $year -and $null -ne $month -and $null -ne $day) {
            try { [void][datetime]::new($year, $month, $day) } catch { Add-Failure "$label Environment Date is not a real calendar date." }
        }
    }
    $time = Get-IniValue $environment 'Time'
    $timeMatch = [regex]::Match($time, '^(\d{1,2}),(\d{1,2})(?:,(\d{1,2}))?$')
    if (-not $timeMatch.Success) { Add-Failure "$label Environment Time must be H,M or H,M,S." }
    else {
        [void](Get-Integer $timeMatch.Groups[1].Value "$label Environment Time hour" 0 23)
        [void](Get-Integer $timeMatch.Groups[2].Value "$label Environment Time minute" 0 59)
        if ($timeMatch.Groups[3].Success) { [void](Get-Integer $timeMatch.Groups[3].Value "$label Environment Time second" 0 59) }
    }
    $sequenceNumber = Get-MissionSequenceNumber $info.Sequence
    $extendedEnvironment = ($null -eq $sequenceNumber -or $sequenceNumber -gt 3)
    if ($extendedEnvironment) {
        foreach ($field in @('ConvertTimeToLocal','LoadBackgroundData')) {
            $value = Get-IniValue $environment $field
            if ([string]::IsNullOrWhiteSpace($value)) { Add-Failure "$label Environment is missing $field." } else { [void](Test-Boolean $value "$label Environment $field") }
        }
    } else {
        foreach ($field in @('ConvertTimeToLocal','LoadBackgroundData')) {
            $value = Get-IniValue $environment $field
            if (-not [string]::IsNullOrWhiteSpace($value)) { [void](Test-Boolean $value "$label Environment $field") }
        }
    }
    [void](Get-Integer (Get-IniValue $environment 'SeaState') "$label Environment SeaState" 0 9)
    if ([string]::IsNullOrWhiteSpace((Get-IniValue $environment 'Clouds'))) { Add-Failure "$label Environment is missing Clouds." }
    $windDirection = Get-IniValue $environment 'WindDirection'
    if ($extendedEnvironment) {
        if ([string]::IsNullOrWhiteSpace($windDirection)) { Add-Failure "$label Environment is missing WindDirection." }
    }
    $latitude = Get-Number (Get-IniValue $environment 'MapCenterLatitude') "$label Environment MapCenterLatitude" -90 90
    $longitude = Get-Number (Get-IniValue $environment 'MapCenterLongitude') "$label Environment MapCenterLongitude" -180 180
    if ($null -eq $latitude -or $null -eq $longitude) { Add-Failure "$label Environment must define finite map center coordinates." }
}

# Variable declarations and writes are checked across all authored missions.
$declaredVariables = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($info in $operationInfos) {
    $variables = $info.Ini.Sections['CampaignVariables']
    foreach ($key in (Get-IniKeys $variables)) {
        if ($key -match $variablePattern) { [void]$declaredVariables.Add($key) }
    }
}
foreach ($info in $operationInfos) {
    foreach ($line in $info.Ini.Text -split "`r?`n") {
        if ($line -match '^\s*(?:Action_VariableSet|SpawnByVariableAND)\s*=\s*(.*)$') {
            $variableReference = $Matches[1].Trim()
            if ($variableReference -match $variablePattern -and -not $declaredVariables.Contains($variableReference)) { Add-Failure "$($info.Stem) references undefined campaign variable $variableReference." }
        }
    }
}

# If an installed game is available, gather unit IDs from its original data.
# A missing installation is a warning because CI and Workshop authors often
# validate the package without a local copy of the game.
$knownInstalledTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if ($GameRoot -and (Test-Path -LiteralPath $GameRoot -PathType Container)) {
    $originalRoot = Join-Path $GameRoot 'Sea Power_Data\StreamingAssets\original'
    if (Test-Path -LiteralPath $originalRoot -PathType Container) {
        foreach ($file in (Get-ChildItem -LiteralPath $originalRoot -Recurse -File -Filter '*.ini')) {
            [void]$knownInstalledTypes.Add(($file.BaseName -replace '_variants$',''))
        }
    }
    if ($knownInstalledTypes.Count -eq 0) { Add-Warning "No original unit INIs were found below $originalRoot; installed unit ID checks skipped." }
    else {
        foreach ($info in $operationInfos) {
            foreach ($unitName in (Get-UnitSectionNames $info.Ini)) {
                $type = Get-IniValue $info.Ini.Sections[$unitName] 'Type'
                if ($type -and -not $knownInstalledTypes.Contains($type)) { Add-Failure "$($info.Stem) references missing installed unit ID: $type" }
            }
        }
    }
} else { Add-Warning 'GameRoot not found; installed unit ID checks skipped.' }

# Optional weapon inventory checks are enabled by the campaign manifest.  The
# validator remains agnostic about weapon names and mission numbers when the
# policy is omitted.
$inventoryEnabled = [bool](Get-ManifestValue $inventoryRules 'enabled' $false)
$inventoryMission = [int](Get-ManifestValue $inventoryRules 'sourceSequence' 0)
$inventoryFollowupMission = [int](Get-ManifestValue $inventoryRules 'followupSequence' 0)
$inventoryWeaponSectionPattern = [string](Get-ManifestValue $inventoryRules 'weaponSectionPattern' ('^' + [regex]::Escape($playerUnitPrefix) + 'Submarine\d+_WeaponSystem\d+$'))
$inventoryAmmunitionPattern = [string](Get-ManifestValue $inventoryRules 'ammunitionPattern' '^(?i)Ammunition(\d+)\s*=\s*(.+)\s*$')
$inventoryAmmunitionNamePattern = [string](Get-ManifestValue $inventoryRules 'ammunitionNamePattern' '^\S+$')
$inventoryLabel = [string](Get-ManifestValue $inventoryRules 'label' 'configured weapon')
$inventoryMinimum = [double](Get-ManifestValue $inventoryRules 'minimumCount' 0)
$inventorySource = $mainOperations | Where-Object { $inventoryMission -gt 0 -and (Get-MissionSequenceNumber $_.Sequence) -eq $inventoryMission } | Select-Object -First 1
$inventoryFollowup = $mainOperations | Where-Object { $inventoryFollowupMission -gt 0 -and (Get-MissionSequenceNumber $_.Sequence) -eq $inventoryFollowupMission } | Select-Object -First 1
if ($inventoryEnabled -and $null -ne $inventorySource) {
    $inventoryWeaponSections = @(Get-SectionNames $inventorySource.Ini $inventoryWeaponSectionPattern)
    $inventoryEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($weaponSectionName in $inventoryWeaponSections) {
        $weaponSection = $inventorySource.Ini.Sections[$weaponSectionName]
        foreach ($line in $weaponSection) {
            if ([string]$line -match $inventoryAmmunitionPattern) {
                $ammoIndex = $Matches[1]
                $ammoName = $Matches[2]
                if ($ammoName -notmatch $inventoryAmmunitionNamePattern) { continue }
                $countKey = 'Ammunition' + $ammoIndex + '_Count'
                $countValue = Get-IniValue $weaponSection $countKey
                if ([string]::IsNullOrWhiteSpace($countValue)) { Add-Failure "$($inventorySource.Stem) [$weaponSectionName] $inventoryLabel is missing $countKey." }
                else {
                    $count = Get-Number $countValue "$($inventorySource.Stem) [$weaponSectionName] $countKey" 0 100000
                    if ($null -ne $count -and $count -le $inventoryMinimum) { Add-Failure "$($inventorySource.Stem) [$weaponSectionName] $inventoryLabel must exceed the configured minimum count." }
                }
                [void]$inventoryEntries.Add([pscustomobject]@{ Section = $weaponSectionName; Index = $ammoIndex })
            }
        }
    }
    if ($inventoryEntries.Count -eq 0) { Add-Warning "$($inventorySource.Stem) has no explicit $inventoryLabel inventory key; compatibility requires in-game verification." }
    if ($null -ne $inventoryFollowup) {
        foreach ($unitName in (Get-UnitSectionNames $inventoryFollowup.Ini | Where-Object { $_ -match $playerSubmarinePattern })) {
            $slot = $inventoryFollowup.Ini.Sections[$unitName]
            if ((Get-IniValue $slot 'CampaignRearm') -match '^(?i:true)$' -or (Get-IniValue $slot 'CampaignRepair') -match '^(?i:true)$') { Add-Failure "$($inventoryFollowup.Stem) must not replenish player slot $unitName after $($inventorySource.Stem)." }
        }
    }
}

$mainCount = @($mainOperations).Count
$optionalCount = @($optionalOperations).Count
if (-not ($VerticalSlice -or $Implemented)) {
    $expectedMainCount = [int](Get-ManifestValue $operationRules 'mainCount' 0)
    $expectedOptionalCount = [int](Get-ManifestValue $operationRules 'optionalCount' 0)
    if ($expectedMainCount -gt 0 -and $mainCount -ne $expectedMainCount) { Add-Failure "Expected $expectedMainCount main operations; found $mainCount." }
    if ($expectedOptionalCount -gt 0 -and $optionalCount -ne $expectedOptionalCount) { Add-Failure "Expected $expectedOptionalCount optional operations; found $optionalCount." }
}

Write-Output "$($manifest.CampaignName) static validation"
Write-Output "Repository: $repo"
Write-Output "Operations: $operationCount; timeline events: $eventCount; briefing assets: $($briefingAssetPaths.Count); event assets: $($eventReferencedFiles.Count); locales: $($locales.Count)"
foreach ($warning in $warnings) { Write-Warning $warning }
if ($failures.Count -gt 0) {
    Write-Error ("FAILED with {0} issue(s):`n - {1}" -f $failures.Count, ($failures -join "`n - "))
    exit 1
}
Write-Output 'PASS: authored-linear graph, locale parity, briefing/event XML, environments, map-marker geometry, trigger and zone references, persistent submarine roster, mission-relative DUG rosters, DUG anchors, variables, and installed IDs.'
exit 0
