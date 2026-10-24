# ============================================================
#  deskpet-chat.ps1 —— 聊天模块（离线版 / API 版共用一套 UI）
#  被 deskpet.ps1 dot-source 引入，共享 $script: 作用域
#  作者备注：先跑离线版验证手感，接 key 后把 模式 改成 api 即可
# ============================================================

# ---------------- 状态 ----------------
$script:chatForm      = $null
$script:chatBox       = $null
$script:chatTimer     = $null
$script:chatBusy      = $false      # 正在等回复
$script:chatDelay     = 0           # 离线模拟思考（帧）
$script:chatTask      = $null       # 直连异步任务
$script:chatClient    = $null       # 直连 HttpClient（用完释放）
$script:chatFull      = ''          # 完整回复文本
$script:chatShown     = 0           # 已显示字数
$script:chatHold      = 0           # 打完后停留帧
$script:chatHistory   = New-Object System.Collections.ArrayList
$script:chatEnable    = [bool](Cfg '聊天.启用' $true)
$script:chatMode      = [string](Cfg '聊天.模式' 'offline')
$script:chatThinkSec  = [double](Cfg '聊天.思考秒数' 0.7)
$script:chatReplyPool = @()
$script:chatKeyword   = $null

# ---------------- 台词库（嘴硬心软） ----------------
$script:chatKeyword = @(
    @{ k = @('可爱','好看','喜欢','漂亮','厉害','棒');                r = @('……才、才不是因为你说才这样的。[害羞]','哼，这还用你说。[害羞]','别夸了，会、会当真的。') },
    @{ k = @('笨','丑','滚','讨厌','烦');                             r = @('你说什么？再说一遍试试。[生气]','……记仇了。[生气]') },
    @{ k = @('名字','你叫','叫什么');                                 r = @('小鲸鱼。不许喊错。','叫我小鲸鱼就行，别乱起外号。') },
    @{ k = @('你是谁','什么','介绍');                                 r = @('小鲸鱼，住你桌面上的。会走会说话，还会生气。','我？一个自己做的桌面宠物。别小看我。') },
    @{ k = @('吃','饿','饭','零食');                                  r = @('饿了就去吃啊，看我干嘛。','有零食分我一半？') },
    @{ k = @('睡','困','熬夜','几点');                                r = @('几点了还不睡，明天起不来别怪我。','去睡吧，我帮你看着桌面。') },
    @{ k = @('摸','撸','揉');                                         r = @('摸一下就好了啊，别一直摸。','……轻点。[害羞]') },
    @{ k = @('谢谢','thanks');                                        r = @('……不客气。','不用谢，顺手的事。') },
    @{ k = @('拜拜','再见','走了','晚安');                            r = @('走了？那……早点回来。','晚安。别熬夜。') },
    @{ k = @('你好','在吗','嗨','hi','hello');                       r = @('……嗯，我在。干嘛。','在的在的，别喊那么大声。','你终于想起我了？') }
)
$script:chatReplyPool = @(
    '嗯。然后呢？',
    '……我听着呢。',
    '哦，这样啊。',
    '你今天话挺多。',
    '哼，随便你怎么说。',
    '说完了？那我继续发呆了。'
)

# ---------------- 取一句回复（离线） ----------------
function Get-OfflineReply {
    param([string]$Text)
    $t = $Text.Trim()
    if (-not $t) { return '……你想说什么？' }
    foreach ($grp in $script:chatKeyword) {
        foreach ($kw in $grp.k) {
            if ($t -like "*$kw*") {
                $arr = $grp.r
                return $arr[(Get-Random -Minimum 0 -Maximum $arr.Count)]
            }
        }
    }
    return $script:chatReplyPool[(Get-Random -Minimum 0 -Maximum $script:chatReplyPool.Count)]
}

# ---------------- 解析表情标签 ----------------
function Invoke-ChatEmotion {
    param([string]$Text)
    $out = $Text
    if ($out -match '\[(开心|高兴)\]') {
        $script:mood = [int](CfgFrames '互动.开心持续秒数' 4.5)
        $script:happy = $script:hopLen
        try { Spawn-Sparkles 14 } catch {}
    }
    elseif ($out -match '\[(害羞)\]') {
        $script:shy = [int](CfgFrames '互动.害羞持续秒数' 4.0)
    }
    elseif ($out -match '\[(生气)\]') {
        $script:angry = [int](CfgFrames '互动.生气持续秒数' 4.2)
    }
    elseif ($out -match '\[(惊讶)\]') {
        $script:surprise = 26
    }
    elseif ($out -match '\[(委屈|伤心)\]') {
        $script:hurt = [int](CfgFrames '互动.吃痛持续秒数' 3.0)
    }
    $out = $out -replace '\[[^\]]{1,6}\]', ''
    return $out.Trim()
}

