# Sea Power Campaign Tools

Reusable PowerShell 7 tooling for authored Sea Power campaigns. The commands
are intentionally campaign-neutral: all package paths, localization, briefing
layout, and campaign-specific validation policy come from a versioned manifest.

## Commands

From a campaign repository root:

```powershell
pwsh -NoProfile -File .\tools\sea-power-campaign-tools\scripts\Generate-SeaPowerBriefings.ps1 `
  -RepoRoot . -Config .\.campaign-tools\campaign.json

pwsh -NoProfile -File .\tools\sea-power-campaign-tools\scripts\Generate-SeaPowerBriefings.ps1 `
  -RepoRoot . -Config .\.campaign-tools\campaign.json -Check

pwsh -NoProfile -File .\tools\sea-power-campaign-tools\scripts\Invoke-SeaPowerCampaignValidation.ps1 `
  -RepoRoot . -Config .\.campaign-tools\campaign.json -GameRoot 'C:\Program Files (x86)\Steam\steamapps\common\Sea Power'

pwsh -NoProfile -File .\tools\sea-power-campaign-tools\tests\Test-SeaPowerCampaignTools.ps1 `
  -RepoRoot . -Config .\.campaign-tools\campaign.json
```

`-Check` is read-only and reports generated XML or localized INI drift.
`-GenerateXml` writes briefing XML while leaving mission INIs unchanged. The
validator skips installed-unit ID checks with a warning when `-GameRoot` is
missing.

## Manifest

The manifest is JSON with `schemaVersion: 1`. See
`schema/campaign-manifest.schema.json` for the complete contract and
`examples/minimal-campaign.json` for the smallest useful configuration.

Required top-level values are `campaign`, `locales`, and `briefing`. The
`campaign` object resolves package paths relative to the manifest and contains
an ID, display name, campaign root, metadata path, campaigns root, and INI
filename. `briefing` supplies the authored content JSON, path pattern, required
fields/headings, and localized labels. The optional `validation` object holds
campaign-specific declarative rules; omitted rules disable only those optional
checks.

## Adding a campaign

1. Add this repository as a Git submodule (for example,
   `tools/sea-power-campaign-tools`) and pin it to a reviewed commit.
2. Add `.campaign-tools/campaign.json` and its briefing content JSON.
3. Populate paths and policies using the manifest schema.
4. Run the briefing check, validator, and fixture tests from the campaign root.

The toolkit contains no campaign art, mission content, or generated package
assets.
