#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [Parameter(Mandatory = $true)]
    [string]$Config,
    [switch]$ExpectGeneratorCheck,
    [switch]$ExpectGeneratorJson,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$toolkitRoot = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $toolkitRoot 'scripts\Invoke-SeaPowerCampaignValidation.ps1'
$generator = Join-Path $toolkitRoot 'scripts\Generate-SeaPowerBriefings.ps1'
. (Join-Path $toolkitRoot 'scripts\CampaignTools.Common.ps1')
$manifest = Read-CampaignToolManifest $Config $root
$manifestRelative = [System.IO.Path]::GetRelativePath($root, $manifest.ManifestPath)
$campaignRelative = [System.IO.Path]::GetRelativePath($root, $manifest.CampaignRoot)
$jsonPath = $manifest.BriefingContentPath
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sea-power-campaign-tests-' + [guid]::NewGuid().ToString('N'))
$testFailures = [System.Collections.Generic.List[string]]::new()
$skips = [System.Collections.Generic.List[string]]::new()

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error 'PowerShell 7 or newer is required.'
    exit 1
}
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    Write-Error "Missing validator: $validator"
    exit 1
}
if (-not (Test-Path -LiteralPath $manifest.CampaignRoot -PathType Container)) {
    Write-Error "Missing campaign package: $($manifest.CampaignRoot)"
    exit 1
}
$generatorText = if (Test-Path -LiteralPath $generator -PathType Leaf) { Get-Content -Raw -LiteralPath $generator } else { '' }
$hasCheck = $generatorText -match '(?is)\bparam\s*\(.*?\bCheck\b.*?\)'
$generatorUsesJson = $generatorText -match '(?i)BriefingContentPath|content'
$generatorInputReady = Test-Path -LiteralPath $jsonPath -PathType Leaf
$skipJsonBackedGenerator = -not $generatorInputReady

$missionsRoot = Join-Path $manifest.CampaignRoot 'missions'
$firstMissionFile = Get-ChildItem -LiteralPath $missionsRoot -Filter '*.ini' -File | Sort-Object Name | Select-Object -First 1
if ($null -eq $firstMissionFile) { throw "No mission INI files found below $missionsRoot" }
$firstMissionRelative = [System.IO.Path]::GetRelativePath($root, $firstMissionFile.FullName)
$firstMissionStem = $firstMissionFile.BaseName
$firstBriefing = Join-Path $missionsRoot ($firstMissionStem + '_briefing\BriefingText_' + $manifest.Locales[0] + '.xml')
$firstBriefingRelative = [System.IO.Path]::GetRelativePath($root, $firstBriefing)
$eventDirectory = Join-Path $manifest.CampaignRoot ('art\events\' + [string]$manifest.Locales[0])
$firstEventFile = Get-ChildItem -LiteralPath $eventDirectory -Filter '*.xml' -File | Sort-Object Name | Select-Object -First 1
if ($null -eq $firstEventFile) { throw "No event XML files found below $eventDirectory" }
$firstEventRelative = [System.IO.Path]::GetRelativePath($root, $firstEventFile.FullName)
$secondEventFile = Get-ChildItem -LiteralPath $eventDirectory -Filter '*.xml' -File | Sort-Object Name | Select-Object -Skip 1 -First 1
if ($null -eq $secondEventFile) { $secondEventFile = $firstEventFile }
$secondEventRelative = [System.IO.Path]::GetRelativePath($root, $secondEventFile.FullName)
$campaignIniRelative = [System.IO.Path]::GetRelativePath($root, $manifest.CampaignIni)
$configRelativeForFixture = $manifestRelative
$campaignText = [IO.File]::ReadAllText($manifest.CampaignIni)
$firstOperationMatch = [regex]::Match($campaignText, '(?ms)^\[(Mission\d+)\][^\[]*?^Type=Mission\s*$')
$firstOperationSection = if ($firstOperationMatch.Success) { $firstOperationMatch.Groups[1].Value } else { 'Mission1' }
$firstMissionText = [IO.File]::ReadAllText($firstMissionFile.FullName)
$firstDynamicMatch = [regex]::Match($firstMissionText, '(?m)^\[(Taskforce\d+\w+\d+)\]\s*$')
$firstDynamicUnit = if ($firstDynamicMatch.Success) { $firstDynamicMatch.Groups[1].Value } else { 'Taskforce2Vessel1' }
$firstAreaLabelMatch = [regex]::Match($firstMissionText, '(?m)^Condition_Condition\d+_AreaLabel\s*=\s*(MapSymbol_[^\r\n]+)$')
$firstMarkerSection = if ($firstAreaLabelMatch.Success) { $firstAreaLabelMatch.Groups[1].Value -replace 'Label$','' } else { 'MapSymbol_Exit' }

function Get-FixtureConfig([string]$FixtureRoot) { return Join-Path $FixtureRoot $configRelativeForFixture }

function New-Fixture([string]$Name) {
    $path = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'mod') -Destination $path -Recurse -Force
    Copy-Item -LiteralPath (Split-Path -Parent $manifest.ManifestPath) -Destination $path -Recurse -Force
    return $path
}