# ---------------- 人设 + 当前状态（给 API 的 system prompt） ----------------
function Get-ChatPersonaText {
    # 优先读 人设\小鲸鱼.txt（用户可以自己改），没有就用内置默认
    try {
        $cfgPath = [string](Cfg '聊天.人设文件' '')
        if ($cfgPath -and (Test-Path -LiteralPath $cfgPath)) {
            $txt = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
            if ($txt -and $txt.Trim().Length -gt 10) { return $txt.Trim() }
        }
        $defFile = Join-Path $PSScriptRoot '人设\小鲸鱼.txt'
        if (Test-Path -LiteralPath $defFile) {
            $txt = Get-Content -LiteralPath $defFile -Raw -Encoding UTF8
            if ($txt -and $txt.Trim().Length -gt 10) { return $txt.Trim() }
        }
    } catch {}
    return '你是"小鲸鱼"，住在用户 Windows 桌面上的小鲸鱼女仆。性格：有点懒、嘴硬心软、爱吃醋、喜欢被摸头、偶尔嘴很毒但会心软。'
}

function Get-PetStateText {
    $parts = @()
    $h = (Get-Date).Hour
    $slot = if ($h -lt 5) { '凌晨' } elseif ($h -lt 9) { '早上' } elseif ($h -lt 12) { '上午' } elseif ($h -lt 18) { '下午' } elseif ($h -lt 23) { '晚上' } else { '深夜' }
    $parts += ('现在是' + $slot + '。')
    if ($script:sleep -gt 0) { $parts += '你正在睡觉（被人叫起来了）。' }
    if ($script:hurt  -gt 0) { $parts += '你刚摔了一跤/被撞疼了，正委屈着。' }
    elseif ($script:angry -gt 0) { $parts += '你正在生气，说话带刺。' }
    elseif ($script:mood  -gt 0) { $parts += '你现在心情不错。' }
    elseif ($script:shy   -gt 0) { $parts += '你有点害羞。' }
    if ($script:petHeat -gt 2.5) { $parts += '刚被人连着戳了好几下，有点烦。' }
    try {
        if ((Get-Command Get-ToneState -ErrorAction SilentlyContinue)) {
            $ts = Get-ToneState
            if ($ts -eq 'hungry') { $parts += '你很饿，想让人喂你吃饭。' }
            elseif ($ts -eq 'sleepy') { $parts += '你困了。' }
            elseif ($ts -eq 'jealous') { $parts += '好久没人跟你说话了，有点吃醋。' }
        }
    } catch {}
    return ($parts -join '')
}

function Get-ChatSystemPrompt {
    $persona = Get-ChatPersonaText
    $state = Get-PetStateText
    $maxChars = [int](Cfg '聊天.回复字数上限' 40)
    if ($maxChars -lt 10) { $maxChars = 10 }
    $rules = @(
        '回复要求：',
        ('- 只说 1~2 句，总字数不超过 ' + $maxChars + ' 字；'),
        '- 用日常口语，像真人发语音那样，不要书面语；',
        '- 不要解释设定、不要列点、不要用 markdown、不要自称"AI"；',
        '- 不要主动反问一堆问题，最多反问一句；',
        '- 可以在句尾加一个表情标签：[开心] [害羞] [生气] [惊讶] [委屈]，也可以不加。'
    ) -join "`r`n"
    return ($persona + "`r`n`r`n[当前状态]`r`n" + $state + "`r`n`r`n" + $rules)
}
# ---------------- 显示气泡（打字机） ----------------
function Show-ChatLine {
    param([string]$Text, [int]$holdFrames = 0)
    $clean = Invoke-ChatEmotion $Text
    # ★ 太长就截断（保持"她说话短"的风格）
    try {
        $maxLen = [int](Cfg '聊天.回复字数上限' 40)
        if ($maxLen -gt 10 -and $clean.Length -gt $maxLen) {
            $cut = $clean.Substring(0, $maxLen)
            $idx = [Math]::Max($cut.LastIndexOf('。'), [Math]::Max($cut.LastIndexOf('！'), $cut.LastIndexOf('？')))
            if ($idx -ge 8) { $clean = $cut.Substring(0, $idx + 1) } else { $clean = $cut + '…' }
        }
    } catch {}
    if (-not $clean) { $clean = '……' }
    $script:chatFull  = $clean
    $script:chatShown = 0
    $fps = 1000.0 / $script:timer.Interval
    $script:chatHold = if ($holdFrames -gt 0) { $holdFrames } else { [int]([double](Cfg '聊天.气泡停留秒数' 7.5) * $fps) }
    $script:bubbleText_ = '…'
    try { Render-BubbleBitmap '…' } catch { Log-Err $_ 'chat-think' }
    $script:bubbleTotal = [Math]::Max(2, $script:chatHold + $script:chatFull.Length * 3)
    $script:bubbleLife  = $script:bubbleTotal
}

