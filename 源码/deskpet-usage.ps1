# ============================================================
#  deskpet-usage.ps1 —— DSH 用量看板（读本地用量文件，不联网）
#   数据来源：C:\Users\Administrator\.dsh\.dshw-usage.json
#   给她的"今日用量"菜单用：调用次数 / tokens / 花费 / 余额
# ============================================================

function Get-UsageFilePath {
    $p = [string](Cfg 'DSH.用量文件' '')
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    $def = Join-Path $env:USERPROFILE '.dsh\.dshw-usage.json'
    if (Test-Path -LiteralPath $def) { return $def }
    return ''
}

# 返回：@{ ok; date; count; tokens; cost; balance; error }
function Get-DshUsage {
    $res = @{ ok = $false; date = ''; count = 0; tokens = 0; cost = 0.0; balance = 0.0; error = '' }
    try {
        $path = Get-UsageFilePath
        if (-not $path) { $res.error = '没有用量文件'; return $res }
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if (-not $raw) { $res.error = '用量文件是空的'; return $res }
        $j = $raw | ConvertFrom-Json
        $today = [string](Get-Date -Format 'yyyy-MM-dd')
        $res.date = $today
        $res.balance = [double]$j.lastBalance
        $res.cost = [double]$j.todayUsage

        $cnt = 0; $tok = 0
        if ($j.events) {
            foreach ($e in $j.events) {
                if ([string]$e.day -eq $today) {
                    $cnt++
                    $tok += [int]$e.tokens
                }
            }
        }
        # 如果 events 里没有今天的（文件结构变化），回退到 history
        if ($cnt -eq 0 -and $j.history -and $j.history.$today) {
            $res.cost = [double]$j.history.$today
        }
        $res.count = $cnt
        $res.tokens = $tok
        $res.ok = $true
    }
    catch { $res.error = $_.Exception.Message }
    return $res
}

# 把数字说成人话
function Format-UsageText {
    param($U)
    if (-not $U -or -not $U.ok) {
        if ($U -and $U.error) { return ('我查不到用量：' + $U.error) }
        return '我查不到用量。'
    }
    $tokTxt = if ($U.tokens -ge 100000000) { [string][Math]::Round($U.tokens / 100000000.0, 2) + ' 亿' }
              elseif ($U.tokens -ge 10000) { [string][Math]::Round($U.tokens / 10000.0, 1) + ' 万' }
              elseif ($U.tokens -ge 1000) { [string][Math]::Round($U.tokens / 1000.0, 1) + ' 千' }
              else { [string]$U.tokens }
    $costTxt = '¥' + [Math]::Round($U.cost, 2)
    $balTxt  = '¥' + [Math]::Round($U.balance, 2)
    $avg = if ($U.count -gt 0) { '¥' + [Math]::Round($U.cost / $U.count, 3) } else { '—' }
    $line = '今天 ' + $U.count + ' 次，' + $tokTxt + ' tokens，花了 ' + $costTxt + '（平均每次 ' + $avg + '），余额 ' + $balTxt + '。'
    if ($U.count -eq 0) { $line = '今天还没用过呢。余额 ' + $balTxt + '。' }
    return $line
}

# 给设置面板/气泡用的短数据
function Get-UsageShort {
    $u = Get-DshUsage
    return @{
        count   = $u.count
        tokens  = $u.tokens
        cost    = $u.cost
        balance = $u.balance
        ok      = $u.ok
        text    = (Format-UsageText $u)
    }
}

# 最近 7 天统计（含今天）
function Get-DshUsageWeek {
    $out = @{ ok = $false; days = @(); total = 0.0; avg = 0.0 }
    try {
        $path = Get-UsageFilePath
        if (-not $path) { return $out }
        $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $j.history) { return $out }
        $list = @()
        for ($i = 6; $i -ge 0; $i--) {
            $d = (Get-Date).AddDays(-$i).ToString('yyyy-MM-dd')
            $c = 0.0
            $v = $j.history.$d
            if ($null -ne $v) { $c = [double]$v }
            $label = (Get-Date).AddDays(-$i).ToString('MM-dd')
            $list += [pscustomobject]@{ date = $d; label = $label; cost = $c }
        }
        $out.days = $list
        $sum = 0.0
        foreach ($x in $list) { $sum += $x.cost }
        $out.total = $sum
        $out.avg = [Math]::Round($sum / 7.0, 2)
        $out.ok = $true
    } catch { }
    return $out
}

# 7 天文本（给设置面板用）
function Format-UsageWeekLines {
    $w = Get-DshUsageWeek
    if (-not $w.ok) { return @('（读不到历史数据）') }
    $max = 0.001
    foreach ($d in $w.days) { if ($d.cost -gt $max) { $max = $d.cost } }
    $lines = @()
    foreach ($d in $w.days) {
        $bars = [int][Math]::Round(($d.cost / $max) * 16)
        if ($bars -lt 0) { $bars = 0 }
        $bar = ('█' * $bars) + ('·' * (16 - $bars))
        $lines += ($d.label + '  ' + $bar + '  ¥' + [Math]::Round($d.cost, 2))
    }
    $lines += ('合计 ¥' + [Math]::Round($w.total, 2) + '   日均 ¥' + $w.avg)
    return $lines
}

# ---------------- 充值 ----------------
$script:usageBalLow = $false
$script:usageLowNotifiedDay = ''

function Get-RechargeUrl {
    $u = [string](Cfg '用量.充值网址' '')
    if ($u) { return $u.Trim() }
    return 'https://platform.deepseek.com/top_up'
}

