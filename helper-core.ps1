# InstallerHelper core library
# 安装器识别 / 静默安装 / 目录迁移(junction) / 快捷方式
# 注意：本文件是函数库，不改动宿主的 $ErrorActionPreference / StrictMode。

$script:LogSink = $null
$script:Tick = $null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    if ($null -ne $script:LogSink) {
        & $script:LogSink $line
    } else {
        Write-Host $line
    }
}

# ---------------------------------------------------------------- 无窗口执行
# 本工具用 -noConsole 编译的 exe 或隐藏窗口的 powershell 跑，此时用 & 或 Start-Process
# 调 cmd / robocopy / taskkill 这类控制台程序，会弹出一个黑色窗口（失败时还带红字一闪而过）。
# 统一走 ProcessStartInfo + CreateNoWindow，彻底不建窗口。

function Start-HiddenProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = ''
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    return [System.Diagnostics.Process]::Start($psi)
}

function Invoke-Hidden {
    # 同步跑一个控制台程序，返回退出码；不建窗口、不抓输出
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = ''
    )
    $p = Start-HiddenProcess -FilePath $FilePath -Arguments $Arguments
    $p.WaitForExit()
    $rc = $p.ExitCode
    $p.Dispose()
    return $rc
}

# ---------------------------------------------------------------- 二进制读取

function Read-BinaryChunk {
    param([string]$Path, [long]$Offset, [int]$Count)
    if ($Count -le 0) { return [byte[]]@() }
    $fs = $null
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        if ($Offset -gt 0) { [void]$fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) }
        $len = [int][Math]::Min([long]$Count, [long]($fs.Length - $Offset))
        if ($len -le 0) { return [byte[]]@() }
        $buf = New-Object byte[] $len
        $read = 0
        while ($read -lt $len) {
            $n = $fs.Read($buf, $read, $len - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        return $buf
    } catch {
        return [byte[]]@()
    } finally {
        if ($null -ne $fs) { $fs.Close() }
    }
}

function Find-PatternInBytes {
    param([byte[]]$Bytes, [string[]]$Patterns)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return $null }
    $ascii = [System.Text.Encoding]::ASCII.GetString($Bytes)
    foreach ($p in $Patterns) {
        if ($ascii.IndexOf($p, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $p }
    }
    $utf16 = [System.Text.Encoding]::Unicode.GetString($Bytes)
    foreach ($p in $Patterns) {
        if ($utf16.IndexOf($p, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $p }
    }
    return $null
}

function Test-BinaryContains {
    param(
        [string]$Path,
        [string[]]$Patterns,
        [int]$MaxBytes = 1048576
    )
    $buf = Read-BinaryChunk -Path $Path -Offset 0 -Count $MaxBytes
    return (Find-PatternInBytes -Bytes $buf -Patterns $Patterns)
}

# ---------------------------------------------------------------- 安装器识别

function Get-InstallerKind {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        '.msi'  { return 'MSI' }
        '.msix' { return 'MSIX' }
        '.appx' { return 'MSIX' }
        '.msu'  { return 'MSU' }
    }
    if ($ext -ne '.exe') { return 'Unknown' }

    $len = 0
    try { $len = (Get-Item -LiteralPath $Path).Length } catch { return 'Unknown' }

    # 只读两段：头部 1MB（stub 与明文配置）+ 尾部 2MB（压缩数据后的元数据）
    $head = Read-BinaryChunk -Path $Path -Offset 0 -Count 1048576
    $tailLen = [int][Math]::Min(2097152, $len)
    $tail = Read-BinaryChunk -Path $Path -Offset ([Math]::Max(0, $len - $tailLen)) -Count $tailLen

    # Inno 的可靠指纹在压缩数据之后，必须查尾部；大包头部查不到
    if (Find-PatternInBytes -Bytes $tail -Patterns @('Inno Setup Setup Data', 'Inno Setup Messages', 'Inno Setup')) { return 'InnoSetup' }
    # 7z SFX 的自解压配置是头部明文，必须先于 InstallShield 判定
    if (Find-PatternInBytes -Bytes $head -Patterns @(';!@Install@!UTF-8!', ';!@InstallEnd@!', ';!@Install@!')) { return 'SevenZipSFX' }
    if (Find-PatternInBytes -Bytes $head -Patterns @('NullsoftInst', 'Nullsoft.NSIS')) { return 'NSIS' }
    # Squirrel 的 Setup.exe 是 WiX Burn 打的，必须先于 WiX 判定
    if (Find-PatternInBytes -Bytes $head -Patterns @('Squirrel', 'Update.exe --processStart', 'SquirrelTemp')) { return 'Squirrel' }
    if (Find-PatternInBytes -Bytes $head -Patterns @('WixBundle', 'BurnStub', 'wixburn')) { return 'WiXBundle' }
    if (Find-PatternInBytes -Bytes $head -Patterns @('InstallShield')) { return 'InstallShield' }
    return 'Unknown'
}

# ---------------------------------------------------------------- 名称推断