# ---------------- 提交输入 ----------------
function Submit-ChatText {
    param([string]$Text)
    $t = ($Text -as [string]).Trim()
    # ★ 睡觉时聊天不唤醒她（只有喂饭能叫醒）→ 直接不理
    if ($script:sleep -gt 0) {
        Close-ChatInput
        try { Say-Something 0 @('（睡着了……听不见）', 'zzz……') 5 } catch {}
        return
    }
    Close-ChatInput
    if (-not $t) { return }
    # ★ 问余额/用量：直接用本地真实数据回答（不走 LLM，避免被敷衍）
    #   走 Say-Something 是为了复用「余额卡片气泡」（大号 ¥ + 今日已用），显示几秒自动消失
    try {
        if ($t -match '余额|用量|花了多少|花多少|花了多少|token|次数|充值|还能聊') {
            $u = Get-DshUsage
            if ($u -and $u.ok) {
                $bal  = [math]::Round([double]$u.balance, 2)
                $cost = [math]::Round([double]$u.cost, 2)
                $line = '余额还剩 ¥' + $bal + '，今天花了 ¥' + $cost + '，' + [int]$u.count + ' 次。'
                try { Say-Something 0 @($line) 150 -force } catch {}
                try { [void]$script:chatHistory.Add(@{ role = 'assistant'; content = $line }) } catch {}
                $script:chatBusy = $false
                return
            }
        }
    } catch {}
    try { if (Get-Command Mark-Chat -ErrorAction SilentlyContinue) { Mark-Chat } } catch {}
    [void]$script:chatHistory.Add(@{ role = 'user'; content = $t })
    $script:chatBusy = $true

    # ★ 语义近似：先测意图（token 梗 / 睡觉 / 累 等，不要求精确关键词）
    try {
        $sem = Get-SemanticIntent $t
        if ($sem.intent -eq 'token' -and (Test-PoolHas 'pool.token')) {
            $line = Get-PoolLine 'pool.token'
            if ($line) { $script:pendingReply = $line; $script:chatDelay = 6; return }
        }
        if ($sem.intent -in @('sleep', 'tired')) {
            $poolName = if ($sem.intent -eq 'sleep') { 'cond.sleepTalk' } else { 'cond.tiredTalk' }
            if (Test-PoolHas $poolName) {
                $line = Get-PoolLine $poolName
                if ($line) { $script:pendingReply = $line; $script:chatDelay = 10; return }
            }
        }
    } catch {}

    # ★ 先思考（托腮 + OS 内心话）
    try { Start-ChatThinking } catch {}

    $beMode = [string](Cfg '聊天.模式' 'offline')
    if ($script:chatMode -eq 'api' -or $beMode -ne 'offline') {
        Start-ApiReply $t
    }
    else {
        $fps = 1000.0 / $script:timer.Interval
        $script:chatDelay = [int]([Math]::Max(3, $script:chatThinkSec * $fps))
        $script:chatTask = $null
        $script:pendingReply = Get-SmartReply $t
    }
}

# ---------------- 后端解析（offline / direct） ----------------
# 真正的解析在 deskpet-llm.ps1（预设 / 地址 / 模型 / key），这里只做兜底
function Get-ChatBackend {
    try {
        if (Get-Command Get-LlmBackend -ErrorAction SilentlyContinue) { return (Get-LlmBackend) }
    } catch { }
    return @{ mode = 'offline'; rawMode = 'offline'; preset = ''; presetName = '离线'; url = ''; model = ''; key = ''; needKey = $false }
}

