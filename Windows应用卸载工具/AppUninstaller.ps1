# ============================================================
#  Windows 10 应用卸载工具
# ------------------------------------------------------------
#  功能：
#    1. 扫描注册表 Uninstall 项与组策略 AppMgmt 项，列出已安装应用
#    2. 校验安装路径：找不到时标记“源文件不存在”，找到则显示完整路径
#    3. 卸载：路径存在 -> 强制结束该目录下所有程序 -> 清除注册项 -> 删除程序目录
#             路径不存在 -> 仅清除注册项
#  运行：双击“启动应用卸载工具.bat”，会自动请求管理员权限
# ============================================================

[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------- 管理员权限 ----------------
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $scriptPath + '"'
        $psi.UseShellExecute = $true
        $psi.Verb = 'runas'
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        exit
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            '本工具需要管理员权限才能清理注册表与程序目录。' + "`r`n" + '请右键选择“以管理员身份运行”。',
            '权限不足',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        exit 1
    }
}

# ============================================================
#  注册表与路径相关函数
# ============================================================

function Get-RegistryBaseKey {
    param(
        [Parameter(Mandatory = $true)][string]$Hive,
        [Parameter(Mandatory = $true)][bool]$Is64
    )
    if ($Hive -eq 'HKLM') {
        $hiveEnum = [Microsoft.Win32.RegistryHive]::LocalMachine
    } else {
        $hiveEnum = [Microsoft.Win32.RegistryHive]::CurrentUser
    }
    if ($Is64) {
        $view = [Microsoft.Win32.RegistryView]::Registry64
    } else {
        $view = [Microsoft.Win32.RegistryView]::Registry32
    }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveEnum, $view)
}

function Read-StringValue {
    param($Key, [string[]]$Names)
    foreach ($n in $Names) {
        try {
            $v = $Key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -ne $v) {
                $s = [string]$v
                if (-not [string]::IsNullOrWhiteSpace($s)) {
                    return [Environment]::ExpandEnvironmentVariables($s.Trim())
                }
            }
        } catch { }
    }
    return ''
}

function Read-DwordValue {
    param($Key, [string]$Name)
    try {
        $v = $Key.GetValue($Name, $null)
        if ($null -ne $v) { return [int]$v }
    } catch { }
    return 0
}

