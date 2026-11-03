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

## Opt-in structured diagnostic data (schema 1)

System, Crashes, Events, and Updates additionally support an internal in-memory
data request. Existing CLI entrypoints and standalone launchers retain their
parameter blocks and default text behavior. This data contract was selected by
the orchestrator during implementation of the snapshots/incident MVP; it is
separate from the toolkit VERSION and from the manifest SchemaVersion.

`Invoke-DiagnosticScript` accepts optional `-CollectData -ModuleId <Id>
-DataStartUtc <ISO8601> -DataEndUtc <ISO8601>`. Both boundaries are optional
together; when supplied they define `[start, end)` and require an explicit `Z`
or offset. Every child has inherited `WDT_DATA_*` controls overwritten, including
legacy calls with collection disabled. Registry manifests have no new fields.

The result retains all existing properties and adds `Data`, `DataStatus`, and
`DataErrors`. Status is `NotCollected`, `Available`, `Partial`, or `Unavailable`.
An exit code of zero or complete stdout is not evidence of complete sources.
`Data` is either null or a module object with these required properties:

| Object | Fields |
| --- | --- |
| Module | `SchemaVersion` integer 1; `ModuleId`; nullable `WindowStartUtc`/`WindowEndUtc`; arrays `Sources`, `Facts`, `Evidence` |
| Source | `Id`, `Kind`, `Scope`, `Availability`, boolean `QueryComplete`/`Truncated`, nullable integer `Limit`, `Coverage`, nullable `StartUtc`/`EndUtc`/`Error` |
| Fact | `Id`, `Type`, nullable `Key`, `IdentityScope`, `ValueState`, `Values` object, `Comparison`, arrays `SourceIds`/`EvidenceIds` |
| Evidence | `Id`, `SourceId`, nullable `TimestampUtc`, `TimePrecision`, nullable `EndUtc`/`OriginalOffset`/`LogName`/`Provider`/`EventId`/`RecordId`/`ReportId`, `Kind`, nullable `Component`/`FailureCode`/`Message` |

Source kinds are `Configuration`, `Inventory`, `History`; availability is
`Available`, `Partial`, `Unavailable`, `NotCollected`; coverage is `Unknown`,
`QueryWindow`, `CurrentState`. History adapters use `Unknown`: query completion
does not establish log retention. Reaching a query cap conservatively marks the
source Partial. An empty successful query remains Available; an inaccessible
reboot check produces an Unknown fact with null `Present`, not false.

Fact types, modules, comparison policies, and exact Values fields are closed:

| Type | Module / Comparison | Values (required keys) |
| --- | --- | --- |
| OsVersion | System / Configuration | Version:string, Build:string |
| RebootIndicator | Updates / Configuration | Name:string, Present:boolean |
| HotFix | Updates / Inventory | HotFixId:string, InstalledDate:nullable string |
| CrashObservation | Crashes / Windowed | Component:string, Kind:string, FailureCode:string |
| EventObservation | Events / Windowed | Provider:string, EventId:integer, Level:integer |
| UpdateFailure | Updates / Windowed | UpdateIdentifier:nullable string, Title:string, ErrorCode:string, Kind:string |

`ValueState` is Known, Unknown, or NotApplicable. Unknown/NotApplicable may carry
null for required value fields. `IdentityScope` is Semantic or SnapshotLocal;
only Semantic has a nonempty comparison key. Source IDs/scopes are fixed by each
adapter in `Assert-WdtDiagnosticData`, not user-provided identities. Fact IDs
`f<number>` and evidence IDs `e<number>` are local to a module; envelope consumers
must qualify references with ModuleId. Duplicate IDs, dangling refs, evidence
whose SourceId is not declared by its fact, incompatible module/type/comparison,
unknown properties, and stringified booleans/numbers are rejected.

