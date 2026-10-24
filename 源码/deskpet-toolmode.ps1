# ============================================================
#  deskpet-toolmode.ps1 —— 工具模式 v2
#   · 主宠物隐藏，只留角落小挂件（三种样式）
#   · 指标循环：余额 / 今日花费 / 今日次数 / 还能聊几次 / 时间
#   · 番茄钟（工作/休息可调，到点提醒）
#   · 久坐提醒
#   · 快速笔记（存 app\笔记\日期.md）
#   · 鼠标穿透（挂着不挡点击）
# ============================================================

$script:autoWalkBeforeTool = $null   # 进入工具模式前的游走状态（切回时恢复）

$script:toolMode    = $false
$script:toolWidget  = $null
$script:toolTimer   = $null
$script:toolStyle   = 1          # 1 头像卡片 / 2 胶囊 / 3 贴边竖条
$script:toolMetric  = 1          # 1 余额 / 2 今日花费 / 3 今日次数 / 4 还能聊次数 / 5 时间
$script:pomoRunning = $false
$script:pomoIsBreak = $false
$script:pomoRemain  = 0
$script:sitMinutes  = 0
$script:toolMsg     = ''         # 临时提醒文字（覆盖显示）
$script:toolMsgUntil = 0
$script:toolBuiltStyle = 0

function Get-ToolStyle { return [int](Cfg '模式.挂件样式' 1) }
function Get-ToolMetric { return [int](Cfg '模式.挂件指标' 1) }

function Set-ToolMsg {
    param([string]$Text, [int]$Seconds = 6)
    $script:toolMsg = $Text
    try { $script:toolMsgUntil = $script:tick + (CfgFrames '模式.提示秒数' 6) } catch { $script:toolMsgUntil = 999999 }
    if ($script:toolWidget) {
        try {
            $script:toolWidget.BackColor = [System.Drawing.Color]::FromArgb(140, 40, 40)
            $script:toolWidget.Refresh()
        } catch {}
    }
}

function Update-ToolWidget {
    if (-not $script:toolWidget) { return }
    try {
        $style = Get-ToolStyle
        if ($style -ne $script:toolBuiltStyle) { try { $script:toolWidget.Close() } catch {}; $script:toolWidget = $null; Show-ToolWidget; return }

        if ($script:toolMsg -and $script:tick -lt $script:toolMsgUntil) {
            if ($script:toolLblMain) { $script:toolLblMain.Text = $script:toolMsg }
            if ($script:toolLblSub) { $script:toolLblSub.Text = '' }
            return
        }
        if ($script:toolMsg) { $script:toolMsg = ''; try { $script:toolWidget.BackColor = [System.Drawing.Color]::FromArgb(24, 40, 80) } catch {} }

        $u = Get-DshUsage
        $metric = Get-ToolMetric
        $main = '--'; $sub = ''
        if ($metric -eq 1) {
            $main = if ($u.ok) { '¥' + [Math]::Round([double]$u.balance, 2) } else { '¥--' }
            $sub = '余额'
        } elseif ($metric -eq 2) {
            $main = if ($u.ok) { '¥' + [Math]::Round([double]$u.cost, 2) } else { '¥--' }
            $sub = '今日花费'
        } elseif ($metric -eq 3) {
            $main = if ($u.ok) { [string]$u.count } else { '--' }
            $sub = '今日次数'
        } elseif ($metric -eq 4) {
            $left = '--'
            if ($u.ok -and $u.count -gt 0 -and $u.cost -gt 0) {
                $avg = [double]$u.cost / [double]$u.count
                if ($avg -gt 0) { $left = [string][Math]::Floor([double]$u.balance / $avg) }
            }
            $main = $left; $sub = '还能聊几次'
        } else {
            $main = (Get-Date).ToString('HH:mm')
            $sub = (Get-Date).ToString('MM-dd')
        }
        if ($script:pomoRunning) {
            $m = [int][Math]::Floor($script:pomoRemain / 60)
            $sec = [int]($script:pomoRemain % 60)
            $main = ('{0:00}:{1:00}' -f $m, $sec)
            $sub = if ($script:pomoIsBreak) { '休息中' } else { '专注中' }
        }
        if ($script:toolLblMain) { $script:toolLblMain.Text = $main }
        if ($script:toolLblSub) { $script:toolLblSub.Text = $sub }
    } catch {}
}