# 判断路径是否位于 Windows\Installer 缓存目录（MSI 图标缓存，不能当作安装目录）
function Test-PathInInstallerCache {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { return $false }
    $cacheRoot = [IO.Path]::Combine($env:SystemRoot, 'Installer').TrimEnd('\')
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    } catch {
        return $false
    }
    if ($full.Equals($cacheRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $full.StartsWith($cacheRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

# 根据 InstallLocation / DisplayIcon / UninstallString 推断安装目录
function Resolve-EntryPath {
    param([string]$InstallLocation, [string]$DisplayIcon, [string]$UninstallString)

    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($InstallLocation)) {
        $p = $InstallLocation.Trim().Trim('"').Trim()
        if ($p.Length -gt 0 -and $p -ne '.' -and $p -ne '\') {
            $candidates.Add($p)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DisplayIcon)) {
        $p = $DisplayIcon.Trim().Trim('"').Trim()
        # 去掉 “,0” 这类图标索引
        $idx = $p.LastIndexOf(',')
        if ($idx -gt 2) {
            $suffix = $p.Substring($idx + 1).Trim()
            if ($suffix -match '^-?\d+$') { $p = $p.Substring(0, $idx).Trim() }
        }
        $p = $p.Trim('"').Trim()
        if ($p.Length -gt 0) {
            $ext = ''
            try { $ext = [IO.Path]::GetExtension($p) } catch { $ext = '' }
            if ($ext.Length -gt 0) {
                try {
                    $parent = [IO.Path]::GetDirectoryName($p)
                    if ($parent -and -not (Test-PathInInstallerCache -Path $parent)) { $candidates.Add($parent) }
                } catch { }
            } elseif (-not (Test-PathInInstallerCache -Path $p)) {
                $candidates.Add($p)
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($UninstallString)) {
        $p = $UninstallString.Trim()
        if ($p.StartsWith('"')) {
            $end = $p.IndexOf('"', 1)
            if ($end -gt 1) { $p = $p.Substring(1, $end - 1) }
        } elseif ($p -match '^\s*([A-Za-z]:\\[^"]*?\.exe)') {
            $p = $matches[1]
        }
        if ($p -match '^[A-Za-z]:\\' -and $p -notmatch '^msiexec(\.exe)?$') {
            try {
                $parent = [IO.Path]::GetDirectoryName($p)
                if ($parent -and -not (Test-PathInInstallerCache -Path $parent)) { $candidates.Add($parent) }
            } catch { }
        }
    }

    $fallback = ''
    foreach ($c in $candidates) {
        $c = $c.TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($fallback)) { $fallback = $c }
        try {
            if (Test-Path -LiteralPath $c) { return $c }
        } catch { }
    }
    return $fallback
}

function New-EntryFromUninstallKey {
    param(
        [Microsoft.Win32.RegistryKey]$Key,
        [string]$Hive,
        [bool]$Is64,
        [string]$Source,
        [string]$KeyPath,
        [bool]$IncludeSystem
    )

    $name = Read-StringValue -Key $Key -Names @('DisplayName')
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }

    $systemComponent = Read-DwordValue -Key $Key -Name 'SystemComponent'
    $parentKeyName = Read-StringValue -Key $Key -Names @('ParentKeyName')
    $releaseType = Read-StringValue -Key $Key -Names @('ReleaseType')

    if (-not $IncludeSystem) {
        if ($systemComponent -eq 1) { return $null }
        if (-not [string]::IsNullOrWhiteSpace($parentKeyName)) { return $null }
        if ($releaseType -match 'Update|Hotfix|Service Pack|Security') { return $null }
    }

    $version = Read-StringValue -Key $Key -Names @('DisplayVersion', 'Version')
    $publisher = Read-StringValue -Key $Key -Names @('Publisher')
    $installLocation = Read-StringValue -Key $Key -Names @('InstallLocation')
    $displayIcon = Read-StringValue -Key $Key -Names @('DisplayIcon')
    $uninstallString = Read-StringValue -Key $Key -Names @('UninstallString', 'QuietUninstallString')

    $path = Resolve-EntryPath -InstallLocation $installLocation -DisplayIcon $displayIcon -UninstallString $uninstallString

    $status = '路径未知'
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        try {
            if (Test-Path -LiteralPath $path) { $status = '正常' } else { $status = '源文件不存在' }
        } catch {
            $status = '源文件不存在'
        }
    }

    return [pscustomobject]@{
        Name            = $name
        Version         = $version
        Publisher       = $publisher
        InstallPath     = $path
        Status          = $status
        Source          = $Source
        Hive            = $Hive
        Is64            = $Is64
        KeyPath         = $KeyPath
        UninstallString = $uninstallString
        DisplayIcon     = $displayIcon
    }
}

# 扫描注册表 Uninstall 项
function Get-ApplicationEntries {
    param([bool]$IncludeSystem)

    $list = New-Object System.Collections.ArrayList
    $is64OS = [Environment]::Is64BitOperatingSystem
    if ($is64OS) {
        $viewFlags = @($true, $false)
    } else {
        $viewFlags = @($false)
    }
    $rootPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'

    foreach ($is64 in $viewFlags) {
        foreach ($hive in @('HKLM', 'HKCU')) {
            if ($hive -eq 'HKLM') {
                if (-not $is64OS) {
                    $source = '注册表'
                } elseif ($is64) {
                    $source = '注册表·64位'
                } else {
                    $source = '注册表·32位'
                }
            } else {
                if ($is64) { $source = '注册表·用户' } else { $source = '注册表·用户32' }
            }

            $base = $null
            $uninstallKey = $null
            try {
                $base = Get-RegistryBaseKey -Hive $hive -Is64 $is64
                $uninstallKey = $base.OpenSubKey($rootPath)
                if ($null -eq $uninstallKey) { continue }

                foreach ($subName in $uninstallKey.GetSubKeyNames()) {
                    $appKey = $null
                    try {
                        $appKey = $uninstallKey.OpenSubKey($subName)
                        if ($null -eq $appKey) { continue }
                        $entry = New-EntryFromUninstallKey -Key $appKey -Hive $hive -Is64 $is64 -Source $source -KeyPath ($rootPath + '\' + $subName) -IncludeSystem $IncludeSystem
                        if ($null -ne $entry) { [void]$list.Add($entry) }
                    } catch {
                    } finally {
                        if ($null -ne $appKey) { $appKey.Close() }
                    }
                }
            } catch {
            } finally {
                if ($null -ne $uninstallKey) { $uninstallKey.Close() }
                if ($null -ne $base) { $base.Close() }
            }
        }
    }
    return $list
}

# 扫描组策略软件安装项（AppMgmt）
function Get-GroupPolicyEntries {
    $list = New-Object System.Collections.ArrayList
    $gpPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\AppMgmt'

    foreach ($hive in @('HKLM', 'HKCU')) {
        $base = $null
        $gpKey = $null
        try {
            $base = Get-RegistryBaseKey -Hive $hive -Is64 $true
            $gpKey = $base.OpenSubKey($gpPath)
            if ($null -eq $gpKey) { continue }

            foreach ($subName in $gpKey.GetSubKeyNames()) {
                $appKey = $null
                try {
                    $appKey = $gpKey.OpenSubKey($subName)
                    if ($null -eq $appKey) { continue }

                    $appName = Read-StringValue -Key $appKey -Names @('AppName', 'DisplayName', 'ApplicationName', 'Name')
                    $package = Read-StringValue -Key $appKey -Names @('PackageName', 'InstallLocation', 'Path', 'Source')
                    if ([string]::IsNullOrWhiteSpace($appName) -and -not [string]::IsNullOrWhiteSpace($package)) {
                        try { $appName = [IO.Path]::GetFileNameWithoutExtension($package) } catch { }
                    }
                    if ([string]::IsNullOrWhiteSpace($appName)) { continue }

                    $path = ''
                    if (-not [string]::IsNullOrWhiteSpace($package)) {
                        $p = $package.Trim().Trim('"').Trim()
                        if ($p -match '^[A-Za-z]:\\' -and $p -notmatch '^msiexec(\.exe)?$') {
                            $ext = ''
                            try { $ext = [IO.Path]::GetExtension($p) } catch { $ext = '' }
                            if ($ext.Length -gt 0) {
                                try {
                                    $parent = [IO.Path]::GetDirectoryName($p)
                                    if ($parent -and -not (Test-PathInInstallerCache -Path $parent)) { $path = $parent }
                                } catch { }
                            } elseif (-not (Test-PathInInstallerCache -Path $p)) {
                                $path = $p
                            }
                        }
                    }

                    $status = '路径未知'
                    if (-not [string]::IsNullOrWhiteSpace($path)) {
                        try {
                            if (Test-Path -LiteralPath $path) { $status = '正常' } else { $status = '源文件不存在' }
                        } catch {
                            $status = '源文件不存在'
                        }
                    }

                    $ver = Read-StringValue -Key $appKey -Names @('Version', 'DisplayVersion')
                    [void]$list.Add([pscustomobject]@{
                        Name            = $appName
                        Version         = $ver
                        Publisher       = ''
                        InstallPath     = $path
                        Status          = $status
                        Source          = '组策略'
                        Hive            = $hive
                        Is64            = $true
                        KeyPath         = $gpPath + '\' + $subName
                        UninstallString = ''
                        DisplayIcon     = ''
                    })
                } catch {
                } finally {
                    if ($null -ne $appKey) { $appKey.Close() }
                }
            }
        } catch {
        } finally {
            if ($null -ne $gpKey) { $gpKey.Close() }
            if ($null -ne $base) { $base.Close() }
        }
    }
    return $list
}

# ============================================================
#  卸载相关函数
# ============================================================

# 结束指定目录下的所有进程
function Stop-ProcessesUnderDirectory {
    param([string]$Directory)

    $killed = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Directory)) { return $killed }

    $full = ''
    try { $full = [IO.Path]::GetFullPath($Directory).TrimEnd('\') } catch { return $killed }
    if ([string]::IsNullOrWhiteSpace($full)) { return $killed }
    $prefix = $full + '\'

    $targets = @()
    $cimOk = $true
    try {
        $targets = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object {
            $exePath = $_.ExecutablePath
            $hit = $false
            if (-not [string]::IsNullOrWhiteSpace($exePath)) {
                if ($exePath.Equals($full, [StringComparison]::OrdinalIgnoreCase) -or
                    $exePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $hit = $true
                }
            }
            $hit
        })
    } catch {
        $cimOk = $false
    }

    # CIM 不可用时退回 Get-Process
    if (-not $cimOk) {
        $targets = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $exePath = $null
            try { $exePath = $_.Path } catch { $exePath = $null }
            $hit = $false
            if (-not [string]::IsNullOrWhiteSpace($exePath)) {
                if ($exePath.Equals($full, [StringComparison]::OrdinalIgnoreCase) -or
                    $exePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $hit = $true
                }
            }
            $hit
        })
    }

    foreach ($proc in $targets) {
        $procId = 0
        $procName = ''
        if ($null -ne $proc.PSObject.Properties['ProcessId']) {
            $procId = [int]$proc.ProcessId
            $procName = [string]$proc.Name
        } else {
            $procId = [int]$proc.Id
            $procName = [string]$proc.ProcessName
        }
        if ($procId -le 4 -or $procId -eq $PID) { continue }

        try {
            & taskkill.exe /F /T /PID $procId 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                [void]$killed.Add(($procName + ' (PID ' + $procId + ')'))
            } else {
                [void]$killed.Add(($procName + ' (PID ' + $procId + '，结束失败)'))
            }
        } catch {
            [void]$killed.Add(($procName + ' (PID ' + $procId + '，结束失败)'))
        }
    }

    if ($killed.Count -gt 0) { Start-Sleep -Milliseconds 900 }
    return $killed
}

