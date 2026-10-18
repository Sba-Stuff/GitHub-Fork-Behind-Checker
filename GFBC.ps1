<#
.SYNOPSIS
  GFBC - GitHub Fork Behind Checker.
  Scrapes github.com web pages only. No api.github.com, no token, no 60-requests/hour limit.

.EXAMPLES
  GFBC.bat                                  asks for the username (Enter = Sba-Stuff)
  GFBC.bat Sba-Stuff
  powershell -ExecutionPolicy Bypass -File GFBC.ps1 -Username Sba-Stuff -DelayMs 600
  powershell -ExecutionPolicy Bypass -File GFBC.ps1 -RepoFile repos.txt     (one owner/repo per line)

.NOTES
  Cost: about 3 requests to list your forks + 2 requests per fork (repo page + branch-infobar).
  Compatible with Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    [string]$Username,
    [int]$DelayMs = 400,      # minimum gap between requests (auto-increases if GitHub says "slow down")
    [string]$RepoFile,        # optional: skip repo-list scraping and use owner/repo lines from this file
    [switch]$NoOpen           # do not open the HTML report when finished
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Username)) {
    $Username = Read-Host 'GitHub username (Enter = Sba-Stuff)'
    if ([string]::IsNullOrWhiteSpace($Username)) { $Username = 'Sba-Stuff' }
}
$Username = $Username.Trim()

$outDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$fileBehind = Join-Path $outDir "$Username-forks-behind.csv"
$fileAll    = Join-Path $outDir "$Username-forks-all.csv"
$fileHtml   = Join-Path $outDir "$Username-forks-report.html"

# ------------------------------------------------------------------
# HTTP client (one reusable connection, gzip, polite pacing, retries)
# ------------------------------------------------------------------
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12,Tls13'
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $true
$handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$http = New-Object System.Net.Http.HttpClient($handler)
$http.Timeout = [TimeSpan]::FromSeconds(30)
[void]$http.DefaultRequestHeaders.UserAgent.TryParseAdd('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')
[void]$http.DefaultRequestHeaders.TryAddWithoutValidation('Accept-Language', 'en-US,en;q=0.9')

$Pace  = [Math]::Max($DelayMs, 150)
$clock = [System.Diagnostics.Stopwatch]::StartNew()

function Wait-Turn {
    $left = $script:Pace - $script:clock.ElapsedMilliseconds
    if ($left -gt 0) { Start-Sleep -Milliseconds ([int]$left) }
    $script:clock.Restart()
}

# Returns @{ Ok; Status; Body }. Retries network errors, 429, 403 and 5xx; never retries 404.
function Get-Web {
    param(
        [string]$Url,
        [string]$Accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    )
    $status = 0
    for ($try = 1; $try -le 4; $try++) {
        Wait-Turn
        $status = 0; $body = $null; $retryAfter = 0
        try {
            $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList @([System.Net.Http.HttpMethod]::Get, $Url)
            [void]$req.Headers.TryAddWithoutValidation('Accept', $Accept)
            if ($Accept -like '*json*') { [void]$req.Headers.TryAddWithoutValidation('X-Requested-With', 'XMLHttpRequest') }
            $resp = $http.SendAsync($req).GetAwaiter().GetResult()
            try {
                $status = [int]$resp.StatusCode
                $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $ra = $resp.Headers.RetryAfter
                if ($ra -and $ra.Delta) { $retryAfter = [int][Math]::Ceiling($ra.Delta.TotalSeconds) }
            } finally {
                $resp.Dispose()
                $req.Dispose()
            }
        } catch {
            $status = 0
        }

        if ($status -eq 200) { return [pscustomobject]@{ Ok = $true; Status = 200; Body = $body } }

        $transient = ($status -eq 0 -or $status -eq 429 -or $status -eq 403 -or $status -ge 500)
        if (-not $transient -or $try -eq 4) { break }

        if ($status -eq 429 -or $status -eq 403) { $script:Pace = [Math]::Min($script:Pace * 2, 4000) }
        $sleep = if ($retryAfter -gt 0) { [Math]::Min($retryAfter, 120) } else { [int][Math]::Pow(2, $try) * 3 }
        Write-Host "    HTTP $status - waiting $sleep s, then retry $try/3 ..." -ForegroundColor Yellow
        Start-Sleep -Seconds $sleep
    }
    return [pscustomobject]@{ Ok = $false; Status = $status; Body = $null }
}