function Invoke-PwshFile([string]$Path, [string[]]$Arguments) {
    $output = @(& pwsh -NoLogo -NoProfile -File $Path @Arguments 2>&1)
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Replace-Text([string]$Path, [string]$Pattern, [string]$Replacement, [string]$Description) {
    $text = Get-Content -Raw -LiteralPath $Path
    $updated = [regex]::Replace($text, $Pattern, $Replacement, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    Assert-True ($updated -ne $text) "Fixture mutation did not find $Description in $Path."
    Set-Content -LiteralPath $Path -Value $updated -Encoding utf8NoBOM
}

function Remove-IniSection([string]$Path, [string]$SectionName) {
    $text = Get-Content -Raw -LiteralPath $Path
    $pattern = '(?ms)^\[' + [regex]::Escape($SectionName) + '\]\s*.*?(?=^\[[^\]\r\n]+\]\s*$|\z)'
    $updated = [regex]::Replace($text, $pattern, '')
    Assert-True ($updated -ne $text) "Fixture mutation did not find [$SectionName] in $Path."
    Set-Content -LiteralPath $Path -Value $updated -Encoding utf8NoBOM
}

function Set-IniSectionValue([string]$Path, [string]$SectionName, [string]$Key, [string]$Value) {
    $text = Get-Content -Raw -LiteralPath $Path
    $sectionPattern = '(?ms)^(\[' + [regex]::Escape($SectionName) + '\]\s*).*?(?=^\[[^\]\r\n]+\]\s*$|\z)'
    $match = [regex]::Match($text, $sectionPattern)
    Assert-True $match.Success "Fixture mutation did not find [$SectionName] in $Path."
    $body = $match.Value
    $keyPattern = '(?m)^' + [regex]::Escape($Key) + '\s*=.*$'
    if ([regex]::IsMatch($body, $keyPattern)) {
        $newBody = [regex]::Replace($body, $keyPattern, ($Key + '=' + $Value), 1)
    } else {
        $newBody = $body.TrimEnd("`r", "`n") + "`r`n" + $Key + '=' + $Value + "`r`n"
    }
    $updated = $text.Substring(0, $match.Index) + $newBody + $text.Substring($match.Index + $match.Length)
    Set-Content -LiteralPath $Path -Value $updated -Encoding utf8NoBOM
}

function Add-Utf8Bom([string]$Path) {
    $source = [System.IO.File]::ReadAllBytes($Path)
    $bytes = [byte[]]::new($source.Length + 3)
    $bytes[0] = 0xEF
    $bytes[1] = 0xBB
    $bytes[2] = 0xBF
    [Array]::Copy($source, 0, $bytes, 3, $source.Length)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-Snapshot([string]$Path) {
    $entries = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    foreach ($file in (Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($Path.Length).TrimStart('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        [void]$entries.Add(('{0}|{1}|{2}' -f $relative, $file.Length, $hash))
    }
    return @($entries)
}

function Get-MissionSectionSignature([string]$Path) {
    $entries = [System.Collections.Generic.List[string]]::new()
    $missionPath = Join-Path $Path ($campaignRelative + '\missions')
    foreach ($file in (Get-ChildItem -LiteralPath $missionPath -Filter '*.ini' -File | Sort-Object Name)) {
        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
            if ($line -match '^\[([^\]\r\n]+)\]\s*$') { [void]$entries.Add(($file.Name + '|' + $Matches[1])) }
        }
    }
    return @($entries)
}

function Get-MissionGameplaySignature([string]$Path) {
    $entries = [System.Collections.Generic.List[string]]::new()
    $missionPath = Join-Path $Path ($campaignRelative + '\missions')
    foreach ($file in (Get-ChildItem -LiteralPath $missionPath -Filter '*.ini' -File | Sort-Object Name)) {
        $section = ''
        foreach ($line in Get-Content -LiteralPath $file.FullName) {
            if ($line -match '^\[([^\]\r\n]+)\]\s*$') { $section = $Matches[1] }
            if ($section -notmatch '^Language_') { [void]$entries.Add(('{0}|{1}|{2}' -f $file.Name, $section, $line)) }
        }
    }
    return @($entries)
}

function Get-JsonProperty([object]$Object, [string[]]$Names) {
    if ($null -eq $Object) { return $null }
    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Name -in $Names) { return $property.Value }
    }
    return $null
}

function Get-JsonLocaleNode([object]$Container, [string]$Locale) {
    if ($null -eq $Container) { return $null }
    if ($Container -is [System.Collections.IEnumerable] -and $Container -isnot [string] -and $Container -isnot [System.Collections.IDictionary]) {
        foreach ($item in $Container) {
            $code = Get-JsonProperty $item @('locale','Locale','language','Language','code','Code','id','Id')
            if ([string]$code -ieq $Locale) { return $item }
        }
        return $null
    }
    foreach ($property in $Container.PSObject.Properties) {
        if ($property.Name -ieq $Locale) { return $property.Value }
    }
    return $null
}

function Get-JsonField([object]$Container, [string[]]$Names) {
    if ($null -eq $Container) { return $null }
    foreach ($property in $Container.PSObject.Properties) {
        if ($property.Name -in $Names) { return $property.Value }
    }
    return $null
}

function Assert-BriefingContentJson([string]$Path) {
    $json = $null
    try { $json = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 100 }
    catch { throw "briefing content JSON is malformed: $($_.Exception.Message)" }
    $schemaVersion = Get-JsonProperty $json @('schemaVersion','SchemaVersion')
    Assert-True ([int]$schemaVersion -eq 1) "briefing content JSON schemaVersion must be 1 (found '$schemaVersion')."

    $requiredLocales = @($manifest.Locales)
    $localeContainer = Get-JsonProperty $json @('locales','Locales','languages','Languages')
    $actualLocales = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($localeContainer -is [System.Collections.IEnumerable] -and $localeContainer -isnot [string] -and $localeContainer -isnot [System.Collections.IDictionary]) {
        foreach ($item in $localeContainer) {
            $code = if ($item -is [string]) { $item } else { Get-JsonProperty $item @('locale','Locale','language','Language','code','Code','id','Id') }
            if (-not [string]::IsNullOrWhiteSpace([string]$code)) { [void]$actualLocales.Add([string]$code) }
        }
    } elseif ($null -ne $localeContainer) {
        foreach ($property in $localeContainer.PSObject.Properties) { [void]$actualLocales.Add($property.Name) }
    }
    foreach ($locale in $requiredLocales) { Assert-True $actualLocales.Contains($locale) "briefing content JSON is missing locale '$locale'." }

    $missions = @(Get-JsonProperty $json @('missions','Missions','operations','Operations'))
    Assert-True ($missions.Count -gt 0) "briefing content JSON must contain at least one mission record (found $($missions.Count))."
    $fieldAliases = Get-ManifestValue $manifest.Briefing 'fieldAliases'
    $fieldDefinitions = @($manifest.RequiredBriefingFields | ForEach-Object {
        $field = [string]$_
        $aliases = @(Get-JsonProperty $fieldAliases $field)
        @{ Label = $field; Names = @($field) + $aliases }
    })
    $recordIndex = 0
    foreach ($record in $missions) {
        $recordIndex++
        $localeContainerForRecord = Get-JsonProperty $record @('briefings','Briefings','content','Content','sections','Sections','locales','Locales','languages','Languages')
        if ($null -eq $localeContainerForRecord) { $localeContainerForRecord = $record }
        foreach ($locale in $requiredLocales) {
            $localeNode = Get-JsonLocaleNode $localeContainerForRecord $locale
            Assert-True ($null -ne $localeNode) "briefing content JSON mission $recordIndex is missing locale '$locale'."
            $fieldContainer = Get-JsonProperty $localeNode @('fields','Fields','sections','Sections','content','Content')
            if ($null -eq $fieldContainer) { $fieldContainer = $localeNode }
            foreach ($definition in $fieldDefinitions) {
                $value = Get-JsonField $fieldContainer $definition.Names
                Assert-True (-not [string]::IsNullOrWhiteSpace([string]$value)) "briefing content JSON mission $recordIndex locale '$locale' is missing $($definition.Label)."
            }
        }
    }
}

function Invoke-Test([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Output "PASS: $Name"
    } catch {
        [void]$testFailures.Add("${Name}: $($_.Exception.Message)")
        Write-Output "FAIL: $Name - $($_.Exception.Message)"
    }
}

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    Invoke-Test 'manifest rejects unsupported schema version' {
        $fixture = New-Fixture 'manifest-schema-version'
        $config = Get-FixtureConfig $fixture
        Replace-Text $config '"schemaVersion"\s*:\s*1' '"schemaVersion": 2' 'manifest schemaVersion'
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', $config, '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match '(?i)schemaVersion') 'Validator accepted an unsupported manifest schema version.'
    }

    Invoke-Test 'manifest rejects paths outside repository' {
        $fixture = New-Fixture 'manifest-path-traversal'
        $config = Get-FixtureConfig $fixture
        Replace-Text $config '"root"\s*:\s*"[^"]+"' '"root": "../../outside-campaign"' 'manifest campaign root'
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', $config, '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match '(?i)outside RepoRoot|Campaign root') 'Validator accepted a manifest path outside RepoRoot.'
    }

    Invoke-Test 'positive campaign validation' {
        $fixture = New-Fixture 'positive'
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GameRoot', '')
        Assert-True ($result.ExitCode -eq 0) ("Expected the authored campaign to validate, but it exited {0}.`n{1}" -f $result.ExitCode, $result.Output)
    }

    Invoke-Test 'missing briefing asset' {
        $fixture = New-Fixture 'missing-briefing'
        $brief = Join-Path $fixture $firstBriefingRelative
        Remove-Item -LiteralPath $brief -Force
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match '(?i)Missing .*briefing') 'Validator did not report the missing briefing asset.'
    }

    Invoke-Test 'malformed briefing XML' {
        $fixture = New-Fixture 'malformed-briefing'
        $brief = Join-Path $fixture $firstBriefingRelative
        Set-Content -LiteralPath $brief -Value '<Grid>' -Encoding utf8NoBOM
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match '(?i)Invalid XML') 'Validator did not report malformed briefing XML.'
    }

    Invoke-Test 'wrong event namespace' {
        $fixture = New-Fixture 'wrong-namespace'
        $event = Join-Path $fixture $firstEventRelative
        Replace-Text $event 'xmlns="(?:http://schemas.microsoft.com/winfx/2006/xaml/presentation|http://schemas.microsoft.com/winfx/2006/xaml)"' 'xmlns="urn:sea-power:test"' 'event default namespace'
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match '(?i)wrong presentation namespace') 'Validator did not report the wrong event namespace.'
    }

    Invoke-Test 'missing locale and environment' {
        $fixture = New-Fixture 'missing-locale-environment'
        $mission = Join-Path $fixture $firstMissionRelative
        Remove-IniSection $mission ('Language_' + [string]$manifest.Locales[-1])
        Remove-IniSection $mission 'Environment'
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match ('(?i)missing Language_' + [regex]::Escape([string]$manifest.Locales[-1])) -and $result.Output -match '(?i)missing \[Environment\]') 'Validator did not report the missing locale and environment.'
    }

    Invoke-Test 'mismatched geographic marker' {
        $fixture = New-Fixture 'mismatched-marker'
        $mission = Join-Path $fixture $firstMissionRelative
        Set-IniSectionValue $mission $firstMarkerSection 'RelativePositionInNM' '999,0,999'
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match '(?i)geographic marker') 'Validator did not report the mismatched marker position.'
    }

    Invoke-Test 'invalid count and reference' {
        $fixture = New-Fixture 'invalid-count-reference'
        $mission = Join-Path $fixture $firstMissionRelative
        Set-IniSectionValue $mission 'Mission' 'NumberOfTriggers' '999'
        Replace-Text $mission '(?m)^Action_ObjectivesCompleted=([^\r\n]+)$' 'Action_ObjectivesCompleted=MissingObjective' 'objective action'
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match '(?i)trigger sections' -and $result.Output -match '(?i)unknown objective') 'Validator did not report invalid count and reference data.'
    }

    Invoke-Test 'duplicate event body' {
        $fixture = New-Fixture 'duplicate-event'
        $source = Join-Path $fixture $firstEventRelative
        $target = Join-Path $fixture $secondEventRelative
        Copy-Item -LiteralPath $source -Destination $target -Force
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match '(?i)duplicates the English event body') 'Validator did not report the duplicate event body.'
    }

    Invoke-Test 'traversal campaign asset path' {
        $fixture = New-Fixture 'traversal-campaign-path'
        $campaign = Join-Path $fixture $campaignIniRelative
        Set-IniSectionValue $campaign $firstOperationSection 'MissionFile' ('..\' + $manifest.CampaignsRootRelative + '\' + $manifest.CampaignId + '\missions\' + $firstMissionStem + '.ini')
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match ('(?i)' + [regex]::Escape($firstOperationSection) + ' has an invalid MissionFile path')) 'Validator accepted a traversal MissionFile path.'
    }

    Invoke-Test 'malformed campaign asset path prefix' {
        $fixture = New-Fixture 'malformed-campaign-path'
        $campaign = Join-Path $fixture $campaignIniRelative
        Set-IniSectionValue $campaign $firstOperationSection 'MissionFile' ('....\' + $manifest.CampaignsRootRelative + '\' + $manifest.CampaignId + '\missions\' + $firstMissionStem + '.ini')
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match ('(?i)' + [regex]::Escape($firstOperationSection) + ' has an invalid MissionFile path')) 'Validator accepted a malformed campaign path prefix.'
    }

    Invoke-Test 'missing dynamic formation definition' {
        $fixture = New-Fixture 'missing-dynamic-formation'
        $mission = Join-Path $fixture $firstMissionRelative
        Set-IniSectionValue $mission $firstDynamicUnit 'DynamicGenerationFormation' 'Missing_Formation'
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match '(?i)references missing formation definition') 'Validator did not report the missing DynamicGenerationFormation definition.'
    }

    Invoke-Test 'missing dynamic roster file' {
        $fixture = New-Fixture 'missing-dynamic-roster'
        $mission = Join-Path $fixture $firstMissionRelative
        Set-IniSectionValue $mission 'DynamicUnitGeneration' ([string](Get-ManifestValue $manifest.Validation.units 'dynamicRosterKey' 'Taskforce2RosterFile')) 'missing_roster.ini'
        $result = Invoke-PwshFile $validator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GameRoot', '')
        Assert-True ($result.ExitCode -ne 0 -and $result.Output -match '(?i)dynamic roster') 'Validator did not report the missing mission-relative dynamic roster.'
    }

    if (-not (Test-Path -LiteralPath $generator -PathType Leaf)) {
        Invoke-Test 'generator is deterministic and preserves gameplay sections' {
            throw "Missing generator: $generator"
        }
    } elseif ($skipJsonBackedGenerator) {
        $message = 'SKIP: generator integration phase (the configured briefing content source is absent; use -ExpectGeneratorJson to require it).'
        [void]$skips.Add($message)
        Write-Output $message
    } else {
        Invoke-Test 'generator is deterministic and preserves gameplay sections' {
            $fixture = New-Fixture 'generator-integrated'
            $beforeSections = Get-MissionSectionSignature $fixture
            $beforeGameplay = Get-MissionGameplaySignature $fixture
            $first = Invoke-PwshFile $generator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture))
            Assert-True ($first.ExitCode -eq 0) ("First generator run failed.`n{0}" -f $first.Output)
            $afterFirst = Get-Snapshot $fixture
            $afterFirstSections = Get-MissionSectionSignature $fixture
            $afterFirstGameplay = Get-MissionGameplaySignature $fixture
            Assert-True ((@($beforeSections) -join "`n") -eq (@($afterFirstSections) -join "`n")) 'Generator changed gameplay section topology.'
            Assert-True ((@($beforeGameplay) -join "`n") -eq (@($afterFirstGameplay) -join "`n")) 'Generator changed gameplay section content.'
            $second = Invoke-PwshFile $generator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture))
            Assert-True ($second.ExitCode -eq 0) ("Second generator run failed.`n{0}" -f $second.Output)
            $afterSecond = Get-Snapshot $fixture
            Assert-True ((@($afterFirst) -join "`n") -eq (@($afterSecond) -join "`n")) 'Generator output is not deterministic across two runs.'
        }
        if ($generatorText -match '(?is)\bGenerateXml\b') {
            Invoke-Test 'generator -GenerateXml leaves mission INIs unchanged' {
                $fixture = New-Fixture 'generator-xml-only'
                $mission = Join-Path $fixture $firstMissionRelative
                Set-IniSectionValue $mission 'Language_en' 'Description' 'XML-only fixture description.'
                $before = Get-Snapshot $fixture
                $result = Invoke-PwshFile $generator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-GenerateXml')
                Assert-True ($result.ExitCode -eq 0) ("Generator -GenerateXml failed.`n{0}" -f $result.Output)
                $after = Get-Snapshot $fixture
                Assert-True ((@($before) -join "`n") -eq (@($after) -join "`n")) 'Generator -GenerateXml rewrote a mission INI.'
            }
        }
    }

    if ($skipJsonBackedGenerator) {
        $message = 'SKIP: generator -Check phase (the configured briefing content source is absent; use -ExpectGeneratorJson to require it).'
        [void]$skips.Add($message)
        Write-Output $message
    } elseif ($hasCheck) {
        Invoke-Test 'generator -Check is read only' {
            $fixture = New-Fixture 'generator-check'
            $before = Get-Snapshot $fixture
            $result = Invoke-PwshFile $generator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-Check')
            Assert-True ($result.ExitCode -eq 0) ("Generator -Check failed.`n{0}" -f $result.Output)
            $after = Get-Snapshot $fixture
            Assert-True ((@($before) -join "`n") -eq (@($after) -join "`n")) 'Generator -Check changed a fixture file.'
        }
        Invoke-Test 'generator -Check detects INI drift without writing' {
            $fixture = New-Fixture 'generator-check-drift'
            $mission = Join-Path $fixture $firstMissionRelative
            Set-IniSectionValue $mission 'Language_en' 'Description' 'Drift fixture description.'
            $before = Get-Snapshot $fixture
            $result = Invoke-PwshFile $generator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-Check')
            Assert-True ($result.ExitCode -ne 0 -and $result.Output -match '(?i)mission INI drift') 'Generator -Check did not report the modified localized INI content.'
            $after = Get-Snapshot $fixture
            Assert-True ((@($before) -join "`n") -eq (@($after) -join "`n")) 'Generator -Check rewrote a fixture containing drift.'
        }
        Invoke-Test 'generator -Check detects UTF-8 BOM drift without writing' {
            $fixture = New-Fixture 'generator-check-bom'
            $brief = Join-Path $fixture $firstBriefingRelative
            Add-Utf8Bom $brief
            $before = Get-Snapshot $fixture
            $result = Invoke-PwshFile $generator @('-RepoRoot', $fixture, '-Config', (Get-FixtureConfig $fixture), '-Check')
            Assert-True ($result.ExitCode -ne 0 -and $result.Output -match '(?i)UTF-8 BOM') 'Generator -Check did not report the UTF-8 BOM.'
            $after = Get-Snapshot $fixture
            Assert-True ((@($before) -join "`n") -eq (@($after) -join "`n")) 'Generator -Check rewrote a fixture containing a UTF-8 BOM.'
        }
    } else {
        $message = 'SKIP: generator -Check phase (the generator has no -Check parameter; use -ExpectGeneratorCheck to require it).'
        [void]$skips.Add($message)
        Write-Output $message
        if ($ExpectGeneratorCheck) { [void]$testFailures.Add('generator -Check phase: expected a -Check parameter, but none was found.') }
    }

    if (-not $generatorInputReady) {
        $message = 'SKIP: briefing content JSON phase (the configured briefing content source is absent; use -ExpectGeneratorJson to require it).'
        [void]$skips.Add($message)
        Write-Output $message
        if ($ExpectGeneratorJson) { [void]$testFailures.Add('briefing content JSON phase: configured briefing content source is absent.') }
    } else {
        Invoke-Test 'briefing content JSON contract' { Assert-BriefingContentJson $jsonPath }
    }
} finally {
    if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot -PathType Container)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    } elseif ($KeepTemp) {
        Write-Output "Temporary fixtures retained at $tempRoot"
    }
}

Write-Output ("Campaign test summary: {0} failure(s), {1} skipped phase(s)." -f $testFailures.Count, $skips.Count)
if ($testFailures.Count -gt 0) {
    Write-Error ($testFailures -join "`n")
    exit 1
}
exit 0
