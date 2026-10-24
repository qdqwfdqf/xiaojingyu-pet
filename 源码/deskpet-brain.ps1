# ============================================================
#  deskpet-brain.ps1 —— 离线对话大脑（不需要 API）
#   能力：意图识别 / 模板槽位 / 上下文记忆 / 时间感知 / 情绪感知 / 指令执行
#   被 deskpet.ps1 dot-source 引入
# ============================================================

$script:brainLast   = New-Object System.Collections.ArrayList   # 最近几条回复（防重复）
$script:brainTopic  = ''      # 上一个话题
$script:brainTurn   = 0       # 对话轮数
$script:brainCmds   = $null
$script:brainIntents = $null

# ---------------- 指令表 ----------------
function Get-BrainCommands {
    if ($script:brainCmds) { return $script:brainCmds }
    $script:brainCmds = [ordered]@{
        'sleep' = @('睡吧', '去睡', '睡觉', '你睡', '休息吧', '晚安')
        'stop'  = @('别动', '站住', '停下', '停下来', '别走', '不许动')
        'go'    = @('过来', '来这', '来我这', '跟过来', '到我这')
        'jump'  = @('跳', '蹦', '跳一下', '蹦一下')
        'pet'   = @('摸摸', '摸一下', '揉揉', '顺毛')
        'sing'  = @('唱歌', '唱一个', '唱首歌')
        'quiet' = @('闭嘴', '安静', '别吵', '别说了')
        'time'  = @('几点', '现在时间', '什么时间')
        'date'  = @('几号', '今天日期', '星期几', '今天几')
    }
    return $script:brainCmds
}

# ---------------- 意图库（带权重） ----------------
function Get-BrainIntents {
    if ($script:brainIntents) { return $script:brainIntents }
    $script:brainIntents = [ordered]@{
        'greet'   = @{ w = @{ '你好' = 3; '在吗' = 3; '嗨' = 2; 'hi' = 2; 'hello' = 2; '早上好' = 3; '早' = 1 }; r = @(
            '{时段}好呀。{称呼}今天也要好好的。', '……嗯，我在。', '来了来了，别催。', '你在啊，正好我无聊。') }
        'praise'  = @{ w = @{ '可爱' = 3; '好看' = 2; '漂亮' = 3; '喜欢' = 2; '厉害' = 3; '棒' = 2; '牛' = 2; '爱' = 2; '乖' = 2 }; r = @(
            '……才、才不是因为你说才高兴的。[害羞]', '哼，这还用你说。[害羞]', '别夸了，会当真的。', '多夸两句也行……') }
        'scold'   = @{ w = @{ '笨' = 3; '丑' = 3; '滚' = 4; '讨厌' = 3; '烦' = 2; '蠢' = 3; '垃圾' = 4; '傻' = 3 }; r = @(
            '你说什么？再说一遍试试。[生气]', '……记仇了。[生气]', '我不好看了？你再说。', '哼，不理你了。') }
        'tired'   = @{ w = @{ '累' = 3; '困' = 2; '乏' = 2; '加班' = 3; '熬夜' = 3; '撑不住' = 3; '好忙' = 2; '忙' = 1 }; r = @(
            '累了就歇会，活不会跑。', '{称呼}又在硬撑？别撑了。', '先去喝口水吧，我等你。', '你这样我会担心的。') }
        'hungry'  = @{ w = @{ '饿' = 3; '吃' = 2; '饭' = 2; '零食' = 3; '外卖' = 3 }; r = @(
            '饿了就去吃啊，看我干嘛。', '有零食分我一半。', '别又是泡面……') }
        'sleeplike' = @{ w = @{ '睡' = 2; '晚安' = 2; '困了' = 3 }; r = @(
            '睡吧，我守着桌面。', '晚安，明天记得叫我。') }
        'name'    = @{ w = @{ '名字' = 3; '你叫' = 3; '你是谁' = 3; '介绍' = 2 }; r = @(
            '小鲸鱼。不许喊错。', '我？住你桌面上的小鲸鱼。别小看我。', '叫我小鲸鱼就行。') }
        'help'    = @{ w = @{ '帮我' = 3; '怎么办' = 3; '不会' = 2; '教我' = 3; '建议' = 2; '难过' = 3; '不开心' = 3; '烦死' = 3 }; r = @(
            '我不会写代码，但我可以陪你一会儿。', '先深呼吸。慢慢说，我听着。', '……我不太懂，但你可以先写下问题。', '别自己扛。') }
        'question'= @{ w = @{ '为什么' = 3; '怎么' = 2; '什么' = 1; '吗' = 1; '?' = 1; '？' = 1 }; r = @(
            '这个我答不上来……去查查吧。', '嗯……我脑子里只有小鱼。', '你比我聪明，你来想。', '我也不知道，别看我。') }
        'thanks'  = @{ w = @{ '谢谢' = 3; 'thanks' = 3; '谢了' = 3 }; r = @(
            '……不客气。', '不用谢，顺手的事。', '记着就行。') }
        'bye'     = @{ w = @{ '拜拜' = 3; '再见' = 3; '走了' = 2; '下线' = 3 }; r = @(
            '走了？那……早点回来。', '拜拜。别熬夜。', '我在这等你。') }
        'chat'    = @{ w = @{}; r = @(
            '嗯。然后呢？', '……我听着呢。', '哦，这样啊。', '你今天话挺多。', '哼，随便你怎么说。', '说完了？那我继续发呆。', '有意思。') }
    }
    return $script:brainIntents
}

