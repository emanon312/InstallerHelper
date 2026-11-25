# InstallerHelper - 拖入安装包，装到指定目录
# 单屏界面：一屏完成，高级能力收进"高级选项"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 编译成 exe 后 $PSScriptRoot 为空，此时固定用 %LOCALAPPDATA%\InstallerHelper
# （helper-core.ps1 和 app.ico 由 ps2exe 的 embedFiles 释放到同一个位置）
$script:Root = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:Root)) {
    $script:Root = Join-Path $env:LOCALAPPDATA 'InstallerHelper'
    if (-not (Test-Path -LiteralPath $script:Root)) { New-Item -ItemType Directory -Path $script:Root -Force | Out-Null }
}
$script:CorePath = Join-Path $script:Root 'helper-core.ps1'
if (-not (Test-Path -LiteralPath $script:CorePath)) {
    $script:CorePath = Join-Path (Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)) 'helper-core.ps1'
}
. $script:CorePath

# ================================================================ 设计变量
$C = @{
    Bg        = [System.Drawing.Color]::FromArgb(245, 246, 248)
    Surface   = [System.Drawing.Color]::FromArgb(255, 255, 255)
    Border    = [System.Drawing.Color]::FromArgb(226, 228, 233)
    BorderHi  = [System.Drawing.Color]::FromArgb(37, 99, 235)
    Text      = [System.Drawing.Color]::FromArgb(31, 35, 40)
    Muted     = [System.Drawing.Color]::FromArgb(107, 114, 128)
    Primary   = [System.Drawing.Color]::FromArgb(37, 99, 235)
    PrimaryHi = [System.Drawing.Color]::FromArgb(29, 78, 216)
    PrimaryLo = [System.Drawing.Color]::FromArgb(191, 206, 250)
    Ok        = [System.Drawing.Color]::FromArgb(21, 128, 61)
    Err       = [System.Drawing.Color]::FromArgb(220, 38, 38)
    Tint      = [System.Drawing.Color]::FromArgb(239, 246, 255)
    LogBg     = [System.Drawing.Color]::FromArgb(250, 251, 252)
}

$FB = 'Microsoft YaHei UI'
$script:F = @{
    H1     = New-Object System.Drawing.Font($FB, 15, [System.Drawing.FontStyle]::Bold)
    Body   = New-Object System.Drawing.Font($FB, 10)
    Label  = New-Object System.Drawing.Font($FB, 10)
    Small  = New-Object System.Drawing.Font($FB, 9)
    SmallB = New-Object System.Drawing.Font($FB, 9, [System.Drawing.FontStyle]::Bold)
    Btn    = New-Object System.Drawing.Font($FB, 11, [System.Drawing.FontStyle]::Bold)
    Mono   = New-Object System.Drawing.Font('Consolas', 9)
    Link   = New-Object System.Drawing.Font($FB, 9)
}

