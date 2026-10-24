# ============================================================
#  deskpet-timetrack.ps1 —— 应用使用时长统计（本地，不联网）
#   只记：进程名 + 秒数。不记窗口标题内容、不上传。
#   数据：统计\YYYY-MM-DD.json   { date, total, apps: { proc: 秒 } }
#   空闲（键鼠不动）不计时；每天自动换文件。
# ============================================================

if (-not ('TT' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class TT {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint IdleMs() {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(li);
        if (!GetLastInputInfo(ref li)) { return 0; }
        return (uint)((uint)Environment.TickCount - li.dwTime);
    }
}
'@ -ErrorAction SilentlyContinue
}

$script:ttDay        = ''
$script:ttApps       = @{}      # 进程名(小写,无.exe) -> 秒
$script:ttTotal      = 0.0
$script:ttLastMs     = 0
$script:ttLastSaveMs = 0
$script:ttDirty      = $false

# 进程名 → 友好名（没映射的直接显示进程名）
$script:ttNames = @{
    'code' = 'VS Code'; 'devenv' = 'Visual Studio'; 'pycharm64' = 'PyCharm'; 'idea64' = 'IDEA'
    'clion64' = 'CLion'; 'sublime_text' = 'Sublime'; 'notepad++' = 'Notepad++'; 'cursor' = 'Cursor'
    'trae' = 'Trae'; 'rider64' = 'Rider'; 'webstorm64' = 'WebStorm'; 'goland64' = 'GoLand'
    'blender' = 'Blender'; 'photoshop' = 'Photoshop'; 'krita' = 'Krita'; 'clipstudiopaint' = 'CSP'
    'aseprite' = 'Aseprite'; 'illustrator' = 'Illustrator'
    'chrome' = 'Chrome'; 'msedge' = 'Edge'; 'firefox' = 'Firefox'; 'bilibili' = 'B站'
    'potplayer' = 'PotPlayer'; 'vlc' = 'VLC'; 'douyin' = '抖音'
    'wechat' = '微信'; 'weixin' = '微信'; 'qq' = 'QQ'; 'discord' = 'Discord'; 'obsidian' = 'Obsidian'
    'winword' = 'Word'; 'excel' = 'Excel'; 'powerpnt' = 'PPT'; 'acrobat' = 'Acrobat'
    'notepad' = '记事本'; 'mspaint' = '画图'; 'ollama' = 'Ollama'; 'mumuplayer' = '模拟器'
    'explorer' = '资源管理器'; 'powershell' = '终端'; 'pwsh' = '终端'; 'windowsterminal' = '终端'
    'qianwen' = '通义千问'; 'steam' = 'Steam'; 'deepseek harness' = 'DeepSeek Harness'
    'siliconflow' = '硅基流动'; 'clash verge' = 'Clash'; 'mumu' = '模拟器'
}

function Get-TimeTrackDir {
    if ($PSScriptRoot) { return (Join-Path $PSScriptRoot '统计') }
    return (Join-Path (Get-Location).Path '统计')
}

function Get-TimeTrackFile {
    param([string]$Day = '')
    if (-not $Day) { $Day = (Get-Date).ToString('yyyy-MM-dd') }
    return (Join-Path (Get-TimeTrackDir) ($Day + '.json'))
}

function Load-TimeTrack {
    param([string]$Day)
    $script:ttApps  = @{}
    $script:ttTotal = 0.0
    $script:ttDay   = $Day
    $p = Get-TimeTrackFile $Day
    if (Test-Path -LiteralPath $p) {
        try {
            $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:ttTotal = [double]$j.total
            if ($j.apps) {
                foreach ($pr in $j.apps.PSObject.Properties) { $script:ttApps[$pr.Name] = [double]$pr.Value }
            }
        } catch { }
    }
}

function Save-TimeTrack {
    if (-not $script:ttDay) { return }
    try {
        $dir = Get-TimeTrackDir
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $obj = [pscustomobject]@{
            date  = $script:ttDay
            total = [Math]::Round($script:ttTotal, 1)
            apps  = [pscustomobject]$script:ttApps
        }
        [System.IO.File]::WriteAllText((Get-TimeTrackFile $script:ttDay), ($obj | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        $script:ttDirty      = $false
        $script:ttLastSaveMs = [Environment]::TickCount
    } catch { }
}

function Get-TimeTrackFgProc {
    try {
        $info = [LW]::ForegroundInfo()
        if (-not $info) { return '' }
        $parts = $info.Split([char]1)
        if ($parts.Count -lt 2) { return '' }
        $title = ([string]$parts[0]).ToLowerInvariant()
        $proc  = ([string]$parts[1]).ToLowerInvariant().Trim()
        if (-not $proc) { return '' }
        # 她自己的窗口 / 桌面不算
        if (-not $script:ttSelfProc) { try { $script:ttSelfProc = [System.Diagnostics.Process]::GetCurrentProcess().ProcessName.ToLowerInvariant() } catch { $script:ttSelfProc = '' } }
        if ($script:ttSelfProc -and $proc -eq $script:ttSelfProc) { return '' }
        if (($proc -eq 'powershell' -or $proc -eq 'pwsh') -and $title -match 'deskpet') { return '' }
        if ($proc -eq 'explorer' -and ($title -eq '' -or $title -match 'program manager')) { return '' }
        return $proc
    } catch { return '' }
}

# 每帧调用：把时间差累加到当前前台应用
function Update-TimeTrack {
    if (-not [bool](Cfg '统计.启用' $true)) { return }
    $now   = [Environment]::TickCount
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($script:ttDay -ne $today) {
        if ($script:ttDay) { Save-TimeTrack }
        Load-TimeTrack $today
        $script:ttLastMs = $now
        return
    }
    if ($script:ttLastMs -le 0) { $script:ttLastMs = $now; return }
    $delta = ($now - $script:ttLastMs) / 1000.0
    $script:ttLastMs = $now
    if ($delta -le 0 -or $delta -gt 5) { return }   # 休眠/卡顿跳变不算
    # 空闲不计
    try {
        $idleMs = [double][TT]::IdleMs()
        $limitMs = [double](Cfg '统计.空闲秒数' 60) * 1000.0
        if ($idleMs -ge $limitMs) { return }
    } catch { }
    $proc = Get-TimeTrackFgProc
    if (-not $proc) { return }
    $script:ttApps[$proc] = [double]($script:ttApps[$proc]) + $delta
    $script:ttTotal += $delta
    $script:ttDirty = $true
    $saveEvery = [double](Cfg '统计.保存间隔秒数' 30) * 1000.0
    if (($now - $script:ttLastSaveMs) -gt $saveEvery) { Save-TimeTrack }
}

function Get-TimeTrackFriendly {
    param([string]$Proc)
    $n = $script:ttNames[$Proc]
    if ($n) { return $n }
    return $Proc
}

function Format-TimeTrackDur {
    param([double]$Sec)
    $m = [int]($Sec / 60)
    if ($m -lt 1) { return ([int]$Sec).ToString() + ' 秒' }
    if ($m -lt 60) { return ($m.ToString() + ' 分') }
    return ([int]($m / 60)).ToString() + ' 小时 ' + ($m % 60).ToString() + ' 分'
}

function Get-TimeTrackTop {
    param([int]$N = 3)
    $list = @()
    foreach ($k in $script:ttApps.Keys) {
        $sec = [double]$script:ttApps[$k]
        if ($sec -lt 3) { continue }   # 不足 3 秒的杂项不列（比如误触一下的窗口）
        $list += [pscustomobject]@{ proc = $k; sec = $sec }
    }
    if ($list.Count -eq 0) { return @() }
    return @($list | Sort-Object sec -Descending | Select-Object -First $N)
}

function Get-TimeTrackText {
    if ($script:ttTotal -lt 60) { return '今天还没怎么用电脑。' }
    $top = Get-TimeTrackTop 3
    $parts = @()
    foreach ($x in $top) { $parts += ((Get-TimeTrackFriendly $x.proc) + ' ' + (Format-TimeTrackDur $x.sec)) }
    return ('今天用电脑 ' + (Format-TimeTrackDur $script:ttTotal) + '。最久：' + ($parts -join '、') + '。')
}

# 右键菜单：今天用了多久 ▸ 动态列出每个应用（每次打开菜单刷新）
function Update-TimeTrackMenu {
    if (-not $script:ttMenu) { return }
    try {
        $dd = $script:ttMenu.DropDownItems
        $dd.Clear()
        $hdr = $dd.Add(('今天用电脑 ' + (Format-TimeTrackDur $script:ttTotal)))
        $hdr.Enabled = $false
        $top = Get-TimeTrackTop 8
        if (-not $top -or $top.Count -eq 0) {
            $it = $dd.Add('（还没记录，用一会儿再看）')
            $it.Enabled = $false
            return
        }
        foreach ($x in $top) {
            $it = $dd.Add(((Get-TimeTrackFriendly $x.proc) + '  ·  ' + (Format-TimeTrackDur $x.sec)))
            $it.Enabled = $false
        }
        [void]$dd.Add('-')
        $it = $dd.Add('只算前台 + 键鼠有操作的时间')
        $it.Enabled = $false
    } catch { }
}