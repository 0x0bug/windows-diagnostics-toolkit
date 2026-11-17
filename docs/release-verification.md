# Release verification

The CI validation job runs repository validation and the regression suites in
PowerShell 7 and Windows PowerShell 5.1 on `windows-latest`. A successful push
to `main` may publish the version in `VERSION` only after validation succeeds.
The release job builds one ZIP, verifies its checksum and packaged source bytes,
and runs the actual extracted package in both engines before publication.
Every successful push verifies the published ZIP against its published SHA-256,
including when a release already exists. For new releases, it also compares
both uploaded files to the tested local artifacts. Existing release files are
kept intact.

## Package and website handoff

1. Review the release notes in `docs/releases/<VERSION>.md` and merge only after
   the pull-request checks succeed.
2. Wait for the `publish` job on the final `main` commit. Confirm that the
   prerelease contains the versioned ZIP and its `.sha256` file.
3. In `0x0bug/wdt-site`, copy `scripts/bootstrap/run.ps1` to `run.ps1` with
   `scripts/Sync-WdtSiteBootstrap.ps1 -SiteCheckoutPath <site-checkout>`.
4. Update the site's versioned release links and displayed ZIP checksum from
   the published assets. Publish the site only after those assets exist.
5. Check the website CI, HTTPS pages, bootstrap bytes, version and checksum.

The release workflow is a repository-maintenance operation. It publishes only
the packaged toolkit; diagnostics do not upload reports or machine data.

## Windows client checks

CI is evidence for its runner environment, not a claim that all client systems
have been tested. Record actual OS build, display language, terminal, privilege,
PowerShell version and result for each manual check. Do not mark a row passed
without running it.

| Environment | Status |
| --- | --- |
| Windows CI runner, PowerShell 5.1 and 7 | Results recorded in GitHub Actions |
| Windows 10, English and Russian, standard and elevated user | Manual verification required |
| Windows 11, English and Russian, standard and elevated user | Manual verification required |
| Interactive bootstrap and terminal resizing on a client PC | Manual verification required |

For each applicable client environment, use a temporary report folder and run:

```powershell
$out = Join-Path $env:TEMP ('wdt-client-check-' + [guid]::NewGuid().ToString('N'))
.\Invoke-WindowsDiagnostics.ps1 -Module Time,Performance,Network -NoExternalNetworkTests -PrivacyMode -ExportMarkdown -OutputDirectory $out
.\Invoke-WindowsDiagnostics.ps1 -Module System,Crashes,Events,Updates -SaveSnapshot -PrivacyMode -ExportMarkdown -OutputDirectory $out
.\Invoke-WindowsDiagnostics.ps1 -IncidentSymptom AppFailure -IncidentAt ([datetimeoffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz')) -PrivacyMode -ExportMarkdown -OutputDirectory $out
```

Capture a second snapshot and compare the two actual JSON paths with
`-BeforeSnapshot` and `-AfterSnapshot`. Check TXT/Markdown readability,
source-availability statements and per-action exit codes; findings are not
execution failures. Review all artifacts manually before sharing them.
Run the public bootstrap interactively after inspecting its source. Confirm
that reports survive temporary-package cleanup and the TUI can exit normally.
