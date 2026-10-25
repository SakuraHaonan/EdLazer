param([string]$CairoSvg = '')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($CairoSvg)) {
  $CairoSvg = (Get-Command cairosvg -ErrorAction Stop).Source
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$assetRoot = Join-Path $repoRoot 'assets\chart_logos'
$sourceRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'lazer_chart_logo_sources'
New-Item -ItemType Directory -Force -Path $assetRoot, $sourceRoot | Out-Null

$logos = @(
  @{ Name = 'biliboard'; Url = 'https://biliboard.uk/logo_black.svg'; Type = 'svg' },
  @{ Name = 'billboard'; Url = 'https://upload.wikimedia.org/wikipedia/commons/9/95/Billboard_logo.svg'; Type = 'svg' },
  @{ Name = 'official_charts'; Url = 'https://www.officialcharts.com/_nuxt/logo-cobalt.CSKpVLm0.svg'; Type = 'svg' },
  @{ Name = 'beatport'; Url = 'https://support.beatport.com/hc/en-us/article_attachments/20473960356628'; Type = 'svg' },
  @{ Name = 'oricon'; Url = 'https://upload.wikimedia.org/wikipedia/commons/0/01/Oricon_Logo_2017.svg'; Type = 'svg' },
  @{ Name = 'nrj'; Url = 'https://upload.wikimedia.org/wikipedia/commons/3/3c/Logo_NRJ_new.png'; Type = 'png' }
)

Add-Type -AssemblyName System.Drawing

foreach ($logo in $logos) {
  $source = Join-Path $sourceRoot ($logo.Name + '.' + $logo.Type)
  $rendered = Join-Path $sourceRoot ($logo.Name + '.png')
  $output = Join-Path $assetRoot ($logo.Name + '.png')
  Invoke-WebRequest -Uri $logo.Url -OutFile $source -UseBasicParsing -TimeoutSec 45
  if ($logo.Type -eq 'svg') {
    & $CairoSvg $source --output-width 720 --output-height 260 -o $rendered
    if ($LASTEXITCODE -ne 0) { throw "Could not render $($logo.Name)" }
  } else {
    $rendered = $source
  }

  $inputBitmap = [System.Drawing.Bitmap]::FromFile($rendered)
  try {
    $whiteBitmap = New-Object System.Drawing.Bitmap $inputBitmap.Width, $inputBitmap.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
      $minX = $inputBitmap.Width
      $minY = $inputBitmap.Height
      $maxX = -1
      $maxY = -1
      for ($x = 0; $x -lt $inputBitmap.Width; $x++) {
        for ($y = 0; $y -lt $inputBitmap.Height; $y++) {
          $pixel = $inputBitmap.GetPixel($x, $y)
          if ($pixel.A -gt 0) {
            $whiteBitmap.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($pixel.A, 255, 255, 255))
            $minX = [Math]::Min($minX, $x)
            $minY = [Math]::Min($minY, $y)
            $maxX = [Math]::Max($maxX, $x)
            $maxY = [Math]::Max($maxY, $y)
          }
        }
      }
      if ($maxX -lt $minX -or $maxY -lt $minY) {
        throw "The $($logo.Name) logo rendered empty"
      }
      $padding = 4
      $left = [Math]::Max(0, $minX - $padding)
      $top = [Math]::Max(0, $minY - $padding)
      $right = [Math]::Min($whiteBitmap.Width - 1, $maxX + $padding)
      $bottom = [Math]::Min($whiteBitmap.Height - 1, $maxY + $padding)
      $cropped = New-Object System.Drawing.Bitmap ($right - $left + 1), ($bottom - $top + 1), ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      try {
        $graphics = [System.Drawing.Graphics]::FromImage($cropped)
        try {
          $graphics.DrawImage(
            $whiteBitmap,
            [System.Drawing.Rectangle]::new(0, 0, $cropped.Width, $cropped.Height),
            [System.Drawing.Rectangle]::new($left, $top, $cropped.Width, $cropped.Height),
            [System.Drawing.GraphicsUnit]::Pixel
          )
        } finally {
          $graphics.Dispose()
        }
        $cropped.Save($output, [System.Drawing.Imaging.ImageFormat]::Png)
      } finally {
        $cropped.Dispose()
      }
    } finally {
      $whiteBitmap.Dispose()
    }
  } finally {
    $inputBitmap.Dispose()
  }
}