function New-RoundRectPath {
    param([int]$W, [int]$H, [int]$R)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($R -le 0 -or $W -lt 2 -or $H -lt 2) {
        $path.AddRectangle((New-Object System.Drawing.Rectangle(0, 0, [Math]::Max($W, 1), [Math]::Max($H, 1))))
        return $path
    }
    $dd = [Math]::Min($R * 2, [Math]::Min($W, $H))
    $path.AddArc(0, 0, $dd, $dd, 180, 90)
    $path.AddArc($W - $dd, 0, $dd, $dd, 270, 90)
    $path.AddArc($W - $dd, $H - $dd, $dd, $dd, 0, 90)
    $path.AddArc(0, $H - $dd, $dd, $dd, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-RoundedRegion {
    param($Control, [int]$Radius)
    $p = New-RoundRectPath -W $Control.Width -H $Control.Height -R $Radius
    $newRegion = New-Object System.Drawing.Region($p)
    $p.Dispose()
    if ($Control.Region) { $Control.Region.Dispose() }
    $Control.Region = $newRegion
}

# ================================================================ 全局异常兜底
# 启动器是隐藏控制台的，未处理异常必须落盘并弹窗，不能静默消失
$script:LogFile = Join-Path $script:Root 'InstallerHelper.log'
$script:LogBox = $null
$script:Busy = $false

function Append-Log {
    param([string]$Text)
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Text
    if ($script:LogBox -and -not $script:LogBox.IsDisposed) {
        $script:LogBox.AppendText($line + "`r`n")
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
    try {
        $fi = Get-Item -LiteralPath $script:LogFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 524288) { Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue }
        [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", [System.Text.Encoding]::UTF8)
    } catch { }
}

function Show-Error {
    param([string]$Title, [string]$Message, [string]$LogPath)
    $body = $Message
    if ($LogPath) { $body += "`r`n`r`n日志：$LogPath" }
    [void][System.Windows.Forms.MessageBox]::Show($body, $Title, 'OK', 'Error')
}

[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
$script:Unhandled = {
    param($sender, $e)
    try { Append-Log "未处理异常：$($e.Exception.Message)" } catch { }
    Show-Error '出错了' $e.Exception.Message $script:LogFile
}
[System.Windows.Forms.Application]::add_ThreadException($script:Unhandled)

$script:LogSink = { param($line) Append-Log $line }
$script:Tick = { [System.Windows.Forms.Application]::DoEvents() }

# ================================================================ 配置
$script:ConfigPath = Join-Path $script:Root 'config.json'
$script:Config = @{ InstallRoot = 'D:\我的应用'; DataRoot = 'D:\我的应用'; Desktop = $true; StartMenu = $true }

function Test-ValidRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -notmatch '^[A-Za-z]:\\') { return $false }
    if ($Path -match '^[A-Za-z]:\\?$') { return $false }
    return $true
}

if (Test-Path -LiteralPath $script:ConfigPath) {
    try {
        $l = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @('InstallRoot', 'DataRoot')) {
            if ($l.$k -and (Test-ValidRoot ([string]$l.$k))) { $script:Config[$k] = [string]$l.$k }
        }
        foreach ($k in @('Desktop', 'StartMenu')) {
            if ($null -ne $l.$k) { $script:Config[$k] = [bool]$l.$k }
        }
    } catch { }
}

function Save-Config {
    try {
        $script:Config | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    } catch {
        Append-Log "保存设置失败：$($_.Exception.Message)"
    }
}

# ================================================================ 窗体
$form = New-Object System.Windows.Forms.Form
$form.Text = 'InstallerHelper'
$form.ClientSize = New-Object System.Drawing.Size(764, 561)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Bg
$form.Font = $F.Body
$form.AllowDrop = $true
$form.Icon = [System.Drawing.SystemIcons]::Application
$icoPath = Join-Path $script:Root 'app.ico'
$script:OwnIcon = $null
if (Test-Path -LiteralPath $icoPath) {
    try {
        $script:OwnIcon = New-Object System.Drawing.Icon($icoPath)
        $form.Icon = $script:OwnIcon
    } catch { }
}

function Set-Busy {
    param([bool]$On)
    $script:Busy = $On
    $btnGo.Enabled = -not $On
    $btnDir.Enabled = -not $On
    $btnData.Enabled = (-not $On) -and $chkData.Checked
    $chkData.Enabled = -not $On
    $txtDir.Enabled = -not $On
    $lnkAdv.Enabled = -not $On
    $drop.AllowDrop = -not $On
    $form.UseWaitCursor = $On
}

# ---------------------------------------------------------------- 拖放区（主角）
$drop = New-Object System.Windows.Forms.Panel
$drop.Location = New-Object System.Drawing.Point(32, 28)
$drop.Size = New-Object System.Drawing.Size(700, 132)
$drop.AllowDrop = $true
$drop.BackColor = $C.Surface
$drop.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:DropHover = $false
$script:DropPath = $null
$script:DropFailed = $false

$drop.add_Paint({
    param($s, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($C.Surface)
        $r = New-RoundRectPath -W ($s.Width - 2) -H ($s.Height - 2) -R 12
        $borderColor = if ($script:DropHover) { $C.BorderHi } elseif ($script:DropFailed) { $C.Err } else { [System.Drawing.Color]::FromArgb(203, 213, 225) }
        $pen = New-Object System.Drawing.Pen($borderColor, 1.5)
        $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
        $g.DrawPath($pen, $r)
        $pen.Dispose()
        $r.Dispose()

        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $bTitle = New-Object System.Drawing.SolidBrush($(if ($script:DropHover) { $C.BorderHi } elseif ($script:DropFailed) { $C.Err } else { $C.Text }))
        $bSub = New-Object System.Drawing.SolidBrush($C.Muted)
        $rect1 = New-Object System.Drawing.RectangleF(0, 30, $s.Width, 34)
        $rect2 = New-Object System.Drawing.RectangleF(0, 66, $s.Width, 26)
        $title = if ($script:DropPath) { [System.IO.Path]::GetFileName($script:DropPath) } elseif ($script:DropFailed) { '这个包认不出来' } else { '拖入安装包' }
        $g.DrawString($title, $F.H1, $bTitle, $rect1, $sf)
        $sub = if ($script:DropPath) { '已识别，点下方按钮开始安装' } elseif ($script:DropFailed) { '换成 exe / msi 试试，或者点这里手动选' } else { 'exe / msi，也可以点一下这里选文件' }
        $g.DrawString($sub, $F.Small, $bSub, $rect2, $sf)
        $bTitle.Dispose()
        $bSub.Dispose()
        $sf.Dispose()
    } catch { }
})
$form.Controls.Add($drop)

# ---------------------------------------------------------------- 安装目录
$lblTo = New-Object System.Windows.Forms.Label
$lblTo.Text = '装到'
$lblTo.Location = New-Object System.Drawing.Point(34, 189)
$lblTo.AutoSize = $true
$lblTo.ForeColor = $C.Muted
$form.Controls.Add($lblTo)

$txtDir = New-Object System.Windows.Forms.TextBox
$txtDir.Location = New-Object System.Drawing.Point(100, 186)
$txtDir.Size = New-Object System.Drawing.Size(520, 26)
$txtDir.BorderStyle = 'FixedSingle'
$txtDir.BackColor = $C.Surface
$txtDir.ForeColor = $C.Text
$txtDir.Font = $F.Body
$form.Controls.Add($txtDir)

$btnDir = New-Object System.Windows.Forms.Button
$btnDir.Text = '选择'
$btnDir.Location = New-Object System.Drawing.Point(630, 184)
$btnDir.Size = New-Object System.Drawing.Size(102, 30)
$btnDir.FlatStyle = 'Flat'
$btnDir.FlatAppearance.BorderSize = 1
$btnDir.FlatAppearance.BorderColor = $C.Border
$btnDir.BackColor = $C.Surface
$btnDir.ForeColor = $C.Text
$btnDir.Font = $F.Small
$btnDir.Cursor = 'Hand'
$form.Controls.Add($btnDir)

# ---------------------------------------------------------------- 数据目录
$chkData = New-Object System.Windows.Forms.CheckBox
$chkData.Text = '把配置数据也搬到 D 盘（AppData 里的东西）'
$chkData.Location = New-Object System.Drawing.Point(100, 228)
$chkData.AutoSize = $true
$chkData.ForeColor = $C.Text
$chkData.Font = $F.Body
$form.Controls.Add($chkData)

$txtData = New-Object System.Windows.Forms.TextBox
$txtData.Location = New-Object System.Drawing.Point(100, 258)
$txtData.Size = New-Object System.Drawing.Size(520, 26)
$txtData.BorderStyle = 'FixedSingle'
$txtData.BackColor = $C.Bg
$txtData.ForeColor = $C.Muted
$txtData.Font = $F.Body
$txtData.Enabled = $false
$form.Controls.Add($txtData)

$btnData = New-Object System.Windows.Forms.Button
$btnData.Text = '选择'
$btnData.Location = New-Object System.Drawing.Point(630, 256)
$btnData.Size = New-Object System.Drawing.Size(102, 30)
$btnData.FlatStyle = 'Flat'
$btnData.FlatAppearance.BorderSize = 1
$btnData.FlatAppearance.BorderColor = $C.Border
$btnData.BackColor = $C.Surface
$btnData.ForeColor = $C.Text
$btnData.Font = $F.Small
$btnData.Cursor = 'Hand'
$btnData.Enabled = $false
$form.Controls.Add($btnData)

# ---------------------------------------------------------------- 主动作
$btnGo = New-Object System.Windows.Forms.Button
$btnGo.Text = '开始安装'
$btnGo.Location = New-Object System.Drawing.Point(32, 306)
$btnGo.Size = New-Object System.Drawing.Size(700, 46)
$btnGo.FlatStyle = 'Flat'
$btnGo.FlatAppearance.BorderSize = 0
$btnGo.FlatAppearance.MouseOverBackColor = $C.PrimaryHi
$btnGo.FlatAppearance.MouseDownBackColor = $C.PrimaryHi
$btnGo.BackColor = $C.Primary
$btnGo.ForeColor = [System.Drawing.Color]::White
$btnGo.Font = $F.Btn
$btnGo.Cursor = 'Hand'
$form.Controls.Add($btnGo)

# ---------------------------------------------------------------- 高级 + 日志
$lnkAdv = New-Object System.Windows.Forms.Label
$lnkAdv.Text = '高级选项'
$lnkAdv.Location = New-Object System.Drawing.Point(32, 374)
$lnkAdv.AutoSize = $true
$lnkAdv.ForeColor = $C.Muted
$lnkAdv.Font = $F.Link
$lnkAdv.Cursor = 'Hand'
$form.Controls.Add($lnkAdv)

$lnkLog = New-Object System.Windows.Forms.Label
$lnkLog.Text = '隐藏日志'
$lnkLog.Location = New-Object System.Drawing.Point(96, 374)
$lnkLog.AutoSize = $true
$lnkLog.ForeColor = $C.Muted
$lnkLog.Font = $F.Link
$lnkLog.Cursor = 'Hand'
$form.Controls.Add($lnkLog)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Location = New-Object System.Drawing.Point(32, 404)
$script:LogBox.Size = New-Object System.Drawing.Size(700, 128)
$script:LogBox.Multiline = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.ReadOnly = $true
$script:LogBox.BorderStyle = 'FixedSingle'
$script:LogBox.BackColor = $C.LogBg
$script:LogBox.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)
$script:LogBox.Font = $F.Mono
$form.Controls.Add($script:LogBox)