$script:JunkTokens = @(
    'x64', 'x86', 'amd64', 'arm64', 'win32', 'win64', 'win', 'windows',
    'setup', 'installer', 'install', 'portable', 'full', 'web',
    'beta', 'alpha', 'rc', 'latest', 'release', 'stable', 'app', 'desktop'
)

function Test-JunkToken {
    param([string]$Token)
    if ($Token -match '^v?\d+(\.\d+)+$') { return $true }
    if ($Token -match '^\d+$') { return $true }
    if ($Token -match '^\d+bit$') { return $true }
    foreach ($j in $script:JunkTokens) {
        if ($Token -ieq $j) { return $true }
    }
    return $false
}

function Get-AppNameFromFile {
    param([string]$Path)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $base = [regex]::Replace($base, '\([^)]*\)', '')
    $base = [regex]::Replace($base, '\[[^\]]*\]', '')

    # 前缀 setup/installer/web 之类先剥掉，避免 Setup_WeChat 变成 "Setup-WeChat"
    $base = [regex]::Replace($base, '(?i)^(setup|installer|install)[-_\. ]+', '')
    $base = [regex]::Replace($base, '(?i)[-_\. ]+(setup|installer|install)$', '')

    $parts = @($base -split '[-_\. ]+' | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { return 'App' }

    while ($parts.Count -gt 1 -and (Test-JunkToken $parts[-1])) {
        $parts = @($parts[0..($parts.Count - 2)])
    }

    $name = ($parts -join '-')
    $name = [regex]::Replace($name, '(?i)(setup|installer|install)$', '')
    $name = $name.Trim('-', '_', ' ')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'App' }
    return $name
}

function Get-InstallerInfo {
    param([string]$Path)
    $kind = Get-InstallerKind -Path $Path
    $name = Get-AppNameFromFile -Path $Path
    $ver = ''
    $vi = $null
    try { $vi = (Get-Item -LiteralPath $Path).VersionInfo } catch { }
    if ($vi) {
        if ($vi.FileVersion) { $ver = $vi.FileVersion }
        elseif ($vi.ProductVersion) { $ver = $vi.ProductVersion }
        # 文件名推断不出东西时，用 PE 里的产品名兜底
        if (($name -eq 'App' -or $name.Length -le 2) -and $vi.ProductName) {
            $pn = ($vi.ProductName -replace '[\\/:*?"<>|]', '').Trim()
            if ($pn) { $name = $pn }
        }
    }

    $installable = $kind -in @('NSIS', 'InnoSetup', 'MSI', 'WiXBundle', 'InstallShield', 'Squirrel')
    $supportsCustomDir = $kind -in @('NSIS', 'InnoSetup', 'MSI', 'InstallShield')

    return [pscustomobject]@{
        Path              = $Path
        Kind              = $kind
        AppName           = $name
        Version           = $ver
        Installable       = $installable
        SupportsCustomDir = $supportsCustomDir
        ProductName       = $(if ($vi) { [string]$vi.ProductName } else { '' })
    }
}

# ---------------------------------------------------------------- 注册表快照

