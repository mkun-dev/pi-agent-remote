# 生成 Pi Agent Remote App 图标（1024x1024）
# 设计：蓝紫渐变圆角方块 + 白色聊天气泡 + 蓝色 Pi 文字
Add-Type -AssemblyName System.Drawing

$size = 1024
$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.Clear([System.Drawing.Color]::Transparent)

# ---- 圆角背景（蓝紫渐变） ----
$radius = 185
$d = $radius * 2
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddArc(0, 0, $d, $d, 180, 90)
$path.AddArc($size - $d, 0, $d, $d, 270, 90)
$path.AddArc($size - $d, $size - $d, $d, $d, 0, 90)
$path.AddArc(0, $size - $d, $d, $d, 90, 90)
$path.CloseFigure()

$rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(90, 88, 230), [System.Drawing.Color]::FromArgb(35, 155, 245), 45)
$g.FillPath($brush, $path)

# ---- 白色聊天气泡（圆角矩形） ----
$bubble = New-Object System.Drawing.Rectangle(180, 250, 664, 430)
$br = 95
$bd = $br * 2
$bpath = New-Object System.Drawing.Drawing2D.GraphicsPath
$bpath.AddArc($bubble.X, $bubble.Y, $bd, $bd, 180, 90)
$bpath.AddArc($bubble.Right - $bd, $bubble.Y, $bd, $bd, 270, 90)
$bpath.AddArc($bubble.Right - $bd, $bubble.Bottom - $bd, $bd, $bd, 0, 90)
$bpath.AddArc($bubble.X, $bubble.Bottom - $bd, $bd, $bd, 90, 90)
$bpath.CloseFigure()
$white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
$g.FillPath($white, $bpath)

# ---- 气泡内 "Pi" 文字（蓝色） ----
$font = New-Object System.Drawing.Font("Arial", 230, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(60, 85, 220))
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = 'Center'
$sf.LineAlignment = 'Center'
$textRect = New-Object System.Drawing.RectangleF(180, 250, 664, 430)
$g.DrawString("Pi", $font, $textBrush, $textRect, $sf)

# ---- 保存 ----
$outDir = "D:\Desktop\demo\pi-link\pi-ios-app\PiAgentRemote\Assets.xcassets\AppIcon.appiconset"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$bmp.Save("$outDir\AppIcon.png", [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()
Write-Output "图标已生成: $outDir\AppIcon.png"
