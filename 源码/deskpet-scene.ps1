# ============================================================
#  deskpet-scene.ps1 —— 窗口感知 + 场景台词（本地，只读标题）
#   能力：知道你在用什么软件 → 说相关的话
#   原则：不确定就不说话（宁可不吭声，也不说错）
#   隐私：只读前台窗口标题 + 进程名，不读内容、不上传、不记录
# ============================================================

$script:sceneLast   = ''       # 上次说话的场景
$script:sceneLastAt = -99999   # 上次说话时刻
$script:sceneNext   = 0        # 下次轮询时刻
$script:sceneCur    = ''       # 当前场景
$script:sceneSince  = 0        # 进入当前场景的时刻
$script:sceneIdleAt = 0        # 同场景下次可说话时刻
$script:scenePending  = $false  # 上次被抢话，待重试
$script:sceneRetryAt = 0         # 重试时刻
$script:sceneQuietUntil = 0     # 场景说完后的静音期（认亲让行）
$script:dsQuietUntil    = 0     # 认亲说完后的静音期（场景让行）
$script:sceneTitle  = ''       # 当前标题（仅内存，不落盘）
$script:sceneLib    = $null

# ---------------- 场景库 ----------------
function Get-SceneLib {
    if ($script:sceneLib) { return $script:sceneLib }
    $script:sceneLib = [ordered]@{
        'code' = @{
            name = '写代码'
            proc = @('code', 'devenv', 'pycharm64', 'idea64', 'clion64', 'sublime_text', 'notepad++', 'cursor', 'trae', 'fleet', 'rider64', 'webstorm64', 'goland64')
            title = @('visual studio', 'vscode', 'visual studio code', 'pycharm', 'intellij', 'clion', 'sublime', 'cursor')
            lines = @(
                '在写代码呀。这个点也要记得歇。'
                '别熬太深，bug 明天还在。'
                '写完了让我看看？……看不懂。'
                '这段代码你写得完吗？写不完明天也行。'
                '编译过了吗？过了就休息一下。'
                '坐久了，站起来动一下。'
                '眼睛累不累？眨两下。'
                '你写的东西我一个字都看不懂，但我守着。'
                '记得存盘。没存别说我没提醒。'
                '改到一半记得存个档，别硬改。'
                '写不出来就先走开十分钟。'
                '又跟代码较劲呢。'
                '这个点了，晚饭吃了吗。'
                '我看不懂，但你别熬太晚。'
                '跑通了就起来走走，别连坐三小时。'
            )
        }
        'blend' = @{
            name = '建模'
            proc = @('blender')
            title = @('blender')
            lines = @(
                '又在建模？别一口气做太久。'
                '别一直站着调视角，坐一会儿。'
                '渲染要多久？我陪你等。'
                '建模很费眼睛，记得抬头看看远处。'
            )
        }
        'art' = @{
            name = '修图'
            proc = @('photoshop', 'krita', 'clipstudiopaint', 'sai', 'aseprite', 'illustrator', 'affinity designer')
            title = @('photoshop', 'krita', 'clip studio', 'aseprite', 'illustrator')
            lines = @(
                '在画画？那我安静点。'
                '画很久了吧，手腕歇一下。'
                '手绘和 AI 哪个快？……都好。'
            )
        }
        'video' = @{
            name = '看视频'
            proc = @('bilibili', 'potplayer', 'vlc', 'iqiyi', 'youku', 'qqlive', 'douyin', 'kwai')
            title = @('bilibili', '哔哩哔哩', 'youtube', 'potplayer', 'vlc', '爱奇艺', '优酷', '腾讯视频', '抖音', '快手')
            lines = @(
                '又在刷视频……眼睛该休息了。'
                '看什么好看的？分我一眼。'
                '看太久眼睛会干。'
                '这次看完了就干活？'
            )
        }
        'doc' = @{
            name = '看文档'
            proc = @('winword', 'excel', 'powerpnt', 'wps', 'acrobat', 'acrord32', 'sumatrapdf', 'notion', 'typora', 'obsidian', 'onenote')
            title = @('word', 'excel', 'powerpoint', 'wps', 'pdf', 'acrobat', 'notion', 'typora', 'obsidian')
            lines = @(
                '在看书还是写作业？'
                '文档看久了眼睛会花。'
                '写的什么？给我也讲讲。'
            )
        }
        'chat' = @{
            name = '聊天'
            proc = @('wechat', 'weixin', 'qq', 'telegram', 'discord', 'dingtalk', 'feishu', 'lark', 'slack', 'whatsapp')
            title = @('微信', 'wechat', 'qq', 'telegram', 'discord', '钉钉', '飞书')
            lines = @(
                '跟谁聊呢？……不是我吧。'
                '聊这么久，手都累了吧。'
                '我也能聊啊。'
            )
        }
        'term' = @{
            name = '命令行'
            proc = @('windowsterminal', 'powershell', 'pwsh', 'cmd', 'conhost', 'mintty', 'wt')
            title = @('terminal', 'powershell', 'cmd', '命令提示符', 'windows terminal')
            lines = @(
                '在敲命令？别删库。'
                '看的懂吗？看不懂我陪你。'
                '命令行看着好吓人。'
            )
        }
        'game' = @{
            name = '游戏'
            proc = @('steam', 'steamwebhelper', 'minecraft', 'leagueclient', 'yuanshen', 'genshinimpact', 'battle.net', 'epicgameslauncher')
            title = @('steam', 'minecraft', 'league of legends', '原神', '英雄联盟')
            lines = @(
                '玩一会儿就回来啊。'
                '游戏赢了没？'
                '别通宵。'
            )
        }
        'browser' = @{
            name = '浏览器'
            proc = @('chrome', 'msedge', 'firefox', 'brave', 'opera', 'iexplore', 'safari')
            title = @('chrome', 'microsoft edge', 'firefox', 'brave')
            lines = @(
                '在查东西？查到没。'
                '浏览器开这么久了，还没查完？'
                '浏览器是个黑洞。'
            )
        }
        'music' = @{
            name = '听歌'
            proc = @('spotify', 'qqmusic', 'cloudmusic', 'foobar2000', 'musicbee', 'kugou')
            title = @('spotify', 'qq音乐', '网易云音乐', '酷狗')
            lines = @(
                '听的什么？也给我听。'
                '有音乐就舒服了。'
                '有歌听着，干活不累。'
            )
        }
        'files' = @{
            name = '翻文件'
            proc = @('explorer')
            title = @('文件资源管理器', 'file explorer', 'desktop')
            lines = @(
                '在找什么？要我帮你翻吗。'
                '这窗口堆这么久，还没弄完？'
            )
        }
    }
    # 允许配置覆盖（config.json 里 行为.场景感知.台词 可以加/改）
    try {
        $over = Cfg '行为.场景感知.台词' $null
        if ($over) {
            foreach ($k in $over.PSObject.Properties.Name) {
                if ($script:sceneLib.Contains($k)) {
                    $script:sceneLib[$k].lines = @($over.$k)
                }
            }
        }
    } catch {}
    return $script:sceneLib
}