# ================================================================ 状态
$script:Info = $null

function Update-DropPaint {
    if ($drop -and -not $drop.IsDisposed) { $drop.Invalidate() }
}

function Clear-Package {
    $script:Info = $null
    $script:DropPath = $null
    $script:DropFailed = $true
    Update-DropPaint
}

function Set-Package {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { Clear-Package; return }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Clear-Package
        Append-Log "文件不存在：$Path"
        return
    }
    try {
        $info = Get-InstallerInfo -Path $Path
    } catch {
        Clear-Package
        Append-Log "识别失败：$($_.Exception.Message)"
        return
    }
    # 先算后提交：拿不到结果时不要把旧状态留在界面上
    $script:Info = $info
    $script:DropPath = $Path
    $script:DropFailed = $false
    Update-DropPaint

    $txtDir.Text = Join-Path $script:Config.InstallRoot $info.AppName
    if ($chkData.Checked) {
        $txtData.Text = Join-Path $script:Config.DataRoot ($info.AppName + '-Data')
    }
    Append-Log "识别：$([System.IO.Path]::GetFileName($Path)) → $($info.Kind) / $($info.AppName)"
    if (-not $info.Installable) {
        Append-Log "提示：这类包没法静默指定目录（$($info.Kind)），建议手动装完再用『高级选项』迁移。"
    } elseif (-not $info.SupportsCustomDir) {
        Append-Log "提示：$($info.Kind) 可能不认目录参数，装完会自动检测并问你是否迁移。"
    }
}

$drop.add_DragEnter({
    param($s, $e)
    try {
        if ($script:Busy) { $e.Effect = [System.Windows.Forms.DragDropEffects]::None; return }
        if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
            $script:DropHover = $true
            Update-DropPaint
        } else {
            $e.Effect = [System.Windows.Forms.DragDropEffects]::None
        }
    } catch { }
})
$drop.add_DragLeave({ $script:DropHover = $false; Update-DropPaint })
$drop.add_DragDrop({
    param($s, $e)
    try {
        $script:DropHover = $false
        Update-DropPaint
        if ($script:Busy) { return }
        $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        if (-not $files -or $files.Count -eq 0) { return }
        $f = $files[0]
        $ext = [System.IO.Path]::GetExtension($f).ToLowerInvariant()
        if ($ext -in @('.exe', '.msi', '.msix', '.msu')) {
            Set-Package $f
        } else {
            Append-Log "不支持的扩展名：$ext"
            [void][System.Windows.Forms.MessageBox]::Show($form, '请拖入 .exe / .msi / .msix 安装包。', 'InstallerHelper', 'OK', 'Information')
        }
    } catch {
        Append-Log "拖放出错：$($_.Exception.Message)"
    }
})
$drop.add_MouseEnter({ $script:DropHover = $true; Update-DropPaint })
$drop.add_MouseLeave({ $script:DropHover = $false; Update-DropPaint })
$drop.add_Click({
    if ($script:Busy) { return }
    $dlg = $null
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = '安装包|*.exe;*.msi;*.msix|所有文件|*.*'
        $dlg.Title = '选择安装包'
        if ($dlg.ShowDialog() -eq 'OK') { Set-Package $dlg.FileName }
    } catch {
        Append-Log "打开文件对话框失败：$($_.Exception.Message)"
    } finally {
        if ($null -ne $dlg) { $dlg.Dispose() }
    }
})

