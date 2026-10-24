# ============================================================
#  deskpet-board.ps1 —— 用量看板 v4（浅色卡片版）
#   · 奶油底 + 白卡 + 青绿强调色，和设置面板风格统一
#   · 数据只读 DSH 本地用量文件
# ============================================================

$script:boardForm  = $null
$script:boardTimer = $null
$script:boardCache = $null
$script:BOARD_W = 372
$script:BOARD_H = 470

function Format-Money2 { param($v) try { return ('¥' + [Math]::Round([double]$v, 2)) } catch { return '¥?' } }

function Get-BoardData {
    $u = @{ ok = $false; count = 0; tokens = 0; cost = 0.0; balance = 0.0 }
    try { $u = Get-DshUsage } catch {}
    $pet = @{ count = 0; tokens = 0 }
    try { $pet = Get-ApiUsage } catch {}
    $week = $null
    try { $week = Get-DshUsageWeek } catch {}
    $avg = 0.0
    if ($u.ok -and $u.count -gt 0 -and $u.cost -gt 0) { $avg = $u.cost / [double]$u.count }
    $left = 0
    if ($avg -gt 0) { $left = [int][Math]::Floor([double]$u.balance / $avg) }
    return @{ u = $u; pet = $pet; week = $week; avg = $avg; left = $left }
}

function Update-BoardTexts {
    if (-not $script:boardForm) { return }
    try { $script:boardCache = Get-BoardData; $script:boardForm.Invalidate() } catch {}
}