# ---------------- 识别当前场景 ----------------
function Get-CurrentScene {
    param([string]$Title = '', [string]$Proc = '')
    if (-not $Title -and -not $Proc) {
        $info = ''
        try { $info = [LW]::ForegroundInfo() } catch { return @{ id = ''; name = '' } }
        if (-not $info) { return @{ id = ''; name = '' } }
        $parts = $info.Split([char]1)
        $Title = if ($parts.Count -ge 1) { $parts[0] } else { '' }
        $Proc  = if ($parts.Count -ge 2) { $parts[1] } else { '' }
    }
    $title = ([string]$Title).ToLowerInvariant()
    $proc  = ([string]$Proc).ToLowerInvariant()
    $script:sceneTitle = $title

    # 自己的窗口 → 不算场景
    if ($proc -eq 'powershell' -and $title -match 'deskpet') { return @{ id = ''; name = '' } }

    $lib = Get-SceneLib
    foreach ($id in $lib.Keys) {
        $sc = $lib[$id]
        # 进程名精确匹配（高置信）
        foreach ($p in $sc.proc) {
            if ($proc -eq $p) { return @{ id = $id; name = $sc.name; conf = 2 } }
        }
        # 标题包含（中置信）
        foreach ($t in $sc.title) {
            if ($title.Contains($t)) { return @{ id = $id; name = $sc.name; conf = 1 } }
        }
    }
    return @{ id = ''; name = ''; conf = 0 }
}