# 安全性判断：拒绝删除盘符根目录、系统保护目录
function Test-SafeDirectoryPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    $full = ''
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    if ($full.Length -le 3) { return $false }
    if ($full -match '^[A-Za-z]:$') { return $false }

    $blocked = @()
    foreach ($b in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, 'C:\Users')) {
        if (-not [string]::IsNullOrWhiteSpace($b)) { $blocked += $b.TrimEnd('\') }
    }
    foreach ($b in $blocked) {
        if ($full.Equals($b, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }

    # 拦截常见的共享/系统目录名（防止注册表填了父级目录时误删）
    $leaf = ''
    try { $leaf = [IO.Path]::GetFileName($full) } catch { $leaf = '' }
    $blockedLeafs = @(
        'Program Files', 'Program Files (x86)', 'Common Files', 'WindowsApps',
        'Windows', 'System32', 'SysWOW64', 'Users', 'Public', 'ProgramData',
        'AppData', 'Roaming', 'Local', 'LocalLow', 'Temp'
    )
    if ($blockedLeafs -contains $leaf) { return $false }

    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $winPrefix = $env:SystemRoot.TrimEnd('\') + '\'
        if ($full.StartsWith($winPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Remove-AppRegistryKey {
    param(
        [string]$Hive,
        [bool]$Is64,
        [string]$KeyPath
    )

    $base = $null
    try {
        $base = Get-RegistryBaseKey -Hive $Hive -Is64 $Is64
        $existing = $base.OpenSubKey($KeyPath)
        if ($null -eq $existing) { return $true, '注册项不存在' }
        $existing.Close()
        $base.DeleteSubKeyTree($KeyPath, $false)
        return $true, '已删除'
    } catch {
        return $false, $_.Exception.Message
    } finally {
        if ($null -ne $base) { $base.Close() }
    }
}

function Remove-ProgramDirectory {
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory)) { return $false, '路径为空' }
    if (-not (Test-Path -LiteralPath $Directory)) { return $true, '目录已不存在' }

    try {
        Remove-Item -LiteralPath $Directory -Recurse -Force -ErrorAction Stop
    } catch {
        try { & cmd.exe /c ('rd /s /q "' + $Directory + '"') 2>&1 | Out-Null } catch { }
    }

    if (Test-Path -LiteralPath $Directory) {
        return $false, '删除失败（文件可能仍被占用或权限不足）'
    }
    return $true, '已移除'
}

# 执行单个应用的卸载流程
function Invoke-AppUninstall {
    param($Entry)

    $result = [pscustomobject]@{
        Name    = $Entry.Name
        Success = $true
        Steps   = (New-Object System.Collections.ArrayList)
        Errors  = (New-Object System.Collections.ArrayList)
    }

    $path = $Entry.InstallPath
    $pathExists = $false
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        try { $pathExists = Test-Path -LiteralPath $path } catch { $pathExists = $false }
    }

    if ($pathExists) {
        if (Test-SafeDirectoryPath -Path $path) {
            $killed = Stop-ProcessesUnderDirectory -Directory $path
            if ($killed.Count -gt 0) {
                [void]$result.Steps.Add('已强制结束 ' + $killed.Count + ' 个进程：' + ($killed -join '、'))
            } else {
                [void]$result.Steps.Add('该目录下未发现正在运行的程序')
            }
        } else {
            [void]$result.Errors.Add('安装路径位于系统保护目录，已跳过进程结束与目录删除：' + $path)
        }
    } else {
        [void]$result.Steps.Add('未找到安装目录，仅清除注册项')
    }

    $regOk, $regMsg = Remove-AppRegistryKey -Hive $Entry.Hive -Is64 $Entry.Is64 -KeyPath $Entry.KeyPath
    if ($regOk) {
        [void]$result.Steps.Add('注册项已清除：' + $Entry.Hive + '\' + $Entry.KeyPath)
    } else {
        [void]$result.Errors.Add('注册项清除失败：' + $regMsg)
        $result.Success = $false
    }

    if ($pathExists -and (Test-SafeDirectoryPath -Path $path)) {
        $dirOk, $dirMsg = Remove-ProgramDirectory -Directory $path
        if ($dirOk) {
            [void]$result.Steps.Add('程序目录已移除：' + $path)
        } else {
            [void]$result.Errors.Add('程序目录移除失败：' + $path + '（' + $dirMsg + '）')
            $result.Success = $false
        }
    }

    return $result
}

# ============================================================
#  界面
# ============================================================

$script:AppEntries = @()

$colorAccent  = [System.Drawing.Color]::FromArgb(37, 99, 235)
$colorDanger  = [System.Drawing.Color]::FromArgb(190, 32, 32)
$colorText    = [System.Drawing.Color]::FromArgb(31, 41, 55)
$colorBorder  = [System.Drawing.Color]::FromArgb(214, 220, 228)
$colorMuted   = [System.Drawing.Color]::FromArgb(107, 114, 128)

$fontBase     = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fontBold     = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$fontTitle    = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)

function New-ToolButton {
    param(
        [string]$Text,
        [int]$Width,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor,
        [System.Drawing.Color]$HoverColor,
        [bool]$Bordered = $true
    )
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Width = $Width
    $btn.Height = 34
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 1
    if ($Bordered) {
        $btn.FlatAppearance.BorderColor = $colorBorder
    } else {
        $btn.FlatAppearance.BorderColor = $BackColor
    }
    $btn.FlatAppearance.MouseOverBackColor = $HoverColor
    $btn.BackColor = $BackColor
    $btn.ForeColor = $ForeColor
    $btn.Font = $fontBase
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    return $btn
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Windows 10 应用卸载工具'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = New-Object System.Drawing.Size(1260, 760)
$form.MinimumSize = New-Object System.Drawing.Size(980, 620)
$form.Font = $fontBase
$form.BackColor = [System.Drawing.Color]::FromArgb(244, 246, 249)

# ---- 顶部工具栏 ----
$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = [System.Windows.Forms.DockStyle]::Top
$panelTop.Height = 58
$panelTop.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 6)
$panelTop.BackColor = [System.Drawing.Color]::White

$flowTop = New-Object System.Windows.Forms.FlowLayoutPanel
$flowTop.Dock = [System.Windows.Forms.DockStyle]::Fill
$flowTop.WrapContents = $false
$flowTop.AutoScroll = $true
$flowTop.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$panelTop.Controls.Add($flowTop)

$btnScan = New-ToolButton -Text '扫描应用' -Width 96 -BackColor $colorAccent -ForeColor ([System.Drawing.Color]::White) -HoverColor ([System.Drawing.Color]::FromArgb(29, 78, 216)) -Bordered $false
$btnUninstall = New-ToolButton -Text '卸载选中' -Width 96 -BackColor $colorDanger -ForeColor ([System.Drawing.Color]::White) -HoverColor ([System.Drawing.Color]::FromArgb(153, 27, 27)) -Bordered $false
$btnOpen = New-ToolButton -Text '打开目录' -Width 96 -BackColor ([System.Drawing.Color]::White) -ForeColor $colorText -HoverColor ([System.Drawing.Color]::FromArgb(243, 244, 246))
$btnCopy = New-ToolButton -Text '复制路径' -Width 96 -BackColor ([System.Drawing.Color]::White) -ForeColor $colorText -HoverColor ([System.Drawing.Color]::FromArgb(243, 244, 246))

$chkSystem = New-Object System.Windows.Forms.CheckBox
$chkSystem.Text = '显示系统组件/补丁'
$chkSystem.AutoSize = $true
$chkSystem.Font = $fontBase
$chkSystem.ForeColor = $colorText
$chkSystem.Margin = New-Object System.Windows.Forms.Padding(10, 9, 8, 0)

$lblFilter = New-Object System.Windows.Forms.Label
$lblFilter.Text = '筛选：'
$lblFilter.AutoSize = $true
$lblFilter.Font = $fontBase
$lblFilter.ForeColor = $colorMuted
$lblFilter.Margin = New-Object System.Windows.Forms.Padding(4, 10, 0, 0)

$txtFilter = New-Object System.Windows.Forms.TextBox
$txtFilter.Width = 230
$txtFilter.Font = $fontBase
$txtFilter.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$txtFilter.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

[void]$flowTop.Controls.Add($btnScan)
[void]$flowTop.Controls.Add($btnUninstall)
[void]$flowTop.Controls.Add($btnOpen)
[void]$flowTop.Controls.Add($btnCopy)
[void]$flowTop.Controls.Add($chkSystem)
[void]$flowTop.Controls.Add($lblFilter)
[void]$flowTop.Controls.Add($txtFilter)

# ---- 应用列表 ----
$dgv = New-Object System.Windows.Forms.DataGridView
$dgv.Dock = [System.Windows.Forms.DockStyle]::Fill
$dgv.ReadOnly = $true
$dgv.AllowUserToAddRows = $false
$dgv.AllowUserToDeleteRows = $false
$dgv.AllowUserToResizeRows = $false
$dgv.AllowUserToOrderColumns = $false
$dgv.MultiSelect = $true
$dgv.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgv.RowHeadersVisible = $false
$dgv.BackgroundColor = [System.Drawing.Color]::White
$dgv.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$dgv.GridColor = [System.Drawing.Color]::FromArgb(235, 238, 242)
$dgv.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
$dgv.EnableHeadersVisualStyles = $false
$dgv.ColumnHeadersHeight = 34
$dgv.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing
$dgv.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(247, 249, 252)
$dgv.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$dgv.ColumnHeadersDefaultCellStyle.Font = $fontBold
$dgv.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(247, 249, 252)
$dgv.ColumnHeadersDefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$dgv.DefaultCellStyle.ForeColor = $colorText
$dgv.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(232, 240, 254)
$dgv.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::FromArgb(20, 30, 45)
$dgv.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
$dgv.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(250, 251, 253)
$dgv.RowTemplate.Height = 27
$dgv.Margin = New-Object System.Windows.Forms.Padding(12, 0, 12, 0)

function Add-GridColumn {
    param(
        $Grid,
        [string]$Name,
        [string]$Header,
        [int]$Width,
        [int]$Weight
    )
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $Name
    $col.HeaderText = $Header
    $col.ReadOnly = $true
    $col.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    if ($Weight -gt 0) {
        $col.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
        $col.FillWeight = $Weight
    } else {
        $col.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::None
        $col.Width = $Width
    }
    [void]$Grid.Columns.Add($col)
}

Add-GridColumn -Grid $dgv -Name 'Name' -Header '名称' -Width 0 -Weight 34
Add-GridColumn -Grid $dgv -Name 'Version' -Header '版本' -Width 88 -Weight 0
Add-GridColumn -Grid $dgv -Name 'Publisher' -Header '发布者' -Width 0 -Weight 18
Add-GridColumn -Grid $dgv -Name 'InstallPath' -Header '安装路径' -Width 0 -Weight 38
Add-GridColumn -Grid $dgv -Name 'Status' -Header '状态' -Width 112 -Weight 0
Add-GridColumn -Grid $dgv -Name 'Source' -Header '来源' -Width 130 -Weight 0

# ---- 详情面板 ----
$panelDetails = New-Object System.Windows.Forms.Panel
$panelDetails.Dock = [System.Windows.Forms.DockStyle]::Bottom
$panelDetails.Height = 152
$panelDetails.Padding = New-Object System.Windows.Forms.Padding(12, 6, 12, 8)
$panelDetails.BackColor = [System.Drawing.Color]::White

$lblDetails = New-Object System.Windows.Forms.Label
$lblDetails.Text = '详细信息'
$lblDetails.Dock = [System.Windows.Forms.DockStyle]::Top
$lblDetails.Height = 24
$lblDetails.Font = $fontBold
$lblDetails.ForeColor = $colorText

$txtDetails = New-Object System.Windows.Forms.TextBox
$txtDetails.Multiline = $true
$txtDetails.ReadOnly = $true
$txtDetails.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtDetails.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtDetails.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$txtDetails.BackColor = [System.Drawing.Color]::White
$txtDetails.ForeColor = $colorText
$txtDetails.Font = $fontBase
$txtDetails.Text = ''

$panelDetails.Controls.Add($txtDetails)
$panelDetails.Controls.Add($lblDetails)

# ---- 状态栏 ----
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusStrip.BackColor = [System.Drawing.Color]::White
$statusStrip.SizingGrip = $false
$statusStrip.Font = $fontBase

$lblCount = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblCount.Text = '共 0 项'
$lblCount.ForeColor = $colorText

$sep1 = New-Object System.Windows.Forms.ToolStripStatusLabel
$sep1.Text = '|'
$sep1.ForeColor = $colorBorder

$lblOk = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblOk.Text = '正常 0'
$lblOk.ForeColor = [System.Drawing.Color]::FromArgb(22, 128, 57)

$lblMissing = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblMissing.Text = '源文件不存在 0'
$lblMissing.ForeColor = [System.Drawing.Color]::FromArgb(190, 32, 32)

$lblUnknown = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblUnknown.Text = '路径未知 0'
$lblUnknown.ForeColor = [System.Drawing.Color]::FromArgb(150, 110, 20)

$lblMessage = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblMessage.Spring = $true
$lblMessage.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblMessage.ForeColor = $colorMuted
$lblMessage.Text = '就绪'

[void]$statusStrip.Items.Add($lblCount)
[void]$statusStrip.Items.Add($sep1)
[void]$statusStrip.Items.Add($lblOk)
[void]$statusStrip.Items.Add($lblMissing)
[void]$statusStrip.Items.Add($lblUnknown)
[void]$statusStrip.Items.Add($lblMessage)

$form.Controls.Add($dgv)
$form.Controls.Add($panelTop)
$form.Controls.Add($panelDetails)
$form.Controls.Add($statusStrip)

# ============================================================
#  界面逻辑
# ============================================================

function Set-DetailsText {
    param($Entry)
    if ($null -eq $Entry) {
        $txtDetails.Text = ''
        return
    }
    $lines = @()
    $lines += '名称：' + $Entry.Name
    if ([string]::IsNullOrWhiteSpace($Entry.Version)) {
        $lines += '版本：—'
    } else {
        $lines += '版本：' + $Entry.Version
    }
    if ([string]::IsNullOrWhiteSpace($Entry.Publisher)) {
        $lines += '发布者：—'
    } else {
        $lines += '发布者：' + $Entry.Publisher
    }
    if ([string]::IsNullOrWhiteSpace($Entry.InstallPath)) {
        $lines += '安装路径：未识别（注册表未记录安装位置）'
    } else {
        $lines += '安装路径：' + $Entry.InstallPath
    }
    $lines += '状态：' + $Entry.Status
    $lines += '来源：' + $Entry.Source
    $viewText = '32 位视图'
    if ($Entry.Is64) { $viewText = '64 位视图' }
    $lines += '注册表项：' + $Entry.Hive + '\' + $Entry.KeyPath + '  [' + $viewText + ']'
    if (-not [string]::IsNullOrWhiteSpace($Entry.UninstallString)) {
        $lines += '卸载命令：' + $Entry.UninstallString
    }
    $txtDetails.Text = ($lines -join "`r`n")
}

function Update-StatusCounts {
    $visibleRows = @($dgv.Rows | Where-Object { $_.Visible })
    $okCount = 0
    $missingCount = 0
    $unknownCount = 0
    foreach ($row in $visibleRows) {
        $entry = $row.Tag
        if ($null -eq $entry) { continue }
        switch ($entry.Status) {
            '正常' { $okCount++ }
            '源文件不存在' { $missingCount++ }
            default { $unknownCount++ }
        }
    }
    $lblCount.Text = '共 ' + $visibleRows.Count + ' 项'
    $lblOk.Text = '正常 ' + $okCount
    $lblMissing.Text = '源文件不存在 ' + $missingCount
    $lblUnknown.Text = '路径未知 ' + $unknownCount
}

function Fill-Grid {
    param($Entries)

    $dgv.SuspendLayout()
    try {
        $dgv.Rows.Clear()
        foreach ($e in $Entries) {
            $index = $dgv.Rows.Add()
            $row = $dgv.Rows[$index]
            $row.Cells[0].Value = $e.Name
            $row.Cells[1].Value = $e.Version
            $row.Cells[2].Value = $e.Publisher
            if ([string]::IsNullOrWhiteSpace($e.InstallPath)) {
                $row.Cells[3].Value = '—'
            } else {
                $row.Cells[3].Value = $e.InstallPath
            }
            $row.Cells[4].Value = $e.Status
            $row.Cells[5].Value = $e.Source
            $row.Tag = $e

            switch ($e.Status) {
                '正常' {
                    $row.Cells[4].Style.ForeColor = [System.Drawing.Color]::FromArgb(22, 128, 57)
                }
                '源文件不存在' {
                    $row.Cells[4].Style.ForeColor = [System.Drawing.Color]::FromArgb(190, 32, 32)
                    $row.Cells[4].Style.Font = $fontBold
                    $row.Cells[3].Style.ForeColor = [System.Drawing.Color]::FromArgb(190, 32, 32)
                }
                default {
                    $row.Cells[4].Style.ForeColor = [System.Drawing.Color]::FromArgb(150, 110, 20)
                }
            }
        }
    } finally {
        $dgv.ResumeLayout()
    }
}

function Apply-RowFilter {
    $query = $txtFilter.Text.Trim()
    $dgv.SuspendLayout()
    try {
        foreach ($row in $dgv.Rows) {
            $show = $true
            if ($query.Length -gt 0) {
                $text = ''
                foreach ($cell in $row.Cells) {
                    if ($null -ne $cell.Value) { $text += ' ' + [string]$cell.Value }
                }
                $show = $text.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0
            }
            $row.Visible = $show
        }
    } finally {
        $dgv.ResumeLayout()
    }
    Update-StatusCounts
}

function Start-Scan {
    $btnScan.Enabled = $false
    $btnUninstall.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $lblMessage.Text = '正在扫描注册表与组策略...'
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $includeSystem = $chkSystem.Checked
        $standard = @(Get-ApplicationEntries -IncludeSystem $includeSystem)
        $gpEntries = @(Get-GroupPolicyEntries)

        $map = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($e in $standard) {
            $key = ($e.Name + '|' + $e.Version).ToLowerInvariant()
            if (-not $map.Contains($key)) {
                $map.Add($key, $e)
            }
        }
        foreach ($g in $gpEntries) {
            $key = ($g.Name + '|' + $g.Version).ToLowerInvariant()
            if ($map.Contains($key)) {
                $existing = $map[$key]
                if ($existing.Source -notlike '*组策略*') {
                    $existing.Source = $existing.Source + ' + 组策略'
                }
            } else {
                $map.Add($key, $g)
            }
        }

        $merged = @($map.Values | Sort-Object -Property Name)
        $script:AppEntries = $merged

        Fill-Grid -Entries $merged
        Apply-RowFilter

        $lblMessage.Text = '扫描完成：' + $merged.Count + ' 项（' + [DateTime]::Now.ToString('HH:mm:ss') + '）'
    } catch {
        $lblMessage.Text = '扫描失败：' + $_.Exception.Message
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnScan.Enabled = $true
        $btnUninstall.Enabled = $true
    }
}

function Open-EntryFolder {
    param($Entry)
    if ($null -eq $Entry) { return }
    $path = $Entry.InstallPath
    $pathExists = $false
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        try { $pathExists = Test-Path -LiteralPath $path } catch { $pathExists = $false }
    }
    if (-not $pathExists) {
        [System.Windows.Forms.MessageBox]::Show(
            '未找到该应用的安装目录。' + "`r`n" + '路径：' + $(if ([string]::IsNullOrWhiteSpace($path)) { '未识别' } else { $path }),
            '提示',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $path + '"')
        } else {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $path + '"')
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show('无法打开目录：' + $_.Exception.Message, '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
}

function Show-UninstallConfirm {
    param($Entries)
    $lines = @()
    if ($Entries.Count -eq 1) {
        $e = $Entries[0]
        $exists = $false
        if (-not [string]::IsNullOrWhiteSpace($e.InstallPath)) {
            try { $exists = Test-Path -LiteralPath $e.InstallPath } catch { $exists = $false }
        }
        $lines += '确定要卸载以下应用吗？'
        $lines += ''
        $lines += '名称：' + $e.Name
        if (-not [string]::IsNullOrWhiteSpace($e.Version)) { $lines += '版本：' + $e.Version }
        if ([string]::IsNullOrWhiteSpace($e.InstallPath)) {
            $lines += '安装路径：未识别'
        } else {
            $lines += '安装路径：' + $e.InstallPath
        }
        $lines += ''
        if ($exists) {
            $lines += '处理方式：'
            $lines += '1. 强制结束该目录下所有正在运行的程序'
            $lines += '2. 清除注册表中的卸载项'
            $lines += '3. 删除程序目录'
        } else {
            $lines += '未找到安装目录，将仅清除注册表中的卸载项。'
        }
        if ($e.Source -like '*组策略*') {
            $lines += ''
            $lines += '注意：该应用由组策略部署，清除注册项后可能在组策略刷新时重新写入。'
        }
    } else {
        $lines += '确定要卸载选中的 ' + $Entries.Count + ' 个应用吗？'
        $lines += ''
        foreach ($e in $Entries) { $lines += '· ' + $e.Name }
        $lines += ''
        $lines += '存在的程序目录会被结束进程后删除；不存在的仅清除注册项。'
        $gpCount = @($Entries | Where-Object { $_.Source -like '*组策略*' }).Count
        if ($gpCount -gt 0) {
            $lines += ''
            $lines += '注意：其中 ' + $gpCount + ' 个由组策略部署，清除后可能在组策略刷新时重新写入。'
        }
    }
    $result = [System.Windows.Forms.MessageBox]::Show(
        ($lines -join "`r`n"),
        '确认卸载',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Show-UninstallResult {
    param($Results)
    $successCount = @($Results | Where-Object { $_.Success }).Count
    $failCount = $Results.Count - $successCount

    $lines = @()
    $lines += '卸载完成：成功 ' + $successCount + ' 个，失败 ' + $failCount + ' 个'
    $lines += ''
    foreach ($r in $Results) {
        if ($r.Success) {
            $lines += '[成功] ' + $r.Name
        } else {
            $lines += '[失败] ' + $r.Name
        }
        foreach ($s in $r.Steps) { $lines += '    · ' + $s }
        foreach ($err in $r.Errors) { $lines += '    × ' + $err }
        $lines += ''
    }

    if ($failCount -gt 0) {
        $icon = [System.Windows.Forms.MessageBoxIcon]::Warning
    } else {
        $icon = [System.Windows.Forms.MessageBoxIcon]::Information
    }
    [System.Windows.Forms.MessageBox]::Show(
        ($lines -join "`r`n"),
        '卸载结果',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icon) | Out-Null
}

# ---------------- 事件绑定 ----------------
$btnScan.Add_Click({
    Start-Scan
})

$chkSystem.Add_CheckedChanged({
    Start-Scan
})

$txtFilter.Add_TextChanged({
    Apply-RowFilter
})

$btnUninstall.Add_Click({
    $selectedEntries = @()
    foreach ($row in $dgv.SelectedRows) {
        if ($null -ne $row.Tag) { $selectedEntries += $row.Tag }
    }
    if ($selectedEntries.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            '请先在列表中选择要卸载的应用。',
            '提示',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    if (-not (Show-UninstallConfirm -Entries $selectedEntries)) { return }

    $btnUninstall.Enabled = $false
    $btnScan.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $results = @()
    try {
        foreach ($entry in $selectedEntries) {
            $lblMessage.Text = '正在卸载：' + $entry.Name
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $results += Invoke-AppUninstall -Entry $entry
            } catch {
                $failed = [pscustomobject]@{
                    Name    = $entry.Name
                    Success = $false
                    Steps   = (New-Object System.Collections.ArrayList)
                    Errors  = @('未预期的错误：' + $_.Exception.Message)
                }
                $results += $failed
            }
        }
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnUninstall.Enabled = $true
        $btnScan.Enabled = $true
    }

    Show-UninstallResult -Results $results
    Start-Scan
})

$btnOpen.Add_Click({
    $row = $null
    if ($dgv.SelectedRows.Count -gt 0) { $row = $dgv.SelectedRows[0] }
    if ($null -eq $row -or $null -eq $row.Tag) {
        [System.Windows.Forms.MessageBox]::Show('请先选择一个应用。', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    Open-EntryFolder -Entry $row.Tag
})

$btnCopy.Add_Click({
    $row = $null
    if ($dgv.SelectedRows.Count -gt 0) { $row = $dgv.SelectedRows[0] }
    if ($null -eq $row -or $null -eq $row.Tag) {
        [System.Windows.Forms.MessageBox]::Show('请先选择一个应用。', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $entry = $row.Tag
    $text = $entry.InstallPath
    if ([string]::IsNullOrWhiteSpace($text)) { $text = '' }
    if ($text.Length -eq 0) {
        $lblMessage.Text = '该应用没有可复制的安装路径'
        return
    }
    try {
        [System.Windows.Forms.Clipboard]::SetText($text)
        $lblMessage.Text = '已复制路径：' + $text
    } catch {
        [System.Windows.Forms.MessageBox]::Show('复制失败：' + $_.Exception.Message, '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})

$dgv.Add_SelectionChanged({
    if ($dgv.SelectedRows.Count -eq 1) {
        Set-DetailsText -Entry $dgv.SelectedRows[0].Tag
    } else {
        $txtDetails.Text = ''
    }
})

$dgv.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0) { return }
    $entry = $sender.Rows[$e.RowIndex].Tag
    if ($null -ne $entry) { Open-EntryFolder -Entry $entry }
})

$form.Add_Shown({
    Start-Scan
})

[void]$form.ShowDialog()
$form.Dispose()
