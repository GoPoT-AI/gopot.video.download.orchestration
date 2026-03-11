# RUN_PIPELINE.ps1

$base = Split-Path $PSScriptRoot -Parent

$queueFile  = Join-Path $base 'QUEUE.txt'
$outputFile = Join-Path $base 'OUTPUT_TABLE.json'
$worker     = Join-Path $base '.ps\video_worker.ps1'

# -----------------------------
# Helper Functions
# -----------------------------

function Get-Sha256Hex {
    param([string]$text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $hash = $sha.ComputeHash($bytes)

    ($hash | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Detect-Platform {
    param([string]$url)

    if (-not $url) { return "unknown" }

    $u = $url.ToLower()

    if ($u -match "youtu") { return "youtube" }
    if ($u -match "vimeo") { return "vimeo" }
    if ($u -match "tiktok") { return "tiktok" }

    return "unknown"
}

function Get-VideoID {
    param([string]$url)

    if (-not $url) { return $null }

    if ($url -match "([A-Za-z0-9_-]{11})") {
        return $Matches[1]
    }

    if ($url -match "vimeo\.com/([0-9]+)") {
        return $Matches[1]
    }

    return $null
}

function ExtractUrlsFromLine {
    param([string]$line)

    $results = @()

    if (-not $line) { return $results }

    $pattern = "https?://\S+"
    $matches = [regex]::Matches($line,$pattern)

    foreach ($m in $matches) {

        $u = $m.Value

        $u = $u.TrimEnd(".")
        $u = $u.TrimEnd(",")
        $u = $u.TrimEnd(";")
        $u = $u.TrimEnd(":")
        $u = $u.TrimEnd(")")
        $u = $u.TrimEnd("]")
        $u = $u.TrimEnd(">")
        $u = $u.TrimEnd('"')

        if ($u.StartsWith("<") -and $u.EndsWith(">")) {
            $u = $u.Substring(1,$u.Length-2)
        }

        if ($u) {
            $results += $u
        }
    }

    return $results
}

# -----------------------------
# Start
# -----------------------------

Write-Host ""
Write-Host "===================================="
Write-Host " Sibby LINK to MP4 Pipeline"
Write-Host "===================================="
Write-Host ""

if (-not (Test-Path $queueFile)) {
    Write-Host "QUEUE.txt not found."
    exit
}

# -----------------------------
# Load database (SAFE ARRAY MODE)
# -----------------------------

$database = @()

if (Test-Path $outputFile) {

    try {

        $raw = Get-Content $outputFile -Raw

        if ($raw.Trim().Length -gt 0) {

            $parsed = $raw | ConvertFrom-Json

            # Force array even if JSON has one object
            if ($parsed -is [System.Collections.IEnumerable]) {
                $database = @($parsed)
            }
            else {
                $database = @($parsed)
            }

        }

    } catch {

        Write-Host "WARNING: JSON could not be parsed."
        $database = @()

    }

}
else {

    $database = @()
    "[]" | Set-Content $outputFile -Encoding UTF8

}

# -----------------------------
# Build skip indexes
# -----------------------------

$existingHashes = @{}
$existingVideoIDs = @{}

foreach ($row in $database) {

    if ($row.url_hash) {
        $existingHashes[$row.url_hash] = $true
    }

    if ($row.video_id) {
        $existingVideoIDs[$row.video_id] = $true
    }

}

# -----------------------------
# Read QUEUE.txt
# -----------------------------

Write-Host "Reading QUEUE.txt..."

$fileLines = Get-Content $queueFile

$rawUrls = @()

foreach ($line in $fileLines) {

    $urls = ExtractUrlsFromLine $line

    foreach ($u in $urls) {
        $rawUrls += $u
    }

}

if ($rawUrls.Count -eq 0) {
    Write-Host "No links found."
    exit
}

# -----------------------------
# Remove duplicates in queue
# -----------------------------

$seen = @{}
$urls = @()

foreach ($u in $rawUrls) {

    $k = $u.ToLower()

    if (-not $seen.ContainsKey($k)) {

        $seen[$k] = $true
        $urls += $u

    }
}

$total = $urls.Count
$index = 1

Write-Host "Unique links: $total"

# -----------------------------
# Processing Loop
# -----------------------------

foreach ($url in $urls) {

    Write-Host ""
    Write-Host "----------------------------------------"
    Write-Host "Processing $index of $total"
    Write-Host $url
    Write-Host "----------------------------------------"

    $url_hash = Get-Sha256Hex $url
    $video_id = Get-VideoID $url

    if ($existingHashes.ContainsKey($url_hash)) {

        Write-Host "Skipping URL already processed."
        $index++
        continue

    }

    if ($video_id -and $existingVideoIDs.ContainsKey($video_id)) {

        Write-Host "Skipping duplicate video ID."
        $index++
        continue

    }

    $platform = Detect-Platform $url
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $entry = @{
        id = ($database.Count + 1)
        url_hash = $url_hash
        original_url = $url
        video_id = $video_id
        platform = $platform
        status = "Processing"
        width = $null
        height = $null
        resolution = $null
        duration = $null
        file_path = $null
        transcript_path = $null
        created_at = $now
        updated_at = $now
    }

    try {

        if (-not (Test-Path $worker)) {
            throw "Worker script missing."
        }

        $workerOut = powershell -NoProfile -ExecutionPolicy Bypass -File $worker -url $url -hash $url_hash

        $resultText = $workerOut -join "`n"

        $match = [regex]::Match($resultText,"{[\s\S]*}$")

        if (-not $match.Success) {
    Write-Host "Worker did not return JSON. Skipping entry."
    $index++
    continue
}

        $json = $match.Value | ConvertFrom-Json

        if ($json.normalized) { $entry.file_path = $json.normalized }
        if ($json.transcript_json) { $entry.transcript_path = $json.transcript_json }

        if ($json.width) { $entry.width = [int]$json.width }
        if ($json.height) { $entry.height = [int]$json.height }

        if ($entry.width -and $entry.height) {
            $entry.resolution = "$($entry.width)x$($entry.height)"
        }

        if ($json.duration) {
            $entry.duration = [math]::Round([double]$json.duration,3)
        }

        $entry.status = "Done"
        $entry.updated_at = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    }
    catch {

        Write-Host "ERROR: $($_.Exception.Message)"

        $entry.status = "Error"
        $entry.updated_at = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    }

    $database = @($database) + [PSCustomObject]$entry

    $existingHashes[$entry.url_hash] = $true
    if ($entry.video_id) { $existingVideoIDs[$entry.video_id] = $true }

    try {

        $database | ConvertTo-Json -Depth 10 | Set-Content $outputFile -Encoding UTF8

        Write-Host "OUTPUT_TABLE.json updated"

    } catch {

        Write-Host "JSON write error."

    }

    $index++

}

Write-Host ""
Write-Host "======================================"
Write-Host "Pipeline finished."
Write-Host "======================================"
Write-Host ""