# ---------------- 轮询 + 场景切换立刻说话 ----------------
function Write-SceneDebug {
    param([string]$Msg)
    if (-not [bool](Cfg '行为.场景感知.调试日志' $false)) { return }
    try {
        "$(Get-Date -Format 'HH:mm:ss') $Msg" |
            Out-File -FilePath (Join-Path $PSScriptRoot 'deskpet-scene.log') -Append -Encoding utf8
    } catch {}
}

# ★ 首次进入某个场景时的「识别到」台词（change 用这个，之后同场景才用 lines）
function Get-SceneFirstLine {
    param([string]$SceneId)
    $m = @{
        'code'    = @('在写代码呀。这个点也要记得歇。', '又打开编辑器了，这次写什么。', '写代码的来了。')
        'blend'   = @('在建模呀。', 'Blender 开了，今天做什么。')
        'art'     = @('在画画？那我安静点。', '修图模式，我闭嘴。')
        'video'   = @('在看视频呀。', '刷视频被我抓到了。')
        'doc'     = @('在看文档？', '又在写作业吗。')
        'chat'    = @('在聊天呀，跟谁。', '聊天窗口开了，不是我吧。')
        'term'    = @('在敲命令？别删库。', '命令行窗口……我有点怕。')
        'game'    = @('在玩游戏呀。', '游戏开了，我安静看。')
        'browser' = @('在查东西？', '浏览器开了，在找什么。')
        'music'   = @('在听歌呀。', '有音乐就舒服了。')
        'files'   = @('在翻文件？', '这窗口堆这么久，还没弄完？')
    }
    try {
        if ($m.ContainsKey($SceneId)) {
            $arr = $m[$SceneId]
            if ($arr -and $arr.Count -gt 0) { return [string]$arr[(Get-Random -Minimum 0 -Maximum $arr.Count)] }
        }
    } catch {}
    return ''
}

function Say-SceneLine {
    param($SceneId, [string]$Why = 'change')
    $line = ''
    if ($Why -eq 'change') { try { $line = Get-SceneFirstLine $SceneId } catch {} }
    if (-not $line) {
        $lines = (Get-SceneLib)[$SceneId].lines
        if (-not $lines -or $lines.Count -eq 0) { return $false }
        $line = [string]$lines[(Get-Random -Minimum 0 -Maximum $lines.Count)]
    }
    try { $line = Fill-Slot $line } catch {}
    $script:sceneLast = $SceneId
    $before = [string]$script:bubbleText_
    # ★ 场景台词优先级提到 45，并【强制打断】自动闲聊（闲聊 prio=5）
    $holdSec = [double](Cfg '行为.场景感知.气泡停留秒数' 7)
    $hold = [int]($holdSec * 1000.0 / [double]$script:timer.Interval)
    # ★ 换场景时强制打断（原来会被说话锁挡掉，导致"切了窗口她不说话"）
    if ($Why -eq 'change') { try { Say-Something $hold @($line) 45 -force } catch { return $false } }
    else { try { Say-Something $hold @($line) 45 } catch { return $false } }
    if ([string]$script:bubbleText_ -eq $before) {
        Write-SceneDebug ('没说出来（场景=' + $SceneId + ' 台词=' + $line + '）')
        return $false
    }
    # ★ 场景台词占住说话权：气泡没消失前，普通闲聊不许顶掉
    $script:sayLock = $hold
    $script:sayLockPrio = 45

    # ★ 让她"注意到"这一刻：冒点星 + 耳朵动一下
    try { Spawn-Sparkles 8 } catch {}
    $script:earV += 1.4
    Write-SceneDebug ('说出来了：' + $line + '  她在(' + [int]$script:px + ',' + [int]$script:py + ')')
    if ([bool](Cfg '行为.场景感知.调试日志' $false)) {
        try {
            "$(Get-Date -Format 'HH:mm:ss') [$Why] 场景=$($SceneId) 标题=$($script:sceneTitle) 台词=$line" |
                Out-File -FilePath (Join-Path $PSScriptRoot 'deskpet-scene.log') -Append -Encoding utf8
        } catch {}
    }
    return $true
}

