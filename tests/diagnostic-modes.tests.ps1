[CmdletBinding()]
param([switch]$RunLiveRecording)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-TargetedServiceReport {
    param([string]$Entrypoint, [string]$OutputDirectory)

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $fixture = [powershell]::Create()
    try {
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $pathAndQuery = '/health/wdt-private-path-marker?fixture=wdt-private-query-marker'
        $targetUrl = 'http://127.0.0.1:{0}{1}' -f $port, $pathAndQuery
        $null = $fixture.AddScript({
            param($Listener)

            $ErrorActionPreference = 'Stop'
            $client = $Listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 5000
                $stream.WriteTimeout = 5000
                $reader = [IO.StreamReader]::new($stream)
                try {
                    $requestLine = $reader.ReadLine()
                    do { $header = $reader.ReadLine() } while ($header)
                    $response = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 401 Unauthorized`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $stream.Write($response, 0, $response.Length)
                    $requestLine
                }
                finally { $reader.Dispose() }
            }
            finally { $client.Dispose() }
        }).AddArgument($listener)
        $worker = $fixture.BeginInvoke()

        # Even a regression that runs the default checks should stay local.
        $consoleLines = @(& $Entrypoint -NetworkWebServiceUrl $targetUrl -NetworkDnsTestName '127.0.0.1' `
                -NetworkHttpsEndpoint 'https://127.0.0.1:1/' -NetworkIcmpTarget '127.0.0.1' `
                -OutputDirectory $OutputDirectory -ExportMarkdown *>&1)

        Assert-True ($worker.AsyncWaitHandle.WaitOne(5000)) 'The launcher did not query the explicit loopback service.'
        $requestLines = @($fixture.EndInvoke($worker))
        Assert-True ($requestLines.Count -eq 1 -and [string]$requestLines[0] -ceq "GET $pathAndQuery HTTP/1.1") 'The service did not receive the configured path and query.'

        $reports = @(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'WindowsDiagnosticsReport-*' -File)
        Assert-True ($reports.Count -eq 2 -and '.txt' -in $reports.Extension -and '.md' -in $reports.Extension) 'The targeted service must produce the requested TXT and Markdown reports.'
        foreach ($report in $reports) {
            $content = Get-Content -LiteralPath $report.FullName -Raw
            Assert-True ($content.Contains('HTTP 401 Unauthorized')) 'The report dropped the targeted HTTP response.'
            Assert-True ($content -match ("(?m)^Port\s+: $port\r?$")) 'The report did not show the explicit service port.'
            Assert-True ($content.Contains('External tests: NotTested (web service target selected)')) 'Targeted reporting did not suppress the public probes.'
            Assert-True ($content -notmatch 'wdt-private-(path|query)-marker') 'The targeted URL path or query appeared in the report.'
        }
        Assert-True (($consoleLines -join "`n") -notmatch 'wdt-private-(path|query)-marker') 'The targeted URL path or query appeared in the console output.'
    }
    finally {
        $listener.Stop()
        $fixture.Dispose()
    }
}

$entrypoint = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-WindowsDiagnostics.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wdt-diagnostic-modes-' + [guid]::NewGuid().ToString('N'))
$beforeSnapshot = Join-Path $testRoot 'before.json'
$afterSnapshot = Join-Path $testRoot 'after.json'
$incidentAt = '2025-11-02T10:00:00Z'
$webServiceUrl = 'http://127.0.0.1:1234/health?fixture=diagnostic-modes'
$isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

try {
    $rejectedRequests = @(
        @{ Name = 'orphan-duration'; Arguments = @{ RecordingSeconds = 60 }; ErrorPattern = 'RecordPerformance' }
        @{ Name = 'duration-below-range'; Arguments = @{ RecordPerformance = $true; RecordingSeconds = 59 }; ErrorPattern = 'RecordingSeconds' }
        @{ Name = 'duration-above-range'; Arguments = @{ RecordPerformance = $true; RecordingSeconds = 121 }; ErrorPattern = 'RecordingSeconds' }
        @{ Name = 'recording-with-all'; Arguments = @{ RecordPerformance = $true; All = $true }; ErrorPattern = 'RecordPerformance|recording' }
        @{ Name = 'recording-with-individual-module'; Arguments = @{ RecordPerformance = $true; System = $true }; ErrorPattern = 'RecordPerformance|recording' }
        @{ Name = 'recording-with-generic-module'; Arguments = @{ RecordPerformance = $true; Module = 'Performance' }; ErrorPattern = 'RecordPerformance|recording' }
        @{ Name = 'recording-with-interactive'; Arguments = @{ RecordPerformance = $true; Interactive = $true }; ErrorPattern = 'RecordPerformance|recording' }
        @{ Name = 'recording-with-snapshot'; Arguments = @{ RecordPerformance = $true; SaveSnapshot = $true }; ErrorPattern = 'RecordPerformance|recording' }
        @{ Name = 'recording-with-comparison'; Arguments = @{ RecordPerformance = $true; BeforeSnapshot = $beforeSnapshot; AfterSnapshot = $afterSnapshot }; ErrorPattern = 'RecordPerformance|recording|snapshot comparison.*combin' }
        @{ Name = 'recording-with-incident'; Arguments = @{ RecordPerformance = $true; IncidentSymptom = 'AppFailure'; IncidentAt = $incidentAt }; ErrorPattern = 'RecordPerformance|recording|incident investigation.*combin' }
        @{ Name = 'recording-with-target'; Arguments = @{ RecordPerformance = $true; NetworkWebServiceUrl = $webServiceUrl }; ErrorPattern = 'RecordPerformance|recording' }
        @{ Name = 'recording-with-network-option'; Arguments = @{ RecordPerformance = $true; NoExternalNetworkTests = $true }; ErrorPattern = 'RecordPerformance|recording' }
        @{ Name = 'empty-url'; Arguments = @{ NetworkWebServiceUrl = '' }; ErrorPattern = 'HTTP|absolute|URL' }
        @{ Name = 'relative-url'; Arguments = @{ NetworkWebServiceUrl = '/health' }; ErrorPattern = 'HTTP|absolute|URL' }
        @{ Name = 'unsupported-url-scheme'; Arguments = @{ NetworkWebServiceUrl = 'ftp://example.test/health' }; ErrorPattern = 'HTTP|scheme|URL' }
        @{ Name = 'url-with-credentials'; Arguments = @{ NetworkWebServiceUrl = 'https://fixture-user:fixture-password@example.test/health' }; ErrorPattern = 'user|credential|URL' }
        @{ Name = 'url-with-fragment'; Arguments = @{ NetworkWebServiceUrl = 'https://example.test/health#fixture' }; ErrorPattern = 'fragment|URL' }
        @{ Name = 'target-with-unrelated-module'; Arguments = @{ NetworkWebServiceUrl = $webServiceUrl; System = $true }; ErrorPattern = 'Network' }
        @{ Name = 'target-with-snapshot'; Arguments = @{ NetworkWebServiceUrl = $webServiceUrl; Network = $true; SaveSnapshot = $true }; ErrorPattern = 'SaveSnapshot' }
        @{ Name = 'target-with-comparison'; Arguments = @{ NetworkWebServiceUrl = $webServiceUrl; BeforeSnapshot = $beforeSnapshot; AfterSnapshot = $afterSnapshot }; ErrorPattern = 'snapshot comparison.*combin|NetworkWebServiceUrl' }
        @{ Name = 'target-with-incident'; Arguments = @{ NetworkWebServiceUrl = $webServiceUrl; IncidentSymptom = 'AppFailure'; IncidentAt = $incidentAt }; ErrorPattern = 'incident investigation.*combin|NetworkWebServiceUrl' }
    )

    foreach ($request in $rejectedRequests) {
        $output = Join-Path $testRoot $request.Name
        $arguments = $request.Arguments
        $failure = $null
        try { & $entrypoint @arguments -OutputDirectory $output *> $null }
        catch { $failure = $_ }

        Assert-True (-not (Test-Path -LiteralPath $output)) "$($request.Name) changed the output directory before validation."
        Assert-True ($null -ne $failure) "$($request.Name) was accepted by the launcher."
        Assert-True ($failure.FullyQualifiedErrorId -notlike 'NamedParameterNotFound,*') "$($request.Name) used a missing launcher parameter."
        Assert-True ($failure.Exception.Message -match $request.ErrorPattern) "$($request.Name) failed for an unexpected reason. $($failure.Exception.Message)"
        Assert-True ($failure.Exception.Message -notmatch 'fixture-password') 'URL validation disclosed credentials.'
    }

    if ($isWindowsHost) {
        $output = Join-Path $testRoot 'target-network'
        & $entrypoint -NetworkWebServiceUrl $webServiceUrl -NoExternalNetworkTests -OutputDirectory $output *> $null
        $reports = @(Get-ChildItem -LiteralPath $output -Filter 'WindowsDiagnosticsReport-*.txt' -File)
        Assert-True ($reports.Count -eq 1) 'A target URL alone must produce a standard Network report.'
        $networkText = Get-Content -LiteralPath $reports[0].FullName -Raw
        Assert-True ($networkText -match '(?m)^Selected\s+: Network Check\r?$') 'A target URL selected more than the Network module.'
        Assert-True ($networkText.Contains('External tests: NotTested (-NoExternalNetworkTests)')) 'NoExternalNetworkTests did not disable the default probes.'
        Assert-True ($networkText.Contains('== Web Service Probe ==')) 'The explicitly selected target did not reach the Network module.'
        Assert-True ($networkText.Contains('Web service tests: NotTested (-NoExternalNetworkTests)')) 'NoExternalNetworkTests did not disable the targeted probe.'
        Test-TargetedServiceReport -Entrypoint $entrypoint -OutputDirectory (Join-Path $testRoot 'active-target-network')
    }

    if ($RunLiveRecording) {
        Assert-True $isWindowsHost 'The scheduled recording smoke test requires Windows.'
        $output = Join-Path $testRoot 'live-recording'
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        & $entrypoint -RecordPerformance -PrivacyMode -ExportMarkdown -OutputDirectory $output *> $null
        $stopwatch.Stop()

        $artifacts = @(Get-ChildItem -LiteralPath $output -File)
        $textReports = @($artifacts | Where-Object { $_.Name -like 'WindowsDiagnosticsRecording-*.txt' })
        $markdownReports = @($artifacts | Where-Object { $_.Name -like 'WindowsDiagnosticsRecording-*.md' })
        Assert-True ($artifacts.Count -eq 2 -and $textReports.Count -eq 1 -and $markdownReports.Count -eq 1) 'Recording must produce matching TXT and Markdown reports only.'
        Assert-True ($textReports[0].BaseName -eq $markdownReports[0].BaseName) 'The recording report filenames must share a base name.'
        Assert-True ($stopwatch.Elapsed.TotalSeconds -ge 59) 'The default recording ended before the sampling window.'

        $recordingText = Get-Content -LiteralPath $textReports[0].FullName -Raw
        $recordingMarkdown = Get-Content -LiteralPath $markdownReports[0].FullName -Raw
        foreach ($report in @($recordingText, $recordingMarkdown)) {
            Assert-True ($report.Contains('Performance Recording')) 'The recording report title is missing.'
            Assert-True ($report.Contains('Requested duration: 60 s')) 'Omitting RecordingSeconds did not request 60 seconds.'
            Assert-True ($report.Contains('Sample interval: 2 s')) 'The sampling interval is missing or incorrect.'
            Assert-True ($report.Contains('Source Coverage')) 'The recording report is missing source coverage.'
            Assert-True ($report.Contains('Recording Peaks')) 'The recording report is missing the peaks summary.'
            Assert-True ($report.Contains('Timestamped Samples')) 'The recording report is missing its timed observations.'
        }

        $sampleCount = [regex]::Match($recordingText, '(?m)^Samples collected: (\d+)/30\r?$')
        Assert-True $sampleCount.Success 'The report did not show the scheduled and collected sample counts.'
        $samples = [regex]::Matches($recordingText, '(?m)^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z \(\+(\d+\.\d{3}) s\)')
        Assert-True ($samples.Count -ge 2 -and $samples.Count -eq [int]$sampleCount.Groups[1].Value) 'The recording did not contain the reported number of timestamped observations.'
        $previousElapsed = -1
        foreach ($sample in $samples) {
            $elapsed = [double]::Parse($sample.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
            Assert-True ($elapsed -gt $previousElapsed) 'Recording sample offsets must increase.'
            $previousElapsed = $elapsed
        }
        Assert-True ($recordingText -match '(?m)^\s*(CPU|RAM): [1-9]\d*/\d+ measured') 'The recorder reported no measured CPU or RAM evidence.'
        Assert-True ($recordingText -match '(?m)^Completeness: (Complete|Partial)\r?$') 'Live recording did not collect usable performance evidence.'
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host 'Diagnostic mode CLI tests passed.'
