[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$siteRoot = Join-Path -Path $repositoryRoot -ChildPath 'site'
$separatorCharacters = [char[]]@('\', '/')
$siteRootFull = [System.IO.Path]::GetFullPath($siteRoot).TrimEnd($separatorCharacters)
$publishedBaseUrl = 'https://0x0bug.github.io/windows-diagnostics-toolkit/'
$projectPathPrefix = '/windows-diagnostics-toolkit/'

$issues = New-Object System.Collections.Generic.List[string]

function Add-TestIssue {
    param([Parameter(Mandatory = $true)][string]$Message)
    $issues.Add($Message)
}

function Get-FirstMatchValue {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    $match = [regex]::Match($Text, $Pattern, $options)
    if (-not $match.Success) {
        return $null
    }

    return [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value.Trim())
}

function Get-RelativeSitePath {
    param([Parameter(Mandatory = $true)][string]$FullPath)

    $full = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $full.StartsWith($siteRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full
    }

    return $full.Substring($siteRootFull.Length).TrimStart($separatorCharacters).Replace('\', '/')
}

function Resolve-LocalSiteTarget {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$SourceFile,
        [Parameter(Mandatory = $true)][string]$Reference
    )

    $referenceWithoutFragment = ($Reference -split '#', 2)[0]
    $pathPart = ($referenceWithoutFragment -split '\?', 2)[0]
    if ([string]::IsNullOrWhiteSpace($pathPart)) {
        return $null
    }

    if ($pathPart -match '(?i)^(https?:|mailto:|tel:|javascript:|data:)') {
        return $null
    }

    $isDirectoryReference = $pathPart.EndsWith('/') -or $pathPart -eq '.' -or $pathPart -eq '..'

    if ($pathPart.StartsWith($projectPathPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $pathPart.Substring($projectPathPrefix.Length).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $target = Join-Path -Path $siteRoot -ChildPath $relative
    }
    elseif ($pathPart.StartsWith('/')) {
        Add-TestIssue "Unsupported absolute local path in $($SourceFile.Name): $Reference"
        return $null
    }
    else {
        $relative = $pathPart.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $target = Join-Path -Path $SourceFile.DirectoryName -ChildPath $relative
    }

    $target = [System.IO.Path]::GetFullPath($target)
    if ($isDirectoryReference) {
        $target = Join-Path -Path $target -ChildPath 'index.html'
    }

    return $target
}

if (-not (Test-Path -LiteralPath $siteRoot -PathType Container)) {
    throw "Site directory is missing: $siteRoot"
}

$htmlFiles = @(Get-ChildItem -LiteralPath $siteRoot -Recurse -Filter '*.html' -File | Sort-Object -Property FullName)
if ($htmlFiles.Count -lt 2) {
    Add-TestIssue 'Expected at least a homepage and one additional HTML page.'
}

$titleOwners = @{}
$canonicalOwners = @{}
$descriptionOwners = @{}
$indexableCanonicals = New-Object System.Collections.Generic.List[string]

foreach ($file in $htmlFiles) {
    $relativePath = Get-RelativeSitePath -FullPath $file.FullName
    $html = Get-Content -LiteralPath $file.FullName -Raw
    $isNotFoundPage = $relativePath -eq '404.html'

    if ($html -notmatch '(?i)<html\s+[^>]*lang=["'']en["'']') {
        Add-TestIssue "$relativePath is missing html lang=en."
    }

    $title = Get-FirstMatchValue -Text $html -Pattern '<title>\s*(.*?)\s*</title>'
    if ([string]::IsNullOrWhiteSpace($title)) {
        Add-TestIssue "$relativePath is missing a title."
    }
    else {
        if ($title.Length -lt 15 -or $title.Length -gt 70) {
            Add-TestIssue "$relativePath title length is $($title.Length); expected 15-70 characters."
        }
        if ($titleOwners.ContainsKey($title)) {
            Add-TestIssue "$relativePath duplicates the title used by $($titleOwners[$title])."
        }
        else {
            $titleOwners[$title] = $relativePath
        }
    }

    $description = Get-FirstMatchValue -Text $html -Pattern '<meta\s+[^>]*name=["'']description["''][^>]*content=["''](.*?)["''][^>]*>'
    if ([string]::IsNullOrWhiteSpace($description)) {
        Add-TestIssue "$relativePath is missing a meta description."
    }
    else {
        if ($description.Length -lt 70 -or $description.Length -gt 180) {
            Add-TestIssue "$relativePath description length is $($description.Length); expected 70-180 characters."
        }
        if (-not $isNotFoundPage) {
            if ($descriptionOwners.ContainsKey($description)) {
                Add-TestIssue "$relativePath duplicates the description used by $($descriptionOwners[$description])."
            }
            else {
                $descriptionOwners[$description] = $relativePath
            }
        }
    }

    $robots = Get-FirstMatchValue -Text $html -Pattern '<meta\s+[^>]*name=["'']robots["''][^>]*content=["''](.*?)["''][^>]*>'
    if ($isNotFoundPage) {
        if ($robots -notmatch '(?i)noindex') {
            Add-TestIssue '404.html must contain a noindex robots directive.'
        }
    }
    elseif ($robots -match '(?i)noindex') {
        Add-TestIssue "$relativePath unexpectedly contains noindex."
    }

    $h1Count = [regex]::Matches($html, '<h1\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    if ($h1Count -ne 1) {
        Add-TestIssue "$relativePath contains $h1Count h1 elements; expected exactly one."
    }

    if (-not $isNotFoundPage) {
        $canonical = Get-FirstMatchValue -Text $html -Pattern '<link\s+[^>]*rel=["'']canonical["''][^>]*href=["''](.*?)["''][^>]*>'
        if ([string]::IsNullOrWhiteSpace($canonical)) {
            Add-TestIssue "$relativePath is missing a canonical URL."
        }
        else {
            if (-not $canonical.StartsWith($publishedBaseUrl, [System.StringComparison]::OrdinalIgnoreCase)) {
                Add-TestIssue "$relativePath canonical is outside the published site: $canonical"
            }
            if ($canonicalOwners.ContainsKey($canonical)) {
                Add-TestIssue "$relativePath duplicates the canonical used by $($canonicalOwners[$canonical])."
            }
            else {
                $canonicalOwners[$canonical] = $relativePath
                $indexableCanonicals.Add($canonical)
            }
        }

        foreach ($requiredMeta in @('og:title', 'og:description', 'og:url', 'og:image')) {
            $metaPattern = '<meta\s+[^>]*property=["'']{0}["''][^>]*content=["''](.*?)["''][^>]*>' -f [regex]::Escape($requiredMeta)
            $value = Get-FirstMatchValue -Text $html -Pattern $metaPattern
            if ([string]::IsNullOrWhiteSpace($value)) {
                Add-TestIssue "$relativePath is missing $requiredMeta."
            }
        }

        foreach ($requiredTwitterMeta in @('twitter:card', 'twitter:title', 'twitter:description', 'twitter:image')) {
            $metaPattern = '<meta\s+[^>]*name=["'']{0}["''][^>]*content=["''](.*?)["''][^>]*>' -f [regex]::Escape($requiredTwitterMeta)
            $value = Get-FirstMatchValue -Text $html -Pattern $metaPattern
            if ([string]::IsNullOrWhiteSpace($value)) {
                Add-TestIssue "$relativePath is missing $requiredTwitterMeta."
            }
        }
    }

    $jsonOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    $jsonLdMatches = [regex]::Matches($html, '<script\s+[^>]*type=["'']application/ld\+json["''][^>]*>(.*?)</script>', $jsonOptions)
    foreach ($jsonLdMatch in $jsonLdMatches) {
        try {
            $null = $jsonLdMatch.Groups[1].Value | ConvertFrom-Json
        }
        catch {
            Add-TestIssue "$relativePath contains invalid JSON-LD: $($_.Exception.Message)"
        }
    }

    $referenceMatches = [regex]::Matches($html, '(?i)\b(?:href|src)=["'']([^"'']+)["'']')
    foreach ($referenceMatch in $referenceMatches) {
        $reference = [System.Net.WebUtility]::HtmlDecode($referenceMatch.Groups[1].Value)
        $target = Resolve-LocalSiteTarget -SourceFile $file -Reference $reference
        if ($null -eq $target) {
            continue
        }

        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Add-TestIssue "$relativePath contains a broken local reference: $reference -> $(Get-RelativeSitePath -FullPath $target)"
        }
    }
}

$sitemapPath = Join-Path -Path $siteRoot -ChildPath 'sitemap.xml'
if (-not (Test-Path -LiteralPath $sitemapPath -PathType Leaf)) {
    Add-TestIssue 'sitemap.xml is missing.'
}
else {
    try {
        [xml]$sitemap = Get-Content -LiteralPath $sitemapPath -Raw
        $sitemapUrls = @($sitemap.urlset.url | ForEach-Object { [string]$_.loc })
        foreach ($canonical in $indexableCanonicals) {
            if ($canonical -notin $sitemapUrls) {
                Add-TestIssue "Canonical URL is missing from sitemap.xml: $canonical"
            }
        }

        foreach ($url in $sitemapUrls) {
            if (-not $url.StartsWith($publishedBaseUrl, [System.StringComparison]::OrdinalIgnoreCase)) {
                Add-TestIssue "Sitemap URL is outside the published site: $url"
                continue
            }

            $relative = $url.Substring($publishedBaseUrl.Length)
            if ([string]::IsNullOrWhiteSpace($relative) -or $relative.EndsWith('/')) {
                $relative = $relative + 'index.html'
            }
            $target = Join-Path -Path $siteRoot -ChildPath ($relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                Add-TestIssue "Sitemap URL has no matching site file: $url"
            }
        }
    }
    catch {
        Add-TestIssue "sitemap.xml is invalid: $($_.Exception.Message)"
    }
}

$robotsPath = Join-Path -Path $siteRoot -ChildPath 'robots.txt'
if (-not (Test-Path -LiteralPath $robotsPath -PathType Leaf)) {
    Add-TestIssue 'robots.txt is missing.'
}
else {
    $robotsText = Get-Content -LiteralPath $robotsPath -Raw
    if ($robotsText -notmatch '(?im)^Sitemap:\s*https://0x0bug\.github\.io/windows-diagnostics-toolkit/sitemap\.xml\s*$') {
        Add-TestIssue 'robots.txt does not reference the published sitemap URL.'
    }
}

Write-Host 'Windows Diagnostics Toolkit site SEO validation'
Write-Host ('HTML files        : {0}' -f $htmlFiles.Count)
Write-Host ('Indexable pages   : {0}' -f $indexableCanonicals.Count)
Write-Host ('Validation issues : {0}' -f $issues.Count)

if ($issues.Count -gt 0) {
    Write-Host ''
    foreach ($issue in $issues) {
        Write-Host ('- {0}' -f $issue)
    }
    throw 'Static site SEO validation failed.'
}

Write-Host 'Static site SEO validation passed.'