function Update-Scene {
    if (-not [bool](Cfg '行为.场景感知.启用' $true)) { return }
    if ($script:dragging -or $script:paused) { return }
    # ★ 启动前 15 秒不冒场景台词（开机时前台窗口不稳定，容易说错话）
    if ($script:tick -lt (CfgFrames '行为.场景感知.启动延迟秒数' 15)) { return }
    # ★ 情绪优先：生气/吃痛/睡觉时不冒场景台词（否则会"生气脸说日常话" ✗）
    if ($script:angry -gt 0 -or $script:hurt -gt 0 -or $script:sleep -gt 0) { return }
    $poll = CfgFrames '行为.场景感知.轮询秒数' 2
    if ($poll -lt 60) { $poll = 60 }
    if ($script:tick -lt $script:sceneNext) { return }
    $script:sceneNext = $script:tick + $poll


    $sc = Get-CurrentScene
    if (-not $sc.id) {
        # 不认识 → 防抖：连续 3 次才真正重置（避免焦点闪一下就把场景弄丢）
        $script:unknownCount++
        if ($script:unknownCount -ge 3 -and $script:sceneCur -ne '') {
            Write-SceneDebug ('未知场景，沉默。标题=' + $script:sceneTitle)
            $script:sceneCur = ''
            $script:scenePending = $false
        }
        return
    }
    $script:unknownCount = 0
    if ($sc.conf -lt 1) { return }

    $now = $script:tick
    $isNew = ($sc.id -ne $script:sceneCur)
    if (-not $isNew -and $script:tick -lt $script:dsQuietUntil) {
        Write-SceneDebug '认亲静音期内，跳过（同场景）'
        return
    }
    if ($isNew) {
        $script:sceneCur = $sc.id
        $script:sceneIdleAt = $now + (CfgFrames '行为.场景感知.检查秒数' 60)
        Write-SceneDebug ('切到场景=' + $sc.id + ' 标题=' + $script:sceneTitle + ' 置信=' + $sc.conf)
    }

    # ★ 被抢话后的重试窗口（8 秒内一直尝试，说出去为止）
    $retryOk = ($script:scenePending -and ($now -ge $script:sceneRetryAt))
    if (-not $isNew -and -not $retryOk -and ($now -lt $script:sceneIdleAt)) { return }

    # 最短说话间隔：换场景 8 秒、同场景 30 秒（可配）
    $gapNeed = if ($isNew -or $retryOk) { CfgFrames '行为.场景感知.换场景硬间隔秒数' 8 }
               else { CfgFrames '行为.场景感知.最短说话间隔秒数' 30 }
    if (($now - $script:sceneLastAt) -lt $gapNeed) {
        if ($isNew) {
            # ★ 换场景被间隔挡住 → 排一个"间隔到点就重试"，不丢失
            $script:scenePending = $true
            $script:sceneRetryAt = $script:sceneLastAt + $gapNeed
        }
        Write-SceneDebug ('间隔不足，稍后重试（场景=' + $sc.id + '）')
        return
    }

    if (-not $isNew -and -not $retryOk) {
        $script:sceneIdleAt = $now + (CfgFrames '行为.场景感知.检查秒数' 60)
        $prob2 = [double](Cfg '行为.场景感知.同场景概率百分比' 15)
        if ((Get-Random -Minimum 0.0 -Maximum 100.0) -gt $prob2) {
            Write-SceneDebug ('同场景概率未中，跳过（场景=' + $sc.id + '）')
            return
        }
    }
    elseif ($isNew) {
        $prob = [double](Cfg '行为.场景感知.换场景概率百分比' 90)
        if ((Get-Random -Minimum 0.0 -Maximum 100.0) -gt $prob) {
            Write-SceneDebug ('换场景概率未中（' + $sc.id + '）')
            return
        }
    }

    $ok = Say-SceneLine $sc.id $(if ($isNew) { 'change' } else { 'retry' })
    if ($ok) {
        $script:sceneLastAt = $now
        $script:scenePending = $false
        # ★ 说完场景台词后，20 秒内认亲不抢话（避免"又认亲又念场景"）
        $script:sceneQuietUntil = $now + (CfgFrames '行为.场景感知.说完静音秒数' 20)
    }
    else {
        # 被抢话（她正在说别的）→ 8 秒后重试
        $script:scenePending = $true
        $script:sceneRetryAt = $now + (CfgFrames '行为.场景感知.重试秒数' 8)
        Write-SceneDebug ('被抢话，8 秒后重试（场景=' + $sc.id + '）')
    }
}