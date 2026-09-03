#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [Parameter(Mandatory = $true)]
    [string]$Config,
    [switch]$Check,
    [switch]$GenerateXml
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'CampaignTools.Common.ps1')
$manifest = Read-CampaignToolManifest $Config $RepoRoot
$RepoRoot = $manifest.RepoRoot
$CampaignRoot = $manifest.CampaignRoot

$locales = @($manifest.Locales)
$requiredFields = @($manifest.RequiredBriefingFields)
$contentPath = $manifest.BriefingContentPath

function Fail([string]$Message) { throw "Briefing content error: $Message" }

function Get-Node([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    return $null
}

function Get-ObjectKeys([object]$Object) {
    if ($null -eq $Object) { return @() }
    if ($Object -is [System.Collections.IDictionary]) { return @($Object.Keys) }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-LocaleNode([object]$Container, [string]$Locale) {
    $node = Get-Node $Container $Locale
    if ($null -ne $node) { return $node }
    foreach ($item in @($Container)) {
        $code = Get-Node $item 'locale'
        if ([string]$code -ieq $Locale) { return $item }
    }
    return $null
}

function Test-NonEmptyString([object]$Value) {
    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Read-ContentData {
    if (-not (Test-Path -LiteralPath $contentPath -PathType Leaf)) { Fail "missing JSON source: $contentPath" }
    try {
        return ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $contentPath).Path) | ConvertFrom-Json -Depth 100)
    } catch { Fail "invalid JSON source $contentPath ($($_.Exception.Message))" }
}