$btnDir.add_Click({
    if ($script:Busy) { return }
    $dlg = $null
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择安装目录'
        if ($dlg.ShowDialog() -eq 'OK') { $txtDir.Text = $dlg.SelectedPath }
    } catch {
        Append-Log "选择目录失败：$($_.Exception.Message)"
    } finally {
        if ($null -ne $dlg) { $dlg.Dispose() }
    }
})

$btnData.add_Click({
    if ($script:Busy) { return }
    $dlg = $null
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择配置数据存放目录'
        if ($dlg.ShowDialog() -eq 'OK') { $txtData.Text = $dlg.SelectedPath }
    } catch {
        Append-Log "选择目录失败：$($_.Exception.Message)"
    } finally {
        if ($null -ne $dlg) { $dlg.Dispose() }
    }
})

$chkData.add_CheckedChanged({
    try {
        $on = $chkData.Checked
        $txtData.Enabled = $on -and (-not $script:Busy)
        $btnData.Enabled = $on -and (-not $script:Busy)
        if ($on) {
            $txtData.BackColor = $C.Surface
            $txtData.ForeColor = $C.Text
            if (-not $txtData.Text -and $script:Info) {
                $txtData.Text = Join-Path $script:Config.DataRoot ($script:Info.AppName + '-Data')
            }
        } else {
            $txtData.BackColor = $C.Bg
            $txtData.ForeColor = $C.Muted
        }
        $script:Config.RedirectData = $on
        Save-Config
    } catch {
        Append-Log "切换配置数据失败：$($_.Exception.Message)"
    }
})