# ---------------- 测试连接（设置面板用） ----------------
function Test-ChatBackend {
    try {
        if (Get-Command Test-LlmBackend -ErrorAction SilentlyContinue) { return (Test-LlmBackend) }
    } catch { }
    return @{ ok = $false; msg = '聊天直连模块没加载（deskpet-llm.ps1）' }
}

function Start-ApiReply {
    param([string]$Text)
    try {
        $be = Get-ChatBackend
        $script:chatBackendMode = [string]$be.mode

        # ★ 发不出去的情况统一走离线台词：没配好 / 刚失败过（冷却）/ 免费额度用完
        $why = ''
        if ($be.mode -eq 'offline') { $why = 'offline' }
        elseif (-not $be.url) { $why = 'nourl' }
        elseif ($be.needKey -and -not $be.key) { $why = 'nokey' }
        elseif ((Get-LlmDownRemainMs) -gt 0) { $why = 'cooldown' }
        if ($why) {
            $script:chatBusy = $false
            $script:chatDelay = 2
            $script:pendingReply = Get-SmartReply $Text
            return
        }

        # ★ 每日上限（只对要花钱的后端；Ollama 本地免费不限制）
        if ($be.needKey) {
            $dailyMax = [int](Cfg '聊天.每日上限' 200)
            if ($dailyMax -gt 0) {
                $usage = Get-ApiUsage
                if ($usage.count -ge $dailyMax) {
                    $script:chatBusy = $false
                    Show-ChatLine '今天说得够多啦，明天再聊。'
                    return
                }
            }
        }

        # ★ 节流：间隔太短直接回离线台词
        $nowMs = [Environment]::TickCount
        $gapMs = [double](Cfg '聊天.最短间隔秒数' 1.5) * 1000.0
        if (($nowMs - $script:chatLastApiMs) -lt $gapMs) {
            $script:chatBusy = $false
            $script:pendingReply = Get-SmartReply $Text
            return
        }
        $script:chatLastApiMs = $nowMs
        $script:chatLastUser = [string]$Text

        # ★ 组包（人设 + 最近 N 条历史 + 这句话）→ 异步发出去
        $b = New-LlmBody -UserText $Text
        if (-not $b.ok) {
            $script:chatBusy = $false
            $script:chatDelay = 2
            $script:pendingReply = Get-SmartReply $Text
            return
        }
        $h = Start-LlmTask -Backend $b.backend -Json $b.json
        $script:chatClient = $h.client
        $script:chatTask = $h.task
        $script:pendingReply = ''
    }
    catch {
        try { Log-Err $_ 'chat-api' } catch {}
        $script:chatBusy = $false
        $script:chatDelay = 2
        $script:pendingReply = Get-SmartReply ([string]$script:chatLastUser)
        try { Set-LlmDown 60000 } catch {}
    }
}

# ---------------- 输入框 ----------------
function Show-ChatInput {
    if ($script:chatForm) { try { $script:chatForm.Activate() } catch {}; return }
    if (-not $script:chatEnable) {
        try { Say-Something 0 @('聊天关着呢。右键打开。') } catch {}
        return
    }

    $w = 470; $h = 58
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.ShowInTaskbar   = $false
    $f.TopMost         = $true
    $f.StartPosition   = 'Manual'
    $f.BackColor       = [System.Drawing.Color]::FromArgb(255, 250, 253, 255)
    $f.ClientSize      = [System.Drawing.Size]::new($w, $h)
    $f.Opacity         = 0.97

    # 圆角
    $rp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rr = 16
    $rp.AddArc(0, 0, $rr, $rr, 180, 90)
    $rp.AddArc(($w - $rr - 1), 0, $rr, $rr, 270, 90)
    $rp.AddArc(($w - $rr - 1), ($h - $rr - 1), $rr, $rr, 0, 90)
    $rp.AddArc(0, ($h - $rr - 1), $rr, $rr, 90, 90)
    $rp.CloseFigure()
    $f.Region = New-Object System.Drawing.Region($rp)
    $rp.Dispose()

    # 顶部细边（用简单的 Padding + 背景色差代替自绘，避免闭包捕获局部变量的问题）
    $f.Padding = New-Object System.Windows.Forms.Padding(2)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.BorderStyle = 'None'
    $tb.Font        = UiFont 13 0
    $tb.ForeColor   = [System.Drawing.Color]::FromArgb(255, 38, 56, 104)
    $tb.BackColor   = [System.Drawing.Color]::FromArgb(255, 250, 253, 255)
    $tb.Location    = New-Object System.Drawing.Point(20, 16)
    $tb.Size        = New-Object System.Drawing.Size(($w - 40), 28)
    $tb.Text        = ''
    $f.Controls.Add($tb)

    # 位置：屏幕下方居中
    $scr = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $f.Location = New-Object System.Drawing.Point(
        [int]($scr.Left + ($scr.Width - $w) / 2),
        [int]($scr.Top + $scr.Height - $h - 120))

    $tb.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            $txt = $s.Text
            Submit-ChatText $txt
        }
        elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            Close-ChatInput
        }
    })
    $f.Add_Shown({ try { $tb.Focus() } catch {} })

    $script:chatForm = $f
    $script:chatBox  = $tb
    $f.Show()
}