$script:UninstallRoots = @(
    @{ Hive = 'HKCU'; Path = 'Software\Microsoft\Windows\CurrentVersion\Uninstall' },
    @{ Hive = 'HKCU'; Path = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' },
    @{ Hive = 'HKLM'; Path = 'Software\Microsoft\Windows\CurrentVersion\Uninstall' },
    @{ Hive = 'HKLM'; Path = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
)

function Get-RootKey {
    param([string]$Hive)
    if ($Hive -eq 'HKCU') { return [Microsoft.Win32.Registry]::CurrentUser }
    return [Microsoft.Win32.Registry]::LocalMachine
}

function Get-UninstallSnapshot {
    $map = @{}
    foreach ($r in $script:UninstallRoots) {
        $base = Get-RootKey -Hive $r.Hive
        $root = $null
        try { $root = $base.OpenSubKey($r.Path) } catch { continue }
        if ($null -eq $root) { continue }
        $names = @()
        try { $names = @($root.GetSubKeyNames()) } catch { $names = @() }
        foreach ($name in $names) {
            $sub = $null
            try { $sub = $root.OpenSubKey($name) } catch { continue }
            if ($null -eq $sub) { continue }
            try {
                $dn = $sub.GetValue('DisplayName')
                if ([string]::IsNullOrWhiteSpace([string]$dn)) { continue }
                $key = "$($r.Hive)|$($r.Path)|$name"
                $map[$key] = [pscustomobject]@{
                    Name              = [string]$dn
                    Version           = [string]$sub.GetValue('DisplayVersion')
                    InstallLoc        = [string]$sub.GetValue('InstallLocation')
                    DisplayIcon       = [string]$sub.GetValue('DisplayIcon')
                    UninstallStr      = [string]$sub.GetValue('UninstallString')
                    QuietUninstallStr = [string]$sub.GetValue('QuietUninstallString')
                    KeyPath           = "$($r.Hive):\$($r.Path)\$name"
                }
            } finally {
                $sub.Close()
            }
        }
        $root.Close()
    }
    return $map
}

# 这些通常是安装器附带塞进来的运行库/前置组件，不是用户要装的那个软件
$script:BundledNamePattern = '(?i)visual c\+\+|vc_?redist|vcredist|\.net (framework|runtime|core)|webview2|directx|windows sdk|bonjour|^update for |^hotfix|windows driver package|microsoft edge update'

function Get-NewUninstallEntries {
    param($Before, $After, [switch]$SkipBundled)
    $new = @()
    foreach ($k in ($After.Keys | Sort-Object)) {
        if (-not $Before.ContainsKey($k)) {
            $e = $After[$k]
            if ($SkipBundled -and $e.Name -match $script:BundledNamePattern) { continue }
            $new += $e
        }
    }
    return $new
}

function Resolve-DirFromDisplayIcon {
    param([string]$Icon, [string]$UninstallString, [string]$InstallLoc)

    # 1) InstallLocation 最可靠
    if ($InstallLoc) {
        $p = [Environment]::ExpandEnvironmentVariables($InstallLoc.Trim()).Trim('"')
        if ($p) {
            if (Test-Path -LiteralPath $p -PathType Container) { return $p }
            if (Test-Path -LiteralPath $p -PathType Leaf) { return ([System.IO.Path]::GetDirectoryName($p)) }
        }
    }

    # 2) DisplayIcon，可能是 "path,0"、@dll,-1、含环境变量、路径里带逗号
    if ($Icon) {
        $s = [Environment]::ExpandEnvironmentVariables($Icon.Trim())
        if ($s.StartsWith('@')) { $s = $s.Substring(1) }
        $p = $null
        $m = [regex]::Match($s, '^(?<p>.+?)(,-?\d+)?$')
        if ($m.Success) { $p = $m.Groups['p'].Value.Trim().Trim('"') }
        if (-not $p) { $p = $s.Trim().Trim('"') }
        if ($p) {
            if (Test-Path -LiteralPath $p -PathType Leaf) { return ([System.IO.Path]::GetDirectoryName($p)) }
            if (Test-Path -LiteralPath $p -PathType Container) { return $p }
        }
    }

    # 3) UninstallString，带引号和不带引号都要能认
    if ($UninstallString) {
        $s = [Environment]::ExpandEnvironmentVariables($UninstallString.Trim())
        $p = $null
        $m = [regex]::Match($s, '^"(?<p>[^"]+\.exe)"')
        if ($m.Success) { $p = $m.Groups['p'].Value }
        else {
            $m = [regex]::Match($s, '^(?<p>[^\s"]+\.exe)')
            if ($m.Success) { $p = $m.Groups['p'].Value }
        }
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return ([System.IO.Path]::GetDirectoryName($p)) }
    }
    return $null
}

# ---------------------------------------------------------------- 路径护栏

function Get-ProtectedPaths {
    $list = @()
    $candidates = @(
        $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
        $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA,
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Downloads')
    )
    foreach ($c in $candidates) {
        if ($c) {
            try { $list += ([System.IO.Path]::GetFullPath($c)).TrimEnd('\') } catch { }
        }
    }
    return $list
}

function Test-ProtectedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $full = $null
    try { $full = ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\') } catch { return $true }
    # 盘根
    if ($full -match '^[A-Za-z]:$') { return $true }
    # 整个 Windows 目录及其子目录
    if ($full -match '^[A-Za-z]:\\Windows(\\|$)') { return $true }
    foreach ($p in (Get-ProtectedPaths)) {
        if ($full -ieq $p) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------- 静默安装

function Get-MsiInstallDirProperty {
    param([string]$Path)
    $found = @()
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))

        $query = {
            param($sql)
            $rows = @()
            $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @($sql))
            $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            while ($true) {
                $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                if ($null -eq $rec) { break }
                $rows += $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1))
            }
            return $rows
        }

        $known = @('INSTALLDIR', 'INSTALLLOCATION', 'APPLICATIONFOLDER', 'INSTALLFOLDER',
                   'INSTALL_ROOT', 'APPDIR', 'TARGETDIR')
        $inList = ($known | ForEach-Object { "'" + $_ + "'" }) -join ','
        $found = @(& $query "SELECT Property FROM Property WHERE Property IN ($inList)")

        # TARGETDIR 会把整个产品根改到目标盘、PROGRAMFILESDIR 是系统目录属性，二者不能从命令行覆盖
        $found = @($found | Where-Object { $_ -in @('INSTALLDIR', 'INSTALLLOCATION', 'APPLICATIONFOLDER', 'INSTALLFOLDER', 'INSTALL_ROOT', 'APPDIR') })

        if ($found.Count -eq 0) {
            $all = @(& $query 'SELECT Property FROM Property')
            $found = @($all | Where-Object {
                $_ -match '(?i)(INSTALLDIR|INSTALLLOCATION|APPLICATIONFOLDER|INSTALLFOLDER|INSTALL_ROOT|APPDIR)$'
            } | Where-Object { $_ -in @('INSTALLDIR', 'INSTALLLOCATION', 'APPLICATIONFOLDER', 'INSTALLFOLDER', 'INSTALL_ROOT', 'APPDIR') })
        }
        $found = @($found | Select-Object -Unique)
        if ($found.Count -gt 1) { $found = @($found[0]) }   # 只取一个，避免多个属性互相打架
        return $found
    } catch {
        if ($null -ne $script:LogSink) { & $script:LogSink "读取 MSI 属性表失败：$($_.Exception.Message)" }
        return @()
    }
}