function Validate-ContentData([object]$Data) {
    $version = Get-Node $Data 'schemaVersion'
    if ($null -eq $version -or [int]$version -ne 1) { Fail 'schemaVersion must be 1' }
    $declaredLocales = @(Get-Node $Data 'locales' | ForEach-Object { [string]$_ })
    if ($declaredLocales.Count -ne $locales.Count) { Fail "locales must contain exactly $($locales.Count) entries" }
    for ($i = 0; $i -lt $locales.Count; $i++) {
        if ($declaredLocales[$i] -cne $locales[$i]) { Fail "locales must be ordered as $($locales -join ',')" }
    }
    $records = @(Get-Node $Data 'missions')
    if ($records.Count -eq 0) { Fail 'missions must contain at least one record' }
    $seenFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $seenCodes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    for ($i = 0; $i -lt $records.Count; $i++) {
        $record = $records[$i]
        $file = [string](Get-Node $record 'file')
        $code = [string](Get-Node $record 'code')
        if (-not (Test-NonEmptyString $file)) { Fail "mission $($i + 1) is missing file" }
        if (-not (Test-NonEmptyString $code)) { Fail "mission $file is missing code" }
        if (-not $seenFiles.Add($file)) { Fail "duplicate mission file '$file'" }
        if (-not $seenCodes.Add($code)) { Fail "duplicate mission code '$code'" }
        $briefings = Get-Node $record 'briefings'
        if ($null -eq $briefings) { Fail "mission $file is missing briefings" }
        foreach ($locale in $locales) {
            $node = Get-LocaleNode $briefings $locale
            if ($null -eq $node) { Fail "mission $file is missing locale '$locale'" }
            foreach ($field in $requiredFields) {
                if (-not (Test-NonEmptyString (Get-Node $node $field))) { Fail "mission $file locale '$locale' is missing non-empty $field" }
            }
            $labels = Get-Node $node 'labels'
            if ($null -ne $labels) {
                foreach ($labelKey in Get-ObjectKeys $labels) {
                    if ($labelKey -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { Fail "mission $file locale '$locale' has invalid label key '$labelKey'" }
                    if (-not (Test-NonEmptyString (Get-Node $labels $labelKey))) { Fail "mission $file locale '$locale' label '$labelKey' is empty" }
                }
            }
        }
    }
    return $records
}

function Get-Text([object]$Node, [string]$Field) {
    $value = Get-Node $Node $Field
    if (-not (Test-NonEmptyString $value)) { Fail "missing $Field while generating briefing" }
    return [string]$value
}

function Get-Heading([string]$Locale, [string]$Field) {
    $labels = Get-ManifestValue $manifest.Briefing 'labels'
    $localeLabels = Get-ManifestValue $labels $Locale
    $value = Get-ManifestValue $localeLabels $Field
    if (-not (Test-NonEmptyString $value)) { Fail "manifest briefing.labels.$Locale.$Field is missing" }
    return [string]$value
}

function New-BriefingXml([object]$Node, [string]$Locale) {
    function Escape-Xaml([string]$Value) { return [System.Security.SecurityElement]::Escape($Value) }

    $title = Escape-Xaml (Get-Text $Node 'title')
    $description = Escape-Xaml (Get-Text $Node 'description')
    # The generated layout uses double-quoted attributes, so preserve a
    # campaign's apostrophes exactly as authored while still escaping other
    # XML-sensitive characters.
    $headerValue = [string](Get-ManifestValue $manifest.Branding 'header' $manifest.CampaignName)
    $campaignName = (Escape-Xaml $headerValue).Replace('&apos;', "'")
    $briefHeading = Escape-Xaml (Get-Heading $Locale 'brief')
    $footer = Escape-Xaml (Get-Heading $Locale 'footer')
    $cards = [System.Collections.Generic.List[string]]::new()
    $cardIndex = 0
    foreach ($field in @('situation', 'mission', 'execution', 'roe', 'friendly', 'support')) {
        $heading = Escape-Xaml (Get-Heading $Locale $field)
        $value = Escape-Xaml (Get-Text $Node $field)
        $background = if (($cardIndex % 2) -eq 0) { '#142630' } else { '#10212A' }
        [void]$cards.Add(('      <Border Grid.Row="{0}" Background="{1}" BorderBrush="#2C5668" BorderThickness="1" Padding="12,10" Margin="0,0,0,8">
        <StackPanel>
          <TextBlock FontSize="13" FontWeight="Bold" Foreground="#71B8D5">{2}</TextBlock>
          <TextBlock TextWrapping="Wrap" FontSize="16" LineHeight="22" Foreground="#E2E8EB" Margin="0,5,0,0">{3}</TextBlock>
        </StackPanel>
      </Border>' -f $cardIndex, $background, $heading, $value))
        $cardIndex++
    }

    $cardText = $cards -join "`n"
    return @"
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="#101922" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
  <Grid.RowDefinitions>
    <RowDefinition Height="Auto" />
    <RowDefinition Height="Auto" />
    <RowDefinition Height="*" />
    <RowDefinition Height="Auto" />
  </Grid.RowDefinitions>
  <Border Grid.Row="0" Background="#193644" BorderBrush="#5AA7C9" BorderThickness="1" Padding="14,10" Margin="8,8,8,0">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*" />
        <ColumnDefinition Width="Auto" />
      </Grid.ColumnDefinitions>
      <TextBlock Text="$campaignName" FontSize="15" FontWeight="Bold" Foreground="#7EC6E1" />
      <TextBlock Grid.Column="1" Text="$briefHeading" FontSize="15" FontWeight="Bold" Foreground="#C4D6DF" />
    </Grid>
  </Border>
  <Border Grid.Row="1" Background="#101922" BorderBrush="#2C5668" BorderThickness="1" Padding="14,12" Margin="8,12,8,10">
    <StackPanel>
      <TextBlock Text="$title" FontSize="28" FontWeight="Bold" Foreground="#E8EDF0" TextWrapping="Wrap" />
      <TextBlock Text="$description" FontSize="16" Foreground="#71B8D5" TextWrapping="Wrap" Margin="0,6,0,0" />
    </StackPanel>
  </Border>
  <Grid Grid.Row="2" Margin="8,0,8,0">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
    </Grid.RowDefinitions>
$cardText
  </Grid>
  <Border Grid.Row="3" Background="#193644" BorderBrush="#2C5668" BorderThickness="1" Padding="12,8" Margin="8,4,8,8">
    <TextBlock Text="$footer" FontSize="12" Foreground="#A9BBC4" TextWrapping="Wrap" />
  </Border>
</Grid>
"@
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Read-LinesPreservingNewline([string]$Path) {
    $raw = [System.IO.File]::ReadAllText($Path)
    $firstNewline = [regex]::Match($raw, "`r?`n")
    $newline = if ($firstNewline.Success) { $firstNewline.Value } else { "`r`n" }
    $hasFinalNewline = $raw.EndsWith("`n")
    $lines = @([regex]::Split($raw, "`r?`n"))
    while ($lines.Count -gt 0 -and $lines[-1] -eq '') {
        if ($lines.Count -eq 1) { $lines = @(); break }
        $lines = @($lines[0..($lines.Count - 2)])
    }
    return [pscustomobject]@{ Lines = $lines; Newline = $newline; HasFinalNewline = $hasFinalNewline }
}

function Get-ExpectedIniUpdates([object]$Record, [string]$Locale, [object]$Node) {
    $pattern = [string](Get-ManifestValue $manifest.Briefing 'pathPattern' 'campaigns/{campaignId}/missions/{stem}_briefing/BriefingText_{locale}.xml')
    $briefingPath = Expand-CampaignPathPattern $pattern $manifest.CampaignId ([string]$Record.file) $Locale
    $updates = [ordered]@{ Name = (Get-Text $Node 'title'); Description = (Get-Text $Node 'description'); MissionBriefingLeftPane = $briefingPath }
    $labels = Get-Node $Node 'labels'
    if ($null -ne $labels) { foreach ($key in (Get-ObjectKeys $labels | Sort-Object)) { $updates[$key] = [string](Get-Node $labels $key) } }
    return $updates
}

function Rewrite-IniLanguageLines([string]$Path, [object]$Record, [object]$Briefings, [bool]$Apply) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "missing mission INI: $Path" }
    $source = Read-LinesPreservingNewline $Path
    $output = [System.Collections.Generic.List[string]]::new()
    $section = $null
    foreach ($line in $source.Lines) {
        if ($line -match '^\[Language_([^\]]+)\]$') {
            # Reset language scope on each header so values never leak between locales.
            $section = $Matches[1]
            [void]$output.Add($line)
            continue
        }
        if ($line -match '^\[') { $section = $null }
        if ($null -eq $section -or $section -notin $locales -or $line -notmatch '^([^=]+)=(.*)$') {
            [void]$output.Add($line)
            continue
        }
        $key = $Matches[1]
        $updates = Get-ExpectedIniUpdates $Record $section (Get-LocaleNode $Briefings $section)
        if ($updates.Contains($key)) { [void]$output.Add($key + '=' + $updates[$key]) }
        else { [void]$output.Add($line) }
    }

    # Add declared values that are absent, immediately before the next section header.
    $final = [System.Collections.Generic.List[string]]::new()
    $section = $null
    $sectionStart = -1
    for ($i = 0; $i -lt $output.Count; $i++) {
        $line = $output[$i]
        if ($line -match '^\[Language_([^\]]+)\]$') { $section = $Matches[1]; $sectionStart = $final.Count }
        elseif ($line -match '^\[') { $section = $null; $sectionStart = -1 }
        [void]$final.Add($line)
        $nextIsHeader = ($i -eq $output.Count - 1) -or ($output[$i + 1] -match '^\[')
        if ($nextIsHeader -and $null -ne $section -and $section -in $locales) {
            $updates = Get-ExpectedIniUpdates $Record $section (Get-LocaleNode $Briefings $section)
            $existing = @{}
            for ($j = $sectionStart + 1; $j -lt $final.Count; $j++) { if ($final[$j] -match '^([^=]+)=') { $existing[$Matches[1]] = $true } }
            foreach ($key in $updates.Keys) { if (-not $existing.ContainsKey($key)) { [void]$final.Add($key + '=' + $updates[$key]) } }
        }
    }
    $result = ($final -join $source.Newline)
    if ($source.HasFinalNewline) { $result += $source.Newline }
    if ($Apply) { Write-Utf8NoBom $Path $result }
    return $result
}

function Test-XmlMatch([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "missing briefing XML: $Path" }
    # File.ReadAllText detects and removes a UTF-8 preamble. Inspect the raw
    # bytes first so -Check still reports a BOM as drift rather than silently
    # accepting a file whose encoding differs from the generated asset.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Fail "briefing XML has a UTF-8 BOM: $Path"
    }
    $actual = [System.IO.File]::ReadAllText($Path)
    if ($actual -cne $Expected) { Fail "briefing XML drift: $Path" }
    try { $document = [System.Xml.XmlDocument]::new(); $document.XmlResolver = $null; $document.LoadXml($actual) }
    catch { Fail "invalid briefing XML $Path ($($_.Exception.Message))" }
}

function Test-TextSemantics([object]$Record, [object]$Node, [string]$Locale, [string]$Xml) {
    $document = [System.Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    $document.LoadXml($Xml)
    $plainText = $document.DocumentElement.InnerText
    foreach ($field in @('situation', 'mission', 'execution', 'roe', 'friendly', 'support')) {
        $heading = Get-Heading $Locale $field
        if ($plainText.IndexOf($heading, [System.StringComparison]::Ordinal) -lt 0) { Fail "$($Record.file) $Locale briefing misses heading '$heading'" }
        $value = Get-Text $Node $field
        if ($plainText.IndexOf($value, [System.StringComparison]::Ordinal) -lt 0) { Fail "$($Record.file) $Locale briefing misses $field text" }
    }
}

try {
    if ($Check -and $GenerateXml) { Fail '-Check and -GenerateXml cannot be combined' }
    $data = Read-ContentData
    $records = Validate-ContentData $data
    $root = (Resolve-Path -LiteralPath $CampaignRoot).Path
    $missionDirectory = Join-Path $root 'missions'
    $drift = [System.Collections.Generic.List[string]]::new()
    foreach ($record in $records) {
        $briefings = Get-Node $record 'briefings'
        $briefingDirectory = Join-Path $missionDirectory ($record.file + '_briefing')
        if (-not (Test-Path -LiteralPath $briefingDirectory -PathType Container)) {
            if ($Check) { Fail "missing briefing directory: $briefingDirectory" }
            New-Item -ItemType Directory -Force -Path $briefingDirectory | Out-Null
        }
        $iniPath = Join-Path $missionDirectory ($record.file + '.ini')
        foreach ($locale in $locales) {
            $node = Get-LocaleNode $briefings $locale
            $xmlPath = Join-Path $briefingDirectory ('BriefingText_' + $locale + '.xml')
            $expectedXml = New-BriefingXml $node $locale
            if ($Check) {
                try { Test-XmlMatch $xmlPath $expectedXml; Test-TextSemantics $record $node $locale $expectedXml }
                catch { [void]$drift.Add($_.Exception.Message) }
            } else { Write-Utf8NoBom $xmlPath $expectedXml }
        }
        if (-not $GenerateXml -and (Test-Path -LiteralPath $iniPath -PathType Leaf)) {
            try {
                $rewrittenIni = Rewrite-IniLanguageLines $iniPath $record $briefings (-not $Check)
                if ($Check -and $rewrittenIni -cne [System.IO.File]::ReadAllText($iniPath)) { [void]$drift.Add("mission INI drift: $iniPath") }
            }
            catch { if ($Check) { [void]$drift.Add($_.Exception.Message) } else { throw } }
        } elseif (-not $GenerateXml -and $Check) { [void]$drift.Add("missing mission INI: $iniPath") }
    }
    if ($Check -and $drift.Count -gt 0) { foreach ($item in $drift) { [Console]::Error.WriteLine([string]$item) }; exit 1 }
    if ($Check) { Write-Output "Briefing content matches $($records.Count) missions x $($locales.Count) locales." }
    elseif ($GenerateXml) { Write-Output "Generated $($records.Count * $locales.Count) briefing XML files without rewriting mission INIs." }
    else { Write-Output "Generated $($records.Count * $locales.Count) briefing XML files from $contentPath." }
    exit 0
} catch { Write-Error ($_.Exception.Message + "`n" + $_.ScriptStackTrace); exit 1 }
