# SibbyTube.ps1
# Writes SibbyTube.html into <archive>\.ps\html.UI.Archive\New folder\ (no new subfolders)
# Finds archive root by searching upward for OUTPUT_TABLE.json.

if ($PSScriptRoot) {
    $startDir = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $startDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $startDir = (Get-Location).ProviderPath
}

function Find-ArchiveRoot {
    param($dir)
    $current = (Resolve-Path $dir).ProviderPath
    while ($true) {
        if (Test-Path (Join-Path $current "OUTPUT_TABLE.json")) {
            return $current
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or ($parent -eq $current)) { break }
        $current = $parent
    }
    return $null
}

$root = Find-ArchiveRoot -dir $startDir

if (-not $root) {
    Write-Host "WARNING: Could not locate OUTPUT_TABLE.json by searching upward from $startDir."
    Write-Host "Please place this script somewhere inside your archive tree, or run it from the archive folder."
    $root = $startDir
}

# ensure the single archive folder exists (no timestamped subfolders)
$archiveBase = Join-Path $root ".ps\html.UI.Archive"
New-Item -Path $archiveBase -ItemType Directory -Force | Out-Null

# output file directly in the archiveBase (overwrite each run)
$outHtml = Join-Path $archiveBase "SibbyTube.html"

$jsonPath = Join-Path $root "OUTPUT_TABLE.json"
if (-not (Test-Path $jsonPath)) {
    Write-Error "Cannot find OUTPUT_TABLE.json at expected path: $jsonPath"
    exit 1
}

try {
    $data = Get-Content $jsonPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse OUTPUT_TABLE.json: $_"
    exit 1
}

$cardsHtml = ""
$transcriptJsLines = @()
$transcriptJsLines += "const transcripts = {};" + "`n"

foreach ($v in $data) {
    $vid = if ($v.video_id) { $v.video_id } else {
        if ($v.original_url) {
            try { ([System.Uri]$v.original_url).Segments[-1].TrimEnd('/') } catch { $v.original_url }
        } else { "unknown_$([guid]::NewGuid())" }
    }

    $videoFolder = Join-Path $root ("0.Videos\$vid")
    $videoPath = Join-Path $videoFolder "normalized.mp4"
    if (-not (Test-Path $videoPath)) {
        continue
    }

    try {
        $videoResolved = Resolve-Path $videoPath
        $videoUri = (New-Object System.Uri($videoResolved.ProviderPath)).AbsoluteUri
    } catch {
        $videoUri = "file:///$($videoPath -replace '\\','/')"
    }

    $thumbUri = ""
    $framesFolder = Join-Path $videoFolder "frames"
    if (Test-Path $framesFolder) {
        $frameFiles = Get-ChildItem $framesFolder -File | Where-Object { $_.Extension -match "(?i)\.(jpg|jpeg|png|bmp)$" } | Sort-Object Name
        if ($frameFiles.Count -ge 5) {
            $thumbFile = $frameFiles[4]
        } elseif ($frameFiles.Count -ge 1) {
            $thumbFile = $frameFiles[0]
        } else {
            $thumbFile = $null
        }
        if ($thumbFile) {
            try {
                $thumbResolved = Resolve-Path $thumbFile.FullName
                $thumbUri = (New-Object System.Uri($thumbResolved.ProviderPath)).AbsoluteUri
            } catch {
                $thumbUri = "file:///$($thumbFile.FullName -replace '\\','/')"
            }
        }
    }

    if (-not $thumbUri) {
        $svg = '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180"><rect width="100%" height="100%" fill="#222"/><text x="50%" y="50%" fill="#999" font-size="16" dominant-baseline="middle" text-anchor="middle">no thumbnail</text></svg>'
        $thumbUri = "data:image/svg+xml;utf8,$([System.Uri]::EscapeDataString($svg))"
    }

    $transcriptPath = Join-Path $videoFolder "transcript\transcript.json"
    if (Test-Path $transcriptPath) {
        try {
            $transObj = Get-Content $transcriptPath -Raw | ConvertFrom-Json
            $compactJson = $transObj | ConvertTo-Json -Compress
        } catch {
            $raw = Get-Content $transcriptPath -Raw
            $compactJson = ($raw | ConvertTo-Json -Compress)
        }
        $transcriptJsLines += "transcripts['$vid'] = $compactJson;" + "`n"
    } else {
        $transcriptJsLines += "transcripts['$vid'] = null;" + "`n"
    }

    $escapedTitle = if ($v.original_url) { [System.Web.HttpUtility]::HtmlEncode($v.original_url) } else { [System.Web.HttpUtility]::HtmlEncode($vid) }
    $durationText = if ($v.duration) { ("{0:N2}s" -f $v.duration) } else { "" }
    $resolution = if ($v.resolution) { $v.resolution } else { if ($v.width -and $v.height) { "$($v.width)x$($v.height)" } else { "" } }

    $cardsHtml += @"
    <div class='card' data-video='$videoUri' data-vid='$vid' onclick='playCard(this)'>
      <div class='thumb'><img src='$thumbUri' alt='thumb'></div>
      <div class='meta'>
        <div class='title'>$escapedTitle</div>
        <div class='meta-row'>ID: $vid &nbsp; &bull; &nbsp; $durationText &nbsp; &bull; &nbsp; $resolution</div>
      </div>
    </div>
"@
}

