# ============================================================
#  小艾艾的工具箱 — 后台服务（由 bat 启动，勿手动关闭）
#  清理垃圾 + C盘软件搬家 · 纯系统组件
# ============================================================
param([string]$Port = "19000", [string]$RootDir = "")

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = "SilentlyContinue"

if (-not $RootDir) { $RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

$script:Moves = [hashtable]::Synchronized(@{})   # key -> @{Step; Done; Err; Log}
$script:BigScan = $null

# ---------------- 云端更新 ----------------
$script:VERSION = "1.1.2"
$script:GH_BASE = "Swenhai/xiaai-toolbox"
# 多源：jsDelivr（国内可达）优先，GitHub raw 备用
$script:UPDATE_SOURCES = @(
    "https://cdn.jsdelivr.net/gh/$($script:GH_BASE)@main/version.json",
    "https://raw.githubusercontent.com/$($script:GH_BASE)/main/version.json"
)

function Get-UpdateManifest {
    foreach ($u in $script:UPDATE_SOURCES) {
        try {
            $m = Invoke-RestMethod -Uri $u -TimeoutSec 20
            if ($m -and $m.version) { return $m }
        } catch {}
    }
    return $null
}

function Get-UpdateZipUrls([string]$rawUrl) {
    $urls = @()
    if ($rawUrl -match '^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$') {
        $urls += "https://cdn.jsdelivr.net/gh/$($Matches[1])@$($Matches[3])/$($Matches[4])"
    }
    $urls += $rawUrl
    return $urls
}

function Invoke-UpdateCheck {
    try {
        $m = Get-UpdateManifest
        if (-not $m) { return [ordered]@{ ok = $false; err = "检查更新失败，网络不通或所有更新源都不可达" } }
        $has = ([version]$m.version) -gt ([version]$script:VERSION)
        return [ordered]@{ ok = $true; current = $script:VERSION; version = $m.version; hasUpdate = $has; notes = $m.notes }
    } catch {
        return [ordered]@{ ok = $false; err = "检查更新失败: " + $_.Exception.Message }
    }
}

function Invoke-UpdateApply {
    try {
        $m = Get-UpdateManifest
        if (-not $m) { return "无法获取云端更新信息，请稍后再试" }
        if (-not $m.zip) { return "云端配置缺少下载地址" }
        $zip = Join-Path $RootDir "update_pkg.zip"
        $downloaded = $false
        foreach ($u in (Get-UpdateZipUrls $m.zip)) {
            for ($try = 1; $try -le 2; $try++) {
                try {
                    Invoke-WebRequest -Uri $u -OutFile $zip -TimeoutSec 180 -UseBasicParsing
                    if ((Get-Item $zip).Length -gt 1000) { $downloaded = $true; break }
                } catch { Start-Sleep -Seconds 3 }
            }
            if ($downloaded) { break }
        }
        if (-not $downloaded) { return "更新包下载失败，请检查网络后重试" }
        $dst = Join-Path $RootDir "_update_tmp"
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $dst -Force
        if (-not (Test-Path (Join-Path $dst "server.ps1"))) { return "更新包内容不对" }
        # 起一个隐藏更新器：等服务退出后替换文件并重启
        $updater = Join-Path $RootDir "_do_update.ps1"
        @"
# 等旧服务退出（最多60秒），再替换文件并重启
$probe = New-Object System.Net.Sockets.TcpClient
for ($wi = 0; $wi -lt 60; $wi++) {
  Start-Sleep -Seconds 1
  try { $probe.Connect('127.0.0.1', $Port); $probe.Close(); $probe = New-Object System.Net.Sockets.TcpClient }
  catch { break }
}
try {
  Copy-Item -Path (Join-Path '$dst' '*') -Destination '$RootDir' -Recurse -Force
  Remove-Item '$dst' -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item '$zip' -Force -ErrorAction SilentlyContinue
} catch {}
$ps = if ($env:OS -eq 'Windows_NT') { 'powershell' } else { 'pwsh' }
Start-Process $ps -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','"$RootDir\server.ps1"','-Port','$Port' -WindowStyle Hidden
"@ | Out-File -FilePath $updater -Encoding UTF8
        $psExe = if ($env:OS -eq 'Windows_NT') { 'powershell' } else { 'pwsh' }
Start-Process $psExe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$updater`"" -WindowStyle Hidden
        return $null
    } catch {
        return "更新失败: " + $_.Exception.Message
    }
}
$script:Pool = $null

# ---------------- 基础工具 ----------------
function Get-DirSize([string]$p) {
    if (-not ($p -and (Test-Path -LiteralPath $p))) { return [int64]0 }
    $sum = [int64]0
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($p, "*", [System.IO.SearchOption]::AllDirectories)) {
            try { $sum += ([System.IO.FileInfo]$f).Length } catch {}
        }
    } catch {}
    return $sum
}

function Get-Categories {
    $la = $env:LOCALAPPDATA
    if (-not $la) { $la = "$env:USERPROFILE\AppData\Local" }
    $chromeUd = Join-Path $la "Google\Chrome\User Data"
    $edgeUd   = Join-Path $la "Microsoft\Edge\User Data"
    $browserPaths = @()
    foreach ($ud in @($chromeUd, $edgeUd)) {
        foreach ($prof in @("Default", "Profile 1", "Profile 2")) {
            $bp = Join-Path $ud "$prof\Cache"
            $bp2 = Join-Path $ud "$prof\Code Cache"
            if (Test-Path -LiteralPath $bp)  { $browserPaths += $bp }
            if (Test-Path -LiteralPath $bp2) { $browserPaths += $bp2 }
        }
    }
    $paths = @{
        temp    = @($env:TEMP, "C:\Windows\Temp") | Where-Object { $_ }
        update  = @("C:\Windows\SoftwareDistribution\Download")
        browser = $browserPaths
        thumb   = @((Join-Path $la "Microsoft\Windows\Explorer"))
        dump    = @((Join-Path $la "CrashDumps"))
    }
    return ,@(
        @{ id="temp";    emoji="🗂️"; name="临时文件";        desc="软件运行留下的临时垃圾，放心清"; paths=$paths.temp },
        @{ id="browser"; emoji="🌐"; name="浏览器缓存";      desc="网页缓存，清理后网页重新加载而已"; paths=$paths.browser },
        @{ id="update";  emoji="🔄"; name="系统更新残留";    desc="Windows 更新留下的旧安装包";      paths=$paths.update },
        @{ id="thumb";   emoji="🖼️"; name="图片缩略图缓存";  desc="文件夹预览小图的缓存，会自动重建"; paths=$paths.thumb },
        @{ id="dump";    emoji="💥"; name="错误报告";        desc="程序崩溃时留下的报告文件";        paths=$paths.dump },
        @{ id="recycle"; emoji="🗑️"; name="回收站";          desc="回收站里的东西将被彻底删除";      recycle=$true }
    )
}

# ---------------- 扫描 ----------------
function Invoke-Scan {
    $result = @()
    foreach ($c in (Get-Categories)) {
        $size = [int64]0
        if ($c.recycle) {
            try {
                $shell = New-Object -ComObject Shell.Application
                $rb = $shell.Namespace(0xA)
                if ($rb) { foreach ($it in $rb.Items()) { $size += $rb.GetDetailsOf($it, 2) -replace '[^\d]', '' } }
            } catch {
                try {
                    $sz = Get-ChildItem 'C:\$Recycle.Bin' -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum
                    $size = [int64]($sz.Sum)
                } catch { $size = 0 }
            }
        } else {
            foreach ($p in $c.paths) { $size += Get-DirSize $p }
        }
        $result += [ordered]@{
            id = $c.id; emoji = $c.emoji; name = $c.name; desc = $c.desc
            size = $size; cleaned = $false
        }
    }
    return $result
}

# ---------------- 清理 ----------------
function Invoke-Clean([string[]]$ids) {
    $freed = [int64]0
    foreach ($c in (Get-Categories)) {
        if ($ids -notcontains $c.id) { continue }
        if ($c.recycle) {
            $before = 0
            try {
                $sz = Get-ChildItem 'C:\$Recycle.Bin' -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum
                $before = [int64]($sz.Sum)
            } catch {}
            try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch {}
            Start-Sleep -Milliseconds 800
            $after = 0
            try {
                $sz2 = Get-ChildItem 'C:\$Recycle.Bin' -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum
                $after = [int64]($sz2.Sum)
            } catch {}
            if ($before -gt $after) { $freed += ($before - $after) }
            continue
        }
        foreach ($p in $c.paths) {
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $before = Get-DirSize $p
            Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch {}
            }
            $after = Get-DirSize $p
            if ($before -gt $after) { $freed += ($before - $after) }
        }
    }
    return $freed
}

# ---------------- 已装软件（C盘） ----------------
function Get-InstalledApps {
    $keys = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $list = @()
    $seen = @{}
    foreach ($k in $keys) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue | ForEach-Object {
            $name = $_.DisplayName
            $loc  = $_.InstallLocation
            if (-not $name -or -not $loc) { return }
            if ($loc -notmatch '^([A-Za-z]):\\') { return }
            if ($loc -match '^C:') { } else { return }
            if (-not (Test-Path -LiteralPath $loc)) { return }
            # 排除系统目录
            if ($loc -match '^(C:\\Windows|C:\\Program Files\\Windows)', 'IgnoreCase') { return }
            $szKB = 0
            if ($_.EstimatedSize) { $szKB = [int64]$_.EstimatedSize }
            $sz = $szKB * 1KB
            $id = $loc.TrimEnd('\').ToLower()
            if ($seen.ContainsKey($id)) {
                # 已记录：取更大的尺寸
                if ($sz -gt $seen[$id].Size) { $seen[$id].Size = $sz }
                return
            }
            $seen[$id] = [pscustomobject]@{
                Key  = $id
                Name = $name
                Loc  = $loc.TrimEnd('\')
                Size = $sz
                RegPaths = @($_.PSPath)
            }
        }
    }
    $list = @($seen.Values | Where-Object { $_.Size -ge 200MB } | Sort-Object Size -Descending)
    return $list
}

# ---------------- 搬家 ----------------
function Start-Move([string]$key, [string]$target) {
    if ($script:Moves.ContainsKey($key)) {
        $prev = $script:Moves[$key]
        if (-not $prev.Done -and -not $prev.Err) { return }  # 正在搬
    }
    $script:Moves[$key] = @{ Step = "准备搬家..."; Done = $false; Err = ""; Log = "" }

    $ps = [powershell]::Create()
    $null = $ps.AddScript({
        param($Key, $Target, $Moves)

        function Get-DirSize([string]$p) {
            if (-not ($p -and (Test-Path -LiteralPath $p))) { return [int64]0 }
            $sum = [int64]0
            try { foreach ($f in [System.IO.Directory]::EnumerateFiles($p, "*", [System.IO.SearchOption]::AllDirectories)) { try { $sum += ([System.IO.FileInfo]$f).Length } catch {} } } catch {}
            return $sum
        }

        function Find-RegKeyPaths([string]$installLoc) {
            $found = @()
            $roots = @(
                "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
            )
            $needle = $installLoc.TrimEnd('\').ToLower()
            foreach ($r in $roots) {
                Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        $p = Get-ItemProperty $_.PSPath -ErrorAction Stop
                        if ($p.InstallLocation -and $p.InstallLocation.TrimEnd('\').ToLower() -eq $needle) { $found += $_.PSPath }
                    } catch {}
                }
            }
            return $found
        }

        try {
            # 1) 重新定位软件信息
            $Moves[$Key].Step = "正在定位软件信息..."
            $apps = @()
            $roots = @(
                "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )
            $seenLoc = @{}
            foreach ($k in $roots) {
                Get-ItemProperty $k -ErrorAction SilentlyContinue | ForEach-Object {
                    $loc = $_.InstallLocation
                    if ($loc -and ($loc.TrimEnd('\').ToLower() -eq $Key) -and -not $seenLoc.ContainsKey($loc)) {
                        $seenLoc[$loc] = $true
                        $apps += @{ Name = $_.DisplayName; Loc = $loc.TrimEnd('\'); RegPaths = @($_.PSPath) }
                    }
                }
            }
            if (-not $apps.Count) { $Moves[$Key].Err = "找不到该软件的注册信息"; $Moves[$Key].Done = $true; return }
            $src = $apps[0].Loc
            if (-not (Test-Path -LiteralPath $src)) { $Moves[$Key].Err = "软件目录不存在"; $Moves[$Key].Done = $true; return }

            $leaf = Split-Path $src -Leaf
            $dst = Join-Path ($Target + ":\") ("小艾艾搬家的软件\" + $leaf)

            # 2) robocopy 搬移
            $Moves[$Key].Step = "正在搬运文件（大软件可能需要几分钟）..."
            $Moves[$Key].Log = "从 $src`n搬到 $dst`n"
            New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
            $rc = Start-Process -FilePath "robocopy" -ArgumentList @("`"$src`"", "`"$dst`"", "/E", "/MOVE", "/R:1", "/W:1", "/NFL", "/NDL", "/NP") -Wait -PassThru -NoNewWindow
            $code = $rc.ExitCode
            $Moves[$Key].Log += "robocopy 退出码: $code`n"
            if ($code -ge 8) {
                $Moves[$Key].Err = "有文件被占用搬不动，请把该软件完全关闭（含后台托盘图标）后重试"
                $Moves[$Key].Done = $true
                return
            }

            # 3) 建传送门（junction）
            $Moves[$Key].Step = "建立传送门..."
            if (Test-Path -LiteralPath $src) {
                $remain = Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue
                if ($remain) {
                    $Moves[$Key].Err = "有文件被占用无法搬走，为安全起见未建传送门，请关闭软件后重试"
                    $Moves[$Key].Done = $true
                    return
                }
                Remove-Item -LiteralPath $src -Force -Recurse -ErrorAction SilentlyContinue
            }
            $cmd = New-Object System.Diagnostics.Process
            $cmd.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $cmd.StartInfo.FileName = "cmd.exe"
            $cmd.StartInfo.Arguments = "/c mklink /J `"$src`" `"$dst`""
            $cmd.StartInfo.UseShellExecute = $false
            $cmd.StartInfo.CreateNoWindow = $true
            $cmd.StartInfo.RedirectStandardOutput = $true
            $cmd.Start() | Out-Null
            $out = $cmd.StandardOutput.ReadToEnd()
            $cmd.WaitForExit()
            if ($cmd.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $src)) {
                $Moves[$Key].Err = "传送门创建失败：$out（文件已搬到 $dst，请手动检查）"
                $Moves[$Key].Done = $true
                return
            }
            $Moves[$Key].Log += "传送门已建立: $src -> $dst`n"

            # 4) 更新注册表 InstallLocation
            $Moves[$Key].Step = "更新软件登记信息..."
            $newLoc = $dst
            $regFixed = 0
            foreach ($a in $apps) {
                foreach ($rp in (Find-RegKeyPaths $a.Loc)) {
                    try {
                        Set-ItemProperty -Path $rp -Name InstallLocation -Value $newLoc -ErrorAction Stop
                        $regFixed++
                    } catch {}
                }
            }
            $Moves[$Key].Log += "已更新 $regFixed 条注册信息`n"
            $Moves[$Key].Step = "搬家完成！"
            $Moves[$Key].Done = $true
        } catch {
            $Moves[$Key].Err = "搬家出错: " + $_.Exception.Message
            $Moves[$Key].Done = $true
        }
    }).AddArgument($key).AddArgument($target).AddArgument($script:Moves) | Out-Null
    $ps.BeginInvoke() | Out-Null
}

