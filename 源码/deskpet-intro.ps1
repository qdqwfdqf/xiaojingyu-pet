# ============================================================
#  deskpet-intro.ps1 —— 第一次打开：先睡着，点她醒来，说一段"初次见面"
#   只触发一次（标记 .cache\firstrun.done）
# ============================================================

$script:introActive  = $false
$script:introIdx     = 0
$script:introNextTick = 0
$script:introLines   = @()
$script:introRoot    = ''
$script:introQuiet   = $false   # 首次见面期间：其它台词全部让行

function Get-IntroMarker { param([string]$Root) return (Join-Path $Root '.cache\firstrun.done') }

# 用户级标记：升级/覆盖程序文件夹后也不会重演"首次见面"
function Get-IntroMarkerUser {
    try {
        $d = Join-Path $env:LOCALAPPDATA '小鲸鱼桌宠'
        return (Join-Path $d 'firstrun.done')
    } catch { return '' }
}

function Test-FirstRun {
    param([string]$Root)
    if (-not $Root) { return $false }
    if (Test-Path -LiteralPath (Get-IntroMarker $Root)) { return $false }
    $u = Get-IntroMarkerUser
    if ($u -and (Test-Path -LiteralPath $u)) { return $false }
    return $true
}

function Complete-FirstRun {
    param([string]$Root)
    try {
        $dir = Join-Path $Root '.cache'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        'done' | Out-File -FilePath (Get-IntroMarker $Root) -Encoding utf8
    } catch {}
    # 同时写用户目录标记（换电脑/重装程序文件夹才算全新安装）
    try {
        $u = Get-IntroMarkerUser
        if ($u) {
            $ud = Split-Path $u -Parent
            if (-not (Test-Path $ud)) { New-Item -ItemType Directory -Path $ud -Force | Out-Null }
            'done' | Out-File -FilePath $u -Encoding utf8
        }
    } catch {}
}

# 开始初次见面：先睡着，等一次点击
function Start-Intro {
    param([string]$Root)
    if (-not (Test-FirstRun $Root)) { return $false }
    $script:introRoot = $Root
    $script:introActive = $true
    $script:introQuiet = $true     # 首次见面独占
    $script:introIdx = 0

    # 取 10 句（按池顺序，不重复）
    $script:introLines = @()
    try {
        if ($script:pools -and $script:pools.ContainsKey('intro.first')) {
            $script:introLines = @($script:pools['intro.first'])
        }
    } catch {}
    if ($script:introLines.Count -eq 0) {
        $script:introLines = @('这是……哪里？', '我怎么在这。', '你好。')
    }
    while ($script:introLines.Count -gt 10) { $script:introLines = $script:introLines[0..9] }

    # 进入睡眠姿态（长睡，只等她被点）
    $script:sleep = [int](1.0e9)
    $script:poseTmp = $null
    try { Clear-Bubble } catch {}
    return $true
}

# 被点醒：由 MouseClick 调用
function Wake-Intro {
    if (-not $script:introActive) { return $false }
    if ($script:introIdx -gt 0) { return $false }     # 已经醒了
    $script:sleep = 0
    $script:introIdx = 1
    $script:introNextTick = $script:tick + 8
    $script:sqV = 0.30
    try { Queue-PoseSwap 'pose_伸懒腰' ([int](1.4 * 1000.0 / [double]$script:timer.Interval)) } catch {}
    return $true
}

# 每帧：按节奏把 10 句说完
function Update-Intro {
    if (-not $script:introActive) { return }
    if ($script:introIdx -le 0) { return }            # 还没被点醒
    if ($script:tick -lt $script:introNextTick) { return }

    $i = $script:introIdx - 1
    if ($i -lt $script:introLines.Count) {
        $line = [string]$script:introLines[$i]
        try { Say-Something 0 @($line) 200 -force } catch {}
        $script:introIdx++
        $script:introNextTick = $script:tick + [int](2.4 * 1000.0 / [double]$script:timer.Interval)
    }
    else {
        # 说完了：收工，写标记
        $script:introActive = $false
        $script:introQuiet = $false
        if ($script:introRoot) { Complete-FirstRun $script:introRoot }
        try { Say-Something 0 @('我记住你了。') 200 -force } catch {}
    }
}