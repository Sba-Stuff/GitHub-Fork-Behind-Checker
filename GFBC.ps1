param (
    [string]$Username
)

# =========================
# INTERACTIVE INPUT
# =========================
if (-not $Username -or $Username.Trim() -eq "") {
    $Username = Read-Host "Enter GitHub username"
}

Write-Host "Fetching repositories for user: $Username"

# =========================
# TLS + HEADERS
# =========================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$headers = @{
    "User-Agent" = "Mozilla/5.0"
}

$baseUrl = "https://github.com/$Username"
$page = 1
$repoLinks = @()

# =========================
# STEP 1: COLLECT REPOSITORIES (FIXED PAGINATION)
# =========================
$lastRepoCount = 0

while ($true) {

    $url = "{0}?page={1}&tab=repositories" -f $baseUrl, $page
    Write-Host "Checking page $page..."

    try {
        $response = Invoke-WebRequest -Uri $url -Headers $headers
    }
    catch {
        Write-Host "Failed page $page"
        break
    }

    $html = $response.Content

    # -------------------------
    # STOP CONDITION 1
    # -------------------------
    if ($html -match "doesn.?t have any public repositories yet") {
        Write-Host "No public repositories found. Stopping."
        break
    }

    # -------------------------
    # EXTRACT REPOS
    # -------------------------
    $matches = [regex]::Matches(
        $html,
        "/$Username/[a-zA-Z0-9_.-]+"
    )

    foreach ($m in $matches) {

        $repoPath = $m.Value

        # ignore unwanted pages
        if ($repoPath -match "/(forks|stargazers)$") {
            continue
        }

        $full = "https://github.com$repoPath"

        if ($repoLinks -notcontains $full) {
            $repoLinks += $full
        }
    }

    Write-Host "Repos found so far: $($repoLinks.Count)"

    # -------------------------
    # STOP CONDITION 2 (NO PROGRESS)
    # -------------------------
    if ($repoLinks.Count -eq $lastRepoCount) {
        Write-Host "No new repositories found. Stopping pagination."
        break
    }

    $lastRepoCount = $repoLinks.Count
    $page++
}

Write-Host "Total repositories found: $($repoLinks.Count)"

# =========================
# STEP 2: IMPROVED COMMIT & FORK PARSING (CASE-INSENSITIVE, COMMA-AWARE)
# =========================
function Get-CommitCount($html) {
    # Case-insensitive, handles commas, optional whitespace, and possible HTML between number and "commits"
    if ($html -match '(?i)([0-9,]+)\s+commits') {
        return [int64]($matches[1] -replace '[^0-9]', '')
    }
    # Fallback: number and "commits" may have HTML tags in between
    if ($html -match '(?i)([0-9,]+).*?commits') {
        return [int64]($matches[1] -replace '[^0-9]', '')
    }
    return $null
}

function Get-ForkSource($html) {
    # Case-insensitive, handles extra whitespace and newlines
    if ($html -match '(?i)forked from\s*<a[^>]+href="([^"]+)"') {
        $source = $matches[1]
        if ($source -match '^/') {
            return "https://github.com$source"
        }
        return $source
    }
    return $null
}

# =========================
# STEP 3: PROCESS REPOS
# =========================
$results = @()

foreach ($repo in $repoLinks) {

    Write-Host "Checking repo: $repo"

    try {
        $forkPage = Invoke-WebRequest -Uri $repo -Headers $headers
    }
    catch {
        Write-Host "Failed repo: $repo"
        continue
    }

    $forkHtml = $forkPage.Content

    $forkCommits = Get-CommitCount $forkHtml
    $sourceUrl   = Get-ForkSource $forkHtml

    if (-not $forkCommits -or -not $sourceUrl) {
        Write-Host "Skipping (no fork data)"
        continue
    }

    try {
        $sourcePage = Invoke-WebRequest -Uri $sourceUrl -Headers $headers
    }
    catch {
        Write-Host "Failed source repo"
        continue
    }

    $sourceCommits = Get-CommitCount $sourcePage.Content

    if (-not $sourceCommits) {
        Write-Host "No source commits found"
        continue
    }

    $behind = $sourceCommits - $forkCommits

    if ($behind -gt 0) {

        $results += [PSCustomObject]@{
            Repository     = $repo
            Fork_Commits   = $forkCommits
            Source_Commits = $sourceCommits
            Commits_Behind = $behind
            Source_Repo    = $sourceUrl
        }

        Write-Host "→ Behind by $behind commits"
    }
}

# =========================
# STEP 4: EXPORT CSV
# =========================
$outputFile = "$Username-repos-behind.csv"
$results | Export-Csv -Path $outputFile -NoTypeInformation

Write-Host "DONE → CSV saved: $outputFile"