# ---------------- C盘健康 ----------------
function Get-CDrive {
    try {
        $d = Get-PSDrive C -ErrorAction Stop
        return [ordered]@{ free = [int64]$d.Free; used = [int64]$d.Used; total = ([int64]$d.Used + [int64]$d.Free) }
    } catch { return [ordered]@{ free = 0; used = 0; total = 0 } }
}

# ---------------- 开机自启项 ----------------
function Get-Startups {
    $scopes = @(
        @{ Root = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"; Ap = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; Lvl = 0 },
        @{ Root = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"; Ap = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; Lvl = 1 },
        @{ Root = "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Ap = "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; Lvl = 1 }
    )
    $list = @()
    foreach ($s in $scopes) {
        $ap = @{}
        if (Test-Path $s.Ap) {
            try {
                $key = Get-Item $s.Ap -ErrorAction Stop
                foreach ($n in $key.GetValueNames()) { $ap[$n] = $key.GetValue($n) }
            } catch {}
        }
        $rk = Get-Item $s.Root -ErrorAction SilentlyContinue
        if (-not $rk) { continue }
        foreach ($n in $rk.GetValueNames()) {
            $enabled = $true
            if ($ap.ContainsKey($n)) {
                $b = $ap[$n] -as [byte[]]
                if ($b -and $b.Length -gt 0) { $enabled = ($b[0] -band 1) -eq 0 }  # 02=开 03=关
            }
            $list += [ordered]@{ name = $n; cmd = [string]$rk.GetValue($n); enabled = $enabled; machine = ($s.Lvl -eq 1) }
        }
    }
    return @($list | Sort-Object -Property @{Expression="enabled";Descending=$true}, @{Expression="name"})
}

function Set-StartupState([string]$name, [bool]$enable) {
    $apPaths = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    )
    $val = if ($enable) { [byte[]](2,0,0,0,0,0,0,0,0,0,0,0) } else { [byte[]](3,0,0,0,0,0,0,0,0,0,0,0) }
    $done = $false
    foreach ($p in $apPaths) {
        if (Test-Path $p) {
            $key = Get-Item $p
            if ($key.GetValueNames() -contains $name -or -not $done) {
                try { Set-ItemProperty -Path $p -Name $name -Value $val -Type Binary -ErrorAction Stop; $done = $true } catch {}
            }
        }
    }
    # 若无 StartupApproved 记录（默认启用），禁用时新建键值
    if (-not $done -and -not $enable) {
        foreach ($p in @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run")) {
            if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
            try { Set-ItemProperty -Path $p -Name $name -Value $val -Type Binary -ErrorAction Stop; $done = $true } catch {}
        }
    }
    return $done
}

# ---------------- 大文件扫描 ----------------
function Start-BigScan {
    $prev = $script:BigScan
    if ($prev -and -not $prev.Done -and -not $prev.Err) { return }
    $script:BigScan = [hashtable]::Synchronized(@{ Step = "正在翻找C盘里的大文件..."; Done = $false; Err = ""; Files = @() })
    $ps = [powershell]::Create()
    $null = $ps.AddScript({
        param($State)
        try {
            $found = New-Object System.Collections.ArrayList
            $roots = @("C:\Users", "C:\ProgramData", "C:\Program Files", "C:\Program Files (x86)")
            $skip = @("windowsapps", "wvs", "packages", "$recycle.bin")
            foreach ($root in $roots) {
                if (-not (Test-Path -LiteralPath $root)) { continue }
                $stack = New-Object System.Collections.Stack
                $stack.Push($root)
                while ($stack.Count -gt 0) {
                    $dir = $stack.Pop()
                    try {
                        foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) {
                            $leaf = (Split-Path $d -Leaf).ToLower()
                            if ($skip -contains $leaf) { continue }
                            $attr = [System.IO.File]::GetAttributes($d)
                            if (-not ($attr -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($d) }
                        }
                    } catch {}
                    try {
                        foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                            try {
                                $fi = New-Object System.IO.FileInfo($f)
                                if ($fi.Length -ge 300MB) { $null = $found.Add(@{ Path = $f; Size = $fi.Length }) }
                            } catch {}
                        }
                    } catch {}
                }
            }
            $State.Files = @($found | Sort-Object { $_.Size } -Descending | Select-Object -First 25)
            $State.Step = "扫描完成"
            $State.Done = $true
        } catch {
            $State.Err = "扫描出错: " + $_.Exception.Message
            $State.Done = $true
        }
    }).AddArgument($script:BigScan) | Out-Null
    $ps.BeginInvoke() | Out-Null
}