# ---------------- 时间感知 ----------------
function Get-TimeSlot {
    $h = (Get-Date).Hour
    if ($h -lt 5)  { return '凌晨' }
    if ($h -lt 9)  { return '早上' }
    if ($h -lt 12) { return '上午' }
    if ($h -lt 18) { return '下午' }
    if ($h -lt 23) { return '晚上' }
    return '深夜'
}

# ---------------- 模板填充 ----------------
function Fill-Slot {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text
    $slot = Get-TimeSlot
    $t = $t.Replace('{时段}', $slot)
    $t = $t.Replace('{称呼}', '你')
    $t = $t.Replace('{自称}', '我')
    $t = $t.Replace('{}', '')
    # 深夜自动催睡（时间感知）
    if (($slot -eq '深夜' -or $slot -eq '凌晨') -and ($t -match '睡|休息|熬夜')) {
        $t = '都' + $slot + '了，' + $t
    }
    return $t.Trim()
}

# ---------------- 意图识别（多词加权） ----------------
function Get-BrainIntent {
    param([string]$Text)
    $t = $Text.Trim()
    if (-not $t) { return 'chat' }
    $low = $t.ToLowerInvariant()
    $best = 'chat'
    $bestScore = 0
    foreach ($name in (Get-BrainIntents).Keys) {
        $grp = (Get-BrainIntents)[$name]
        $score = 0
        foreach ($k in $grp.w.Keys) {
            if ($low.Contains($k.ToLowerInvariant())) { $score += [int]$grp.w[$k] }
        }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $name }
    }
    return $best
}

# ---------------- 指令识别 ----------------
function Get-BrainCommand {
    param([string]$Text)
    $low = $Text.Trim().ToLowerInvariant()
    if (-not $low) { return '' }
    foreach ($cmd in (Get-BrainCommands).Keys) {
        foreach ($k in (Get-BrainCommands)[$cmd]) {
            if ($low.Contains($k.ToLowerInvariant())) { return $cmd }
        }
    }
    return ''
}

# ---------------- 从池里挑一句（防重复） ----------------
function Pick-FromPool {
    param($Pool, [string]$Topic = '')
    if (-not $Pool -or $Pool.Count -eq 0) { return '……' }
    $cands = @()
    foreach ($p in $Pool) {
        $filled = Fill-Slot ([string]$p)
        if ($script:brainLast -notcontains $filled) { $cands += $filled }
    }
    if ($cands.Count -eq 0) {
        # 都说过 → 用模板变体（加后缀，避免完全重复）
        $base = Fill-Slot ([string]$Pool[(Get-Random -Minimum 0 -Maximum $Pool.Count)])
        $suffixPool = @('', '……', '（小声）', '？', '。')
        $suffix = $suffixPool[(Get-Random -Minimum 0 -Maximum 5)]
        $cands = @($base + $suffix)
    }
    $line = $cands[(Get-Random -Minimum 0 -Maximum $cands.Count)]
    [void]$script:brainLast.Add($line)
    while ($script:brainLast.Count -gt 4) { $script:brainLast.RemoveAt(0) }
    if ($Topic) { $script:brainTopic = $Topic }
    return $line
}