function Open-Recharge {
    try {
        $u = Get-RechargeUrl
        if (-not $u) { return $false }
        Start-Process $u | Out-Null
        try { Say-Something 0 @('充值页面给你打开了，快去看看。') 40 } catch {}
        return $true
    } catch {
        try { Say-Something 0 @('浏览器打不开……你自己搜一下 DeepSeek 充值吧。') 45 } catch {}
        return $false
    }
}

# 池子里取一句，把 {bal} / {cost} 换成数字（台词包可自己改）
function Format-UsagePoolLine {
    param([string]$PoolName, [double]$Bal = 0.0, [double]$Cost = 0.0, [string]$Fallback = '')
    $line = ''
    try { $line = [string](Get-PoolLine $PoolName) } catch {}
    if (-not $line) { $line = $Fallback }
    if (-not $line) { return '' }
    $line = $line.Replace('{bal}', [string]([Math]::Round($Bal, 2)))
    $line = $line.Replace('{cost}', [string]([Math]::Round($Cost, 2)))
    return $line
}

# 余额是不是低到该提醒了（给菜单/看板/设置面板用）
function Test-UsageBalLow {
    try {
        $u = Get-DshUsage
        if (-not $u.ok) { return $false }
        $lim = [double](Cfg '用量.余额低于' 5)
        if ($lim -le 0) { return $false }
        return ([double]$u.balance -le $lim)
    } catch { return $false }
}

# ---------------- 定时播报余额（默认 30 分钟一次） ----------------
function Update-BalanceBroadcast {
    if (-not [bool](Cfg '用量.余额播报' $true)) { return }
    if ($script:sleep -gt 0 -or $script:introQuiet) { return }
    $min = [double](Cfg '用量.余额播报分钟数' 30)
    if ($min -le 0) { return }
    $gapFrames = $min * 60.0 * (1000.0 / [double]$script:timer.Interval)
    if (($script:tick - $script:usageLastBroadcast) -lt $gapFrames) { return }
    if ($script:tick -lt $script:usageBroadcastCheck) { return }
    $script:usageBroadcastCheck = $script:tick + (CfgFrames '用量.播报检查间隔秒数' 300)
    try {
        $u = Get-DshUsage
        if (-not $u.ok) { return }
        $bal = [Math]::Round([double]$u.balance, 2)
        $limit = [double](Cfg '用量.余额低于' 5)
        $costLimit = [double](Cfg '用量.今日花费阈值' 5)
        $line = ''
        if ($limit -gt 0 -and [double]$u.balance -le $limit) {
            # ★ 余额不足：用"该充了"的池子，并记下状态（给菜单/看板高亮）
            $script:usageBalLow = $true
            $line = Format-UsagePoolLine 'broadcast.low' $bal ([double]$u.cost) ('饿……余额只剩 ¥' + $bal + ' 了，右键能充值。')
        }
        elseif ($costLimit -gt 0 -and [double]$u.cost -ge $costLimit) {
            $script:usageBalLow = $false
            $line = Format-UsagePoolLine 'broadcast.cost' $bal ([double]$u.cost) ('今天已经花了 ¥' + [Math]::Round([double]$u.cost, 2) + ' 了。')
        }
        else {
            $script:usageBalLow = $false
            $line = Format-UsagePoolLine 'broadcast.balance' $bal ([double]$u.cost) ('余额还有 ¥' + $bal + '。')
        }
        $script:usageLastBroadcast = $script:tick
        try { Say-Something 0 @($line) 24 } catch {}
    } catch {}
}

# ---------------- 阈值提醒（每 5 分钟检查，当天各提醒一次） ----------------
function Check-UsageAlert {
    if (-not [bool](Cfg '用量.提醒启用' $true)) { return }
    if ($script:tick -lt $script:usageNextCheck) { return }
    $script:usageNextCheck = $script:tick + (CfgFrames '用量.检查间隔秒数' 300)
    if ($script:sleep -gt 0) { return }

    $u = Get-DshUsage
    if (-not $u.ok) { return }
    $today = $u.date
    if ($script:usageAlertDay -ne $today) {
        $script:usageAlertDay = $today
        $script:usageAlertCost = $false
        $script:usageAlertBal = $false
    }
    $bal = [double]$u.balance
    $cost = [double]$u.cost
    $costLimit = [double](Cfg '用量.今日花费阈值' 5)
    $balLimit = [double](Cfg '用量.余额低于' 5)

    # 充过值（余额回到阈值 1.5 倍以上）→ 允许下次再提醒
    if ($script:usageAlertBal -and $balLimit -gt 0 -and $bal -gt ($balLimit * 1.5)) {
        $script:usageAlertBal = $false
    }

    if (-not $script:usageAlertCost -and $costLimit -gt 0 -and $cost -ge $costLimit) {
        $script:usageAlertCost = $true
        $line = Format-UsagePoolLine 'broadcast.cost' $bal $cost ('今天已经花了 ¥' + [Math]::Round($cost, 2) + ' 了，省着点。')
        try { Say-Something 0 @($line) 50 } catch {}
        return
    }
    if (-not $script:usageAlertBal -and $balLimit -gt 0 -and $bal -le $balLimit) {
        $script:usageAlertBal = $true
        $script:usageBalLow = $true
        $script:usageLowNotifiedDay = $today
        $line = Format-UsagePoolLine 'broadcast.low' $bal $cost ('余额只剩 ¥' + [Math]::Round($bal, 2) + ' 了，右键菜单能充值。')
        try { Say-Something 0 @($line) 50 } catch {}
        return
    }
}