function Remove-BigFile([string]$path) {
    if (-not $path -or $path -notmatch '^[A-Za-z]:\\') { return "路径不合法" }
    if ($path -match '(?i)^C:\\Windows|^C:\\Program Files\\WindowsApps') { return "系统文件不能删哦" }
    if (-not (Test-Path -LiteralPath $path)) { return "文件已经不在了" }
    try {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        return $null
    } catch { return "删不掉，文件可能正被使用中" }
}

# ============================================================
#  视频解析下载模块（抖音/快手/B站 分享链接）
# ============================================================
$script:API = "https://api.douyin.wtf"
$script:VUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
$script:Jobs = [hashtable]::Synchronized(@{})
$script:VPool = [runspacefactory]::CreateRunspacePool(1, 4)
$script:VPool.Open()
$script:VRunning = @{}

function Get-VSaveDir {
    $prof = $env:USERPROFILE
    if (-not $prof) { $prof = $HOME }
    if (-not $prof) { $prof = [Environment]::GetFolderPath("UserProfile") }
    $dl = Join-Path $prof "Downloads"
    if (-not (Test-Path $dl)) { $dl = $prof }
    $d = Join-Path $dl "小艾艾下载的视频"
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function Start-VJobTask([string]$jobId) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:VPool
    $null = $ps.AddScript({
        param($Jobs, $UA, $API, $jobId)
        $script:Jobs = $Jobs; $script:UA = $UA; $script:API = $API
        $script:Session = $null; $script:SaveDir = $null

        function Get-SaveDir {
            if ($script:SaveDir) { return $script:SaveDir }
            $prof = $env:USERPROFILE
            if (-not $prof) { $prof = $HOME }
            if (-not $prof) { $prof = [Environment]::GetFolderPath("UserProfile") }
            if (-not $prof) { $prof = [Environment]::GetFolderPath("MyDocuments") }
            if (-not $prof) { $prof = "." }
            $dl = Join-Path $prof "Downloads"
            if (-not (Test-Path $dl)) { $dl = Join-Path $prof "Desktop" }
            if (-not (Test-Path $dl)) { $dl = $prof }
            $d = Join-Path $dl "小艾艾下载的视频"
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            $script:SaveDir = $d
            return $d
        }
        function Api-Call([string]$method, [string]$path, $body) {
            $p = @{ Uri = "$script:API$path"; Method = $method; UserAgent = $script:UA; WebSession = $script:Session; TimeoutSec = 90; UseBasicParsing = $true }
            if ($body) { $p.Body = ($body | ConvertTo-Json -Compress); $p.ContentType = "application/json" }
            $r = Invoke-WebRequest @p
            return ($r.Content | ConvertFrom-Json)
        }
        function Connect-Api {
            try {
                $script:Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
                $r = Api-Call "POST" "/api/v1/auth/login" @{ username = "demo"; password = "kelp-kelp-delta-3690" }
                return [bool]$r.success
            } catch { return $false }
        }
        $reURL     = [regex]'https?://[^\s，,。；;'']+'
        $reVideoID = [regex]'(?:video/|aweme_id=|group_id=|modal_id=)(\d{15,})'
        $reLongNum = [regex]'\b(\d{18,20})\b'
        $reBad     = [regex]'[\\/:*?"<>|#@\r\n]'

        function Resolve-ShortLink([string]$u) {
            if ($u -match 'v\.douyin\.com|b23\.tv|v\.kuaishou\.com') {
                try {
                    $req = [System.Net.HttpWebRequest]::Create($u)
                    $req.UserAgent = $script:UA
                    $req.AllowAutoRedirect = $false
                    $req.Timeout = 15000
                    $resp = $req.GetResponse()
                    $loc = $resp.Headers["Location"]
                    $resp.Close()
                    if ($loc) { return $loc }
                } catch {
                    try { if ($_.Exception.Response -and $_.Exception.Response.Headers["Location"]) { return $_.Exception.Response.Headers["Location"] } } catch {}
                }
            }
            return $u
        }
        function Get-VideoId([string]$rawUrl) {
            $u = Resolve-ShortLink $rawUrl
            $m = $reVideoID.Match($u); if ($m.Success) { return $m.Groups[1].Value }
            $m = $reLongNum.Match($u); if ($m.Success) { return $m.Groups[1].Value }
            return ""
        }
        function Clean-Name([string]$s) {
            $n = $reBad.Replace($s, "")
            $n = ($n -split '\s+' | Where-Object { $_ }) -join " "
            $n = $n.Trim()
            if ($n.Length -gt 60) { $n = $n.Substring(0, 60) }
            if (-not $n) { $n = "视频_" + (Get-Date -Format "yyyyMMdd_HHmmss") }
            return $n
        }
        function Download-One($job, [string]$u, [string]$out) {
            $tmp = "$out.part"
            try {
                $req = [System.Net.HttpWebRequest]::Create($u)
                $req.UserAgent = $script:UA
                $req.Referer = "https://www.douyin.com/"
                $req.Timeout = 30000
                $req.ReadWriteTimeout = 120000
                $resp = $req.GetResponse()
                $total = $resp.ContentLength
                if ($total -gt 0) { $job.Total = $total }
                $inS = $resp.GetResponseStream()
                $fs = [System.IO.File]::Create($tmp)
                $buf = New-Object byte[] 262144
                $recv = [int64]0
                $lastSave = Get-Date
                while (($read = $inS.Read($buf, 0, $buf.Length)) -gt 0) {
                    $fs.Write($buf, 0, $read)
                    $recv += $read
                    if (((Get-Date) - $lastSave).TotalMilliseconds -gt 400) { $job.Received = $recv; $lastSave = Get-Date }
                }
                $fs.Close(); $inS.Close(); $resp.Close()
                $job.Received = $recv
                if ($recv -lt 100000) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; return $false }
                if (Test-Path $out) { Remove-Item $out -Force -ErrorAction SilentlyContinue }
                Move-Item $tmp $out -Force
                $job.Total = $recv
                return $true
            } catch {
                if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
                return $false
            }
        }
        function Save-VideoFile($job, [string[]]$urls, [string]$vid) {
            $dir = Get-SaveDir
            $base = Clean-Name $job.Title
            $out = Join-Path $dir "$base.mp4"
            $n = 1
            while (Test-Path $out) { $out = Join-Path $dir "$base($n).mp4"; $n++ }
            $job.File = Split-Path $out -Leaf
            foreach ($u in $urls) { if (Download-One $job $u $out) { return $true } }
            if (Download-One $job ("https://www.douyin.com/aweme/v1/play/?video_id=" + $vid) $out) { return $true }
            return $false
        }

        # ---------- 主流程 ----------
        $job = $script:Jobs[$jobId]
        if (-not $job) { return }
        try {
            $m = $reURL.Match($job.Text)
            if (-not $m.Success) { $job.Status = "error"; $job.Err = "没找到链接，请粘贴完整的分享口令"; return }
            $vid = Get-VideoId $m.Value
            if (-not $vid) { $job.Status = "error"; $job.Err = "未能识别视频ID"; return }
            $null = Connect-Api
            $maxAttempts = 8
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                if ($attempt -gt 1) { $job.Step = "服务繁忙，稍后自动重试（第${attempt}次）" }
                $taskId = ""
                try {
                    $r = Api-Call "GET" ("/api/v1/douyin/video?url=" + [uri]::EscapeDataString("https://www.douyin.com/video/$vid")) $null
                    if ($r.success -and $r.data.task_id) { $taskId = $r.data.task_id }
                } catch {}
                if (-not $taskId) {
                    if ($attempt -eq $maxAttempts) { $job.Status = "error"; $job.Err = "解析服务连接失败，请检查网络"; return }
                    $job.Step = "连接解析服务，30 秒后重试"
                    Start-Sleep -Seconds 30
                    $null = Connect-Api
                    continue
                }
                $job.Step = "解析视频"
                $needRetry = $false; $waitSec = 30
                for ($i = 0; $i -lt 60; $i++) {
                    Start-Sleep -Seconds 2
                    if (-not $script:Jobs.ContainsKey($jobId)) { return }
                    $t = $null
                    try { $t = Api-Call "GET" "/api/v1/tasks/$taskId" $null } catch { continue }
                    if (-not $t -or -not $t.data) { continue }
                    $st = $t.data.state
                    if ($st -eq "done") {
                        $dd = $t.data.data
                        $job.Title = $dd.title
                        if ($dd.author) { $job.Author = $dd.author.nickname }
                        $urls = @()
                        if ($dd.media.video.urls) { $urls = @($dd.media.video.urls) }
                        $job.Step = "下载视频"; $job.Status = "downloading"
                        if (Save-VideoFile $job $urls $vid) { $job.Status = "done"; $job.Step = "完成" }
                        else { $job.Status = "error"; $job.Err = "下载失败，链接可能已过期，请重新解析" }
                        return
                    }
                    if ($st -eq "failed" -or $st -eq "error") {
                        $errObj = $t.data.error
                        if ($errObj -and $errObj.retryable -and $errObj.retry_after -gt 0 -and $errObj.retry_after -lt 600 -and $attempt -lt $maxAttempts) {
                            $waitSec = [int]$errObj.retry_after + 5
                            $job.Step = "服务繁忙，$waitSec 秒后自动重试（第$($attempt+1)次）"
                            $needRetry = $true
                        } elseif ($attempt -lt $maxAttempts) {
                            $job.Step = "解析异常，30 秒后自动重试"
                            $needRetry = $true
                        }
                        break
                    }
                }
                if ($needRetry) { Start-Sleep -Seconds $waitSec; continue }
                break
            }
            if ($job.Status -ne "done") {
                $job.Status = "error"
                $job.Err = "解析失败，视频可能已被删除、私密或服务暂不可用"
            }
        } catch {
            $job.Status = "error"
            $job.Err = "内部错误: " + $_.Exception.Message
        }
    }).AddArgument($script:Jobs).AddArgument($script:VUA).AddArgument($script:API).AddArgument($jobId) | Out-Null
    $handle = $ps.BeginInvoke()
    $script:VRunning[$jobId] = @{ PS = $ps; Handle = $handle }
}