function Install-Silent {
    param(
        [string]$Path,
        [string]$Kind,
        [string]$InstallDir,
        [int]$TimeoutSeconds = 900,
        [string]$AppNameHint
    )
    $tmpLog = Join-Path $env:TEMP ("ih_" + [guid]::NewGuid().ToString('N') + ".log")
    $before = Get-UninstallSnapshot

    $dirExisted = Test-Path -LiteralPath $InstallDir -PathType Container
    $filesBefore = 0
    $bytesBefore = [long]0
    $mtimeBefore = $null
    if ($dirExisted) {
        $stBefore = Get-TreeStat -Path $InstallDir
        $filesBefore = $stBefore.Files
        $bytesBefore = $stBefore.Bytes
        try { $mtimeBefore = (Get-Item -LiteralPath $InstallDir -Force).LastWriteTimeUtc } catch { }
    }
    $result = {
        param($ok, $code, $actual, $msg, $honored)
        [pscustomobject]@{
            Success             = $ok
            ExitCode            = $code
            ActualDir           = $actual
            Message             = $msg
            LogFile             = $tmpLog
            RequestedDirHonored = [bool]$honored
            NewEntries          = @()
        }
    }

    $proc = $null
    $launchError = $null
    try {
        switch ($Kind) {
            'NSIS' {
                # /D 必须是最后一个参数，且不能加引号
                $argStr = "/S /D=$InstallDir"
                $proc = Start-Process -FilePath $Path -ArgumentList $argStr -PassThru -WindowStyle Hidden
            }
            'InnoSetup' {
                $argStr = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=`"$InstallDir`" /LOG=`"$tmpLog`""
                $proc = Start-Process -FilePath $Path -ArgumentList $argStr -PassThru -WindowStyle Hidden
            }
            'MSI' {
                $props = @(Get-MsiInstallDirProperty -Path $Path)
                $argStr = "/i `"$Path`" /qn /norestart /L*v `"$tmpLog`""
                if ($props.Count -gt 0) {
                    foreach ($p in $props) { $argStr += " $p=`"$InstallDir`"" }
                }
                $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $argStr -PassThru -WindowStyle Hidden
            }
            'InstallShield' {
                # /v 的值里有空格时必须嵌套转义，否则命令行会被切成两段
                $dir = $InstallDir.TrimEnd('\')
                $argStr = '/s /v"/qn INSTALLDIR=\"' + $dir + '\""'
                $proc = Start-Process -FilePath $Path -ArgumentList $argStr -PassThru -WindowStyle Hidden
            }
            'WiXBundle' {
                $argStr = "/install /quiet /norestart"
                $proc = Start-Process -FilePath $Path -ArgumentList $argStr -PassThru -WindowStyle Hidden
            }
            'Squirrel' {
                $argStr = "--silent"
                $proc = Start-Process -FilePath $Path -ArgumentList $argStr -PassThru -WindowStyle Hidden
            }
            default {
                return (& $result $false $null $null "这个包识别不出类型（$Kind），没法静默安装。可以手动装完再用『高级选项 → 把软件目录迁到 D 盘』。" $false)
            }
        }
    } catch {
        $launchError = $_.Exception.Message
    }

    if ($launchError -or $null -eq $proc) {
        $needAdmin = ($launchError -match '(?i)elevation|提升|拒绝访问|Access is denied|0x80070005')
        $msg = if ($needAdmin) {
            "需要管理员权限。请关掉本工具，右键启动器 → 以管理员身份运行，再试一次。"
        } else {
            "启动安装程序失败：$launchError"
        }
        return (& $result $false $null $null $msg $false)
    }

    # 轮询等待：让 GUI 有机会 DoEvents，避免"未响应"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $proc.HasExited) {
        if ((Get-Date) -gt $deadline) {
            try { $null = Invoke-Hidden 'taskkill.exe' "/PID $($proc.Id) /T /F" } catch { try { $proc.Kill() } catch { } }
            $after = Get-UninstallSnapshot
            $ne = @(Get-NewUninstallEntries -Before $before -After $after -SkipBundled)
            $r = & $result $false $null $null "安装超时（${TimeoutSeconds} 秒），已结束进程树。可能留下半个安装，建议检查目标目录或重装。" $false
            $r.NewEntries = $ne
            return $r
        }
        if ($null -ne $script:Tick) { & $script:Tick }
        Start-Sleep -Milliseconds 250
    }
    $proc.WaitForExit()
    $code = $proc.ExitCode

    # 有些安装器会起子进程后自己先退出，等子进程结束、卸载表稳定再判断
    $stable = 0
    $lastCount = -1
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $after = Get-UninstallSnapshot
    while ($sw.Elapsed.TotalSeconds -lt 90 -and $stable -lt 3) {
        $kids = 0
        try { $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id)" -ErrorAction SilentlyContinue).Count } catch { $kids = 0 }
        $after = Get-UninstallSnapshot
        $n = $after.Count
        if ($kids -eq 0 -and $n -eq $lastCount) { $stable++ } else { $stable = 0 }
        $lastCount = $n
        if ($null -ne $script:Tick) { & $script:Tick }
        Start-Sleep -Milliseconds 700
    }
    $after = Get-UninstallSnapshot
    $newEntries = @(Get-NewUninstallEntries -Before $before -After $after -SkipBundled)

    # 判定一：目标目录有真实变化（新建 / 文件数变 / 字节数变 / 目录写入时间变）才算装到了指定位置
    $actual = $null
    $honored = $false
    $unchanged = $false
    if (Test-Path -LiteralPath $InstallDir -PathType Container) {
        $stAfter = Get-TreeStat -Path $InstallDir
        $mtimeAfter = $null
        try { $mtimeAfter = (Get-Item -LiteralPath $InstallDir -Force).LastWriteTimeUtc } catch { }
        $changed = (-not $dirExisted) -or ($stAfter.Files -ne $filesBefore) -or ($stAfter.Bytes -ne $bytesBefore) -or ($mtimeAfter -ne $mtimeBefore)
        if ($changed) {
            $actual = $InstallDir
            $honored = $true
        }
    }

    # 判定二：看卸载表新增项推断真实安装位置
    if (-not $actual -and $newEntries.Count -gt 0) {
        $norm = ''
        if ($AppNameHint) { $norm = ($AppNameHint.ToLowerInvariant() -replace '[^a-z0-9]', '') }
        $sorted = @($newEntries | Sort-Object -Property @{ Expression = {
            if ($norm) { Get-NameMatchScore -Name $_.Name -Norm $norm } else { 0 }
        }; Descending = $true })
        foreach ($e in $sorted) {
            $dd = Resolve-DirFromDisplayIcon -Icon $e.DisplayIcon -UninstallString $e.UninstallString -InstallLoc $e.InstallLoc
            if ($dd -and (Test-Path -LiteralPath $dd -PathType Container) -and -not (Test-ProtectedPath $dd)) {
                $actual = $dd
                if ($dd.TrimEnd('\') -ieq $InstallDir.TrimEnd('\')) { $honored = $true }
                break
            }
        }
    }

    # 判定三：目录本来就有内容、安装器又正常退出 → 认为已经装在这里（重装或已是最版本）
    if (-not $actual -and $dirExisted -and $filesBefore -gt 0 -and (Test-Path -LiteralPath $InstallDir -PathType Container)) {
        $actual = $InstallDir
        $honored = $true
        $unchanged = $true
    }
    $okCodes = @(0, 3010, 1641)
    $ok = ($code -in $okCodes) -and ($null -ne $actual)
    $msg = "退出码 $code"
    if ($code -eq 3010) { $msg += "（需要重启才能完成）" }
    elseif ($code -eq 1641) { $msg += "（安装器已发起重启）" }
    if ($unchanged) { $msg += "；目标目录没有变化，可能已经装过或是同一版本" }
    if (-not $actual) { $msg += "；没找到安装目录" }
    elseif (-not $honored) { $msg += "；装到了 $actual，不是指定的目录" }

    $r = & $result $ok $code $actual $msg $honored
    $r.NewEntries = $newEntries
    return $r
}

# ---------------------------------------------------------------- 目录迁移

function Test-IsJunction {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch { return $false }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TreeStat {
    param([string]$Path)
    $files = 0
    $bytes = [long]0
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [pscustomobject]@{ Files = 0; Bytes = 0 } }
    try {
        $items = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue
        foreach ($f in $items) {
            $files++
            $bytes += [long]$f.Length
        }
    } catch { }
    return [pscustomobject]@{ Files = $files; Bytes = $bytes }
}

function Invoke-Robocopy {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 1800, [switch]$Move)
    $all = @($Arguments)
    if ($Move) { $all += '/MOVE' }
    $all += @('/E', '/COPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    $p = Start-HiddenProcess -FilePath 'robocopy.exe' -Arguments ($all -join ' ')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $p.HasExited) {
        if ((Get-Date) -gt $deadline) {
            try { $null = Invoke-Hidden 'taskkill.exe' "/PID $($p.Id) /T /F" } catch { try { $p.Kill() } catch { } }
            return 9999
        }
        if ($null -ne $script:Tick) { & $script:Tick }
        Start-Sleep -Milliseconds 300
    }
    return $p.ExitCode
}

function Move-DirWithJunction {
    param(
        [string]$Source,
        [string]$Destination,
        [int]$TimeoutSeconds = 1800
    )
    $fail = { param($m, $dataAt) [pscustomobject]@{ Ok = $false; Message = $m; Target = $null; DataAt = $dataAt } }

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        return (& $fail "源目录不存在：$Source" $null)
    }

    $srcFull = ([System.IO.Path]::GetFullPath($Source)).TrimEnd('\')
    $dstFull = ([System.IO.Path]::GetFullPath($Destination)).TrimEnd('\')

    if (Test-ProtectedPath $srcFull) {
        return (& $fail "拒绝迁移系统目录或用户目录：$srcFull" $null)
    }
    if (Test-IsJunction $srcFull) {
        return (& $fail "源目录已经是链接了，跳过：$srcFull" $null)
    }
    if ($srcFull -ieq $dstFull) {
        return (& $fail "源和目标相同：$srcFull" $null)
    }
    if ($dstFull.StartsWith($srcFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return (& $fail "目标在源目录内部，拒绝：$dstFull" $null)
    }
    if ($srcFull.StartsWith($dstFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return (& $fail "源在目标目录内部，拒绝：$srcFull" $null)
    }

    if (Test-Path -LiteralPath $dstFull -PathType Container) {
        $cnt = @(Get-ChildItem -LiteralPath $dstFull -Force -ErrorAction SilentlyContinue).Count
        if ($cnt -gt 0) { return (& $fail "目标目录已存在且非空：$dstFull" $null) }
    } else {
        try { New-Item -ItemType Directory -Path $dstFull -Force | Out-Null } catch {
            return (& $fail "无法创建目标目录：$($_.Exception.Message)" $null)
        }
    }

    # 第一步：只复制，不动源
    $rc = Invoke-Robocopy -Arguments @("`"$srcFull`"", "`"$dstFull`"") -TimeoutSeconds $TimeoutSeconds
    if ($rc -eq 9999) { return (& $fail "复制超时（${TimeoutSeconds} 秒），源目录未改动" $null) }
    if ($rc -ge 8) { return (& $fail "复制失败（robocopy 退出码 $rc），源目录未改动" $null) }

    # 第二步：校验文件数与字节数一致
    $srcStat = Get-TreeStat -Path $srcFull
    $dstStat = Get-TreeStat -Path $dstFull
    if (($srcStat.Files -ne $dstStat.Files) -or ($srcStat.Bytes -ne $dstStat.Bytes)) {
        return (& $fail ("复制结果不一致（源 {0} 个文件 / {1} 字节，目标 {2} 个文件 / {3} 字节），源目录未改动" -f `
            $srcStat.Files, $srcStat.Bytes, $dstStat.Files, $dstStat.Bytes) $null)
    }

    # 第三步：把源目录改名留作回滚点，再建链接
    $backup = $srcFull + '.ih_bak_' + (Get-Date -Format 'HHmmss')
    try {
        Move-Item -LiteralPath $srcFull -Destination $backup -ErrorAction Stop
    } catch {
        return (& $fail "无法重命名源目录（可能有程序正占用）：$($_.Exception.Message)。源目录未改动。" $null)
    }

    $rcLink = Invoke-Hidden 'cmd.exe' "/c mklink /J `"$srcFull`" `"$dstFull`""
    $ok = (Test-Path -LiteralPath $srcFull) -and (Test-IsJunction $srcFull)

    if (-not $ok) {
        # 回滚：删掉可能建了一半的链接，把原名改回去
        try {
            if (Test-Path -LiteralPath $srcFull) { $null = Invoke-Hidden 'cmd.exe' "/c rmdir `"$srcFull`"" }
            Move-Item -LiteralPath $backup -Destination $srcFull -Force -ErrorAction Stop
            return (& $fail ("建链接失败（mklink 退出码 {0}）。原目录已还原，数据副本留在 {1}，可以手动删。" -f ("$rcLink"), $dstFull) $null)
        } catch {
            return (& $fail ("建链接失败（mklink 退出码 {0}），且原目录还原也失败了。原目录内容现在在 {1}，请手动改回。" -f ("$rcLink"), $backup) $backup)
        }
    }

    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Ok = $true; Message = "已迁移并建立链接"; Target = $dstFull; DataAt = $dstFull }
}

function Remove-Junction {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-IsJunction $Path)) { throw "不是链接，拒绝删除：$Path" }
    $null = Invoke-Hidden 'cmd.exe' "/c rmdir `"$Path`""
    if (Test-Path -LiteralPath $Path) { throw "删除链接失败：$Path" }
}

function Restore-Junction {
    param([string]$Path, [int]$TimeoutSeconds = 1800)
    if (-not (Test-IsJunction $Path)) {
        return [pscustomobject]@{ Ok = $false; Message = "这个路径不是链接：$Path" }
    }
    $item = Get-Item -LiteralPath $Path -Force
    $target = @($item.Target)[0]
    if (-not $target -or -not (Test-Path -LiteralPath $target -PathType Container)) {
        return [pscustomobject]@{ Ok = $false; Message = "链接指向的目标不存在：$Path" }
    }
    $staging = $Path + '.ih_restore_' + (Get-Date -Format 'HHmmss')
    try {
        $null = Invoke-Hidden 'cmd.exe' "/c rmdir `"$Path`""
        if (Test-Path -LiteralPath $Path) { throw "无法删除链接（可能被占用）" }
        $rc = Invoke-Robocopy -Arguments @("`"$target`"", "`"$Path`"") -TimeoutSeconds $TimeoutSeconds -Move
        if ($rc -ge 8) { throw "复制回原路径失败（robocopy 退出码 $rc）" }
        return [pscustomobject]@{ Ok = $true; Message = "已还原为普通目录：$Path" }
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = "还原失败：$($_.Exception.Message)。数据仍在 $target。" }
    }
}

# ---------------------------------------------------------------- 应用数据探测

$script:KnownSystemDirs = @(
    'Microsoft', 'Temp', 'Packages', 'Programs', 'ConnectedDevicesPlatform', 'D3DSCache',
    'CrashDumps', 'ElevatedDiagnostics', 'Comms', 'PlaceholderTileLogoFolder', 'PeerDistRepub',
    'Publish', 'VirtualStore', 'Application Data', 'History', 'Temporary Internet Files',
    'Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos', 'OneDrive',
    'Google', 'Mozilla', 'Adobe', 'npm-cache', 'pip', 'NuGet', 'pnpm', 'Yarn', 'uv',
    'herdr-core', 'antigravity', 'Python', 'Linger', 'SquirrelTemp', 'Downloaded Installations',
    'go-build', 'go', 'Docker', 'JetBrains', 'NVIDIA', 'NVIDIA Corporation', 'Intel',
    'Caches', 'diagnostics', 'Fonts', 'IconCache', 'EBWebView', 'Packages', 'GroupPolicy',
    'IsolatedStorage', 'LocalLow', 'VirtualStore', 'Application Data', 'Microsoft Corporation'
)

function Get-AppDataRoots {
    # 只扫这两个，%USERPROFILE% 顶层有 Desktop/Documents 等，容易误伤
    return @(
        @{ Name = 'APPDATA(Roaming)'; Path = $env:APPDATA },
        @{ Name = 'LOCALAPPDATA';    Path = $env:LOCALAPPDATA }
    )
}

function Get-AppDataSnapshot {
    $snap = @{}
    foreach ($root in (Get-AppDataRoots)) {
        if (-not $root.Path -or -not (Test-Path -LiteralPath $root.Path)) { continue }
        $key = $root.Name
        $snap[$key] = @{}
        Get-ChildItem -LiteralPath $root.Path -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $snap[$key][$_.Name] = [pscustomobject]@{
                FullName  = $_.FullName
                LastWrite = $_.LastWriteTimeUtc
                Created   = $_.CreationTimeUtc
            }
        }
    }
    return $snap
}

function Get-NameMatchScore {
    param([string]$Name, [string]$Norm)
    if (-not $Name -or -not $Norm) { return 0 }
    $n = ($Name.ToLowerInvariant() -replace '[^a-z0-9]', '')
    if (-not $n) { return 0 }
    if ($n -eq $Norm) { return 100 }
    if ($n.StartsWith($Norm)) { return 90 }
    if ($n.Contains($Norm)) { return 80 }
    if ($Norm.StartsWith($n)) {
        $ratio = [double]$n.Length / [double]$Norm.Length
        if ($ratio -ge 0.3) { return 60 }
    }
    if ($Norm.Contains($n) -and $n.Length -ge 4) { return 50 }
    return 0
}

function Get-NewAppDataDirs {
    param($Before, $After, [string]$AppNameHint, [datetime]$SinceUtc)
    $norm = ''
    if ($AppNameHint) { $norm = ($AppNameHint.ToLowerInvariant() -replace '[^a-z0-9]', '') }
    $result = @()
    foreach ($key in $After.Keys) {
        if (-not $Before.ContainsKey($key)) { continue }
        foreach ($name in $After[$key].Keys) {
            if ($Before[$key].ContainsKey($name)) { continue }
            if ($script:KnownSystemDirs -contains $name) { continue }
            $item = $After[$key][$name]
            # 只有在安装开始之后才创建的目录才算候选
            if ($SinceUtc -and $item.Created -lt $SinceUtc) { continue }

            $score = 0
            if ($norm) {
                $score = Get-NameMatchScore -Name $name -Norm $norm
            } elseif ($AppNameHint) {
                # 中文等归一化后为空的名字：退化成原始名比较
                if ($name -ieq $AppNameHint) { $score = 100 }
                elseif ($name -like "*$AppNameHint*" -or $AppNameHint -like "*$name*") { $score = 70 }
            }

            $result += [pscustomobject]@{
                Root      = $key
                Name      = $name
                FullName  = $item.FullName
                SizeMB    = [math]::Round((Get-DirSizeSB -Path $item.FullName) / 1MB, 1)
                Created   = $item.Created.ToLocalTime()
                MatchHint = ($score -eq 100)   # 只有精确同名才自动勾选
                Score     = $score
            }
        }
    }
    return $result | Sort-Object Score -Descending
}

function Get-DirSizeSB {
    param([string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $it = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            if ($it -and (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -and $it.Target) {
                $t = @($it.Target)[0]
                if ($t -and (Test-Path -LiteralPath $t)) { $Path = $t }
            }
        }
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [double]$sum
    } catch { return 0 }
}

# ---------------------------------------------------------------- 主程序与快捷方式

# 卸载器/更新器/崩溃处理器/运行库安装器，绝不能被当成主程序
$script:ExeBlacklistPattern = '(?i)(^unins|^uninst|^unwise|^setup$|^setup\.|^install$|^update|^updater|^au\.|^squirrel|^crashpad|^crashreport|^crashhandler|^elevate|^notification|^mshta|^conhost|^cmd$|^helper$|vc_?redist|vcredist|dxsetup|^dotnet|unitycrash|^python-|^node\.exe$)'

function Find-MainExecutable {
    param([string]$InstallDir, [string]$AppNameHint)
    if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) { return $null }

    $all = @(Get-ChildItem -LiteralPath $InstallDir -Filter '*.exe' -File -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return $null }
    if ($all.Count -gt 400) { $all = @($all | Select-Object -First 400) }

    $filtered = @($all | Where-Object { $_.BaseName -notmatch $script:ExeBlacklistPattern })
    if ($filtered.Count -eq 0) { return $null }   # 宁可不建快捷方式，也不要把卸载器当主程序

    $hintNorm = ''
    if ($AppNameHint) { $hintNorm = ($AppNameHint.ToLowerInvariant() -replace '[^a-z0-9]', '') }
    $dirName = Split-Path -Leaf $InstallDir

    $scored = @()
    foreach ($e in $filtered) {
        $score = 0
        $bn = $e.BaseName.ToLowerInvariant()
        $bnNorm = $bn -replace '[^a-z0-9]', ''

        if ($hintNorm -and $bnNorm) {
            if ($bnNorm -eq $hintNorm) { $score += 100 }
            elseif ($bnNorm.Contains($hintNorm) -or $hintNorm.Contains($bnNorm)) { $score += 40 }
        }
        if ($dirName -and ($bn -ieq $dirName.ToLowerInvariant())) { $score += 30 }

        try {
            $vi = $e.VersionInfo
            if ($vi) {
                $fd = [string]$vi.FileDescription
                if ($AppNameHint -and $fd -and $fd.IndexOf($AppNameHint, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $score += 30 }
                if ([string]::IsNullOrWhiteSpace([string]$vi.FileVersion)) { $score -= 15 }
            }
        } catch { }

        $score += [Math]::Min(20, [int]($e.Length / 1MB))

        $rel = $e.FullName.Substring($InstallDir.TrimEnd('\').Length).TrimStart('\')
        $depth = ([regex]::Matches($rel, '\\')).Count
        $score -= ($depth * 8)

        $scored += [pscustomobject]@{ Exe = $e; Score = $score }
    }

    if ($scored.Count -eq 0) { return $null }
    return ($scored | Sort-Object Score -Descending | Select-Object -First 1).Exe
}

function New-AppShortcut {
    param(
        [string]$TargetExe,
        [string]$Name,
        [string]$WorkingDir,
        [switch]$Desktop,
        [switch]$StartMenu
    )
    $created = @()
    $targets = @()
    $safe = ($Name -replace '[\\/:*?"<>|]', '_').Trim()
    if (-not $safe) { $safe = 'App' }
    if ($StartMenu) { $targets += (Join-Path ([System.Environment]::GetFolderPath('Programs')) "$safe.lnk") }
    if ($Desktop) {
        $desk = [System.Environment]::GetFolderPath('Desktop')
        $targets += (Join-Path $desk "$safe.lnk")
    }

    $ws = $null
    try {
        $ws = New-Object -ComObject WScript.Shell
        foreach ($t in $targets) {
            $final = $t
            if (Test-Path -LiteralPath $final) {
                # 同名但指向别的程序时不要覆盖用户的快捷方式，改名另存
                $sameTarget = $false
                try {
                    $old = $ws.CreateShortcut($final)
                    $sameTarget = ($old.TargetPath -ieq $TargetExe)
                } catch { $sameTarget = $false }
                if (-not $sameTarget) {
                    $dir = [System.IO.Path]::GetDirectoryName($final)
                    $stem = [System.IO.Path]::GetFileNameWithoutExtension($final)
                    $i = 2
                    while (Test-Path -LiteralPath $final) {
                        $final = Join-Path $dir ("$stem ($i).lnk")
                        $i++
                    }
                }
            }
            $lnk = $ws.CreateShortcut($final)
            $lnk.TargetPath = $TargetExe
            if ($WorkingDir) { $lnk.WorkingDirectory = $WorkingDir }
            $lnk.IconLocation = '"' + $TargetExe + '",0'
            $lnk.Description = $safe
            $lnk.Save()
            $created += $final
        }
    } catch {
        if ($null -ne $script:LogSink) { & $script:LogSink "创建快捷方式失败：$($_.Exception.Message)" }
    } finally {
        if ($null -ne $ws) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) } catch { }
        }
    }
    return $created
}
