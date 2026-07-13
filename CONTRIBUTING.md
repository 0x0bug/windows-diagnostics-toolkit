# Contributing

Windows Diagnostics Toolkit accepts focused fixes, tests, documentation improvements, and new read-only diagnostic ideas.

## Project boundaries

Contributions must remain read-only. Do not add automatic remediation, registry or service changes, update installation, log cleanup, telemetry, uploads, remote collection, installers, GUIs, Docker, WSL, or third-party runtime dependencies.

## Development workflow

1. Create a focused branch from `main`.
2. Keep one logical change per pull request.
3. Add or update dependency-free tests when behavior changes.
4. Run validation in both supported shells:

```powershell
pwsh -NoProfile -File .\scripts\validate.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1
```

5. Run the relevant module tests and a temporary-output smoke test.
6. Remove generated reports before committing.

## Built-in diagnostic modules

Standard diagnostics live under `modules/<slug>/` with a declarative `module.psd1` and one automatically executed `diagnostic.ps1` entrypoint. Module-local helper scripts are allowed, but every package `.ps1` is parsed and checked by the AST safety policy. Do not add external plugin paths, lifecycle callbacks, executable manifest values, or remote loading.

Use `-Module <Id>` for the general CLI selector. Existing individual switches and documented `scripts/*.ps1` paths are compatibility contracts. See [Built-in Diagnostic Module Authoring](docs/module-authoring.md) for the exact ten-field schema, option bindings, containment rules, and test commands.

## Reports and privacy

Never attach a raw personal diagnostic report to an issue. Generate a combined report with `-PrivacyMode`, review it manually, and remove any remaining data you do not want to publish.

## Pull request description

Include:

- what changed;
- why the change is useful;
- commands used for verification;
- confirmation that no system-changing behavior or external runtime dependency was added.
