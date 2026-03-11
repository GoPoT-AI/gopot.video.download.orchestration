param(
    [Parameter(Mandatory=$true)][string]$url,
    [Parameter(Mandatory=$true)][string]$hash
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Log { param($m) [Console]::Error.WriteLine($m) }

# ---------------- CONFIG ----------------

$base = Split-Path $PSScriptRoot -Parent

$yt = Join-Path $base ".tools\ff\yt-dlp.exe"
$ffmpeg = Join-Path $base ".tools\ff\ffmpeg.exe"
$ffprobe = Join-Path $base ".tools\ff\ffprobe.exe"
$whisper = Join-Path $base ".tools\whisper.cpp\build\bin\Release\whisper-cli.exe"
$model = Join-Path $base ".tools\whisper.cpp\models\ggml-medium.bin"

$outRoot = Join-Path $base "0.Videos"

# ----------------------------------------

try {

Log "worker start"

# ---------------- VIDEO ID ----------------

if ($url -match "([A-Za-z0-9_-]{11})") {
    $videoID = $Matches[1]
} else {
    $videoID = $hash.Substring(0,10)
}

$videoDir = Join-Path $outRoot $videoID
New-Item -ItemType Directory -Force -Path $videoDir | Out-Null


# ---------------- DOWNLOAD ----------------

$videoPath = Join-Path $videoDir "video.mp4"

$quickjs = Join-Path $base ".tools\yt\quickjs.exe"

Log "download video"

$ytArgs = @(
    '--no-playlist'
    '-f','bv*+ba/b'
    '--merge-output-format','mp4'
    '--ffmpeg-location', (Split-Path $ffmpeg)
    '--concurrent-fragments','6'
    '-N','6'
    '--retries','10'
    '--fragment-retries','10'
    '-o', $videoPath
)

# enable JS runtime if available
if (Test-Path $quickjs) {
    $ytArgs += '--js-runtimes'
    $ytArgs += "quickjs:$quickjs"
}

& $yt @ytArgs $url

if ($LASTEXITCODE -ne 0) {
    throw "yt-dlp failed"
}

if (-not (Test-Path $videoPath)) {
    throw "download finished but video file missing"
}

# ---------------- NORMALIZE ----------------

$norm = Join-Path $videoDir "normalized.mp4"

Log "normalize video"

& $ffmpeg -y -loglevel error `
    -i $videoPath `
    -map 0:v:0 -map 0:a? `
    -c:v libx264 `
    -preset veryfast `
    -crf 23 `
    -pix_fmt yuv420p `
    -c:a aac `
    -b:a 160k `
    -movflags +faststart `
    $norm

if ($LASTEXITCODE -ne 0) { throw "ffmpeg normalize failed" }

# remove original downloaded file to avoid duplication
Remove-Item $videoPath -Force -ErrorAction SilentlyContinue

# ---------------- FRAMES ----------------

$framesDir = Join-Path $videoDir "frames"
New-Item -ItemType Directory -Force -Path $framesDir | Out-Null

Log "extract frames"

& $ffmpeg -loglevel error `
    -i $norm `
    -vf fps=5 `
    -q:v 2 `
    (Join-Path $framesDir "frame_%06d.jpg")

if ($LASTEXITCODE -ne 0) { throw "frame extraction failed" }

# ---------------- PROBE ----------------

$probe = & $ffprobe -v quiet -print_format json -show_streams -show_format $norm
$meta = $probe | ConvertFrom-Json

$width = ($meta.streams | Where {$_.codec_type -eq "video"} | Select -First 1).width
$height = ($meta.streams | Where {$_.codec_type -eq "video"} | Select -First 1).height
$duration = $meta.format.duration

$hasAudio = $meta.streams | Where {$_.codec_type -eq "audio"}

# ---------------- AUDIO ----------------

$audioFile = $null
$transcriptJson = $null
$transcriptText = ""

if ($hasAudio) {

$audioDir = Join-Path $videoDir "audio"
New-Item -ItemType Directory -Force -Path $audioDir | Out-Null

$audioFile = Join-Path $audioDir "audio.wav"

Log "extract audio"

& $ffmpeg -y -loglevel error `
    -i $norm `
    -vn `
    -acodec pcm_s16le `
    -ar 16000 `
    -ac 1 `
    $audioFile

if ($LASTEXITCODE -ne 0) { throw "audio extraction failed" }

# ---------------- WHISPER ----------------

$transcriptDir = Join-Path $videoDir "transcript"
New-Item -ItemType Directory -Force -Path $transcriptDir | Out-Null

$outputBase = Join-Path $transcriptDir "transcript"

Log "transcribe"

& $whisper `
    -m $model `
    -f $audioFile `
    -of $outputBase `
    --output-json `
    -l auto `
    -t 8

if ($LASTEXITCODE -ne 0) { throw "whisper failed" }

$transcriptJson = "$outputBase.json"

if (Test-Path $transcriptJson) {
    $transcriptText = (Get-Content $transcriptJson -Raw | ConvertFrom-Json).text
}

}

# ---------------- RESULT ----------------

$result = [PSCustomObject]@{

    normalized = $normalizedVideo
    frames = $framesFolder
    audio = $audioFile

    width = $width
    height = $height
    duration = $duration

    transcript_text = $transcriptText
    transcript_json = $transcriptJson
}

$result | ConvertTo-Json -Depth 10

exit 0

}
catch {
Log $_
exit 1
}