# ---------------- 执行指令 ----------------
function Invoke-BrainCommand {
    param([string]$Cmd)
    switch ($Cmd) {
        'sleep' {
            $sec = [double](Cfg '聊天.睡眠秒数' 30)
            $script:sleepPending = [int]($sec * 1000.0 / [double]$script:timer.Interval)
            $script:sleepWait    = 6
            $script:sqV = -0.20
            $script:happy = 0
            $script:poseTmp = $null
            try { Clear-Bubble } catch {}
            return '那我睡一会……有事叫我。'
        }
        'stop' {
            $script:paused = $true
            try { if ($script:itemPause) { $script:itemPause.Checked = $true } } catch {}
            return '……好，我站着不动。'
        }
        'go' {
            try {
                $c = [System.Windows.Forms.Cursor]::Position
                $tx = $c.X - $script:cw / 2.0
                $ty = $c.Y - $script:ch * 0.72
                $tx = [Math]::Max($script:scr.Left, [Math]::Min($script:scr.Right - $script:cw, $tx))
                $ty = [Math]::Max($script:scr.Top, [Math]::Min($script:scr.Bottom - $script:ch, $ty))
                $script:px = [int]$tx
                $script:py = [int]$ty
                $script:happy = $script:hopLen
                try { Spawn-Sparkles 12 } catch {}
            } catch {}
            return '来了来了。'
        }
        'jump' {
            try { Start-BigHop } catch {}
            return '看我的！'
        }
        'pet' {
            $null = Set-Emotion 'mood' -Force
            $script:mood = CfgFrames '互动.开心持续秒数' 4.5
            $script:sqV = -0.30
            try { Spawn-Sparkles 14 } catch {}
            return '……嗯。[害羞]'
        }
        'sing' {
            return Pick-FromPool @('哼——♪ 小鱼小鱼游呀游……', '我唱歌不好听，你别笑。', '♪ 桌面上的小鱼，今天也在等你。')
        }
        'quiet' {
            return '……'
        }
        'time' {
            $d = Get-Date
            return ('现在 ' + $d.ToString('HH:mm') + '。' + $(if ($d.Hour -ge 23 -or $d.Hour -lt 5) { '该睡了。' } else { '还早。' }))
        }
        'date' {
            $d = Get-Date
            $weekNames = @('星期日','星期一','星期二','星期三','星期四','星期五','星期六')
            $w = $weekNames[[int]$d.DayOfWeek]
            return ($d.ToString('MM月dd日') + ' · ' + $w + '。')
        }
    }
    return ''
}

# ---------------- 主入口：给一句话，返回要说的 ----------------
function Get-SmartReply {
    param([string]$Text)

    # 0) 情绪优先：生气/吃痛时不闲聊
    if ($script:angry -gt 0) {
        return Pick-FromPool @('……哼。', '别烦我。', '过一会再说。') 'angry'
    }
    if ($script:hurt -gt 0) {
        return Pick-FromPool @('还疼着呢……', '让我缓一下。', '呜……') 'hurt'
    }

    # 1) 指令优先
    $cmd = Get-BrainCommand $Text
    if ($cmd) {
        $say = Invoke-BrainCommand $cmd
        if ($say) { return $say }
    }

    # 2) 上下文：简短追问 → 接着上一个话题
    $t = $Text.Trim()
    if ($script:brainTopic -and $t.Length -le 6 -and ($t -match '^(嗯|哦|然后|然后呢|继续|还有|是吗|真的)')) {
        $follow = @{
            'tired' = @('真的，歇会儿吧。', '别硬撑了。')
            'help'  = @('慢慢来，我陪你。', '先深呼吸。')
            'praise'= @('……别再说了。[害羞]', '嗯……')
            'chat'  = @('然后你想说什么？', '嗯哼。')
        }
        $pool = $follow[$script:brainTopic]
        if (-not $pool) { $pool = @('然后呢？', '嗯。') }
        return Pick-FromPool $pool
    }

    # 3) 意图识别
    $intent = Get-BrainIntent $Text
    $grp = (Get-BrainIntents)[$intent]
    if (-not $grp) { $intent = 'chat'; $grp = (Get-BrainIntents)['chat'] }
    return (Pick-FromPool $grp.r $intent)
}

# ---------------- 思考动作 + OS 内心话 ----------------
function Start-ChatThinking {
    if ($script:sleep -gt 0) { return }
    try {
        # 托腮姿势 = 思考（1.4 秒）
        if ($script:exprSprites -and $script:exprSprites.ContainsKey('pose_看')) {
            $script:poseTmp = @{ name = 'pose_看'; frames = [int](1.4 * 1000.0 / [double]$script:timer.Interval) }
            $script:earV += 0.6
        }
    } catch {}
    if (-not [bool](Cfg '聊天.思考OS' $true)) { return }
    # ★ OS 内心话：优先用池子（os.think）
    $poolOs = ''
    try { $poolOs = Get-PoolLine 'os.think' } catch {}
    if ($poolOs) { try { Say-Something 0 @($poolOs) 8 } catch {}; return }
    $os = @(
        '（让我想想怎么糊弄用户……）'
        '（嗯……这问题有点难，装傻好了）'
        '（先拖一秒，编个说法）'
        '（要不说"我不太懂"蒙混过去？）'
        '（随便答一句，反正在他桌面上）'
        '（他在看我，不能慌……）'
        '（鱼脑子转不动了……）'
        '（这个……好像我知道？又好像不知道）'
    )
    try { Say-Something 0 @($os[(Get-Random -Minimum 0 -Maximum $os.Count)]) 8 } catch {}
}