function Set-ClickThrough {
    param([bool]$On)
    try {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class TW {
  const int GWL_EXSTYLE = -20;
  const int WS_EX_TRANSPARENT = 0x20;
  const int WS_EX_LAYERED = 0x80000;
  [DllImport("user32.dll", SetLastError=true)] static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll", SetLastError=true)] static extern int SetWindowLong(IntPtr h, int idx, int v);
  public static void Set(IntPtr h, bool on) {
    int ex = GetWindowLong(h, GWL_EXSTYLE);
    if (on) { SetWindowLong(h, GWL_EXSTYLE, ex | WS_EX_TRANSPARENT | WS_EX_LAYERED); }
    else { SetWindowLong(h, GWL_EXSTYLE, ex & ~WS_EX_TRANSPARENT); }
  }
}
'@ -ErrorAction SilentlyContinue
        if ($script:toolWidget) { [TW]::Set($script:toolWidget.Handle, $On) }
    } catch {}
}

function Show-ToolWidget {
    if ($script:toolWidget) { try { $script:toolWidget.Show(); $script:toolWidget.BringToFront() } catch {}; return }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $style = Get-ToolStyle
    $script:toolBuiltStyle = $style

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
    $f.TopMost         = $true
    $f.ShowInTaskbar   = $false
    $f.BackColor       = [System.Drawing.Color]::FromArgb(24, 40, 80)
    $wa = [System.Windows.Forms.SystemInformation]::WorkingArea

    if ($style -eq 3) {
        $f.ClientSize = [System.Drawing.Size]::new(58, 150)
        $f.Location = [System.Drawing.Point]::new(($wa.Right - 62), ($wa.Top + 120))
        $lblM = New-Object System.Windows.Forms.Label
        $lblM.Location = [System.Drawing.Point]::new(4, 34); $lblM.Size = [System.Drawing.Size]::new(50, 40)
        $lblM.TextAlign = 'MiddleCenter'
        $lblM.Font = UiFont 10 1 -Num
        $lblM.ForeColor = [System.Drawing.Color]::FromArgb(235, 242, 255)
        $lblM.BackColor = [System.Drawing.Color]::Transparent
        $f.Controls.Add($lblM); $script:toolLblMain = $lblM
        $lblS = New-Object System.Windows.Forms.Label
        $lblS.Location = [System.Drawing.Point]::new(2, 78); $lblS.Size = [System.Drawing.Size]::new(54, 60)
        $lblS.Font = UiFont 7 0
        $lblS.ForeColor = [System.Drawing.Color]::FromArgb(150, 175, 220)
        $lblS.BackColor = [System.Drawing.Color]::Transparent
        $lblS.TextAlign = 'MiddleCenter'
        $f.Controls.Add($lblS); $script:toolLblSub = $lblS
    } elseif ($style -eq 2) {
        $f.ClientSize = [System.Drawing.Size]::new(216, 40)
        $f.Location = [System.Drawing.Point]::new(($wa.Right - 232), ($wa.Bottom - 60))
        $lblM = New-Object System.Windows.Forms.Label
        $lblM.Location = [System.Drawing.Point]::new(12, 6); $lblM.Size = [System.Drawing.Size]::new(96, 26)
        $lblM.Font = UiFont 12 1 -Num
        $lblM.ForeColor = [System.Drawing.Color]::FromArgb(235, 242, 255)
        $lblM.BackColor = [System.Drawing.Color]::Transparent
        $f.Controls.Add($lblM); $script:toolLblMain = $lblM
        $lblS = New-Object System.Windows.Forms.Label
        $lblS.Location = [System.Drawing.Point]::new(110, 11); $lblS.Size = [System.Drawing.Size]::new(96, 20)
        $lblS.Font = UiFont 8 0
        $lblS.ForeColor = [System.Drawing.Color]::FromArgb(150, 175, 220)
        $lblS.BackColor = [System.Drawing.Color]::Transparent
        $f.Controls.Add($lblS); $script:toolLblSub = $lblS
    } else {
        $f.ClientSize = [System.Drawing.Size]::new(206, 76)
        $f.Location = [System.Drawing.Point]::new(($wa.Right - 220), ($wa.Bottom - 96))
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Location = [System.Drawing.Point]::new(6, 10); $pic.Size = [System.Drawing.Size]::new(56, 56)
        $pic.SizeMode = 'Zoom'; $pic.BackColor = [System.Drawing.Color]::Transparent
        try {
            # 用姿势图当头像（.ico 的 PNG 压缩格式在部分 .NET 下会解出噪点）
            foreach ($n in @('pose_坐.png','pose_看.png','pose_站.png')) {
                $ip = Join-Path $PSScriptRoot ('assets\sprites\' + $n)
                if (Test-Path -LiteralPath $ip) { $pic.Image = [System.Drawing.Image]::FromFile($ip); break }
            }
        } catch {}
        $f.Controls.Add($pic)
        $lblM = New-Object System.Windows.Forms.Label
        $lblM.Location = [System.Drawing.Point]::new(70, 8); $lblM.Size = [System.Drawing.Size]::new(130, 30)
        $lblM.Font = UiFont 14 1 -Num
        $lblM.ForeColor = [System.Drawing.Color]::FromArgb(235, 242, 255)
        $lblM.BackColor = [System.Drawing.Color]::Transparent
        $f.Controls.Add($lblM); $script:toolLblMain = $lblM
        $lblS = New-Object System.Windows.Forms.Label
        $lblS.Location = [System.Drawing.Point]::new(71, 40); $lblS.Size = [System.Drawing.Size]::new(128, 20)
        $lblS.Font = UiFont 8 0
        $lblS.ForeColor = [System.Drawing.Color]::FromArgb(150, 175, 220)
        $lblS.BackColor = [System.Drawing.Color]::Transparent
        $f.Controls.Add($lblS); $script:toolLblSub = $lblS
    }
    $script:toolWidget = $f

    $f.Add_MouseDown({ param($s,$e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:twDrag = @{ on=$true; x=$e.X; y=$e.Y } } })
    $f.Add_MouseMove({ param($s,$e) if ($script:twDrag -and $script:twDrag.on) { $f.Left = $f.Left + ($e.X - $script:twDrag.x); $f.Top = $f.Top + ($e.Y - $script:twDrag.y) } })
    $f.Add_MouseUp({ param($s,$e) $script:twDrag = @{ on=$false; x=0; y=0 } })
    $f.Add_MouseClick({ param($s,$e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $m = (Get-ToolMetric) + 1; if ($m -gt 5) { $m = 1 }
            try { Set-CfgValue '模式.挂件指标' $m } catch {}
            Update-ToolWidget
        }
    })

    $cm = New-Object System.Windows.Forms.ContextMenuStrip
    $miBoard = $cm.Items.Add('打开用量看板')
    $miBoard.Add_Click({ try { Show-UsageBoard } catch {} })
    $null = $cm.Items.Add('-')
    $miStyle = $cm.Items.Add('切换挂件样式（头像/胶囊/竖条）')
    $miStyle.Add_Click({ try { $s = (Get-ToolStyle) + 1; if ($s -gt 3) { $s = 1 }; Set-CfgValue '模式.挂件样式' $s; Update-ToolWidget } catch {} })
    $miPomo = $cm.Items.Add('番茄钟 开始/停止')
    $miPomo.Add_Click({ try { Toggle-Pomodoro } catch {} })
    $miSit = $cm.Items.Add('久坐计时重置')
    $miSit.Add_Click({ try { $script:sitMinutes = 0; Set-ToolMsg '久坐计时已重置' 4 } catch {} })
    $miNote = $cm.Items.Add('快速笔记…')
    $miNote.Add_Click({ try { Show-NoteInput } catch {} })
    $miClick = $cm.Items.Add('鼠标穿透')
    $miClick.CheckOnClick = $true
    $miClick.Checked = [bool](Cfg '模式.鼠标穿透' $false)
    $miClick.Add_Click({ try { Set-CfgValue '模式.鼠标穿透' $miClick.Checked; Set-ClickThrough $miClick.Checked; Set-ToolMsg ($(if ($miClick.Checked) {'已开启穿透'} else {'已关闭穿透'})) 5 } catch {} })
    $miMute = $cm.Items.Add('工具模式静音')
    $miMute.CheckOnClick = $true
    $miMute.Checked = [bool](Cfg '模式.工具模式静音' $false)
    $miMute.Add_Click({ try { Set-CfgValue '模式.工具模式静音' $miMute.Checked } catch {} })
    $null = $cm.Items.Add('-')
    $miBack = $cm.Items.Add('切回桌宠模式')
    $miBack.Add_Click({ try { Set-ToolMode $false } catch {} })
    $f.ContextMenuStrip = $cm

    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 1000
    $t.Add_Tick({
        try {
            if ($script:pomoRunning) {
                $script:pomoRemain--
                if ($script:pomoRemain -le 0) {
                    if ($script:pomoIsBreak) {
                        $script:pomoIsBreak = $false
                        $script:pomoRemain = [int]([double](Cfg '模式.番茄工作分钟' 25) * 60)
                        Set-ToolMsg '休息结束，继续干活' 8
                    } else {
                        $script:pomoIsBreak = $true
                        $script:pomoRemain = [int]([double](Cfg '模式.番茄休息分钟' 5) * 60)
                        Set-ToolMsg '专注结束，起来动动' 8
                    }
                }
            } else {
                $script:sitMinutes++
                $limit = [double](Cfg '模式.久坐提醒分钟' 45)
                if ($limit -gt 0 -and $script:sitMinutes -ge $limit) {
                    $script:sitMinutes = 0
                    Set-ToolMsg '坐太久了，起来走两步' 8
                }
            }
            Update-ToolWidget
        } catch {}
    })
    $t.Start()
    $script:toolTimer = $t

    $f.Add_FormClosed({
        try { if ($script:toolTimer) { $script:toolTimer.Stop(); $script:toolTimer.Dispose() } } catch {}
        $script:toolTimer = $null; $script:toolWidget = $null
    })

    try { if ([bool](Cfg '模式.鼠标穿透' $false)) { Set-ClickThrough $true } } catch {}
    Update-ToolWidget
    $f.Show()
}

function Toggle-Pomodoro {
    if ($script:pomoRunning) {
        $script:pomoRunning = $false
        Set-ToolMsg '番茄钟已停' 4
    } else {
        $script:pomoIsBreak = $false
        $script:pomoRemain = [int]([double](Cfg '模式.番茄工作分钟' 25) * 60)
        $script:pomoRunning = $true
        Set-ToolMsg '开始专注' 4
    }
}

function Show-NoteInput {
    Add-Type -AssemblyName System.Windows.Forms
    $f = New-Object System.Windows.Forms.Form
    $f.Text = '快速笔记'
    try {
        $ip = Join-Path $PSScriptRoot '桌宠.ico'
        if (Test-Path -LiteralPath $ip) { $f.Icon = New-Object System.Drawing.Icon($ip) }
    } catch {}
    $f.ClientSize = [System.Drawing.Size]::new(360, 130)
    $f.StartPosition = 'CenterScreen'
    $f.TopMost = $true
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = [System.Drawing.Point]::new(12, 12); $tb.Size = [System.Drawing.Size]::new(336, 60)
    $tb.Multiline = $true
    $f.Controls.Add($tb)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = '记下来'; $btn.Location = [System.Drawing.Point]::new(268, 84); $btn.Size = [System.Drawing.Size]::new(80, 30)
    $f.Controls.Add($btn)
    $btn.Add_Click({ try { Save-ToolNote $tb.Text; $f.Close() } catch {} })
    $f.Add_Shown({ $tb.Focus() })
    $f.Show()
}

function Save-ToolNote {
    param([string]$Text)
    $t = $Text.Trim()
    if (-not $t) { return }
    try {
        $dir = Join-Path $PSScriptRoot '笔记'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $file = Join-Path $dir ((Get-Date).ToString('yyyy-MM-dd') + '.md')
        $line = '- [' + (Get-Date).ToString('HH:mm') + '] ' + $t
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8
        Set-ToolMsg '记好了 ✓' 4
    } catch { Set-ToolMsg '笔记没记上…' 4 }
}

function Set-ToolMode {
    param([bool]$On)
    $script:toolMode = $On
    try { Set-CfgValue '模式.工具模式' $On } catch {}
    # 同步右键菜单的勾选状态（以前不同步 → 菜单显示勾选但实际不在工具模式 ✗）
    try { if ($script:itemToolMode) { $script:itemToolMode.Checked = $On } } catch {}
    if ($On) {
        $script:autoWalkBeforeTool = $script:autoWalk
        try { $script:autoWalk = $false } catch {}
        try { Clear-Bubble } catch {}
        try { $script:form.Hide() } catch {}
        try { Show-ToolWidget } catch {}
    } else {
        try { if ($script:toolTimer) { $script:toolTimer.Stop(); $script:toolTimer.Dispose() } } catch {}
        $script:toolTimer = $null
        try { if ($script:toolWidget) { $script:toolWidget.Close() } } catch {}
        $script:toolWidget = $null
        try { $script:form.Show(); $script:form.Visible = $true; $script:form.Activate() } catch {}
        # ★ 恢复进入工具模式之前的游走状态（以前写死成打开 → 切回来就自己乱走 ✗）
        if ($null -ne $script:autoWalkBeforeTool) { try { $script:autoWalk = [bool]$script:autoWalkBeforeTool } catch {} }
        try { if ($script:itemAuto) { $script:itemAuto.Checked = $script:autoWalk } } catch {}
        try { $script:pomoRunning = $false } catch {}
        try { $script:sitMinutes = 0 } catch {}
    }
}
