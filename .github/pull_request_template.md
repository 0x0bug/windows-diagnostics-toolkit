## Summary

Describe what changed and the user-visible effect.

## Motivation

Explain why this change is needed and what problem it solves.

## Validation

List the exact commands and environments used for verification.

- [ ] `pwsh -NoProfile -File .\scripts\validate.ps1`
- [ ] `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1`
- [ ] Relevant dependency-free tests were run in PowerShell 7.
- [ ] Relevant dependency-free tests were run in Windows PowerShell 5.1.
- [ ] A temporary-output report smoke test was completed when runtime behavior changed.
- [ ] Generated reports and temporary files were removed before commit.

## Project Boundaries

- [ ] The change remains read-only and does not modify Windows configuration.
- [ ] No telemetry, report upload, remote collection, or automatic remediation was added.
- [ ] No third-party runtime dependency was added.
- [ ] No external plugin path, remote script loading, or unreviewed executable entry point was added.
- [ ] Existing public parameters, standalone launchers, and documented behavior remain compatible, or the compatibility impact is explained below.

## Privacy and Security

Describe any effect on Privacy Mode, report contents, external network probes, process execution, path handling, or sensitive data exposure.

## Documentation

- [ ] User documentation was updated when public behavior changed.
- [ ] New documentation and user-facing text are written in English.
- [ ] Finding-code or report-format changes include migration notes when applicable.

## Compatibility Notes

State which Windows and PowerShell environments were tested, and list any known limitations or unverified cases.