function Draw-BoardCanvas {
    param($g, $w, $h)
    $bd = $script:boardCache
    if (-not $bd) { $bd = Get-BoardData; $script:boardCache = $bd }
    $u = $bd.u; $pet = $bd.pet

    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    $cBg   = [System.Drawing.Color]::FromArgb(250, 247, 240)
    $ink   = [System.Drawing.Color]::FromArgb(30, 38, 52)
    $sub   = [System.Drawing.Color]::FromArgb(122, 132, 150)
    $acc   = [System.Drawing.Color]::FromArgb(52, 168, 140)
    $warn  = [System.Drawing.Color]::FromArgb(226, 84, 74)
    $line  = [System.Drawing.Color]::FromArgb(233, 229, 219)
    $cardW = [System.Drawing.Color]::FromArgb(255, 255, 255)

    $g.Clear($cBg)
    $g.DrawRectangle((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(228, 222, 210)), 1), 0, 0, ($w - 1), ($h - 1))

    $bInk = New-Object System.Drawing.SolidBrush $ink
    $bSub = New-Object System.Drawing.SolidBrush $sub
    $bAcc = New-Object System.Drawing.SolidBrush $acc
    $bWarn = New-Object System.Drawing.SolidBrush $warn
    $penLine = New-Object System.Drawing.Pen $line, 1

    $fTitle = UiFont 12 1
    $fCap   = UiFont 8 0
    $fBal   = UiFont 34 1 -Num
    $fNum   = UiFont 14 1 -Num
    $fMid   = UiFont 10 1

    # ---- 标题 ----
    $g.DrawString('用量', $fTitle, $bInk, 24, 18)
    $g.DrawString('只读本机 · 不联网', $fCap, $bSub, 24, 44)

    # ---- 余额卡 ----
    $bal = 0.0
    if ($u.ok) { $bal = [double]$u.balance }
    $low = [double](Cfg '用量.余额低于' 2)
    $isLow = ($u.ok -and $low -gt 0 -and $bal -le $low)
    $balColor = if ($isLow) { $warn } else { $ink }
    $bBal = New-Object System.Drawing.SolidBrush $balColor

    $cardRect = New-Object System.Drawing.Rectangle 16, 62, ($w - 32), 112
    $bCard = New-Object System.Drawing.SolidBrush $cardW
    $g.FillRectangle($bCard, $cardRect)
    $g.DrawRectangle($penLine, $cardRect)

    $g.DrawString('余额', $fCap, $bSub, 30, 74)
    $g.DrawString((Format-Money2 $bal), $fBal, $bBal, 26, 90)

    if ($isLow) {
        $pill = New-Object System.Drawing.Rectangle ($w - 108), 78, 78, 22
        $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 240, 238))), $pill)
        $g.DrawString('该充值了', $fCap, $bWarn, ($w - 100), 82)
    }

    $leftTxt = '今天还没用过'
    $leftBrush = $bSub
    if ($bd.left -gt 0) { $leftTxt = '还能聊大约 ' + $bd.left + ' 次'; $leftBrush = $bAcc }
    elseif ($bd.avg -gt 0) { $leftTxt = '余额不够再聊一次了'; $leftBrush = $bWarn }
    $g.DrawString($leftTxt, $fMid, $leftBrush, 30, 146)

    # ---- 三列数据 ----
    $tokTxt = '--'
    if ($u.ok) {
        if ($u.tokens -ge 100000000) { $tokTxt = [string][Math]::Round($u.tokens / 100000000.0, 2) + ' 亿' }
        elseif ($u.tokens -ge 10000) { $tokTxt = [string][Math]::Round($u.tokens / 10000.0, 1) + ' 万' }
        else { $tokTxt = [string]$u.tokens }
    }
    $costTxt = '--'; if ($u.ok) { $costTxt = Format-Money2 $u.cost }
    $cntTxt  = '--'; if ($u.ok) { $cntTxt = [string]$u.count }

    $rowY = 192
    $g.DrawString('今日花费', $fCap, $bSub, 26, $rowY)
    $g.DrawString($costTxt, $fNum, $bInk, 24, ($rowY + 16))
    $g.DrawString('今日次数', $fCap, $bSub, 148, $rowY)
    $g.DrawString($cntTxt, $fNum, $bInk, 146, ($rowY + 16))
    $g.DrawString('tokens', $fCap, $bSub, 258, $rowY)
    $g.DrawString($tokTxt, $fNum, $bInk, 256, ($rowY + 16))

    # ---- 分隔线 ----
    $g.DrawLine($penLine, 24, 250, ($w - 24), 250)

    # ---- 最近 7 天 ----
    $g.DrawString('最近 7 天', $fCap, $bSub, 24, 264)
    $bx = 24; $by = 288; $bw = $w - 48; $bh = 86
    $week = $bd.week
    $okWeek = $false
    if ($week) { if ($week.ok) { $okWeek = $true } }
    if ($okWeek -and $week.days.Count -gt 0) {
        $max = 0.001
        foreach ($d in $week.days) { if ($d.cost -gt $max) { $max = $d.cost } }
        $n = $week.days.Count
        $gap = 9.0
        $cw = ($bw - $gap * ($n - 1)) / [double]$n
        for ($i = 0; $i -lt $n; $i++) {
            $d = $week.days[$i]
            $hh = [Math]::Max(4.0, ($d.cost / $max) * ($bh - 16))
            $x = $bx + $i * ($cw + $gap)
            $y = $by + $bh - 14 - $hh
            $rect = New-Object System.Drawing.Rectangle ([int]$x), ([int]$y), ([int]$cw), ([int]$hh)
            if ($i -eq ($n - 1)) {
                $gb = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(52, 168, 140), [System.Drawing.Color]::FromArgb(120, 208, 178), 90)
            } else {
                $gb = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(206, 226, 219), [System.Drawing.Color]::FromArgb(226, 238, 232), 90)
            }
            $g.FillRectangle($gb, $rect)
            $gb.Dispose()
            $label = [string]$d.label
            if ($label.Length -gt 3) { $label = $label.Substring(3) }
            $g.DrawString($label, $fCap, $bSub, [single]$x, [single]($by + $bh - 12))
        }
    } else {
        $g.DrawString('（没有历史数据）', $fCap, $bSub, $bx, ($by + 30))
    }

    # ---- 底部 ----
    $g.DrawLine($penLine, 24, ($h - 44), ($w - 24), ($h - 44))
    $g.DrawString(('平均 ' + (Format-Money2 $bd.avg) + ' / 次'), $fCap, $bSub, 24, ($h - 32))
    $g.DrawString(('桌宠自己 ' + [int]$pet.count + ' 次'), $fCap, $bSub, ($w - 118), ($h - 32))

    $fTitle.Dispose(); $fCap.Dispose(); $fBal.Dispose(); $fNum.Dispose(); $fMid.Dispose()
    $bInk.Dispose(); $bSub.Dispose(); $bAcc.Dispose(); $bWarn.Dispose(); $bBal.Dispose(); $bCard.Dispose()
    $penLine.Dispose()
}

