# Security Policy

## Supported versions

Security fixes are applied to the current prerelease, `v0.2.0-beta.2`, and `main`. Earlier beta packages remain available as historical releases.

## Release bootstrap

The documented `irm | iex` bootstrap downloads the fixed `v0.2.0-beta.2` GitHub Release ZIP and verifies its SHA-256 checksum before extraction and execution. It does not download code from a branch. SHA-256 verification protects the ZIP after download, but the one-line command still requires trust in the bootstrap delivered through GitHub Pages. Users who want to inspect it first should download `run.ps1` with `-OutFile`, review it, and then execute the saved file. Cloning the repository remains available for development and complete source inspection.

## Reporting a vulnerability

Do not publish sensitive machine data, unredacted diagnostic reports, credentials, tokens, private network details, or a working exploit in a public issue.

Use GitHub private vulnerability reporting when available. Otherwise contact the repository owner through the profile contact methods and include only the minimum information needed to reproduce the problem.

For ordinary false positives, compatibility problems, and non-sensitive bugs, use the public issue templates.

## Report privacy

Use `-PrivacyMode` before sharing a combined report and review the generated file manually before publication. Privacy Mode reduces exposure but cannot guarantee removal of arbitrary sensitive text contained in Windows Event Log messages or other application-provided text.

## Scope

The toolkit is intended to remain read-only, local, dependency-free, and free of telemetry or upload behavior. A change that violates those boundaries should be treated as a security concern.