# ------------------------------------------------------------------
# HTML helpers
# ------------------------------------------------------------------
function Enc { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

function Get-Meta {
    param([string]$Html, [string]$Name)
    $n = [regex]::Escape($Name)
    $m = [regex]::Match($Html, '<meta[^>]+name="' + $n + '"[^>]+content="([^"]*)"')
    if (-not $m.Success) { $m = [regex]::Match($Html, '<meta[^>]+content="([^"]*)"[^>]+name="' + $n + '"') }
    if ($m.Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    return $null
}

function Get-DefaultBranch {
    param([string]$Html)
    foreach ($p in '"defaultBranch"\s*:\s*"([^"]+)"', '"refInfo"\s*:\s*\{\s*"name"\s*:\s*"([^"]+)"') {
        $m = [regex]::Match($Html, $p)
        if ($m.Success) { return [regex]::Unescape($m.Groups[1].Value) }
    }
    return $null
}

$Reserved = 'followers', 'following', 'stars', 'projects', 'packages', 'sponsoring', 'sponsors', 'settings', 'repositories', 'people', 'teams'

function Find-RepoLinks {
    param([string]$Html, [string]$User)
    $u = [regex]::Escape($User)
    $ms = [regex]::Matches($Html, '(?i)href="/(' + $u + ')/([^"/?#]+)"[^>]*itemprop="name codeRepository"')
    if ($ms.Count -eq 0) {
        $ms = [regex]::Matches($Html, '(?i)href="/(' + $u + ')/([A-Za-z0-9_.-]+)"')
    }
    $out = @()
    foreach ($m in $ms) {
        $name = $m.Groups[2].Value
        if ($name -in $script:Reserved) { continue }
        $out += ($m.Groups[1].Value + '/' + $name)
    }
    return $out
}

# Lists repos from the public profile pages. Type 'fork' lists only forks (smaller + faster).
function Get-RepoNames {
    param([string]$User, [string]$Type)
    $found = New-Object System.Collections.ArrayList
    $seen = @{}
    $templates = @(
        'https://github.com/{0}?tab=repositories&type={1}&page={2}',
        'https://github.com/orgs/{0}/repositories?type={1}&page={2}'
    )
    foreach ($t in $templates) {
        for ($p = 1; $p -le 50; $p++) {
            $r = Get-Web ($t -f $User, $Type, $p)
            if (-not $r.Ok) { break }
            $added = 0
            foreach ($name in @(Find-RepoLinks $r.Body $User)) {
                if (-not $seen.ContainsKey($name)) {
                    $seen[$name] = $true
                    [void]$found.Add($name)
                    $added++
                }
            }
            Write-Host ("  listing page {0}: {1} new" -f $p, $added)
            if ($added -eq 0) { break }
        }
        if ($found.Count -gt 0) { break }
    }
    return $found.ToArray()
}

# ------------------------------------------------------------------
# Per-fork check:  1) repo page -> default branch, is-fork, parent
#                  2) /branch-infobar/<branch> (JSON) -> ahead / behind
# ------------------------------------------------------------------
function Get-Compare {
    param([string]$Repo, [string]$Branch)
    $path = ($Branch -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $r = Get-Web ("https://github.com/$Repo/branch-infobar/" + $path) 'application/json'
    $out = [pscustomobject]@{ Ok = $false; Status = $r.Status; Ahead = $null; Behind = $null; Base = $null }
    if (-not $r.Ok) { return $out }

    try {
        $c = ($r.Body | ConvertFrom-Json).refComparison
        if ($c) {
            $out.Ahead = [int64]$c.ahead
            $out.Behind = [int64]$c.behind
            $out.Base = [string]$c.baseBranch
        }
    } catch { }

    if ($null -eq $out.Behind) {     # fallback if the body was not clean JSON
        $b = [regex]::Match($r.Body, '"behind"\s*:\s*(\d+)')
        $a = [regex]::Match($r.Body, '"ahead"\s*:\s*(\d+)')
        if ($a.Success -and $b.Success) {
            $out.Ahead = [int64]$a.Groups[1].Value
            $out.Behind = [int64]$b.Groups[1].Value
        }
    }
    $out.Ok = ($null -ne $out.Behind)
    return $out
}

function New-Row {
    param([string]$Repo)
    return [ordered]@{
        Repository      = "https://github.com/$Repo"
        Upstream        = ''
        Fork_Branch     = ''
        Upstream_Branch = ''
        Behind          = ''
        Ahead           = ''
        Status          = ''
        Compare_URL     = ''
        Note            = ''
    }
}

function Test-Fork {
    param([string]$Repo)
    $row = New-Row $Repo

    $page = Get-Web "https://github.com/$Repo"
    if (-not $page.Ok) {
        $row['Status'] = 'Failed'
        $row['Note'] = if ($page.Status -eq 404) { 'Repo page not found (404): renamed, deleted or private' } else { "Repo page failed (HTTP $($page.Status))" }
        return [pscustomobject]$row
    }
    $html = $page.Body

    $isFork = Get-Meta $html 'octolytics-dimension-repository_is_fork'
    if (-not $isFork) {
        $m = [regex]::Match($html, '"isFork"\s*:\s*(true|false)')
        if ($m.Success) { $isFork = $m.Groups[1].Value }
    }
    if ($isFork -eq 'false') {
        $row['Status'] = 'Not a fork'
        return [pscustomobject]$row
    }

    $parent = Get-Meta $html 'octolytics-dimension-repository_parent_nwo'
    $branch = Get-DefaultBranch $html
    $guessed = -not $branch
    $candidates = if ($branch) { @($branch) } else { @('main', 'master') }

    $cmp = $null
    foreach ($cand in $candidates) {
        $cmp = Get-Compare $Repo $cand
        if ($cmp.Ok) { $branch = $cand; break }
    }

    $row['Upstream'] = [string]$parent
    $row['Fork_Branch'] = [string]$branch

    if (-not $cmp.Ok) {
        $row['Status'] = 'Unknown'
        $row['Note'] = "No comparison data (HTTP $($cmp.Status)): upstream may be deleted/private, or this is not a fork"
        return [pscustomobject]$row
    }

    $upRepo = $parent
    $upBranch = ''
    if ($cmp.Base) {
        $i = $cmp.Base.IndexOf(':')
        if ($i -ge 0) {
            $upBranch = $cmp.Base.Substring($i + 1)
            if (-not $upRepo) { $upRepo = $cmp.Base.Substring(0, $i) }
        }
    }
    $row['Upstream'] = [string]$upRepo
    $row['Upstream_Branch'] = $upBranch
    $row['Behind'] = $cmp.Behind
    $row['Ahead'] = $cmp.Ahead
    if ($guessed) { $row['Note'] = 'Default branch was guessed' }

    if ($cmp.Behind -gt 0 -and $cmp.Ahead -gt 0) { $row['Status'] = 'Diverged' }
    elseif ($cmp.Behind -gt 0) { $row['Status'] = 'Behind' }
    elseif ($cmp.Ahead -gt 0) { $row['Status'] = 'Ahead' }
    else { $row['Status'] = 'Up to date' }

    if ($cmp.Behind -gt 0 -and $upBranch -and ($upRepo -match '^([^/]+)/(.+)$')) {
        $row['Compare_URL'] = "https://github.com/$Repo/compare/$branch...$($Matches[1]):$($Matches[2]):$upBranch"
    }
    return [pscustomobject]$row
}

# ------------------------------------------------------------------
# Reports (CSV + HTML)
# ------------------------------------------------------------------
$Css = @'
:root{color-scheme:light dark;--bd:#8884;--red:#d1242f;--grn:#1a7f37;--yel:#9a6700;--blu:#0969da}
@media (prefers-color-scheme:dark){:root{--red:#ff7b72;--grn:#56d364;--yel:#e3b341;--blu:#58a6ff}}
body{font:14px/1.45 system-ui,"Segoe UI",sans-serif;margin:24px auto;max-width:1250px;padding:0 16px}
h1{font-size:20px;margin:0 0 4px}
.note{opacity:.7;font-size:12px}
.sum{display:flex;gap:10px;flex-wrap:wrap;margin:16px 0}
.sum div{border:1px solid var(--bd);border-radius:8px;padding:8px 16px}
.sum b{display:block;font-size:22px}
table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--bd);vertical-align:top}
th{position:sticky;top:0;background:Canvas}
td.n{text-align:right;font-variant-numeric:tabular-nums}
a{color:var(--blu);text-decoration:none}
tr.behind .st{color:var(--red);font-weight:600}
tr.ok .st{color:var(--grn)}
tr.ahead .st{color:var(--blu)}
tr.other .st{color:var(--yel)}
'@

function Get-Counts {
    param($Rows)
    $c = @{}
    foreach ($r in $Rows) { $c[$r.Status] = 1 + [int]$c[$r.Status] }
    return $c
}

function New-HtmlReport {
    param($Rows)
    $c = Get-Counts $Rows
    $behindN = [int]$c['Behind'] + [int]$c['Diverged']
    $okN = [int]$c['Up to date']
    $aheadN = [int]$c['Ahead']
    $otherN = @($Rows).Count - $behindN - $okN - $aheadN

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Fork report</title><style>')
    [void]$sb.Append($script:Css)
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine("<h1>Fork status for $(Enc $Username)</h1>")
    [void]$sb.AppendLine("<div class='note'>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') from github.com web pages (no API). Sorted by commits behind.</div>")
    [void]$sb.AppendLine("<div class='sum'><div><b>$(@($Rows).Count)</b>scanned</div><div><b style='color:var(--red)'>$behindN</b>behind</div><div><b style='color:var(--grn)'>$okN</b>up to date</div><div><b style='color:var(--blu)'>$aheadN</b>ahead only</div><div><b style='color:var(--yel)'>$otherN</b>other / failed</div></div>")
    [void]$sb.AppendLine('<table><thead><tr><th>Fork</th><th>Upstream</th><th>Branch</th><th>Behind</th><th>Ahead</th><th>Status</th><th>Missing commits</th><th>Note</th></tr></thead><tbody>')

    foreach ($r in $Rows) {
        $cls = switch ($r.Status) {
            'Behind'     { 'behind' }
            'Diverged'   { 'behind' }
            'Up to date' { 'ok' }
            'Ahead'      { 'ahead' }
            default      { 'other' }
        }
        $name = $r.Repository -replace '^https://github.com/', ''
        $up = ''
        if ($r.Upstream) { $up = "<a href='https://github.com/$($r.Upstream)'>$(Enc $r.Upstream)</a>" }
        $cmpLink = ''
        if ($r.Compare_URL) { $cmpLink = "<a href='$(Enc $r.Compare_URL)'>view</a>" }
        [void]$sb.AppendLine("<tr class='$cls'><td><a href='$($r.Repository)'>$(Enc $name)</a></td><td>$up</td><td>$(Enc $r.Fork_Branch)</td><td class='n'>$($r.Behind)</td><td class='n'>$($r.Ahead)</td><td class='st'>$(Enc $r.Status)</td><td>$cmpLink</td><td class='note'>$(Enc $r.Note)</td></tr>")
    }
    [void]$sb.AppendLine('</tbody></table></body></html>')
    return $sb.ToString()
}

function Save-Reports {
    if ($results.Count -eq 0) { return }
    $all = @($results | Sort-Object @{ Expression = { [int64]($_.Behind -as [int64]) }; Descending = $true }, Repository)
    $behind = @($all | Where-Object { $_.Behind -is [int64] -and $_.Behind -gt 0 })
    try {
        if ($behind.Count -gt 0) {
            $behind | Export-Csv -LiteralPath $fileBehind -NoTypeInformation -Encoding UTF8
        } elseif (Test-Path -LiteralPath $fileBehind) {
            Remove-Item -LiteralPath $fileBehind -Force      # stale output from an earlier run
        }
        $all | Export-Csv -LiteralPath $fileAll -NoTypeInformation -Encoding UTF8
        [System.IO.File]::WriteAllText($fileHtml, (New-HtmlReport $all), (New-Object System.Text.UTF8Encoding($true)))
    } catch {
        Write-Host "Could not write report files: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '(If a CSV is open in Excel, close it and run again.)' -ForegroundColor Red
    }
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' GFBC - GitHub Fork Behind Checker'        -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "Account : $Username"
Write-Host 'Source  : github.com web pages only (no API, no token)'
Write-Host ''

$repos = @()
if ($RepoFile) {
    if (-not (Test-Path -LiteralPath $RepoFile)) { throw "RepoFile not found: $RepoFile" }
    $repos = @(Get-Content -LiteralPath $RepoFile |
        ForEach-Object { ($_.Trim() -replace '^https?://github\.com/', '').TrimEnd('/') -replace '\.git$', '' } |
        Where-Object { $_ -match '^[\w.-]+/[\w.-]+$' })
} else {
    Write-Host 'Listing forks...'
    $repos = @(Get-RepoNames $Username 'fork')
    if ($repos.Count -eq 0) {
        Write-Host 'No forks found with the fork filter - retrying with the full repo list...' -ForegroundColor Yellow
        $repos = @(Get-RepoNames $Username 'all')
    }
}

if ($repos.Count -eq 0) {
    Write-Host ''
    Write-Host "No repositories found for '$Username'." -ForegroundColor Red
    Write-Host 'Check the spelling, your internet connection, or pass -RepoFile repos.txt (one owner/repo per line).' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host "Checking $($repos.Count) repositories (about 2 requests each, ~$([Math]::Ceiling($repos.Count * 2 * $Pace / 1000)) s minimum)..." -ForegroundColor Cyan
Write-Host ''

$results = New-Object System.Collections.ArrayList
$n = 0
try {
    foreach ($repo in $repos) {
        $n++
        try {
            $r = Test-Fork $repo
        } catch {
            $row = New-Row $repo
            $row['Status'] = 'Failed'
            $row['Note'] = $_.Exception.Message
            $r = [pscustomobject]$row
        }
        [void]$results.Add($r)

        switch ($r.Status) {
            'Behind'     { $txt = "BEHIND by $($r.Behind)"; $col = 'Red' }
            'Diverged'   { $txt = "DIVERGED: behind $($r.Behind), ahead $($r.Ahead)"; $col = 'Yellow' }
            'Ahead'      { $txt = "ahead by $($r.Ahead)"; $col = 'Cyan' }
            'Up to date' { $txt = 'up to date'; $col = 'Green' }
            default      { $txt = "$($r.Status) - $($r.Note)"; $col = 'DarkYellow' }
        }
        Write-Host ('[{0,3}/{1}] {2,-48} {3}' -f $n, $repos.Count, $repo, $txt) -ForegroundColor $col
    }
} finally {
    Save-Reports       # also runs if you press Ctrl+C, so partial results are never lost
    $http.Dispose()
}

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
$c = Get-Counts $results
$behindRows = @($results | Where-Object { $_.Behind -is [int64] -and $_.Behind -gt 0 } | Sort-Object Behind -Descending)
$failed = @($results | Where-Object { $_.Status -eq 'Failed' })

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host '             SCAN COMPLETE'               -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "Scanned        : $($results.Count)"
Write-Host "Behind         : $($behindRows.Count)" -ForegroundColor Red
Write-Host "Up to date     : $([int]$c['Up to date'])" -ForegroundColor Green
Write-Host "Ahead only     : $([int]$c['Ahead'])"
Write-Host "Unknown/failed : $([int]$c['Unknown'] + $failed.Count)" -ForegroundColor Yellow
Write-Host "Not a fork     : $([int]$c['Not a fork'])"

if ($behindRows.Count -gt 0) {
    Write-Host ''
    Write-Host 'Forks that are behind (most behind first):' -ForegroundColor Red
    $behindRows |
        Select-Object @{ n = 'Fork'; e = { $_.Repository -replace '^https://github.com/', '' } }, Behind, Ahead, Upstream |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}
if ($failed.Count -gt 0) {
    Write-Host 'Some requests failed (GitHub throttling or network). Run again in a few minutes, or use a larger -DelayMs, e.g. 800.' -ForegroundColor Yellow
}

Write-Host 'Reports:'
if (Test-Path -LiteralPath $fileBehind) { Write-Host "  $fileBehind" -ForegroundColor Green }
Write-Host "  $fileAll" -ForegroundColor Green
Write-Host "  $fileHtml" -ForegroundColor Green
Write-Host ''

if (-not $NoOpen -and (Test-Path -LiteralPath $fileHtml)) {
    try { Start-Process -FilePath $fileHtml } catch { }
}
