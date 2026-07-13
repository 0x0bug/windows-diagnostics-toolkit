# Built-in Diagnostic Module Authoring

Windows Diagnostics Toolkit discovers trusted, repository-owned diagnostics from `modules/*/module.psd1`. This registry is not an external plugin system: modules are reviewed with the repository, and WDT does not load modules from the current directory, user profiles, `%APPDATA%`, or remote sources.

## Package layout

A standard built-in module needs one manifest and one entrypoint:

```text
modules/<lowercase-slug>/
  module.psd1
  diagnostic.ps1
```

The manifest selects exactly one automatically executed `EntryPoint`. Additional module-local `.ps1` helper scripts and normal subdirectories are allowed inside the same package. Every `.ps1` in the package is parsed and checked by the AST safety policy whether or not the entrypoint imports it. Reparse points, symbolic links, and junctions are not allowed anywhere inside a production package.

## Manifest schema

The canonical manifest keys are case-sensitive in documentation but are matched case-insensitively by the importer:

```powershell
@{
    SchemaVersion = 1
    Id = 'Example'
    Title = 'Example Diagnostics'
    Label = 'Example diagnostics'
    Description = 'A short description of the read-only context collected.'
    EntryPoint = 'diagnostic.ps1'
    Recommended = $false
    Order = 110
    DefaultArguments = @()
    OptionBindings = @{}
}
```

All ten keys are required and no unknown keys are accepted. Duplicate keys are rejected without regard to case. The spelling above is canonical for production manifests, while the importer accepts different key casing and normalizes it. `SchemaVersion` and `Order` must be `Int32`, `Recommended` must be Boolean, text values must be non-empty strings, `DefaultArguments` must be a flat array of non-empty string tokens, and `OptionBindings` must be a flat string-to-string dictionary that maps supported core-option names to top-level entrypoint parameter names. Scriptblocks, expressions, nested collections, and complex values are rejected before the manifest is imported.

Registry snapshots, definitions, argument lists, option bindings, and script-path lists are exposed through built-in read-only collections. Module code must not attempt to mutate registry state or depend on raw manifest objects.

`Id` must match `^[A-Z][A-Za-z0-9]{1,31}$`. `EntryPoint` must be a relative `.ps1` path contained in the package; absolute paths, `..`, missing files, and reparse points are rejected. Package folder names are organizational slugs and are not runtime identity.

## Arguments and core options

`DefaultArguments` contains the argument tokens always supplied by the combined report runner. Tokens are passed directly to the existing process runner and are never evaluated as PowerShell source.

`OptionBindings` maps a supported WDT core option to an actual parameter in the entrypoint's top-level `param()` block. Target names are matched case-insensitively, duplicate targets are rejected, and target types must be compatible:

- Boolean sources bind to `[switch]` parameters whose default is absent or `$false`.
- String sources bind to `[string]` parameters.
- Integer sources bind to `[int]` parameters.

Aliases and parameters declared only inside nested functions are not valid targets. Adding a new core option requires a separate, justified core change; a manifest cannot invent one.

## Diagnostic contract

Entrypoints must remain read-only and work in Windows PowerShell 5.1 and PowerShell 7. Use the shared helper from `scripts/report-common.ps1`; do not copy it into the package. Emit human-readable context to stdout and use `Write-WdtFinding` for stable findings. Do not hide failures behind catch-all fallbacks.

Combined reports interpret execution as follows:

- exit code `0`: the module executed successfully;
- non-zero exit code: execution failed and collection is partial;
- timeout or launch failure: the process runner records the existing timeout/error finding and completeness state.

Finding severity does not itself change the process exit code. Preserve existing finding codes, severity, evidence, thresholds, stdout/stderr behavior, and exit semantics when moving or extending a diagnostic.

Legacy standalone launchers under `scripts/` are compatibility entrypoints. If an established standalone path exists, keep its exact parameter contract and delegate to the package entrypoint without duplicating diagnostic logic.

## Safety and testing

Before submitting a module:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\module-registry.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\module-registry.tests.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1
```

Registry validation checks manifest data, containment, reparse points, the entrypoint parameter contract, parser errors, and AST policy for every package script. Add targeted tests for the diagnostic's classification logic and safe fixture tests for any compatibility launcher.

After a valid package is added, it automatically appears in the interactive TUI according to `Order`, participates in `-All`, and can be selected by ID:

```powershell
.\Invoke-WindowsDiagnostics.ps1 -Module Example
```

Do not add a production example package merely to demonstrate the format. The example above is documentation only.
