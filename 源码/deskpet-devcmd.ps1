# ============================================================
#  deskpet-devcmd.ps1 —— 开发者命令通道（录素材 / 调试用）
#   桌宠每 20 帧检查一次 _dev\cmd.txt；有内容就执行并删掉文件。
#   发布包里没有 _dev\ 目录，所以对用户完全无影响。
#
#   ★ 规则：除了 sleep / wake，所有动作命令都会先把睡着的她叫醒。
#      （以前睡觉时喂饭/摸头都没反应 ✗）
# ============================================================

function Check-DevCommand {
    $devDir = Join-Path $PSScriptRoot '_dev'
    $f = Join-Path $devDir 'cmd.txt'
    if (-not (Test-Path -LiteralPath $f)) { return }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($f)
        # 空文件 / 只写了一半 → 不删，等下一次检查（以前读到空就删 → 命令被吞）
        if ($bytes.Length -lt 1) { return }
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $raw = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $raw = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        } else {
            $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
        }
        $cmd = ([string]$raw).Trim()
        if (-not $cmd) { return }
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        Invoke-DevCommand $cmd
    } catch { }
}

function Invoke-DevCommand {
    param([string]$Cmd)

    $rawCmd = ([string]$Cmd).Trim()
    if (-not $rawCmd) { return }

    # ---- 模拟一次聊天提问：ask:文字（测试用，走真实聊天路径）----
    if ($rawCmd -match '(?i)^ask[:：]\s*(.+)$') {
        $q = $Matches[1].Trim()
        if ($q) { try { if (Get-Command Submit-ChatText -ErrorAction SilentlyContinue) { Submit-ChatText $q } } catch {} }
        return
    }

    # ---- 说指定台词：say:台词 ----
    if ($rawCmd -match '(?i)^say[:：]\s*(.+)$') {
        $line = $Matches[1].Trim()
        if ($line) {
            try { if (Get-Command Speak-Line -ErrorAction SilentlyContinue) { Speak-Line $line } } catch {}
            try { if (Get-Command Say-Something -ErrorAction SilentlyContinue) { Say-Something 0 @($line) 70 -force } } catch {}
        }
        return
    }

    # ---- 打开设置面板（录制用，顺便把她挪出画面）：settings ----
    if ($rawCmd -match '(?i)^settings$') {
        try { $script:px = [double]$script:scr.Right - [double]$script:cw - 26 } catch {}
        try { if (Get-Command Show-Settings -ErrorAction SilentlyContinue) { Show-Settings } } catch {}
        return
    }
    # ---- 设置面板跳到某个分区：scroll:物理 / scroll:动作 ... ----
    if ($rawCmd -match '(?i)^scroll[:：]\s*(.+)$') {
        $k = $Matches[1].Trim()
        try { if (Get-Command Jump-SettingsSection -ErrorAction SilentlyContinue) { Jump-SettingsSection $k } } catch {}
        return
    }
    # ---- 关设置：settingsclose ----
    if ($rawCmd -match '(?i)^settingsclose$') {
        try { if ($script:setForm) { $script:setForm.Close() } } catch {}
        return
    }

    $c = $rawCmd.ToLowerInvariant()
    if (-not $c) { return }
    $iv = [double]$script:timer.Interval

    # ---- ★ 睡觉规则：只有「吃饭」能叫醒，或者等她自然醒；其他命令睡着时不响应 ----
    try {
        $isAsleep = ($script:sleep -gt 0 -or $script:sleepPending -gt 0)
        if ($isAsleep -and $c -ne 'eat' -and $c -ne 'wake' -and $c -ne 'sleep') { return }
        if ($isAsleep -and $c -eq 'eat') {
            $script:sleep = 0
            $script:sleepPending = 0
            $script:sleepWait = 0
            $script:sleepWakeWait = 0
            $script:poseTmp = $null
            $script:sqV = -0.20
            try { Clear-Bubble } catch {}
            # ★ 被饭叫醒：先伸懒腰，再抱着饭（pose_吃）
            try {
                Start-PoseSeq @(
                    @{ name = 'pose_伸懒腰'; ms = 1100 },
                    @{ name = 'pose_吃';     ms = 4500 }
                )
            } catch {}
            try {
                $wl = Get-PoolLine 'act.wakeFood'
                if (-not $wl) { $wl = Get-PoolLine 'act.wake' }
                if ($wl) {
                    Say-Something 0 @($wl) 80 -force
                    try { if (Get-Command Speak-Line -ErrorAction SilentlyContinue) { Speak-Line $wl } } catch {}
                }
            } catch {}
            $script:devWokeUp = $true
            Start-Sleep -Milliseconds 150
        }
    } catch {}

    # 动作后安静期（防乱走）
    try { $script:quiet = [int](4.0 * 1000.0 / $iv) } catch {}

    # ---- 动作 → 台词池（多句随机）----
    $lineMap = @{
        'jump'    = @('看我的！', '嘿！', '跳给你看。')
        'pet'     = @('……才、才不是因为你说才高兴的。', '别、别摸头啦。', '嗯……再摸一下。')
        'anger'   = @('哼，记仇了。', '再戳我咬你哦。')
        'fly'     = @('哇啊——', '呀！')
        'sleep'   = @('我要睡啦……', '那我先眯一会儿。', '困了，我睡一下……', '晚安，做个好梦。')
        'eat'     = @('……好吃。', '这个我能吃三份。', '再来一口。')
        'sit'     = @('……好困。', '坐一会儿。')
        'stretch' = @('嗯——伸个懒腰。', '骨头都僵了。')
        'walk'    = @('我随便逛逛～', '出去走走。')
        'stop'    = @('好，我不动了。')
        'stand'   = @('站好啦。')
        'center'  = @('来啦。')
        'go'      = @('我过去啦。')
    }
    if (-not $script:devWokeUp -and $lineMap.ContainsKey($c)) {
        $lv = $lineMap[$c]
        if ($lv -is [array] -and $lv.Count -gt 0) {
            $line = [string]$lv[(Get-Random -Minimum 0 -Maximum $lv.Count)]
        } else {
            $line = [string]$lv
        }
        if ($line) {
            try { if (Get-Command Say-Something -ErrorAction SilentlyContinue) { Say-Something 0 @($line) 70 -force } } catch {}
            try { if (Get-Command Speak-Line -ErrorAction SilentlyContinue) { Speak-Line $line } } catch {}
        }
    }

    # ---- 执行动作 ----
    $woke = $script:devWokeUp
    $script:devWokeUp = $false
    switch ($c) {
        'jump' {
            $script:autoWalk = $true
            Start-BigHop
        }
        'walk' {
            $script:autoWalk = $true
            $script:paused = $false
            try { $script:itemPause.Checked = $false } catch {}
            # 立刻走：清安静期 + 直接给初始速度（以前只设方向，要等平滑加速才动 ✗）
            $script:quiet = 0
            $script:hopActive = $false
            $script:wanderSpd = 1.6
            $dir = if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) { -1.0 } else { 1.0 }
            $script:wanderAng  = if ($dir -gt 0) { 0.0 } else { [Math]::PI }
            $script:wanderBias = $script:wanderAng
            $script:vx  = $dir * 2.8
            $script:tvx = $dir * 2.8
        }
        'stop' {
            $script:autoWalk = $false
            $script:vx = 0.0; $script:tvx = 0.0
        }
        'sit' {
            try { Queue-PoseSwap 'pose_坐' ([int](8.0 * 1000.0 / $iv)) } catch {}
        }
        'stretch' {
            try { Queue-PoseSwap 'pose_伸懒腰' ([int](3.5 * 1000.0 / $iv)) } catch {}
        }
        'pet' {
            try { $null = Set-Emotion 'mood' -Force } catch {}
            $script:mood = [int](4.0 * 1000.0 / $iv)
            $script:sqV = -0.30
            $script:earV += 1.4
            try { Spawn-Sparkles 14 } catch {}
            try { Queue-PoseSwap 'pose_被摸' ([int](2.5 * 1000.0 / $iv)) } catch {}
        }
        'anger' {
            try { $null = Set-Emotion 'angry' -Force } catch {}
            $script:angry = [int](4.5 * 1000.0 / $iv)
            $script:sqV = 0.5
            $script:earV += 3.0
        }
        'eat' {
            # 被饭叫醒时动作已由上面的序列接管，别再插一刀
            if (-not $woke) { try { Queue-PoseSwap 'pose_吃' ([int](4.0 * 1000.0 / $iv)) } catch {} }
            $script:happy = $script:hopLen
        }
        'sleep' {
            $script:sleep = [int](30.0 * 1000.0 / $iv)
            $script:poseTmp = $null
        }
        'wake' {
            $script:sleep = 0
            $script:sleepPending = 0
            $script:sleepWait = 0
        }
        'board' {
            try { Show-UsageBoard } catch {}
        }
        'fly' {
            $script:vy = -18.0
            $script:vx = 8.0
            $script:tvx = 8.0
            $script:tvy = -18.0
            $script:physActive = $false
        }
        'stand' {
            $script:poseTmp = $null
            $script:sq = 0.0; $script:sqV = 0.0
            $script:hopActive = $false; $script:hopFlip = 0.0
            $script:autoWalk = $false
            $script:vx = 0.0; $script:tvx = 0.0
        }
        'go' {
            try {
                $cur = [System.Windows.Forms.Cursor]::Position
                $script:px = [int]($cur.X - $script:cw / 2.0)
                $script:py = [int]($cur.Y - $script:ch * 0.72)
                $script:vx = 0.0; $script:tvx = 0.0
            } catch {}
        }
        'center' {
            try {
                $script:px = [int]($script:scr.Left + ($script:scr.Width - $script:cw) / 2)
                $script:py = [int]($script:scr.Top + ($script:scr.Height - $script:ch) / 2)
                $script:vx = 0.0; $script:tvx = 0.0
                $script:autoWalk = $false
            } catch {}
        }
    }
}