$transcriptJs = ($transcriptJsLines -join "`n")

$html = @"
<!doctype html>
<html>
<head>
<meta charset='utf-8'>
<meta http-equiv='X-UA-Compatible' content='IE=edge'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>SibbyTube</title>
<style>
body{background:#0f0f0f;color:#eee;font-family:Segoe UI,Arial;margin:0}
.header{background:#202020;padding:12px 18px;font-size:20px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:18px;padding:18px}
.card{background:#1b1b1b;border-radius:8px;overflow:hidden;cursor:pointer;transition:transform .12s;box-shadow:0 2px 6px rgba(0,0,0,0.6)}
.card:hover{transform:translateY(-6px)}
.thumb{height:140px;background:#2b2b2b;display:flex;align-items:center;justify-content:center;overflow:hidden}
.thumb img{width:100%;height:100%;object-fit:cover;display:block}
.meta{padding:10px;font-size:13px}
.title{font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.meta-row{font-size:12px;color:#aaa;margin-top:6px}
.player{position:fixed;inset:0;background:rgba(0,0,0,0.85);display:none;align-items:center;justify-content:center;z-index:1000;padding:20px;box-sizing:border-box}
.player-inner{width:100%;max-width:1100px;display:flex;flex-direction:column;align-items:center}
video{max-width:100%;max-height:65vh;background:black}
.transcript{width:100%;max-width:1100px;height:220px;overflow:auto;background:#0b0b0b;color:#ddd;padding:12px;margin-top:12px;border-radius:6px;font-family:monospace;font-size:13px}
.close{position:absolute;right:18px;top:16px;color:#fff;font-size:22px;cursor:pointer}
.small-note{color:#999;font-size:12px;padding:10px 18px}
code{background:#111;padding:2px 6px;border-radius:4px;color:#d7d7d7}
</style>
</head>
<body>
<div class="header">SibbyTube &mdash; local archive player</div>

<div class="small-note">Video files are opened from your local archive (normalized.mp4). Thumbnails use the 5th frame in each video's frames folder when available. Instance stored at: <code>$archiveBase</code></div>

<div class="grid">
$cardsHtml
</div>

<div class="player" id="player">
  <div class="close" onclick="closePlayer()">&times;</div>
  <div class="player-inner">
    <video id="video" controls></video>
    <div class="transcript" id="transcript">Select a video to load transcript...</div>
  </div>
</div>

<script>
$transcriptJs

function playCard(elem) {
    const videoUri = elem.dataset.video;
    const vid = elem.dataset.vid;
    playVideo(videoUri, vid);
}

function playVideo(videoUri, vid) {
    const player = document.getElementById('player');
    const videoEl = document.getElementById('video');
    const transcriptEl = document.getElementById('transcript');

    videoEl.pause();
    videoEl.src = videoUri;
    videoEl.load();

    const t = transcripts[vid];
    if (t) {
        if (typeof t === 'object') {
            transcriptEl.textContent = JSON.stringify(t, null, 2);
        } else {
            transcriptEl.textContent = String(t);
        }
    } else {
        transcriptEl.textContent = "No transcript available.";
    }

    player.style.display = 'flex';
    videoEl.play().catch(()=>{ /* autoplay may be blocked by browser */ });
}

function closePlayer() {
    const player = document.getElementById('player');
    const videoEl = document.getElementById('video');
    videoEl.pause();
    videoEl.removeAttribute('src');
    videoEl.load();
    player.style.display = 'none';
}
</script>
</body>
</html>
"@

# write the HTML file (UTF-8) and open it
$html | Out-File -FilePath $outHtml -Encoding utf8 -Force

Write-Host "Generated SibbyTube UI at: $outHtml"

# open the HTML file using Start-Process -FilePath (explicit)
Start-Process -FilePath $outHtml