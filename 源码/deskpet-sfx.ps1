# ============================================================
#  deskpet-sfx.ps1 —— 交互音效（本地 wav，SoundPlayer，不联网）
#   · 音量：音效.音量 0~100 → 预生成的 5 档文件（click-20/40/60/80/100.wav）
#     SoundPlayer 没有音量接口，所以用"不同增益的 wav"实现
#   · 规则：只在用户操作时响；文件缺失/开关关闭 → 静默，绝不报错
# ============================================================

$script:sfxPlayers = @{}
$script:sfxLastMs  = @{}

function Get-SfxLevel {
    $vol = [int](Cfg '音效.音量' 70)
    if ($vol -le 0) { return 0 }
    if ($vol -lt 30) { return 20 }
    if ($vol -lt 50) { return 40 }
    if ($vol -lt 70) { return 60 }
    if ($vol -lt 90) { return 80 }
    return 100
}

function Get-SfxPath {
    param([string]$Name)
    $level = Get-SfxLevel
    if ($level -le 0) { return '' }
    $dir = Join-Path $PSScriptRoot '音效'
    $f = Join-Path $dir ($Name + '-' + $level + '.wav')
    if (Test-Path -LiteralPath $f) { return $f }
    $f2 = Join-Path $dir ($Name + '.wav')
    if (Test-Path -LiteralPath $f2) { return $f2 }
    return ''
}

function Play-Sfx {
    param([string]$Name = 'click', [int]$MinGapMs = 40)
    if (-not [bool](Cfg '音效.启用' $true)) { return }
    try {
        $now = [Environment]::TickCount
        if ($script:sfxLastMs.ContainsKey($Name) -and (($now - $script:sfxLastMs[$Name]) -lt $MinGapMs)) { return }
        $p = Get-SfxPath $Name
        if (-not $p) { return }
        $script:sfxLastMs[$Name] = $now
        if (-not $script:sfxPlayers.ContainsKey($p)) {
            $sp = New-Object System.Media.SoundPlayer $p
            $sp.Load()
            $script:sfxPlayers[$p] = $sp
        }
        $script:sfxPlayers[$p].Play()
    } catch { }
}