function Close-ChatInput {
    if ($script:chatForm) {
        try { $script:chatForm.Close(); $script:chatForm.Dispose() } catch {}
        $script:chatForm = $null
        $script:chatBox  = $null
    }
}

# ---------------- 收尾一次直连回复（定时器每帧调用；也可以单独测） ----------------
function Update-ChatTask {
    if (-not $script:chatBusy) { return }
    if ($script:chatTask -eq $null) { return }
    if (-not $script:chatTask.IsCompleted) { return }
    $script:chatBusy = $false
    $r = Read-LlmTask -Task $script:chatTask
    $script:chatTask = $null
    try { if ($script:chatClient) { $script:chatClient.Dispose() } } catch {}
    $script:chatClient = $null
    $txt = ''
    if ($r.ok) {
        $txt = [string]$r.text
        try { Add-ApiUsage -PromptTokens ([int]$r.promptTokens) -CompletionTokens ([int]$r.completionTokens) } catch {}
        try { Clear-LlmDown } catch {}
    }
    else {
        # ★ 失败自动回离线台词：不显示技术错误，并冷却 60 秒（不然每句都等超时）
        try { Set-LlmDown 60000 } catch {}
        $script:chatBackendMode = 'offline'
        $txt = Get-SmartReply ([string]$script:chatLastUser)
        try { if (Get-Command Log-Err -ErrorAction SilentlyContinue) { Log-Err ([Exception]::new([string]$r.err)) 'chat-llm' } } catch {}
    }
    if (-not $txt) { $txt = '……' }
    [void]$script:chatHistory.Add(@{ role = 'assistant'; content = $txt })
    # 历史别无限长：只留最近 40 条
    try { while ($script:chatHistory.Count -gt 40) { $script:chatHistory.RemoveAt(0) } } catch {}
    Show-ChatLine $txt
}

# ---------------- 聊天专用定时器（打字机 / 异步轮询） ----------------
function Start-ChatTimer {
    if ($script:chatTimer) { return }
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = $script:timer.Interval
    $t.Add_Tick({
        try {
            # ① 离线延迟
            if ($script:chatBusy -and $script:chatTask -eq $null -and $script:chatDelay -gt 0) {
                $script:chatDelay--
                if ($script:chatDelay -le 0) {
                    Show-ChatLine ([string]$script:pendingReply)
                    $script:chatBusy = $false
                }
                return
            }
            # ② 直连 API 异步任务
            if ($script:chatBusy -and $script:chatTask -ne $null) {
                Update-ChatTask
                return
            }
            # ③ 打字机
            if ($script:chatFull -and $script:chatShown -lt $script:chatFull.Length) {
                $step = [int](Cfg '聊天.打字速度字数' 2)
                if ($step -lt 1) { $step = 1 }
                $script:chatShown = [Math]::Min($script:chatFull.Length, $script:chatShown + $step)
                $part = $script:chatFull.Substring(0, $script:chatShown)
                $script:bubbleText_ = $part
                try { Render-BubbleBitmap $part } catch {}
                $script:bubbleLife = [Math]::Max($script:bubbleLife, 30)
                return
            }
        }
        catch { Log-Err $_ 'chat-tick' }
    })
    $t.Start()
    $script:chatTimer = $t
}

# ---------------- 右键菜单里的聊天开关 ----------------
function Toggle-ChatEnable {
    param([bool]$on)
    $script:chatEnable = $on
    if (-not $on) {
        Close-ChatInput
        Show-ChatLine '那我先不聊天了。'
    }
}