# ---------------- HTTP 服务 ----------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() } catch { exit 0 }

function Send-Json($ctx, $obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 8 -Compress
    if (-not $json) { $json = "[]" }
    if ($json -notmatch '^\[|^\<|\{') { $json = '{}' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ctx.Response.ContentType = "application/json; charset=utf-8"
    $ctx.Response.Headers.Add("Cache-Control", "no-store")
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}

while ($listener.IsListening) {
    try { $ctx = $listener.GetContext() } catch { break }
    $req = $ctx.Request
    $res = $ctx.Response
    $path = $req.Url.AbsolutePath

    try {
        if ($path -eq "/" -or $path -eq "/index.html") {
            $html = Get-Content -Path (Join-Path $RootDir "ui.html") -Raw -Encoding UTF8
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
            $res.ContentType = "text/html; charset=utf-8"
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            $res.Close()
        }
        elseif ($path -eq "/api/scan" -and $req.HttpMethod -eq "POST") {
            $cats = Invoke-Scan
            Send-Json $ctx $cats
        }
        elseif ($path -eq "/api/clean" -and $req.HttpMethod -eq "POST") {
            $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd(); $sr.Close()
            $in = $body | ConvertFrom-Json
            $ids = @($in.ids) | ForEach-Object { [string]$_ }
            $freed = Invoke-Clean $ids
            Send-Json $ctx ([ordered]@{ ok = $true; freed = $freed })
        }
        elseif ($path -eq "/api/apps" -and $req.HttpMethod -eq "POST") {
            $apps = Get-InstalledApps
            $arr = @()
            foreach ($a in $apps) {
                $arr += [ordered]@{ key = $a.Key; name = $a.Name; loc = $a.Loc; size = $a.Size }
            }
            Send-Json $ctx $arr
        }
        elseif ($path -eq "/api/drives" -and $req.HttpMethod -eq "GET") {
            $arr = @()
            Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 10GB -and $_.Name -match '^[A-Z]$' -and $_.Name -ne 'C' } | ForEach-Object {
                $arr += [ordered]@{ letter = $_.Name; free = $_.Free }
            }
            Send-Json $ctx $arr
        }
        elseif ($path -eq "/api/move" -and $req.HttpMethod -eq "POST") {
            $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd(); $sr.Close()
            $in = $body | ConvertFrom-Json
            if (-not $in.key -or -not $in.target) {
                Send-Json $ctx ([ordered]@{ ok = $false; err = "参数不完整" })
            } else {
                Start-Move $in.key $in.target
                Send-Json $ctx ([ordered]@{ ok = $true })
            }
        }
        elseif ($path -eq "/api/move/status" -and $req.HttpMethod -eq "GET") {
            $active = $false; $step = ""; $done = $false
            foreach ($k in $script:Moves.Keys) {
                $m = $script:Moves[$k]
                if (-not $m.Done -and -not $m.Err) { $active = $true; $step = $m.Step }
                if ($m.Done) { $done = $true }
            }
            $lastLog = ""
            foreach ($k in $script:Moves.Keys) { if ($script:Moves[$k].Log) { $lastLog = $script:Moves[$k].Log } }
            Send-Json $ctx ([ordered]@{ active = $active; step = $step; done = $done; log = $lastLog })
        }
        elseif ($path -eq "/api/cdrive" -and $req.HttpMethod -eq "GET") {
            Send-Json $ctx (Get-CDrive)
        }
        elseif ($path -eq "/api/startups" -and $req.HttpMethod -eq "POST") {
            $st = Get-Startups
            if (-not $st) { $st = @() }
            Send-Json $ctx $st
        }
        elseif ($path -eq "/api/startup/toggle" -and $req.HttpMethod -eq "POST") {
            $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd(); $sr.Close()
            $in = $body | ConvertFrom-Json
            if (-not $in.name) { Send-Json $ctx ([ordered]@{ ok = $false; err = "参数不完整" }) }
            else {
                $okd = Set-StartupState $in.name ([bool]$in.enable)
                Send-Json $ctx ([ordered]@{ ok = $okd; err = $(if ($okd) { $null } else { "设置失败，可能需要管理员权限" }) })
            }
        }
        elseif ($path -eq "/api/bigfiles" -and $req.HttpMethod -eq "POST") {
            Start-BigScan
            Send-Json $ctx ([ordered]@{ ok = $true })
        }
        elseif ($path -eq "/api/bigfiles/status" -and $req.HttpMethod -eq "GET") {
            $b = $script:BigScan
            if (-not $b) { Send-Json $ctx ([ordered]@{ active = $false; done = $false; files = @() }) }
            else {
                $arr = @()
                foreach ($f in $b.Files) { $arr += [ordered]@{ path = $f.Path; size = $f.Size } }
                Send-Json $ctx ([ordered]@{ active = (-not $b.Done -and -not $b.Err); done = $b.Done; err = $b.Err; files = $arr })
            }
        }
        elseif ($path -eq "/api/delfile" -and $req.HttpMethod -eq "POST") {
            $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd(); $sr.Close()
            $in = $body | ConvertFrom-Json
            $err = Remove-BigFile $in.path
            if ($err) { Send-Json $ctx ([ordered]@{ ok = $false; err = $err }) }
            else { Send-Json $ctx ([ordered]@{ ok = $true }) }
        }
        elseif ($path -eq "/api/jobs" -and $req.HttpMethod -eq "POST") {
            $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $bodyText = $sr.ReadToEnd(); $sr.Close()
            $in = $bodyText | ConvertFrom-Json
            if (-not $in.text -or -not $in.text.Trim()) {
                Send-Json $ctx ([ordered]@{ ok = $false; err = "内容为空" })
            } else {
                $id = "j" + [DateTime]::UtcNow.Ticks
                $script:Jobs[$id] = [pscustomobject]@{
                    ID = $id; Text = $in.text; Title = ""; Author = ""
                    Status = "parsing"; Step = "排队中"; Received = 0; Total = 0; File = ""; Err = ""
                }
                Start-VJobTask $id
                Send-Json $ctx ([ordered]@{ ok = $true; id = $id })
            }
        }
        elseif ($path -eq "/api/jobs" -and $req.HttpMethod -eq "GET") {
            $arr = @()
            foreach ($k in ($script:Jobs.Keys | Sort-Object -Descending)) {
                $j = $script:Jobs[$k]
                $arr += [ordered]@{
                    id = $j.ID; title = $j.Title; author = $j.Author; status = $j.Status
                    step = $j.Step; received = $j.Received; total = $j.Total; file = $j.File; err = $j.Err
                }
            }
            $json = ConvertTo-Json -InputObject @($arr) -Depth 6 -Compress
            if (-not $json) { $json = "[]" }
            if ($json -notmatch '^\[') { $json = "[$json]" }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $res.ContentType = "application/json; charset=utf-8"
            $res.Headers.Add("Cache-Control", "no-store")
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            $res.Close()
        }
        elseif ($path -like "/api/jobs/*" -and $req.HttpMethod -eq "DELETE") {
            $jid = $path.Substring($path.LastIndexOf("/") + 1)
            if ($script:Jobs.ContainsKey($jid)) { $script:Jobs.Remove($jid) }
            Send-Json $ctx ([ordered]@{ ok = $true })
        }
        elseif ($path -eq "/api/update/check" -and $req.HttpMethod -eq "GET") {
            Send-Json $ctx (Invoke-UpdateCheck)
        }
        elseif ($path -eq "/api/update/apply" -and $req.HttpMethod -eq "POST") {
            $err = Invoke-UpdateApply
            if ($err) { Send-Json $ctx ([ordered]@{ ok = $false; err = $err }) }
            else { Send-Json $ctx ([ordered]@{ ok = $true }) }
        }
        elseif ($path -eq "/api/quit") {
            Send-Json $ctx ([ordered]@{ ok = $true })
            break
        }
        else {
            $res.StatusCode = 404
            $res.Close()
        }
    } catch {
        try { $res.StatusCode = 500; $res.Close() } catch {}
    }
}
try { $listener.Stop(); $listener.Close() } catch {}
