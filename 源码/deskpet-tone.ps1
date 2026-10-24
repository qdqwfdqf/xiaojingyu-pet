# ============================================================
#  deskpet-tone.ps1 —— 状态语气（饿 / 困 / 吃醋 / 被戳烦）
#    · 用台词池的 tone.* 池子，不需要额外美术
#    · 状态由"上次喂饭 / 上次互动 / 上次聊天 / 手感热度"推算
# ============================================================

$script:lastFeedTick     = 0   # 上次喂饭
$script:lastChatTick     = 0   # 上次聊天（用户发话）
$script:lastInteractTick = 0   # 上次互动（点/摸）
$script:lastToneSay      = @{}     # 每类语气上次说话的 tick
$script:toneNextAt       = 0       # 全局间隔，防止刷屏

function Mark-Feed     { $script:lastFeedTick     = $script:tick }
function Mark-Chat     { $script:lastChatTick     = $script:tick }
function Mark-Interact { $script:lastInteractTick = $script:tick }

function Get-ToneState {
    try {
        $fps = 1000.0 / [double]$script:timer.Interval
        if ($fps -le 0) { $fps = 62.5 }

        # ① 刚被狂戳 → 烦
        if ($script:petHeat -gt 2.5) { return 'annoyed' }

        # ② 饿 = 余额不够了（"喂饭" = 充值）
        try {
            if (Get-Command Get-DshUsage -ErrorAction SilentlyContinue) {
                $u = Get-DshUsage
                if ($u -and $u.ok) {
                    $limit = [double](Cfg '用量.余额低于' 2)
                    if ($limit -gt 0 -and [double]$u.balance -le $limit) { return 'hungry' }
                }
            }
        } catch {}

        # ③ 深夜 + 一段时间没互动 → 困
        $h = (Get-Date).Hour
        $sinceInteract = 99.0
        if ($script:lastInteractTick -gt -900000) { $sinceInteract = (($script:tick - $script:lastInteractTick) / $fps / 3600.0) }
        if (($h -ge 23 -or $h -lt 6) -and $sinceInteract -ge 1.0) { return 'sleepy' }

        # ④ 好久没聊天 → 吃醋
        $jealousMin = [double](Cfg '互动.吃醋分钟数' 45)
        if ($jealousMin -gt 0 -and $script:lastChatTick -gt -900000) {
            if ((($script:tick - $script:lastChatTick) / $fps / 60.0) -ge $jealousMin) { return 'jealous' }
        }
    } catch {}
    return ''
}

function Update-ToneState {
    if (-not [bool](Cfg '互动.状态语气' $true)) { return }
    if ($script:tick -lt $script:toneNextAt) { return }
    if ($script:introQuiet -or $script:sleep -gt 0) { return }
    if ($script:hurt -gt 0 -or $script:angry -gt 0) { return }   # 情绪优先，别抢
    $st = Get-ToneState
    if (-not $st) { return }
    $cd = CfgFrames '互动.状态语气冷却秒数' 150
    $last = 0
    if ($script:lastToneSay.ContainsKey($st)) { $last = [int]$script:lastToneSay[$st] }
    if ($last -gt 0 -and (($script:tick - $last) -lt $cd)) { return }   # 0=从没说过，不冷却
    $poolName = 'tone.' + $st
    if (-not (Get-Command Test-PoolHas -ErrorAction SilentlyContinue)) { return }
    if (-not (Test-PoolHas $poolName)) { return }
    # 她正在说话/刚说完 → 别抢，等下次（不推进冷却，避免"白等一轮"）
    if ($script:sayLock -gt 0) { return }
    $line = Get-PoolLine $poolName
    if (-not $line) { return }
    try { Say-Something 0 @($line) 26 } catch { Log-Err $_ 'tone-say'; return }
    if ($script:sayLock -le 0) { return }   # 被别的高优先级挡了 → 下次再来
    $gap = CfgFrames '互动.状态语气间隔秒数' 60
    $script:toneNextAt = $script:tick + $gap + (Get-Random -Minimum 0 -Maximum ([Math]::Max(1, [int]$gap)))
    $script:lastToneSay[$st] = $script:tick
}