$txtDir.add_TextChanged({
    # 用户清空或填盘根时不要抛异常，静默忽略
    try {
        if (-not $chkData.Checked -or -not $txtData.Enabled) { return }
        $t = $txtDir.Text
        if ([string]::IsNullOrWhiteSpace($t)) { return }
        $t = $t.TrimEnd('\')
        if ($t -notmatch '^[A-Za-z]:\\') { return }
        $leaf = [System.IO.Path]::GetFileName($t)
        if ($leaf) { $txtData.Text = Join-Path $script:Config.DataRoot ($leaf + '-Data') }
    } catch { }
})

$lnkLog.add_Click({
    if ($script:LogBox.Visible) {
        $script:LogBox.Visible = $false
        $lnkLog.Text = '显示日志'
    } else {
        $script:LogBox.Visible = $true
        $lnkLog.Text = '隐藏日志'
    }
})

$lnkAdv.add_Click({ if (-not $script:Busy) { Show-Advanced } })

# ================================================================ 主流程
function Invoke-Install {
    if ($script:Busy) { return }
    if (-not $script:Info) {
        [void][System.Windows.Forms.MessageBox]::Show($form, '先把安装包拖进来。', 'InstallerHelper', 'OK', 'Information')
        return
    }
    if (-not $script:Info.Installable) {
        $msg = switch ($script:Info.Kind) {
            'MSIX' { 'MSIX 应用得用系统安装器装。装完后可以用『高级选项 → 重定向软件的数据目录』。' }
            'SevenZipSFX' { '这是自解压包，不能静默指定目录。请手动解压或运行它，再用『高级选项』迁移。' }
            'MSU' { '这是 Windows 更新包，不是应用安装器。' }
            default { "识别不出这是什么安装器（$($script:Info.Kind)），没法自动静默安装。`r`n`r`n可以手动装完，再用『高级选项 → 把软件目录迁到 D 盘』。" }
        }
        [void][System.Windows.Forms.MessageBox]::Show($form, $msg, '装不了这个包', 'OK', 'Warning')
        return
    }

    $dir = $txtDir.Text.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($dir)) {
        [void][System.Windows.Forms.MessageBox]::Show($form, '请填写安装目录。', 'InstallerHelper', 'OK', 'Warning')
        return
    }
    if ($dir -notmatch '^[A-Za-z]:\\') {
        [void][System.Windows.Forms.MessageBox]::Show($form, "安装目录要写成完整路径，比如 D:\我的应用\软件名。", 'InstallerHelper', 'OK', 'Warning')
        return
    }
    if ($dir -match '^[A-Za-z]:$') {
        [void][System.Windows.Forms.MessageBox]::Show($form, '别直接装到盘根，给它一个单独的文件夹。', 'InstallerHelper', 'OK', 'Warning')
        return
    }
    if (Test-ProtectedPath $dir) {
        [void][System.Windows.Forms.MessageBox]::Show($form, "不往系统目录里装：$dir", 'InstallerHelper', 'OK', 'Warning')
        return
    }

    $installStart = [DateTime]::UtcNow
    Set-Busy $true
    $btnGo.Text = '安装中，请稍候…'
    $btnGo.BackColor = $C.PrimaryLo

    try {
        Append-Log "—— 开始安装到 $dir"
        $snapBefore = Get-AppDataSnapshot
        $result = Install-Silent -Path $script:Info.Path -Kind $script:Info.Kind -InstallDir $dir -AppNameHint $script:Info.AppName

        Append-Log "安装器：$($result.Message)"
        if ($result.LogFile -and (Test-Path -LiteralPath $result.LogFile)) {
            Append-Log "安装日志：$($result.LogFile)"
        }

        $final = $result.ActualDir

        if (-not $result.Success) {
            $lines = @("安装没成功。", "")
            $lines += "退出码：$($result.ExitCode)"
            $lines += "原因：$($result.Message)"
            if ($result.LogFile) { $lines += "日志：$($result.LogFile)" }
            if (-not (Test-IsAdmin)) { $lines += ""; $lines += "提示：试试右键启动器 → 以管理员身份运行。" }
            [void][System.Windows.Forms.MessageBox]::Show($form, ($lines -join "`r`n"), '安装失败', 'OK', 'Error')
            $btnGo.Text = '没装上'
            return
        }

        # 装到了别的地方：问要不要搬
        if ($final -and (-not $result.RequestedDirHonored) -and ($final -ne $dir) -and (Test-Path -LiteralPath $final)) {
            $ans = [System.Windows.Forms.MessageBox]::Show($form,
                "安装器没听指令，装到了：`r`n$final`r`n`r`n要不要迁到 $dir ？`r`n（用链接方式，软件仍按原路径找得到）",
                '装错地方了', 'YesNo', 'Question')
            if ($ans -eq 'Yes') {
                $mv = Move-DirWithJunction -Source $final -Destination $dir
                if ($mv.Ok) {
                    Append-Log "已迁到 $dir"
                    $final = $dir
                } else {
                    Append-Log "迁移没成：$($mv.Message)"
                    [void][System.Windows.Forms.MessageBox]::Show($form, $mv.Message, '迁移失败', 'OK', 'Warning')
                }
            }
        }

        if ($final) {
            # 只有装了东西才往下走，避免对着空目录建快捷方式
            $hasContent = @(Get-ChildItem -LiteralPath $final -Force -ErrorAction SilentlyContinue).Count -gt 0
            if ($hasContent) {
                $exe = Find-MainExecutable -InstallDir $final -AppNameHint $script:Info.AppName
                if ($exe) {
                    Append-Log "主程序：$($exe.Name)"
                    if ($script:Config.Desktop -or $script:Config.StartMenu) {
                        $made = New-AppShortcut -TargetExe $exe.FullName -Name $script:Info.AppName `
                            -WorkingDir $exe.DirectoryName `
                            -Desktop:$script:Config.Desktop -StartMenu:$script:Config.StartMenu
                        if ($made -and $made.Count -gt 0) { Append-Log "快捷方式：$($made.Count) 个" }
                    }
                } else {
                    Append-Log '没找到合适的主程序，先不建快捷方式。'
                }
                $gb = [math]::Round((Get-DirSizeSB -Path $final) / 1GB, 2)
                Append-Log "装好了：$final（$gb GB）"
                $script:Config.InstallRoot = [System.IO.Path]::GetDirectoryName($dir)
                Save-Config
            } else {
                Append-Log "目录是空的：$final"
            }
        }

        # 配置数据重定向
        if ($chkData.Checked -and $txtData.Text) {
            $target = $txtData.Text.TrimEnd('\')
            Append-Log '检查 AppData 里新增的配置目录…'
            $snapAfter = Get-AppDataSnapshot
            $newDirs = @(Get-NewAppDataDirs -Before $snapBefore -After $snapAfter `
                            -AppNameHint $script:Info.AppName -SinceUtc $installStart |
                         Where-Object { $_.MatchHint })
            if ($newDirs.Count -eq 0) {
                Append-Log '暂时没有。多数软件首次启动才建配置目录 —— 先运行一次软件，回来点"高级选项 → 重定向软件的数据目录"。'
            } else {
                $names = ($newDirs | ForEach-Object { '  ' + $_.FullName }) -join "`r`n"
                $ans = [System.Windows.Forms.MessageBox]::Show($form,
                    "发现这些配置目录：`r`n`r`n$names`r`n`r`n搬到 $target 并在原位置留链接？",
                    '配置数据', 'YesNo', 'Question')
                if ($ans -eq 'Yes') {
                    $ok = 0
                    foreach ($d in $newDirs) {
                        $dest = Join-Path $target $d.Name
                        $r = Move-DirWithJunction -Source $d.FullName -Destination $dest
                        if ($r.Ok) {
                            $ok++
                            Append-Log "已搬：$($d.Name)"
                        } else {
                            Append-Log "未搬：$($d.Name) — $($r.Message)"
                        }
                    }
                    Append-Log "配置数据：搬了 $ok / $($newDirs.Count) 个"
                    if ($ok -gt 0) {
                        $script:Config.DataRoot = [System.IO.Path]::GetDirectoryName($target)
                        Save-Config
                    }
                }
            }
        }

        $btnGo.Text = '装好啦'
        $script:ResetTimer.Start()
    } catch {
        Append-Log "出错：$($_.Exception.Message)"
        Show-Error '安装失败' $_.Exception.Message $script:LogFile
        $btnGo.Text = '出错了'
    } finally {
        Set-Busy $false
        if ($btnGo.Text -eq '安装中，请稍候…') {
            $btnGo.Text = '开始安装'
            $btnGo.BackColor = $C.Primary
        }
    }
}
$btnGo.add_Click({ Invoke-Install })

$script:ResetTimer = New-Object System.Windows.Forms.Timer
$script:ResetTimer.Interval = 1800
$script:ResetTimer.add_Tick({
    $script:ResetTimer.Stop()
    $btnGo.Text = '开始安装'
    $btnGo.BackColor = $C.Primary
})

# ================================================================ 高级对话框
function Show-Advanced {
    $d = $null
    try {
        $d = New-Object System.Windows.Forms.Form
        $d.Text = '高级选项'
        $d.ClientSize = New-Object System.Drawing.Size(440, 300)
        $d.FormBorderStyle = 'FixedDialog'
        $d.MaximizeBox = $false
        $d.MinimizeBox = $false
        $d.StartPosition = 'CenterParent'
        $d.BackColor = $C.Bg
        $d.Font = $F.Body

        $t = New-Object System.Windows.Forms.Label
        $t.Text = '安装后创建快捷方式'
        $t.Location = New-Object System.Drawing.Point(24, 22)
        $t.AutoSize = $true
        $t.ForeColor = $C.Text
        $t.Font = $F.SmallB
        $d.Controls.Add($t)

        $c1 = New-Object System.Windows.Forms.CheckBox
        $c1.Text = '桌面'
        $c1.Location = New-Object System.Drawing.Point(26, 50)
        $c1.AutoSize = $true
        $c1.Checked = [bool]$script:Config.Desktop
        $d.Controls.Add($c1)

        $c2 = New-Object System.Windows.Forms.CheckBox
        $c2.Text = '开始菜单'
        $c2.Location = New-Object System.Drawing.Point(150, 50)
        $c2.AutoSize = $true
        $c2.Checked = [bool]$script:Config.StartMenu
        $d.Controls.Add($c2)

        $line = New-Object System.Windows.Forms.Label
        $line.Location = New-Object System.Drawing.Point(24, 88)
        $line.Size = New-Object System.Drawing.Size(392, 1)
        $line.BackColor = $C.Border
        $d.Controls.Add($line)

        $t2 = New-Object System.Windows.Forms.Label
        $t2.Text = '已经装好的软件'
        $t2.Location = New-Object System.Drawing.Point(24, 104)
        $t2.AutoSize = $true
        $t2.ForeColor = $C.Text
        $t2.Font = $F.SmallB
        $d.Controls.Add($t2)

        $b1 = New-Object System.Windows.Forms.Button
        $b1.Text = '把软件目录迁到 D 盘…'
        $b1.Location = New-Object System.Drawing.Point(26, 132)
        $b1.Size = New System.Drawing.Size(390, 34)
        $b1.FlatStyle = 'Flat'
        $b1.FlatAppearance.BorderSize = 1
        $b1.FlatAppearance.BorderColor = $C.Border
        $b1.BackColor = $C.Surface
        $b1.Cursor = 'Hand'
        $d.Controls.Add($b1)

        $b2 = New-Object System.Windows.Forms.Button
        $b2.Text = '重定向软件的数据目录…'
        $b2.Location = New-Object System.Drawing.Point(26, 174)
        $b2.Size = New-Object System.Drawing.Size(390, 34)
        $b2.FlatStyle = 'Flat'
        $b2.FlatAppearance.BorderSize = 1
        $b2.FlatAppearance.BorderColor = $C.Border
        $b2.BackColor = $C.Surface
        $b2.Cursor = 'Hand'
        $d.Controls.Add($b2)

        $hint = New-Object System.Windows.Forms.Label
        $hint.Text = '迁移用链接实现，软件感知不到。卸载前先把链接还原成普通目录。'
        $hint.Location = New-Object System.Drawing.Point(26, 216)
        $hint.Size = New-Object System.Drawing.Size(390, 34)
        $hint.ForeColor = $C.Muted
        $hint.Font = $F.Small
        $d.Controls.Add($hint)

        $ok = New-Object System.Windows.Forms.Button
        $ok.Text = '完成'
        $ok.Location = New-Object System.Drawing.Point(316, 254)
        $ok.Size = New System.Drawing.Size(100, 32)
        $ok.FlatStyle = 'Flat'
        $ok.FlatAppearance.BorderSize = 0
        $ok.BackColor = $C.Primary
        $ok.ForeColor = [System.Drawing.Color]::White
        $ok.Cursor = 'Hand'
        $d.Controls.Add($ok)
        $ok.add_Click({ $d.Close() })

        $c1.add_CheckedChanged({ $script:Config.Desktop = $c1.Checked; Save-Config })
        $c2.add_CheckedChanged({ $script:Config.StartMenu = $c2.Checked; Save-Config })

        $b1.add_Click({
            if ($script:Busy) { return }
            $dlg = $null
            try {
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = '选择要迁移的现有安装目录'
                if ($dlg.ShowDialog() -ne 'OK') { return }
                $src = $dlg.SelectedPath.TrimEnd('\')
                if (Test-ProtectedPath $src) {
                    [void][System.Windows.Forms.MessageBox]::Show($d, "不迁移系统目录：$src", '不让迁', 'OK', 'Warning')
                    return
                }
                if (Test-IsJunction $src) {
                    [void][System.Windows.Forms.MessageBox]::Show($d, "这个目录已经是链接了：$src", '不用迁', 'OK', 'Information')
                    return
                }
                $dst = Join-Path $script:Config.InstallRoot ([System.IO.Path]::GetFileName($src))
                if ([System.IO.Path]::GetFullPath($src).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($dst).TrimEnd('\')) {
                    [void][System.Windows.Forms.MessageBox]::Show($d, "它已经在 $($script:Config.InstallRoot) 下了，不用迁。", '不用迁', 'OK', 'Information')
                    return
                }
                if ([System.Windows.Forms.MessageBox]::Show($d, "把`r`n$src`r`n迁到`r`n$dst ？`r`n`r`n迁移期间别关窗口，大目录可能要几分钟。", '确认', 'YesNo', 'Question') -ne 'Yes') { return }

                Set-Busy $true
                try {
                    Append-Log "开始迁移：$src → $dst"
                    $r = Move-DirWithJunction -Source $src -Destination $dst
                } finally {
                    Set-Busy $false
                }
                if ($r.Ok) {
                    Append-Log "已迁移：$src → $dst"
                    [void][System.Windows.Forms.MessageBox]::Show($d, '迁好了。', '完成', 'OK', 'Information')
                } else {
                    Append-Log "迁移失败：$($r.Message)"
                    [void][System.Windows.Forms.MessageBox]::Show($d, $r.Message, '迁移失败', 'OK', 'Error')
                }
            } catch {
                Append-Log "迁移出错：$($_.Exception.Message)"
                [void][System.Windows.Forms.MessageBox]::Show($d, $_.Exception.Message, '迁移失败', 'OK', 'Error')
            } finally {
                if ($null -ne $dlg) { $dlg.Dispose() }
            }
        })

        $b2.add_Click({ if (-not $script:Busy) { Show-Redirect } })

        [void]$d.ShowDialog($form)
    } catch {
        Append-Log "高级选项出错：$($_.Exception.Message)"
    } finally {
        if ($null -ne $d) { $d.Dispose() }
    }
}

# ================================================================ 数据重定向
function Show-Redirect {
    $d = $null
    try {
        $d = New-Object System.Windows.Forms.Form
        $d.Text = '重定向数据目录'
        $d.ClientSize = New-Object System.Drawing.Size(680, 470)
        $d.FormBorderStyle = 'FixedDialog'
        $d.MaximizeBox = $false
        $d.MinimizeBox = $false
        $d.StartPosition = 'CenterParent'
        $d.BackColor = $C.Bg
        $d.Font = $F.Body

        $t = New-Object System.Windows.Forms.Label
        $t.Text = '软件名'
        $t.Location = New-Object System.Drawing.Point(22, 24)
        $t.AutoSize = $true
        $t.ForeColor = $C.Muted
        $d.Controls.Add($t)

        $name = New-Object System.Windows.Forms.TextBox
        $name.Location = New-Object System.Drawing.Point(80, 21)
        $name.Size = New-Object System.Drawing.Size(200, 26)
        $name.BorderStyle = 'FixedSingle'
        if ($script:Info) { $name.Text = $script:Info.AppName }
        $d.Controls.Add($name)

        $scan = New-Object System.Windows.Forms.Button
        $scan.Text = '扫描'
        $scan.Location = New-Object System.Drawing.Point(290, 19)
        $scan.Size = New-Object System.Drawing.Size(80, 30)
        $scan.FlatStyle = 'Flat'
        $scan.FlatAppearance.BorderSize = 1
        $scan.FlatAppearance.BorderColor = $C.Border
        $scan.BackColor = $C.Surface
        $scan.Cursor = 'Hand'
        $d.Controls.Add($scan)

        $list = New-Object System.Windows.Forms.ListView
        $list.Location = New-Object System.Drawing.Point(22, 62)
        $list.Size = New System.Drawing.Size(636, 250)
        $list.View = 'Details'
        $list.CheckBoxes = $true
        $list.FullRowSelect = $true
        $list.BorderStyle = 'FixedSingle'
        $list.BackColor = $C.Surface
        $list.Font = $F.Small
        [void]$list.Columns.Add('目录名', 170)
        [void]$list.Columns.Add('大小', 70)
        [void]$list.Columns.Add('创建时间', 110)
        [void]$list.Columns.Add('完整路径', 260)
        $d.Controls.Add($list)

        $tl = New-Object System.Windows.Forms.Label
        $tl.Text = '放到'
        $tl.Location = New-Object System.Drawing.Point(22, 330)
        $tl.AutoSize = $true
        $tl.ForeColor = $C.Muted
        $d.Controls.Add($tl)

        $target = New-Object System.Windows.Forms.TextBox
        $target.Location = New-Object System.Drawing.Point(80, 327)
        $target.Size = New-Object System.Drawing.Size(500, 26)
        $target.BorderStyle = 'FixedSingle'
        $target.Text = $script:Config.DataRoot
        $d.Controls.Add($target)

        $bt = New-Object System.Windows.Forms.Button
        $bt.Text = '选择'
        $bt.Location = New System.Drawing.Point(590, 325)
        $bt.Size = New System.Drawing.Size(68, 30)
        $bt.FlatStyle = 'Flat'
        $bt.FlatAppearance.BorderSize = 1
        $bt.FlatAppearance.BorderColor = $C.Border
        $bt.BackColor = $C.Surface
        $bt.Cursor = 'Hand'
        $d.Controls.Add($bt)

        $hint = New-Object System.Windows.Forms.Label
        $hint.Text = '勾选要搬走的目录（点左边的小方块）。搬完原位置会变成链接，软件照样能找到。'
        $hint.Location = New System.Drawing.Point(22, 360)
        $hint.Size = New System.Drawing.Size(636, 20)
        $hint.ForeColor = $C.Muted
        $hint.Font = $F.Small
        $d.Controls.Add($hint)

        $go = New-Object System.Windows.Forms.Button
        $go.Text = '迁移勾选项'
        $go.Location = New System.Drawing.Point(22, 390)
        $go.Size = New System.Drawing.Size(160, 40)
        $go.FlatStyle = 'Flat'
        $go.FlatAppearance.BorderSize = 0
        $go.BackColor = $C.Primary
        $go.ForeColor = [System.Drawing.Color]::White
        $go.Cursor = 'Hand'
        $d.Controls.Add($go)

        $close = New-Object System.Windows.Forms.Button
        $close.Text = '关闭'
        $close.Location = New System.Drawing.Point(556, 390)
        $close.Size = New System.Drawing.Size(102, 40)
        $close.FlatStyle = 'Flat'
        $close.FlatAppearance.BorderSize = 1
        $close.FlatAppearance.BorderColor = $C.Border
        $close.BackColor = $C.Surface
        $close.Cursor = 'Hand'
        $d.Controls.Add($close)
        $close.add_Click({ $d.Close() })

        $scan.add_Click({
            try {
                $hintText = $name.Text.Trim()
                if (-not $hintText) { return }
                $norm = ($hintText.ToLowerInvariant() -replace '[^a-z0-9]', '')
                $found = @()
                foreach ($root in (Get-AppDataRoots)) {
                    if (-not $root.Path -or -not (Test-Path -LiteralPath $root.Path)) { continue }
                    foreach ($di in @(Get-ChildItem -LiteralPath $root.Path -Directory -Force -ErrorAction SilentlyContinue)) {
                        if ($script:KnownSystemDirs -contains $di.Name) { continue }
                        $sc = 0
                        if ($norm) { $sc = Get-NameMatchScore -Name $di.Name -Norm $norm }
                        elseif ($di.Name -ieq $hintText) { $sc = 100 }
                        if ($sc -gt 0) {
                            $found += [pscustomobject]@{
                                Name    = $di.Name
                                FullName= $di.FullName
                                SizeMB  = [math]::Round((Get-DirSizeSB -Path $di.FullName) / 1MB, 1)
                                Created = $di.CreationTime
                                Score   = $sc
                                Auto    = ($sc -eq 100)
                                IsLink  = (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
                            }
                        }
                    }
                }
                $list.Items.Clear()
                foreach ($f in ($found | Sort-Object Score -Descending)) {
                    $it = New-Object System.Windows.Forms.ListViewItem($f.Name)
                    [void]$it.SubItems.Add("$($f.SizeMB) MB")
                    [void]$it.SubItems.Add($f.Created.ToString('yyyy-MM-dd HH:mm'))
                    [void]$it.SubItems.Add($f.FullName)
                    $it.Checked = $f.Auto
                    $it.Tag = $f
                    if ($f.IsLink) { $it.ForeColor = $C.Ok }
                    [void]$list.Items.Add($it)
                }
                Append-Log "扫描 $hintText：$($found.Count) 个候选（绿字的是已经搬过的）"
            } catch {
                Append-Log "扫描出错：$($_.Exception.Message)"
            }
        })

        $bt.add_Click({
            $dlg = $null
            try {
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = '选择数据存放目录'
                if ($dlg.ShowDialog() -eq 'OK') { $target.Text = $dlg.SelectedPath }
            } finally {
                if ($null -ne $dlg) { $dlg.Dispose() }
            }
        })

        $go.add_Click({
            if ($script:Busy) { return }
            try {
                $dstRoot = $target.Text.TrimEnd('\')
                $sel = @($list.Items | Where-Object { $_.Checked })
                if (-not $dstRoot) { [void][System.Windows.Forms.MessageBox]::Show($d, '先选放到哪里。', '提示', 'OK', 'Warning'); return }
                if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($d, '先勾选要搬的目录。', '提示', 'OK', 'Warning'); return }
                if (Test-ProtectedPath $dstRoot) {
                    [void][System.Windows.Forms.MessageBox]::Show($d, "别放到系统目录：$dstRoot", '不行', 'OK', 'Warning')
                    return
                }
                if (-not (Test-Path -LiteralPath $dstRoot)) { New-Item -ItemType Directory -Path $dstRoot -Force | Out-Null }

                Set-Busy $true
                $ok = 0
                $failed = @()
                try {
                    foreach ($it in $sel) {
                        $f = $it.Tag
                        if ($f.IsLink) {
                            Append-Log "已经是链接，跳过：$($f.Name)"
                            continue
                        }
                        $r = Move-DirWithJunction -Source $f.FullName -Destination (Join-Path $dstRoot $f.Name)
                        if ($r.Ok) {
                            $ok++
                            $it.Checked = $false
                            $it.ForeColor = $C.Ok
                            Append-Log "已搬：$($f.Name)"
                        } else {
                            $failed += $f.Name
                            Append-Log "未搬：$($f.Name) — $($r.Message)"
                        }
                    }
                } finally {
                    Set-Busy $false
                }
                if ($ok -gt 0) {
                    $script:Config.DataRoot = [System.IO.Path]::GetDirectoryName($dstRoot)
                    Save-Config
                }
                $msg = "搬好 $ok 个"
                if ($failed.Count -gt 0) { $msg += "，失败 $($failed.Count) 个：`r`n" + ($failed -join "`r`n") }
                [void][System.Windows.Forms.MessageBox]::Show($d, $msg, '完成', 'OK', 'Information')
            } catch {
                Append-Log "迁移出错：$($_.Exception.Message)"
                [void][System.Windows.Forms.MessageBox]::Show($d, $_.Exception.Message, '迁移失败', 'OK', 'Error')
            }
        })

        [void]$d.ShowDialog($form)
    } catch {
        Append-Log "数据目录窗口出错：$($_.Exception.Message)"
    } finally {
        if ($null -ne $d) { $d.Dispose() }
    }
}

# ================================================================ 收尾
$lnkAdv.add_MouseEnter({ $lnkAdv.ForeColor = $C.Primary })
$lnkAdv.add_MouseLeave({ $lnkAdv.ForeColor = $C.Muted })
$lnkLog.add_MouseEnter({ $lnkLog.ForeColor = $C.Primary })
$lnkLog.add_MouseLeave({ $lnkLog.ForeColor = $C.Muted })

$form.add_Shown({
    try {
        $lblTo.BackColor = $C.Bg
        $chkData.BackColor = $C.Bg
        $lnkAdv.BackColor = $C.Bg
        $lnkLog.BackColor = $C.Bg
        Set-RoundedRegion -Control $btnGo -Radius 8
        Set-RoundedRegion -Control $btnDir -Radius 6
        Set-RoundedRegion -Control $btnData -Radius 6
        $btnDir.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(249, 250, 251)
        $btnData.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(249, 250, 251)
        Append-Log '把安装包拖进来，或者点一下上面那个框选择文件。'
        if (-not (Test-IsAdmin)) { Append-Log '（当前不是管理员，往系统目录装可能会失败）' }
        if ($script:Config.RedirectData) { $chkData.Checked = $true }
    } catch { }
})

$form.add_FormClosing({
    param($s, $e)
    if ($script:Busy) {
        $e.Cancel = $true
        [void][System.Windows.Forms.MessageBox]::Show($form, '正在安装或迁移，等它跑完再关。', 'InstallerHelper', 'OK', 'Information')
        return
    }
    try { Save-Config } catch { }
})

$form.add_FormClosed({
    try {
        $script:ResetTimer.Stop()
        foreach ($f in $script:F.Values) { if ($f) { $f.Dispose() } }
        if ($script:OwnIcon) { $script:OwnIcon.Dispose() }
    } catch { }
})

[void]$form.ShowDialog()