Evidence kinds are Crash, Hang, BugCheck, Event, UpdateInstallationFailure,
UpdateDownloadFailure, HotFix. TimePrecision is Instant, Day, or Unknown. Instant
requires a timestamp; Day requires an uncertainty interval, not an event at
midnight; Unknown has no UTC timestamp or interval. OriginalOffset, when known,
is within -14:00 to +14:00. `InstalledDate` is a source-reported date such as
`2025-01-01`; an unspecified historical timezone does not become the current
machine offset. In that case evidence time remains Unknown and the date is
available separately for presentation. Get-HotFix is not a full Windows Update
installation history.

Use these shared helpers from `scripts/diagnostic-data.ps1`:

- `New-WdtDiagnosticData -ModuleId -WindowStartUtc -WindowEndUtc -Sources -Facts -Evidence`
- `New-WdtDataSource`, `New-WdtDataFact`, `New-WdtDataEvidence` (named parameters match the table)
- `Assert-WdtDiagnosticData -Data` (throws generic schema errors, never evaluates data)
- `ConvertTo-WdtDataUtcText -Value` (canonical ISO UTC text; rejects timezone-less or Unspecified input)
- `Get-WdtDataRequest` (Enabled, StartUtc, EndUtc from the closed child request)
- `Write-WdtDiagnosticData -Data` (opt-in only)
- `Resolve-WdtDiagnosticData -OutputLines -Nonce -ExpectedModuleId -ExecutionComplete`
  (Data, DataStatus, DataErrors, cleaned OutputLines)
- `Protect-WdtDiagnosticData -Data -Context` (copy, never mutates raw input)

The JSON wire protocol has authenticated Begin, Item, and End frames; end counts
and schema/ref integrity are checked. JSON payload limits are 16,384 characters
per frame, 12,000 items, and 16 MiB characters in total. Emission is bounded before
writing each item; overflow and missing end markers cannot be Available. The
existing general stdout capture is unchanged and these limits are not a new
global limit on legacy text output. Protocol errors do not echo raw payload.
There are no raw temporary JSON files.

PowerShell 7 JSON parsing may produce Int64 and DateTime where Windows
PowerShell 5.1 yields Int32 and timestamp strings. The validator accepts actual
Int32/Int64 values within Int32 range and the UTC helper accepts both timestamp
representations, preserving the same instant. Other primitive types stay strict.

Privacy projection removes command/URL secrets even without a privacy context;
with a context it protects nested values, errors, and evidence identity fields.
Any fact whose key or string values change becomes SnapshotLocal with no key.
Existing privacy token text is never promoted into a semantic key. The caller
must project before writing any artifact and must not serialize the redaction
context. Crashes exposes individual records before legacy five-minute merging;
new incident consumers must implement conservative correlation on those records.

The incident consumer in `scripts/incident.ps1` exposes
`Resolve-WdtIncidentWindow -Symptom -At [-BeforeMinutes 30 -AfterMinutes 30]`,
`Assert-WdtIncidentWindow -Window`, `New-WdtIncident -Window -Results
-ToolkitVersion -CollectionStartedUtc -CollectionFinishedUtc [-PrivacyMode
<bool>] [-Context]`, and `Get-WdtIncidentLines -Incident`. The window has canonical
`Symptom`, original `RequestedAt`/`OriginalOffset`, canonical `AtUtc`,
`StartUtc`/`EndUtc`, and integer `BeforeMinutes`/`AfterMinutes`. Both CLI and API
validate the window, and the API checks all precomputed fields against the
original request. Results use the accepted runner contract, in fixed
Crashes/Events/Updates order, with the same exact window in all module data.

The consumer reuses snapshot wrapper validation and privacy projection entirely
in memory; it does not write a snapshot or parse findings text. Strong identity
correlation precedes projection, and every returned source value is projected
under the report context. Summary/timeline refs use `ModuleId/EvidenceId`, not
raw identity values or cross-capture tokens. Returned collections are
Observations, Timeline, DateContext, Evidence, Coverage, and Limitations, together
with the requested/observed/collection bounds and action ExitCode. The helper
performs no file I/O. The launcher writes only its safe TXT/optional Markdown
presentation, using the existing unique report path and Markdown fence helpers.

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
