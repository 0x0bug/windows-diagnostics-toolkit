# SEO launch checklist

This checklist covers the manual steps that cannot be completed from the static-site source alone.

## Published URLs

- Site: `https://0x0bug.github.io/windows-diagnostics-toolkit/`
- Troubleshooting guides: `https://0x0bug.github.io/windows-diagnostics-toolkit/cases/`
- Sitemap: `https://0x0bug.github.io/windows-diagnostics-toolkit/sitemap.xml`
- Robots file: `https://0x0bug.github.io/windows-diagnostics-toolkit/robots.txt`

## After merging a site change

1. Confirm the GitHub Pages workflow completes successfully.
2. Open the homepage, guide index, one article, `robots.txt`, and `sitemap.xml` in a private browser window.
3. Confirm each page returns the expected content over HTTPS.
4. Check that canonical URLs use the published GitHub Pages domain and repository path.
5. Check the social card in at least one Open Graph or social-preview debugger.
6. Update sitemap `lastmod` only for pages whose primary content changed.

## Google Search Console

1. Add the GitHub Pages URL as a URL-prefix property.
2. Choose an available verification method.
3. Add the provided verification token or verification file in a separate focused pull request.
4. Submit `sitemap.xml` after verification.
5. Inspect the homepage and guide index with URL Inspection after deployment.
6. Monitor indexing, queries, pages, countries, devices, and crawl errors.

Do not commit a placeholder verification value. Wait for the exact value supplied by Search Console.

## Bing Webmaster Tools

1. Add or import the site property.
2. Complete ownership verification.
3. Submit the same `sitemap.xml` URL.
4. Review crawl and indexing reports for broken links or excluded pages.

## GitHub repository discovery

Set the repository website to:

```text
https://0x0bug.github.io/windows-diagnostics-toolkit/
```

Recommended repository description:

```text
Read-only PowerShell diagnostics for local Windows security, performance, network, crash, disk, service and update reports.
```

Recommended Topics:

```text
windows
windows-11
windows-10
powershell
diagnostics
troubleshooting
system-information
security-audit
network-diagnostics
performance-monitoring
event-log
privacy
tech-support
read-only
```

Upload a raster 1280×640 version of `site/assets/social-preview.svg` as the repository social preview when available.

## Content maintenance

- Keep one primary search intent per guide.
- Add a guide only when the toolkit collects evidence relevant to that symptom.
- Link new guides from the homepage, guide index, related guides, and sitemap.
- Avoid duplicate pages that answer the same query with slightly different wording.
- Keep claims measurable and avoid universal promises about runtime or diagnosis accuracy.
- Review every command and capability statement against the current scripts before publishing.

## Measurement

Use GitHub repository traffic for referral and clone trends. Use search-engine webmaster tools for impressions, clicks, indexed pages, search queries, and crawl problems. Do not add analytics or telemetry to the site unless the project policy explicitly changes.