function Show-UsageBoard {
    if ($script:boardForm) { try { $script:boardForm.Activate(); $script:boardForm.BringToFront() } catch {}; return }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $W = $script:BOARD_W; $H = $script:BOARD_H
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.Text = '小鲸鱼 · 用量'
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ClientSize = [System.Drawing.Size]::new($W, $H)
    $f.TopMost = $true
    $f.ShowInTaskbar = $false
    $f.BackColor = [System.Drawing.Color]::FromArgb(250, 247, 240)

    # ★ 位置：贴着她（左侧优先，放不下就右侧），不挡屏幕中间
    $wa = [System.Windows.Forms.SystemInformation]::WorkingArea
    $px = 200; $py = 200; $cw = 400; $ch = 700
    try { if ($script:px) { $px = [int]$script:px }; if ($script:py) { $py = [int]$script:py } } catch {}
    try { if ($script:cw) { $cw = [int]$script:cw }; if ($script:ch) { $ch = [int]$script:ch } } catch {}
    $x = $px - $W - 18
    if ($x -lt ($wa.Left + 8)) { $x = $px + $cw + 18 }
    if (($x + $W) -gt ($wa.Right - 8)) { $x = $wa.Right - $W - 8 }
    $y = $py + 30
    if (($y + $H) -gt ($wa.Bottom - 8)) { $y = $wa.Bottom - $H - 8 }
    if ($y -lt ($wa.Top + 8)) { $y = $wa.Top + 8 }
    $f.Location = [System.Drawing.Point]::new([int]$x, [int]$y)
    $script:boardForm = $f

    $f.Add_Paint({ param($s, $e) try { Draw-BoardCanvas $e.Graphics $s.ClientSize.Width $s.ClientSize.Height } catch {} })

    $f.KeyPreview = $true
    $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { try { $script:boardForm.Close() } catch {} } })
    $f.Add_DoubleClick({ try { if ($script:boardForm) { $script:boardForm.Close() } } catch {} })

    $bgBtn = [System.Drawing.Color]::FromArgb(250, 247, 240)
    $fgBtn = [System.Drawing.Color]::FromArgb(60, 72, 92)
    $hoverBtn = [System.Drawing.Color]::FromArgb(232, 240, 236)

    $btnX = New-Object System.Windows.Forms.Button
    $btnX.Text = '✕'
    $btnX.Location = [System.Drawing.Point]::new(($W - 50), 10)
    $btnX.Size = [System.Drawing.Size]::new(36, 30)
    $btnX.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnX.FlatAppearance.BorderSize = 0
    $btnX.FlatAppearance.MouseOverBackColor = $hoverBtn
    $btnX.BackColor = $bgBtn
    $btnX.ForeColor = $fgBtn
    $btnX.Font = UiFont 10 0
    $btnX.Cursor = 'Hand'
    $f.Controls.Add($btnX)
    $btnX.Add_Click({ try { $script:boardForm.Close() } catch { try { $f.Close() } catch {} } })

    $btnR = New-Object System.Windows.Forms.Button
    $btnR.Text = '刷新'
    $btnR.Location = [System.Drawing.Point]::new(($W - 106), 10)
    $btnR.Size = [System.Drawing.Size]::new(52, 30)
    $btnR.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnR.FlatAppearance.BorderSize = 0
    $btnR.FlatAppearance.MouseOverBackColor = $hoverBtn
    $btnR.BackColor = $bgBtn
    $btnR.ForeColor = $fgBtn
    $btnR.Font = UiFont 8.5 0
    $btnR.Cursor = 'Hand'
    $f.Controls.Add($btnR)
    $btnR.Add_Click({ try { $script:boardCache = $null; Update-BoardTexts } catch {} })

    $btnTop = New-Object System.Windows.Forms.Button
    $btnTop.Text = '充值'
    $btnTop.Location = [System.Drawing.Point]::new(($W - 174), 10)
    $btnTop.Size = [System.Drawing.Size]::new(64, 30)
    $btnTop.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnTop.FlatAppearance.BorderSize = 0
    $btnTop.FlatAppearance.MouseOverBackColor = $hoverBtn
    $btnTop.BackColor = $bgBtn
    $btnTop.ForeColor = [System.Drawing.Color]::FromArgb(40, 140, 116)
    $btnTop.Font = UiFont 8.5 0
    $btnTop.Cursor = 'Hand'
    $f.Controls.Add($btnTop)
    $btnTop.Add_Click({ try { Open-Recharge } catch {} })

    $script:boardDrag = @{ on = $false; x = 0; y = 0 }
    $f.Add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:boardDrag = @{ on = $true; x = $e.X; y = $e.Y } } })
    $f.Add_MouseMove({ param($s, $e) if ($script:boardDrag -and $script:boardDrag.on) { $f.Left = $f.Left + ($e.X - $script:boardDrag.x); $f.Top = $f.Top + ($e.Y - $script:boardDrag.y) } })
    $f.Add_MouseUp({ param($s, $e) $script:boardDrag = @{ on = $false; x = 0; y = 0 } })

    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 30000
    $t.Add_Tick({ try { if ($script:boardForm) { $script:boardCache = $null; Update-BoardTexts } else { $t.Stop() } } catch {} })
    $t.Start()
    $script:boardTimer = $t

    $f.Add_FormClosed({
        try { if ($script:boardTimer) { $script:boardTimer.Stop(); $script:boardTimer.Dispose() } } catch {}
        $script:boardTimer = $null; $script:boardForm = $null
    })

    $script:boardCache = $null
    try { $script:boardCache = Get-BoardData } catch {}
    $f.Show()
}
