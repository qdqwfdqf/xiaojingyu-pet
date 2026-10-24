# ============================================================
#  deskpet-settings.ps1 —— 设置面板 v2（冰蓝玻璃卡片风）
#  依赖 deskpet-ui.ps1（自绘控件）、deskpet-apikey.ps1（密钥）
# ============================================================

$script:setForm   = $null
$script:setItems  = New-Object System.Collections.ArrayList
$script:setChecks = New-Object System.Collections.ArrayList
$script:setSeg    = $null
$script:setBody   = $null
$script:setApiStatus = $null
$script:setApiBox    = $null
$script:setApiResult = $null
$script:setApiUsage  = $null
$script:setBackendStatus = $null
$script:setTbUrl     = $null
$script:setTbModel   = $null
$script:setApiKeyWho = $null
$script:bodyW = 0
$script:curY = 0
$script:cards = New-Object System.Collections.ArrayList
if (-not $script:settingsCfg) {
    $script:settingsCfg = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'config.json' } else { Join-Path (Get-Location).Path 'config.json' }
}

# ---- 主题调色板（每次打开设置都重算，切换主题立刻生效）----
function Update-ThemePalette {
    $script:uiTheme = [string](Cfg '界面.主题' 'light')
    if ($script:uiTheme -eq 'dark') {
        $script:C_BG2  = [System.Drawing.Color]::FromArgb(18, 22, 36)
        $script:C_CARD = [System.Drawing.Color]::FromArgb(26, 34, 54)
        $script:C_LINE = [System.Drawing.Color]::FromArgb(46, 58, 86)
        $script:C_INK  = [System.Drawing.Color]::FromArgb(232, 240, 252)
        $script:C_SUB  = [System.Drawing.Color]::FromArgb(152, 170, 204)
        $script:C_BLUE = [System.Drawing.Color]::FromArgb(104, 150, 255)
        $script:C_SEC  = [System.Drawing.Color]::FromArgb(158, 196, 255)
    } else {
        $script:C_BG2  = [System.Drawing.Color]::FromArgb(247, 245, 238)
        $script:C_CARD = [System.Drawing.Color]::FromArgb(253, 252, 250)
        $script:C_LINE = [System.Drawing.Color]::FromArgb(234, 230, 222)
        $script:C_INK  = [System.Drawing.Color]::FromArgb(26, 28, 33)
        $script:C_SUB  = [System.Drawing.Color]::FromArgb(126, 126, 122)
        $script:C_BLUE = [System.Drawing.Color]::FromArgb(52, 168, 140)
        $script:C_SEC  = [System.Drawing.Color]::FromArgb(28, 120, 104)
    }
}
Update-ThemePalette

function New-SetLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [single]$Size = 9, $Color = $null, [bool]$Bold = $false)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.Font = UiFont $Size ([int]($(if ($Bold) { 1 } else { 0 })))
    $l.ForeColor = if ($Color) { $Color } else { $script:C_INK }
    $l.BackColor = [System.Drawing.Color]::Transparent
    $Parent.Controls.Add($l)
    return $l
}

function Set-CfgValue {
    param($Root, [string]$DotPath, $Value)
    # 支持两种写法：
    #   Set-CfgValue $cfgRoot 'a.b' value    （3 参，设置页保存时用）
    #   Set-CfgValue 'a.b' value             （2 参，直接改 $script:cfg 并落盘）
    if (-not $PSBoundParameters.ContainsKey('Value')) {
        $Value = $DotPath
        $DotPath = [string]$Root
        $Root = $script:cfg
    }
    if ($null -eq $Root) { $Root = $script:cfg }
    if ($null -eq $Root) { return }
    $parts = $DotPath -split '\.'
    $node = $Root
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $k = $parts[$i]
        if ($null -eq $node.$k) { $node | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]@{}) -Force }
        $node = $node.$k
    }
    $last = $parts[$parts.Count - 1]
    if ($null -eq $node.$last) { $node | Add-Member -NotePropertyName $last -NotePropertyValue $Value -Force }
    else { $node.$last = $Value }
}

function Jump-SettingsSection {
    param([string]$Key)
    try {
        $bd = $script:setBody
        if (-not $bd) { return }
        if ($Key -eq '全部' -or [string]::IsNullOrEmpty($Key)) {
            $bd.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
            return
        }
        $map = @{ '物理' = '物理'; '动作' = '蹦跳'; '交互' = '碰撞'; '聊天' = '聊天后端'; '数据' = '用量'; '工具' = '工具模式' }
        if (-not $map.ContainsKey($Key)) { return }
        $want = [string]$map[$Key]
        $target = $null
        foreach ($c in $bd.Controls) {
            if (-not $c.GetType().Name.Contains('PetCard')) { continue }
            $tagText = [string]$c.Tag
            if ([string]::IsNullOrEmpty($tagText)) {
                try {
                    foreach ($cc in $c.Controls) {
                        if ($cc -is [System.Windows.Forms.Label]) { $tagText = [string]$cc.Text; break }
                    }
                } catch {}
            }
            if ($tagText -like ('*' + $want + '*')) { $target = $c; break }
        }
        if ($target) {
            $wantY = [int][Math]::Max(0, ($target.Top - 10))
            $bd.AutoScrollPosition = New-Object System.Drawing.Point(0, $wantY)
            # 双保险：AutoScrollPosition 不生效时直接设滚动条
            if ([Math]::Abs($bd.AutoScrollPosition.Y) -lt 1 -and $wantY -gt 0 -and $bd.VerticalScroll.Visible) {
                try { $bd.VerticalScroll.Value = [Math]::Min($wantY, $bd.VerticalScroll.Maximum); $bd.PerformLayout() } catch {}
            }
            $bd.Focus()
        }
    } catch {}
}

function New-CardBlock {
    param([string]$Title, [string]$Sub = '')
    $card = New-Object PetUI.PetCard
    $card.FillColor = $script:C_CARD
    $card.LineColor = $script:C_LINE
    $card.Width = $script:bodyW
    $card.Height = 70
    $card.Location = New-Object System.Drawing.Point(0, $script:curY)
    $script:setBody.Controls.Add($card)
    try { [void]$script:cards.Add($card) } catch {}
    $null = New-SetLabel $card $Title 26 18 360 28 13.5 $script:C_SEC $true
    if ($Sub) { $null = New-SetLabel $card $Sub 26 50 430 18 9.5 $script:C_SUB }
    return @{ card = $card; y = $(if ($Sub) { 84 } else { 60 }); title = $Title }
}

function Close-CardBlock {
    param($Block)
    $Block.card.Height = $Block.y + 16
    $Block.card.Tag = [string]$Block.title
    $script:curY += $Block.card.Height + 18
}

function Add-SliderRow {
    param($Block, [string]$Caption, [string]$Path, [double]$Min, [double]$Max, [int]$Dec)
    $card = $Block.card
    $y = $Block.y
    $null = New-SetLabel $card $Caption 26 ($y + 8) 160 24 11 $script:C_INK $false
    $sl = New-Object PetUI.PetSlider
    $sl.Location = New-Object System.Drawing.Point(190, ($y + 4))
    $sl.Size = New-Object System.Drawing.Size(246, 32)
    $sl.Min = $Min
    $sl.Max = $Max
    $sl.Decimals = $Dec
    $sl.Tint = $script:C_BLUE
    $card.Controls.Add($sl)
    $vl = New-SetLabel $card '' 442 ($y + 8) 96 24 12 $script:C_BLUE $true
    $vl.TextAlign = 'MiddleRight'
    $item = @{ path = $Path; slider = $sl; val = $vl; min = $Min; max = $Max; dec = $Dec }
    [void]$script:setItems.Add($item)
    $sl.Add_ValueChanged({
        param($s, $e)
        $it = $script:setItems | Where-Object { $_.slider -eq $s } | Select-Object -First 1
        if ($it) { $it.val.Text = [Math]::Round($it.slider.Value, $it.dec).ToString() }
    })
    $Block.y = $y + 60
}

function Add-PresetRow {
    param($Block, [string]$Caption, $Presets)
    $card = $Block.card
    $y = $Block.y
    $null = New-SetLabel $card $Caption 26 ($y + 10) 150 22 10 $script:C_SUB $false
    $x = 190
    foreach ($p in $Presets) {
        if ($p -is [hashtable] -and $p.ContainsKey('n')) { $name = $p.n; $vals = $p.v }
        else { continue }
        $b = New-Object PetUI.PetButton
        $b.Text = $name
        $b.Location = New-Object System.Drawing.Point($x, ($y + 2))
        $b.Size = New-Object System.Drawing.Size(88, 32)
        $b.Tag = $vals   # ★ 数组不能用字符串索引（以前 $Presets[$name] 恒为 $null → 点了没反应）
        $b.Add_Click({
            param($s, $e)
            $vals = $s.Tag
            foreach ($k in $vals.Keys) {
                $it = $script:setItems | Where-Object { $_.path -eq $k } | Select-Object -First 1
                if ($it) {
                    $it.slider.SetVal([double]$vals[$k])
                    $it.val.Text = [Math]::Round($it.slider.Value, $it.dec).ToString()
                }
            }
        })
        $card.Controls.Add($b)
        $x += 98
    }
    $Block.y = $y + 50
}

function Add-ToggleRow {
    param($Block, [string]$Caption, [string]$Path)
    $card = $Block.card
    $y = $Block.y
    $null = New-SetLabel $card $Caption 26 ($y + 6) 380 26 11 $script:C_INK $false
    $tg = New-Object PetUI.PetToggle
    $tg.Location = New-Object System.Drawing.Point(466, ($y + 4))
    $tg.Tint = $script:C_BLUE
    $card.Controls.Add($tg)
    [void]$script:setChecks.Add(@{ path = $Path; toggle = $tg })
    $Block.y = $y + 58
}

function Apply-ThemeRecolor {
    param($Parent)
    foreach ($c in $Parent.Controls) {
        try {
            if ($c -is [System.Windows.Forms.TextBox]) {
                if ($script:uiTheme -eq 'dark') { $c.BackColor = [System.Drawing.Color]::FromArgb(40, 50, 74); $c.ForeColor = $script:C_INK }
                else { $c.BackColor = [System.Drawing.Color]::White; $c.ForeColor = $script:C_INK }
                try { if ($c -isnot [System.Windows.Forms.TextBox]) { $c.BorderStyle = 'FixedSingle' } } catch {}
            } elseif ($c -is [System.Windows.Forms.ComboBox]) {
                if ($script:uiTheme -eq 'dark') { $c.BackColor = [System.Drawing.Color]::FromArgb(40, 50, 74); $c.ForeColor = $script:C_INK }
            }
            if ($c.Controls.Count -gt 0) { Apply-ThemeRecolor $c }
        } catch {}
    }
}

function Apply-ThemeLive {
    param($Form, $Head, $Foot, $Body)
    try {
        Update-ThemePalette
        if ($Form) { $Form.BackColor = $script:C_BG2 }
        if ($Head) { $Head.BackColor = $script:C_CARD }
        if ($Foot) { $Foot.BackColor = $script:C_CARD }
        if ($Body) { $Body.BackColor = $script:C_BG2 }
        Apply-ThemeRecolor $Form
        $stack = New-Object System.Collections.Stack
        if ($Form) { $stack.Push($Form) }
        while ($stack.Count -gt 0) {
            $p = $stack.Pop()
            foreach ($c in $p.Controls) {
                try {
                    if ($c -is [PetUI.PetCard]) { $c.FillColor = $script:C_CARD; $c.LineColor = $script:C_LINE; $c.Invalidate() }
                    elseif ($c -is [PetUI.PetSlider]) { $c.Tint = $script:C_BLUE; $c.Invalidate() }
                    elseif ($c -is [PetUI.PetToggle]) { $c.Tint = $script:C_BLUE; $c.Invalidate() }
                    elseif ($c -is [PetUI.PetSegmented]) { $c.Tint = $script:C_BLUE; $c.Invalidate() }
                    elseif ($c -is [PetUI.PetButton]) { $c.Tint = $script:C_BLUE; $c.Invalidate() }
                    elseif ($c -is [System.Windows.Forms.Label]) {
                        if ($c.Font.Bold) { $c.ForeColor = $script:C_SEC } else { $c.ForeColor = $script:C_SUB }
                    }
                } catch {}
                if ($c.Controls.Count -gt 0) { $stack.Push($c) }
            }
        }
        if ($Form) { $Form.Invalidate($true); $Form.Refresh() }
    } catch { try { ("THEMELIVE-ERR: " + $_.Exception.ToString()) | Out-File -FilePath (Join-Path $PSScriptRoot 'themeerr.log') -Append -Encoding utf8 } catch {} }
}

function Set-PetButtonsTheme {
    param($Parent)
    try {
        $stack = New-Object System.Collections.Stack
        if ($Parent) { $stack.Push($Parent) }
        while ($stack.Count -gt 0) {
            $p = $stack.Pop()
            foreach ($c in $p.Controls) {
                if ($c -is [PetUI.PetButton]) {
                    if (-not $c.Primary) {
                        $c.FillColor = $script:C_CARD
                        $c.TextColor = $script:C_INK
                        $c.BorderColor = $script:C_LINE
                    }
                    try { $c.Font = UiFont 9 0 } catch {}
                    $c.Invalidate()
                }
                if ($c -is [PetUI.PetSegmented]) {
                    $c.TrackColor = $script:C_LINE
                    $c.TextColor = $script:C_SUB
                    $c.Tint = $script:C_BLUE
                    try { $c.Font = UiFont 8.5 0 } catch {}
                    $c.Invalidate()
                }
                if ($c -is [PetUI.PetSlider]) {
                    $c.TrackColor = $script:C_LINE
                    $c.Tint = $script:C_BLUE
                    $c.Invalidate()
                }
                if ($c -is [PetUI.PetToggle]) {
                    $c.OffColor = $script:C_LINE
                    $c.Tint = $script:C_BLUE
                    $c.Invalidate()
                }
                if ($c.Controls.Count -gt 0) { $stack.Push($c) }
            }
        }
    } catch {}
}

function Apply-SettingsFilter {
    param([string]$Key)
    try {
        $bd = $script:setBody
        if (-not $bd -or $script:cards.Count -eq 0) { return }
        $map = @{ '物理' = '物理'; '动作' = '蹦跳'; '交互' = '碰撞'; '聊天' = '聊天'; '数据' = '用量'; '工具' = '工具模式' }
        $want = ''
        if ($Key -ne '全部' -and $map.ContainsKey($Key)) { $want = [string]$map[$Key] }
        $y = 14
        foreach ($card in $script:cards) {
            if (-not $card) { continue }
            $title = [string]$card.Tag
            if ([string]::IsNullOrEmpty($title)) {
                try { foreach ($cc in $card.Controls) { if ($cc -is [System.Windows.Forms.Label]) { $title = [string]$cc.Text; break } } } catch {}
            }
            $show = $true
            if ($want -ne '') {
                $show = $false
                if ($title -like ('*' + $want + '*')) { $show = $true }
                # 聊天分类多含两卡：聊天后端 + API Key
                if ($Key -eq '聊天' -and ($title -like '*聊天*' -or $title -like '*API Key*')) { $show = $true }
                if ($Key -eq '动作' -and ($title -like '*表情*')) { $show = $true }
                if ($Key -eq '交互' -and ($title -like '*功能*')) { $show = $true }
            }
            $card.Visible = $show
            if ($show) {
                $card.Location = New-Object System.Drawing.Point(0, $y)
                $y += $card.Height + 12
            }
        }
        $bd.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
        $bd.AutoScrollMinSize = New-Object System.Drawing.Size(0, ($y + 10))
        $bd.Invalidate()
    } catch {}
}

# ---------------- 聊天直连：界面显示用的小函数 ----------------
function Ensure-LlmCfgDefaults {
    # 老配置里没有 聊天.直连.* 这一块 → 只补缺失的键（已有值不动）
    try {
        if (-not $script:cfg) { return }
        if ($null -eq (Cfg '聊天.直连.预设' $null)) { Set-CfgValue '聊天.直连.预设' 'deepseek' }
        if ($null -eq (Cfg '聊天.直连.历史条数' $null)) { Set-CfgValue '聊天.直连.历史条数' 8 }
        if ($null -eq (Cfg '聊天.直连.超时秒数' $null)) { Set-CfgValue '聊天.直连.超时秒数' 20 }
        if ($null -eq (Cfg '聊天.直连.接口' $null)) { Set-CfgValue '聊天.直连.接口' (Get-LlmUrlText) }
        if ($null -eq (Cfg '聊天.直连.模型' $null)) { Set-CfgValue '聊天.直连.模型' (Get-LlmModelText) }
    } catch {}
}

function Get-LlmUrlText {
    try {
        $u = [string](Cfg '聊天.直连.接口' '')
        if ($u) { return $u }
        $id = Get-LlmPresetId
        return [string]$script:llmPresets[$id].url
    } catch { return '' }
}

function Get-LlmModelText {
    try {
        $m = [string](Cfg '聊天.直连.模型' '')
        if ($m) { return $m }
        $id = Get-LlmPresetId
        return [string]$script:llmPresets[$id].model
    } catch { return '' }
}

function Refresh-ChatBackendStatus {
    try {
        $mode = [string](Cfg '聊天.模式' 'offline')
        if ($mode -eq 'offline') { return '当前：离线（内置台词，不联网）' }
        $id = Get-LlmPresetId
        $p = $script:llmPresets[$id]
        $keyTxt = '不需要 Key'
        if ([bool]$p.needKey) {
            $st = Get-LlmKeyState $id
            if ($st.configured) { $keyTxt = 'Key 已配置 ' + [string]$st.masked }
            else { $keyTxt = 'Key 未配置（会回落到离线台词）' }
        }
        return ('当前：直连 · ' + [string]$p.name + ' · ' + [string]$p.model + ' · ' + $keyTxt)
    } catch { return '当前：读取失败' }
}

function Show-Settings {
    if ($script:setForm) { try { $script:setForm.Activate() } catch {}; return }
    Update-ThemePalette
    Ensure-LlmCfgDefaults
    $script:setItems.Clear()
    $script:setChecks.Clear()
    try { if ($script:cards) { $script:cards.Clear() } } catch {}

    $W = 620; $H = 920
    $form = New-Object System.Windows.Forms.Form
    $form.Text = '小鲸鱼 · 设置'
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'CenterScreen'
    # ★ 标题栏图标：用桌宠自己的 ico（默认的 WinForms 图标太丑）
    try {
        $ip = Join-Path $PSScriptRoot '桌宠.ico'
        if (Test-Path -LiteralPath $ip) { $form.Icon = New-Object System.Drawing.Icon($ip) }
    } catch {}
    $form.ClientSize = New-Object System.Drawing.Size($W, $H)
    $form.TopMost = $false
    $form.BackColor = $script:C_BG2
    $form.Font = UiFont 10 0

    $rp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rr = 20
    $rp.AddArc(0, 0, $rr, $rr, 180, 90)
    $rp.AddArc(($W - $rr), 0, $rr, $rr, 270, 90)
    $rp.AddArc(($W - $rr), ($H - $rr), $rr, $rr, 0, 90)
    $rp.AddArc(0, ($H - $rr), $rr, $rr, 90, 90)
    $rp.CloseFigure()
    $form.Region = New-Object System.Drawing.Region($rp)
    $rp.Dispose()

    $head = New-Object System.Windows.Forms.Panel
    $head.Location = New-Object System.Drawing.Point(0, 0)
    $head.Size = New-Object System.Drawing.Size($W, 80)
    $head.BackColor = $script:C_CARD
    $form.Controls.Add($head)
    $null = New-SetLabel $head '小鲸鱼 · 设置' 30 16 300 30 15.5 $script:C_SEC $true
    $null = New-SetLabel $head '物理 / 蹦跳 / 碰撞 / 表情 / 聊天 · 保存后立即生效' 30 50 460 20 9 $script:C_SUB
    $btnX = New-Object PetUI.PetButton
    $btnX.Text = '✕'
    $btnX.Location = New-Object System.Drawing.Point(($W - 62), 20)
    $btnX.Size = New-Object System.Drawing.Size(40, 40)
    $btnX.Add_Click({ if ($script:setForm) { $script:setForm.Close() } })
    $head.Controls.Add($btnX)

    $script:dragState = @{ on = $false; sx = 0; sy = 0; fx = 0; fy = 0 }
    $head.Add_MouseDown({
        param($s, $e)
        $script:dragState.on = $true
        $script:dragState.sx = [System.Windows.Forms.Cursor]::Position.X
        $script:dragState.sy = [System.Windows.Forms.Cursor]::Position.Y
        $script:dragState.fx = $script:setForm.Left
        $script:dragState.fy = $script:setForm.Top
    })
    $head.Add_MouseMove({
        param($s, $e)
        if ($script:dragState.on) {
            $dx = [System.Windows.Forms.Cursor]::Position.X - $script:dragState.sx
            $dy = [System.Windows.Forms.Cursor]::Position.Y - $script:dragState.sy
            $script:setForm.Location = New-Object System.Drawing.Point(($script:dragState.fx + $dx), ($script:dragState.fy + $dy))
        }
    })
    $head.Add_MouseUp({ param($s, $e) $script:dragState.on = $false })

    $foot = New-Object System.Windows.Forms.Panel
    $foot.Location = New-Object System.Drawing.Point(0, ($H - 76))
    $foot.Size = New-Object System.Drawing.Size($W, 76)
    $foot.BackColor = $script:C_CARD
    $form.Controls.Add($foot)

    $btnReset = New-Object PetUI.PetButton
    $btnReset.Text = '恢复默认'
    $btnReset.Location = New-Object System.Drawing.Point(($W - 384), 20)
    $btnReset.Size = New-Object System.Drawing.Size(112, 36)
    $btnReset.Add_Click({ try { Reset-SettingsDefaults } catch {} })
    $foot.Controls.Add($btnReset)

    $btnCancel = New-Object PetUI.PetButton
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(($W - 258), 20)
    $btnCancel.Size = New-Object System.Drawing.Size(88, 36)
    $btnCancel.Add_Click({ if ($script:setForm) { $script:setForm.Close() } })
    $foot.Controls.Add($btnCancel)

    $btnSave = New-Object PetUI.PetButton
    $btnSave.Text = '保存'
    $btnSave.Primary = $true
    $btnSave.Tint = $script:C_BLUE
    $btnSave.Location = New-Object System.Drawing.Point(($W - 156), 20)
    $btnSave.Size = New-Object System.Drawing.Size(116, 38)
    $btnSave.Add_Click({ try { Save-SettingsPage } catch { [System.Windows.Forms.MessageBox]::Show("保存失败：" + $_.Exception.Message, '出错了') } })
    $foot.Controls.Add($btnSave)

    $chips = New-Object System.Windows.Forms.Panel
    $chips.Location = New-Object System.Drawing.Point(0, 80)
    $chips.Size = New-Object System.Drawing.Size($W, 46)
    $chips.BackColor = $script:C_BG2
    $form.Controls.Add($chips)
    $script:chipBtns = @{}
    $chipDefs = @(@('全部', ''), @('物理', '物理'), @('动作', '蹦跳'), @('交互', '碰撞'), @('聊天', '聊天'), @('数据', '用量'), @('工具', '工具模式'))
    $cx = 24
    foreach ($cd in $chipDefs) {
        $cb = New-Object PetUI.PetButton
        $cb.Text = [string]$cd[0]
        $cb.Size = New-Object System.Drawing.Size(70, 32)
        $cb.Location = New-Object System.Drawing.Point($cx, 8)
        $cb.Tint = $script:C_BLUE
        $chips.Controls.Add($cb)
        $script:chipBtns[[string]$cd[0]] = $cb
        $key = [string]$cd[0]; $kw = [string]$cd[1]
        $cb.Add_Click({ param($snd, $ev) try { Apply-SettingsFilter ([string]$snd.Text) } catch {} })
        $cx += 78
    }

    $body = New-Object System.Windows.Forms.Panel
    $body.Location = New-Object System.Drawing.Point(0, 126)
    $body.Size = New-Object System.Drawing.Size($W, ($H - 126 - 76))
    $body.AutoScroll = $true
    $body.BackColor = $script:C_BG2
    $form.Controls.Add($body)
    $script:setBody = $body
    $script:setHead = $head
    $script:setFoot = $foot
    $script:bodyW = $W - 48
    $script:curY = 18

    $b1 = New-CardBlock '物理' '甩出去之后的手感'
    Add-SliderRow $b1 '重力' '物理.重力' 0.3 1.8 2
    Add-SliderRow $b1 '弹跳' '物理.弹跳' 0.10 0.90 2
    Add-SliderRow $b1 '摔疼门槛' '物理.摔疼冲击门槛' 6 26 1
    Add-SliderRow $b1 '撞墙冷却 s' '行为.撞墙冷却秒数' 0.2 4.0 1
    Add-SliderRow $b1 '甩出阈值（越小越容易飞）' '物理.甩出阈值' 0.5 4.0 1
    Add-PresetRow $b1 '预设' @(
        @{ n = '轻盈'; v = @{ '物理.重力' = 0.6; '物理.弹跳' = 0.68; '物理.摔疼冲击门槛' = 18 } },
        @{ n = '标准'; v = @{ '物理.重力' = 0.85; '物理.弹跳' = 0.52; '物理.摔疼冲击门槛' = 13 } },
        @{ n = '真实'; v = @{ '物理.重力' = 1.3; '物理.弹跳' = 0.35; '物理.摔疼冲击门槛' = 10 } }
    )
    Close-CardBlock $b1

    $b2 = New-CardBlock '蹦跳' '她的特殊移动方式'
    Add-SliderRow $b2 '触发概率 %' '行为.蹦跳概率百分比' 0 100 0
    Add-SliderRow $b2 '跳多高 px' '行为.蹦跳高度' 6 60 0
    Add-SliderRow $b2 '连跳次数' '行为.蹦跳次数' 1 6 0
    Add-SliderRow $b2 '水平速度' '行为.蹦跳水平速度' 0 10 1
    Add-SliderRow $b2 '游走速度' '行为.游走速度倍率' 0.3 2.0 1
# 滚动大小已固定 1:1（最清晰）
Add-SliderRow $b2 '滚动速度档 1~4' '行为.滚动速度档位' 1 4 0
    # 走路帧选项已移除（现在用滚动）
    Add-ToggleRow $b2 '待机·坐下' '行为.允许坐下'
    Add-ToggleRow $b2 '待机·张望' '行为.允许张望'
    Add-ToggleRow $b2 '待机·伸懒腰' '行为.允许伸懒腰'
    Add-SliderRow $b2 '走路步频 ms' '行为.走路步频毫秒' 120 600 0
    Add-PresetRow $b2 '预设' @(
        @{ n = '小跳'; v = @{ '行为.蹦跳概率百分比' = 12; '行为.蹦跳高度' = 12; '行为.蹦跳次数' = 2; '行为.蹦跳水平速度' = 1.6 } },
        @{ n = '标准'; v = @{ '行为.蹦跳概率百分比' = 22; '行为.蹦跳高度' = 20; '行为.蹦跳次数' = 3; '行为.蹦跳水平速度' = 3.2 } },
        @{ n = '疯跳'; v = @{ '行为.蹦跳概率百分比' = 45; '行为.蹦跳高度' = 34; '行为.蹦跳次数' = 4; '行为.蹦跳水平速度' = 6.0 } }
    )
    Close-CardBlock $b2

    $b3 = New-CardBlock '表情与说话' '防止表情和台词互相打架'
    Add-ToggleRow $b3 '悬停会害羞' '互动.悬停害羞'
    Add-SliderRow $b3 '害羞要摸够(约秒)' '互动.害羞需要次数' 1 10 0
    Add-SliderRow $b3 '待机动作间隔 s' '行为.待机动作间隔秒数' 10 90 0
    Add-SliderRow $b3 '待机动作概率 %' '行为.待机动作概率百分比' 0 100 0
    Add-SliderRow $b3 '表情切换 s' '表情.最短切换秒数' 0.2 4.0 1
    Add-SliderRow $b3 '说话锁 s' '气泡.锁秒数' 0.5 6.0 1
    Add-SliderRow $b3 '闲聊间隔 s' '气泡.最短间隔秒数' 5 60 0
    Add-SliderRow $b3 '场景检查 s' '行为.场景感知.检查秒数' 10 300 0
    Close-CardBlock $b3

    $b4 = New-CardBlock '碰撞反应' '撞到窗口时的反应概率'
    Add-SliderRow $b4 '吃痛' '碰撞.反应权重.吃痛' 0 100 0
    Add-SliderRow $b4 '生气' '碰撞.反应权重.生气' 0 100 0
    Add-SliderRow $b4 '抱怨' '碰撞.反应权重.抱怨' 0 100 0
    Add-SliderRow $b4 '惊讶' '碰撞.反应权重.惊讶' 0 100 0
    Add-PresetRow $b4 '预设' @(
        @{ n = '少哭'; v = @{ '碰撞.反应权重.吃痛' = 25; '碰撞.反应权重.生气' = 25; '碰撞.反应权重.抱怨' = 40; '碰撞.反应权重.惊讶' = 10 } },
        @{ n = '标准'; v = @{ '碰撞.反应权重.吃痛' = 55; '碰撞.反应权重.生气' = 20; '碰撞.反应权重.抱怨' = 20; '碰撞.反应权重.惊讶' = 5 } },
        @{ n = '爱生气'; v = @{ '碰撞.反应权重.吃痛' = 20; '碰撞.反应权重.生气' = 60; '碰撞.反应权重.抱怨' = 15; '碰撞.反应权重.惊讶' = 5 } }
    )
    Close-CardBlock $b4

    $b5 = New-CardBlock '功能开关'
    Add-ToggleRow $b5 '物理拖拽（能甩飞）' '物理.启用'
    Add-ToggleRow $b5 '碰撞反应' '碰撞.启用'
    Add-ToggleRow $b5 '认亲（DeepSeek Harness）' '碰撞.认亲启用'
    Add-ToggleRow $b5 '被框住检测' '行为.被框检测.启用'
    Add-ToggleRow $b5 '窗口感知（场景台词）' '行为.场景感知.启用'
    Add-ToggleRow $b5 '语音（她开口说话）' '语音.启用'
    Add-ToggleRow $b5 '聊天功能' '聊天.启用'
    Add-ToggleRow $b5 '点击音效' '音效.启用'
    Add-SliderRow $b5 '音效音量 0~100' '音效.音量' 0 100 0
    Close-CardBlock $b5

    # ---- 语音 ----
    $b7 = New-CardBlock '语音' '让她真的开口说话（edge=免费联网 / sapi=离线）'
    $yV = $b7.y
    $null = New-SetLabel $b7.card '引擎' 18 ($yV + 3) 70 22 9 $script:C_INK $false
    $segV = New-Object PetUI.PetSegmented
    $segV.Location = New-Object System.Drawing.Point(96, ($yV - 3))
    $segV.Size = New-Object System.Drawing.Size(160, 28)
    $segV.Items = @('Edge 免费', 'SAPI 离线')
    $segV.Tint = $script:C_BLUE
    $b7.card.Controls.Add($segV)
    $script:setVoiceSeg = $segV

    $btnVoice = New-Object PetUI.PetButton
    $btnVoice.Text = '试听'
    $btnVoice.Location = New-Object System.Drawing.Point(272, ($yV - 3))
    $btnVoice.Size = New-Object System.Drawing.Size(70, 28)
    $btnVoice.Add_Click({
        try {
            if ($script:setVoiceSeg) { Set-CfgValue $script:cfg '语音.引擎' $(if ($script:setVoiceSeg.SelectedIndex -eq 1) { 'sapi' } else { 'edge' }) }
            [System.IO.File]::WriteAllText($script:settingsCfg, ($script:cfg | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
            $r = Test-Voice '你好呀，我是小鲸鱼。'
            if ($script:setApiResult) { }
        } catch {}
    })
    $b7.card.Controls.Add($btnVoice)
    $b7.y = $yV + 34

    # 音色（点击循环切换）
    $voiceList = @('zh-CN-XiaoxiaoNeural', 'zh-CN-XiaoyiNeural', 'zh-CN-liaoning-XiaobeiNeural', 'zh-CN-shaanxi-XiaoniNeural')
    $null = New-SetLabel $b7.card '音色' 18 ($b7.y + 3) 70 22 9 $script:C_INK $false
    $btnVoiceName = New-Object PetUI.PetButton
    $btnVoiceName.Text = $(if ($script:cfg -and $script:cfg.语音) { $script:cfg.语音.音色 } else { 'zh-CN-XiaoxiaoNeural' })
    $btnVoiceName.Location = New-Object System.Drawing.Point(96, ($b7.y - 3))
    $btnVoiceName.Size = New-Object System.Drawing.Size(246, 28)
    $btnVoiceName.Add_Click({
        try {
            $cur = [string]$script:cfg.语音.音色
            $idx = [Array]::IndexOf($voiceList, $cur)
            if ($idx -lt 0) { $idx = -1 }
            $next = $voiceList[($idx + 1) % $voiceList.Count]
            Set-CfgValue $script:cfg '语音.音色' $next
            $script:setVoiceNameBtn.Text = $next
            [System.IO.File]::WriteAllText($script:settingsCfg, ($script:cfg | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
            $r = Test-Voice '这个音色怎么样？'
        } catch {}
    })
    $b7.card.Controls.Add($btnVoiceName)
    $script:setVoiceNameBtn = $btnVoiceName
    $b7.y = $b7.y + 34
    Close-CardBlock $b7

    # ---- 本地数据 / 导入 ----
    $b9 = New-CardBlock '本地数据 / 导入' '全部只在本机处理 · 不联网上传'
    $y9 = $b9.y

    $btnImportLines = New-Object PetUI.PetButton
    $btnImportLines.Text = '导入台词'
    $btnImportLines.Location = New-Object System.Drawing.Point(18, $y9)
    $btnImportLines.Size = New-Object System.Drawing.Size(104, 30)
    $btnImportLines.Add_Click({
        try {
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = '台词文件 (*.txt;*.json)|*.txt;*.json'
            $ofd.Title = '选择台词文件（txt 每行一句 / json 台词包）'
            if ($ofd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $src = $ofd.FileName
            $packDir = Join-Path (Split-Path $script:settingsCfg) '台词包'
            if (-not (Test-Path $packDir)) { New-Item -ItemType Directory -Path $packDir -Force | Out-Null }
            if ($src.ToLower().EndsWith('.json')) {
                $dst = Join-Path $packDir ('导入-' + (Get-Date -Format 'MMdd-HHmmss') + '.json')
                Copy-Item $src $dst -Force
            } else {
                $linesRaw = Get-Content $src -Encoding UTF8 | Where-Object { $_.Trim().Length -gt 0 }
                $arr = @()
                foreach ($ln in $linesRaw) { $arr += $ln.Trim() }
                $obj = [pscustomobject]@{ '普通' = $arr }
                $dst = Join-Path $packDir ('导入-' + (Get-Date -Format 'MMdd-HHmmss') + '.json')
                $obj | ConvertTo-Json -Depth 5 | Set-Content $dst -Encoding UTF8
            }
            # 热重载
            $r = $null
            try { $r = Reload-Lines } catch {}
            if ($script:setUsageToday) {
                if ($r -and $r.ok) { $script:setUsageToday.Text = ('台词已导入：共 ' + $r.total + ' 条（已生效）') }
                else { $script:setUsageToday.Text = '台词已导入（重启后生效）' }
            }
        } catch { }
    })
    $b9.card.Controls.Add($btnImportLines)

    $btnExportCfg = New-Object PetUI.PetButton
    $btnExportCfg.Text = '导出配置'
    $btnExportCfg.Location = New-Object System.Drawing.Point(130, $y9)
    $btnExportCfg.Size = New-Object System.Drawing.Size(104, 30)
    $btnExportCfg.Add_Click({
        try {
            $sfd = New-Object System.Windows.Forms.SaveFileDialog
            $sfd.Filter = '配置文件 (*.json)|*.json'
            $sfd.FileName = ('小鲸鱼配置-' + (Get-Date -Format 'MMdd') + '.json')
            if ($sfd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            Copy-Item $script:settingsCfg $sfd.FileName -Force
            if ($script:setUsageToday) { $script:setUsageToday.Text = ('配置已导出到：' + $sfd.FileName) }
        } catch { }
    })
    $b9.card.Controls.Add($btnExportCfg)

    $btnClearVoice = New-Object PetUI.PetButton
    $btnClearVoice.Text = '清语音缓存'
    $btnClearVoice.Location = New-Object System.Drawing.Point(242, $y9)
    $btnClearVoice.Size = New-Object System.Drawing.Size(104, 30)
    $btnClearVoice.Add_Click({
        try {
            $vd = Join-Path (Split-Path $script:settingsCfg) '.cache\voice'
            $n = 0
            if (Test-Path $vd) {
                $n = (Get-ChildItem $vd -File).Count
                Get-ChildItem $vd -File | Remove-Item -Force -ErrorAction SilentlyContinue
            }
            if ($script:setUsageToday) { $script:setUsageToday.Text = ('已清空语音缓存（' + $n + ' 个文件）') }
        } catch { }
    })
    $b9.card.Controls.Add($btnClearVoice)

    $btnOpenDir = New-Object PetUI.PetButton
    $btnOpenDir.Text = '打开目录'
    $btnOpenDir.Location = New-Object System.Drawing.Point(354, $y9)
    $btnOpenDir.Size = New-Object System.Drawing.Size(94, 30)
    $btnOpenDir.Add_Click({
        try { Start-Process explorer.exe (Split-Path $script:settingsCfg) } catch {}
    })
    $b9.card.Controls.Add($btnOpenDir)

    $btnBackupCfg = New-Object PetUI.PetButton
    $btnBackupCfg.Text = '备份配置'
    $btnBackupCfg.Location = New-Object System.Drawing.Point(18, ($y9 + 36))
    $btnBackupCfg.Size = New-Object System.Drawing.Size(104, 30)
    $btnBackupCfg.Add_Click({
        try {
            $bk = Join-Path (Split-Path $script:settingsCfg) '_backup'
            if (-not (Test-Path $bk)) { New-Item -ItemType Directory -Path $bk -Force | Out-Null }
            $dst = Join-Path $bk ('config-' + (Get-Date -Format 'MMdd-HHmmss') + '.json')
            Copy-Item $script:settingsCfg $dst -Force
            if ($script:setUsageToday) { $script:setUsageToday.Text = ('已备份：' + (Split-Path $dst -Leaf)) }
        } catch { }
    })
    $b9.card.Controls.Add($btnBackupCfg)

    $null = New-SetLabel $b9.card '小鲸鱼桌宠 v1.1 · 本地运行 · 代码/美术：自己做的（AI 辅助）' 130 ($y9 + 43) 340 20 7.5 $script:C_SUB $false

    $y9 += 74
    $null = New-SetLabel $b9.card '隐私：台词/配置/语音缓存都只在本机；只有 Edge 语音会联网（可切 SAPI 离线）' 18 $y9 480 34 7.5 $script:C_SUB $false
    $b9.y = $y9 + 36
    Close-CardBlock $b9

    # ---- 用量 / 余额 ----
    # ===== 聊天直连（OpenAI 兼容） =====
    $bBackend = New-CardBlock '聊天直连' 'OpenAI 兼容 · DeepSeek / 硅基流动 / OpenRouter / Ollama / 自定义'
    $cardB = $bBackend.card
    $stB = New-SetLabel $cardB '' 18 $bBackend.y 500 34 9 $script:C_SUB $false
    $stB.AutoSize = $false
    $script:setBackendStatus = $stB
    $stB.Text = Refresh-ChatBackendStatus
    $bBackend.y += 40

    # 模式：离线 / 直连
    $null = New-SetLabel $cardB '模式' 18 ($bBackend.y + 6) 70 20 9 $script:C_INK $false
    $modeList = @(
        @{ k = 'offline'; t = '离线' },
        @{ k = 'api';     t = '直连' }
    )
    $mx = 90
    foreach ($m in $modeList) {
        $btn = New-Object PetUI.PetButton
        $btn.Text = $m.t
        $btn.Location = New-Object System.Drawing.Point($mx, $bBackend.y)
        $btn.Size = New-Object System.Drawing.Size(96, 30)
        $btn.Tag = $m.k
        $btn.Tint = $script:C_BLUE
        $btn.Add_Click({
            param($s2, $e2)
            try {
                $k = [string]$s2.Tag
                Set-CfgValue '聊天.模式' $k
                $script:chatMode = $k
                try { Clear-LlmDown } catch {}
                [void](Save-CfgNow)
                if ($script:setBackendStatus) { $script:setBackendStatus.Text = Refresh-ChatBackendStatus }
            } catch {}
        })
        $cardB.Controls.Add($btn)
        $mx += 104
    }
    $bBackend.y += 38

    # 服务商预设（点一下 = 换地址 + 换模型 + 切直连）
    $null = New-SetLabel $cardB '服务商' 18 ($bBackend.y + 6) 70 20 9 $script:C_INK $false
    $px = 90
    $presetList = @('deepseek', 'siliconflow', 'openrouter', 'ollama', 'custom')
    foreach ($pid2 in $presetList) {
        $pb = New-Object PetUI.PetButton
        $pb.Text = [string]$script:llmPresets[$pid2].name
        $pb.Location = New-Object System.Drawing.Point($px, $bBackend.y)
        $pb.Size = New-Object System.Drawing.Size(88, 30)
        $pb.Tag = $pid2
        $pb.Tint = $script:C_BLUE
        $pb.Add_Click({
            param($s3, $e3)
            try {
                $id = [string]$s3.Tag
                Set-CfgValue '聊天.直连.预设' $id
                Set-CfgValue '聊天.直连.接口' [string]$script:llmPresets[$id].url
                Set-CfgValue '聊天.直连.模型' [string]$script:llmPresets[$id].model
                Set-CfgValue '聊天.模式' 'api'
                $script:chatMode = 'api'
                try { Clear-LlmDown } catch {}
                [void](Save-CfgNow)
                if ($script:setTbUrl) { $script:setTbUrl.Text = [string]$script:llmPresets[$id].url }
                if ($script:setTbModel) { $script:setTbModel.Text = [string]$script:llmPresets[$id].model }
                if ($script:setBackendStatus) { $script:setBackendStatus.Text = Refresh-ChatBackendStatus }
                Refresh-SetApiStatus
            } catch {}
        })
        $cardB.Controls.Add($pb)
        $px += 92
    }
    $bBackend.y += 38

    # 接口地址
    $null = New-SetLabel $cardB '接口' 18 ($bBackend.y + 5) 70 20 9 $script:C_INK $false
    $tbUrl = New-Object System.Windows.Forms.TextBox
    $tbUrl.BorderStyle = 'FixedSingle'
    $tbUrl.Font = UiFont 8.5 0
    $tbUrl.Location = New-Object System.Drawing.Point(90, $bBackend.y)
    $tbUrl.Size = New-Object System.Drawing.Size(440, 24)
    $tbUrl.Text = Get-LlmUrlText
    $tbUrl.Add_TextChanged({ try { Set-CfgValue '聊天.直连.接口' $script:setTbUrl.Text } catch {} })
    $script:setTbUrl = $tbUrl
    $cardB.Controls.Add($tbUrl)
    $bBackend.y += 30

    # 模型
    $null = New-SetLabel $cardB '模型' 18 ($bBackend.y + 5) 70 20 9 $script:C_INK $false
    $tbModel = New-Object System.Windows.Forms.TextBox
    $tbModel.BorderStyle = 'FixedSingle'
    $tbModel.Font = UiFont 9 0
    $tbModel.Location = New-Object System.Drawing.Point(90, $bBackend.y)
    $tbModel.Size = New-Object System.Drawing.Size(280, 24)
    $tbModel.Text = Get-LlmModelText
    $tbModel.Add_TextChanged({ try { Set-CfgValue '聊天.直连.模型' $script:setTbModel.Text } catch {} })
    $script:setTbModel = $tbModel
    $cardB.Controls.Add($tbModel)
    $bBackend.y += 34

    Add-SliderRow $bBackend '带几轮上下文' '聊天.直连.历史条数' 0 20 0

    $btnTestB = New-Object PetUI.PetButton
    $btnTestB.Text = '测试连接'
    $btnTestB.Primary = $true
    $btnTestB.Tint = $script:C_BLUE
    $btnTestB.Location = New-Object System.Drawing.Point(18, $bBackend.y)
    $btnTestB.Size = New-Object System.Drawing.Size(112, 32)
    $btnTestB.Add_Click({
        try {
            if ($script:setTbUrl) { Set-CfgValue '聊天.直连.接口' $script:setTbUrl.Text }
            if ($script:setTbModel) { Set-CfgValue '聊天.直连.模型' $script:setTbModel.Text }
            [void](Save-CfgNow)
            $script:setBackendStatus.Text = '测试中…'
            $script:setBackendStatus.ForeColor = $script:C_SUB
            [System.Windows.Forms.Application]::DoEvents()
            $r = Test-ChatBackend
            if ($r.ok) {
                $script:setBackendStatus.ForeColor = [System.Drawing.Color]::FromArgb(30, 150, 80)
                $script:setBackendStatus.Text = ('✓ ' + [string]$r.msg)
            } else {
                $script:setBackendStatus.ForeColor = [System.Drawing.Color]::FromArgb(190, 70, 70)
                $script:setBackendStatus.Text = ('✗ ' + [string]$r.msg)
            }
        } catch { $script:setBackendStatus.Text = ('出错：' + $_.Exception.Message) }
    })
    $cardB.Controls.Add($btnTestB)
    $bBackend.y += 40

    $null = New-SetLabel $cardB 'Ollama 要先 ollama serve 并拉好模型；换服务商后要重新填对应 Key' 18 $bBackend.y 500 34 7.5 $script:C_SUB $false
    $bBackend.y += 34
    Close-CardBlock $bBackend

    $b8 = New-CardBlock '用量 / 余额' '读 DSH 本地用量文件 · 不联网'
    $lblToday = New-SetLabel $b8.card '' 18 $b8.y 460 20 9.5 $script:C_INK $false
    $script:setUsageToday = $lblToday
    $b8.y += 24
    $lblWeek = New-SetLabel $b8.card '' 18 $b8.y 470 132 8.0 $script:C_SUB $false
    $script:setUsageWeek = $lblWeek
    $b8.y += 136

    $btnUsageRefresh = New-Object PetUI.PetButton
    $btnUsageRefresh.Text = '刷新'
    $btnUsageRefresh.Location = New-Object System.Drawing.Point(18, $b8.y)
    $btnUsageRefresh.Size = New-Object System.Drawing.Size(76, 28)
    $btnUsageRefresh.Add_Click({ try { Refresh-UsagePanel } catch {} })
    $b8.card.Controls.Add($btnUsageRefresh)

    $tgUsage = New-Object PetUI.PetToggle
    $tgUsage.Location = New-Object System.Drawing.Point(430, ($b8.y + 1))
    $tgUsage.Tint = $script:C_BLUE
    $b8.card.Controls.Add($tgUsage)
    [void]$script:setChecks.Add(@{ path = '用量.提醒启用'; toggle = $tgUsage })
    $null = New-SetLabel $b8.card '超阈值提醒' 300 ($b8.y + 3) 120 20 8.5 $script:C_INK $false
    $b8.y += 36

    # 余额定时播报（开关 + 间隔 + 台词池）
    $tgBroadcast = New-Object PetUI.PetToggle
    $tgBroadcast.Location = New-Object System.Drawing.Point(430, ($b8.y + 1))
    $tgBroadcast.Tint = $script:C_BLUE
    $b8.card.Controls.Add($tgBroadcast)
    [void]$script:setChecks.Add(@{ path = '用量.余额播报'; toggle = $tgBroadcast })
    $null = New-SetLabel $b8.card '余额定时播报' 300 ($b8.y + 3) 120 20 8.5 $script:C_INK $false
    $b8.y += 36
    Add-SliderRow $b8 '播报间隔 分钟' '用量.余额播报分钟数' 15 180 0

    # 充值网址（默认 DeepSeek 平台；想换别的地址就改这里）
    $null = New-SetLabel $b8.card '充值网址' 26 ($b8.y + 8) 90 24 10.5 $script:C_INK $false
    $tbRecharge = New-Object System.Windows.Forms.TextBox
    $tbRecharge.BorderStyle = 'FixedSingle'
    $tbRecharge.Font = UiFont 8.5 0
    $tbRecharge.Location = New-Object System.Drawing.Point(120, $b8.y)
    $tbRecharge.Size = New-Object System.Drawing.Size(410, 24)
    $tbRecharge.Text = [string](Cfg '用量.充值网址' 'https://platform.deepseek.com/top_up')
    $tbRecharge.Add_TextChanged({ try { Set-CfgValue '用量.充值网址' $script:setTbRecharge.Text } catch {} })
    $script:setTbRecharge = $tbRecharge
    $b8.card.Controls.Add($tbRecharge)
    $b8.y += 32

        # ===== 工具模式 =====
    $bTool = New-CardBlock '工具模式' '缩成角落小挂件 · 番茄钟 / 久坐 / 笔记'
    Add-SliderRow $bTool '挂件样式 1头2胶3条' '模式.挂件样式' 1 3 0
    Add-SliderRow $bTool '番茄工作 分钟' '模式.番茄工作分钟' 5 60 0
    Add-SliderRow $bTool '番茄休息 分钟' '模式.番茄休息分钟' 1 20 0
    Add-SliderRow $bTool '久坐提醒 分钟' '模式.久坐提醒分钟' 0 120 0
    Add-ToggleRow $bTool '鼠标穿透（挂着不挡点击）' '模式.鼠标穿透'
    Add-ToggleRow $bTool '工具模式静音' '模式.工具模式静音'
Add-SliderRow $b8 '今日花费超 ¥' '用量.今日花费阈值' 1 50 0
    Add-SliderRow $b8 '余额低于 ¥' '用量.余额低于' 0 20 1
    Close-CardBlock $b8

    $b6 = New-CardBlock '聊天 API Key' '只存本机 · DPAPI 加密 · 每家服务商各存一份'
    $card6 = $b6.card
    $who = New-SetLabel $card6 '' 18 $b6.y 500 18 8.5 $script:C_SUB $false
    $who.AutoSize = $false
    $script:setApiKeyWho = $who
    $b6.y += 22
    $st = New-SetLabel $card6 '' 18 $b6.y 500 20 9 $script:C_SUB $false
    $st.AutoSize = $false
    $script:setApiStatus = $st
    $b6.y += 26

    $boxWrap = New-Object PetUI.PetCard
    $boxWrap.FillColor = [System.Drawing.Color]::FromArgb(246, 250, 255)
    $boxWrap.LineColor = [System.Drawing.Color]::FromArgb(206, 224, 246)
    $boxWrap.Radius = 10
    $boxWrap.Location = New-Object System.Drawing.Point(16, $b6.y)
    $boxWrap.Size = New-Object System.Drawing.Size(430, 40)
    $card6.Controls.Add($boxWrap)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $tb.UseSystemPasswordChar = $true
    $tb.Font = UiFont 9 0
    $tb.Location = New-Object System.Drawing.Point(14, 9)
    $tb.Size = New-Object System.Drawing.Size(266, 20)
    $tb.BackColor = [System.Drawing.Color]::FromArgb(246, 250, 255)
    $boxWrap.Controls.Add($tb)
    $script:setApiBox = $tb

    $btnSaveKey = New-Object PetUI.PetButton
    $btnSaveKey.Text = '保存并测试'
    $btnSaveKey.Primary = $true
    $btnSaveKey.Tint = $script:C_BLUE
    $btnSaveKey.Location = New-Object System.Drawing.Point(288, 7)
    $btnSaveKey.Size = New-Object System.Drawing.Size(132, 26)
    $btnSaveKey.Add_Click({
        try {
            $k = ($script:setApiBox.Text -as [string]).Trim()
            if (-not $k) { $script:setApiResult.Text = '请先粘贴 key'; $script:setApiResult.ForeColor = $script:C_SUB; return }
            $presetId = Get-LlmPresetId
            if (-not (Save-LlmKey $presetId $k)) { $script:setApiResult.Text = '保存失败'; return }
            $script:setApiBox.Text = ''
            Refresh-SetApiStatus
            $script:setApiResult.Text = '正在测试…'
            $script:setApiResult.ForeColor = $script:C_SUB
            [System.Windows.Forms.Application]::DoEvents()
            $r = Test-ChatBackend
            if ($r.ok) {
                $script:setApiResult.ForeColor = [System.Drawing.Color]::FromArgb(30, 150, 80)
                $script:setApiResult.Text = '✓ ' + $r.msg
            } else {
                $script:setApiResult.ForeColor = [System.Drawing.Color]::FromArgb(190, 70, 70)
                $script:setApiResult.Text = '✗ ' + $r.msg
            }
        } catch { $script:setApiResult.Text = '出错：' + $_.Exception.Message }
    })
    $boxWrap.Controls.Add($btnSaveKey)
    $b6.y += 54

    $btnTest = New-Object PetUI.PetButton
    $btnTest.Text = '测试连接'
    $btnTest.Location = New-Object System.Drawing.Point(16, $b6.y)
    $btnTest.Size = New-Object System.Drawing.Size(96, 30)
    $btnTest.Add_Click({
        try {
            $script:setApiResult.Text = '测试中…'
            $script:setApiResult.ForeColor = $script:C_SUB
            [System.Windows.Forms.Application]::DoEvents()
            $r = Test-ChatBackend
            if ($r.ok) {
                $script:setApiResult.ForeColor = [System.Drawing.Color]::FromArgb(30, 150, 80)
                $script:setApiResult.Text = '✓ ' + $r.msg
            } else {
                $script:setApiResult.ForeColor = [System.Drawing.Color]::FromArgb(190, 70, 70)
                $script:setApiResult.Text = '✗ ' + $r.msg
            }
        } catch {}
    })
    $card6.Controls.Add($btnTest)

    $btnDelKey = New-Object PetUI.PetButton
    $btnDelKey.Text = '删除 Key'
    $btnDelKey.Location = New-Object System.Drawing.Point(120, $b6.y)
    $btnDelKey.Size = New-Object System.Drawing.Size(92, 30)
    $btnDelKey.Add_Click({
        try {
            Remove-LlmKey (Get-LlmPresetId)
            Refresh-SetApiStatus
            $script:setApiResult.ForeColor = $script:C_SUB
            $script:setApiResult.Text = '已删除这个服务商的 key'
        } catch {}
    })
    $card6.Controls.Add($btnDelKey)

    $res = New-SetLabel $card6 '' 222 ($b6.y + 2) 270 34 8.5 $script:C_SUB $false
    $res.AutoSize = $false
    $script:setApiResult = $res
    $b6.y += 40

    $use = New-SetLabel $card6 '' 16 $b6.y 460 18 7.5 $script:C_SUB $false
    $script:setApiUsage = $use
    $b6.y += 26
    $null = New-SetLabel $card6 'Key 去哪拿：platform.deepseek.com · cloud.siliconflow.cn · openrouter.ai/keys（Ollama 不用 Key）' 16 $b6.y 500 18 7.5 $script:C_SUB $false
    $b6.y += 22
    Close-CardBlock $b6

    $tip = New-SetLabel $body '提示：物理 / 蹦跳 / 碰撞 / 表情 / 说话 保存后立即生效；缩放与置顶需重启' 22 ($script:curY + 2) 480 32 7.5 $script:C_SUB $false
    $body.Controls.Add($tip)

    $form.Add_FormClosed({ $script:setForm = $null })

    # ---- 主题切换（浅色 / 深色）----
    try {
        $tLight = New-Object PetUI.PetButton
        $tLight.Text = '浅色'; $tLight.Size = New-Object System.Drawing.Size(64, 32)
        $tLight.Location = New-Object System.Drawing.Point(24, 22)
        $tLight.Tint = $script:C_BLUE
        if ($foot) { $foot.Controls.Add($tLight) } else { $head.Controls.Add($tLight) }
        $tDark = New-Object PetUI.PetButton
        $tDark.Text = '深色'; $tDark.Size = New-Object System.Drawing.Size(64, 32)
        $tDark.Location = New-Object System.Drawing.Point(98, 22)
        $tDark.Tint = $script:C_BLUE
        if ($foot) { $foot.Controls.Add($tDark) } else { $head.Controls.Add($tDark) }
        $tLight.Add_Click({ try { Set-CfgValue '界面.主题' 'light'; if ($script:settingsCfg -and $script:cfg) { $script:cfg | ConvertTo-Json -Depth 12 | Set-Content $script:settingsCfg -Encoding UTF8 }; if ($script:setForm) { $script:setForm.Close() }
        $script:themeTimer = New-Object System.Windows.Forms.Timer
        $script:themeTimer.Interval = 180
        $script:themeTimer.Add_Tick({ try { $script:themeTimer.Stop(); $script:themeTimer.Dispose(); $script:themeTimer = $null } catch {}; try { Show-Settings } catch {} })
        $script:themeTimer.Start() } catch {} })
        $tDark.Add_Click({ try { Set-CfgValue '界面.主题' 'dark'; if ($script:settingsCfg -and $script:cfg) { $script:cfg | ConvertTo-Json -Depth 12 | Set-Content $script:settingsCfg -Encoding UTF8 }; if ($script:setForm) { $script:setForm.Close() }
        $script:themeTimer = New-Object System.Windows.Forms.Timer
        $script:themeTimer.Interval = 180
        $script:themeTimer.Add_Tick({ try { $script:themeTimer.Stop(); $script:themeTimer.Dispose(); $script:themeTimer = $null } catch {}; try { Show-Settings } catch {} })
        $script:themeTimer.Start() } catch {} })
        Apply-ThemeRecolor $form
        Set-PetButtonsTheme $form
    } catch {}

    $script:setForm = $form
    Load-SettingsPage
    try {
        $form.Show()
        $form.TopMost = $false
        $form.Activate()
        $form.BringToFront()
        [System.Windows.Forms.Application]::DoEvents()
    } catch {}
    if ($script:reopenSettings) { $script:reopenSettings = $false; Start-Sleep -Milliseconds 120; Show-Settings }
}

function Refresh-UsagePanel {
    try {
        if ($script:setUsageToday) {
            $u = Get-DshUsage
            if ($u.ok) {
                $tokTxt = if ($u.tokens -ge 100000000) { [string][Math]::Round($u.tokens/100000000.0,2) + ' 亿' }
                          elseif ($u.tokens -ge 10000) { [string][Math]::Round($u.tokens/10000.0,1) + ' 万' }
                          else { [string]$u.tokens }
                $script:setUsageToday.Text = ('今日 ' + $u.count + ' 次 · ' + $tokTxt + ' tokens · ¥' + [Math]::Round($u.cost,2) + ' · 余额 ¥' + [Math]::Round($u.balance,2))
                $script:setUsageToday.ForeColor = $script:C_SEC
            } else {
                $script:setUsageToday.Text = ('读不到用量：' + $u.error)
                $script:setUsageToday.ForeColor = $script:C_SUB
            }
        }
        if ($script:setUsageWeek) {
            $lines = Format-UsageWeekLines
            $script:setUsageWeek.Text = ($lines -join "`r`n")
        }
    } catch {}
}

function Refresh-SetApiStatus {
    try {
        $id = 'deepseek'
        try { $id = Get-LlmPresetId } catch {}
        $presetName = ''
        try { $presetName = [string]$script:llmPresets[$id].name } catch {}
        if ($script:setApiKeyWho) {
            $script:setApiKeyWho.Text = '当前服务商：' + $presetName + '（每家各存一份 key，换预设要重新填）'
        }
        if ($script:setApiStatus) {
            $st = @{ configured = $false; masked = '' }
            try { $st = Get-LlmKeyState $id } catch {}
            if ($st.configured) {
                $script:setApiStatus.Text = '● ' + $presetName + ' 已配置 ' + [string]$st.masked
                $script:setApiStatus.ForeColor = [System.Drawing.Color]::FromArgb(30, 150, 80)
            }
            else {
                $script:setApiStatus.Text = '● ' + $presetName + ' 未配置 · 会自动回落到离线台词'
                $script:setApiStatus.ForeColor = $script:C_SUB
            }
        }
        if ($script:setApiUsage) {
            $u = Get-ApiUsage
            $cost = ($u.prompt / 1000000.0 * 1.0) + ($u.completion / 1000000.0 * 4.0)
            $script:setApiUsage.Text = ('今日 ' + $u.count + ' 条 · ' + $u.total + ' tokens · 约 ¥' + [Math]::Round($cost, 4) + '（本地估算）')
        }
    } catch {}
}

function Load-SettingsPage {
    foreach ($it in $script:setItems) {
        $cur = Cfg $it.path $it.min
        try {
            $it.slider.SetVal([double]$cur)
            $it.val.Text = [Math]::Round($it.slider.Value, $it.dec).ToString()
        } catch {}
    }
    foreach ($ck in $script:setChecks) {
        $cur = Cfg $ck.path $true
        $ck.toggle.Checked = [bool]$cur
    }
    if ($script:setVoiceSeg) {
        $ve = [string](Cfg '语音.引擎' 'edge')
        $script:setVoiceSeg.SelectedIndex = if ($ve -eq 'sapi') { 1 } else { 0 }
    }
    if ($script:setVoiceNameBtn) {
        $vn = [string](Cfg '语音.音色' 'zh-CN-XiaoxiaoNeural')
        $script:setVoiceNameBtn.Text = $vn
    }
    if ($script:setSeg) {
        $m = [string](Cfg '聊天.模式' 'offline')
        $script:setSeg.SelectedIndex = if ($m -eq 'api') { 1 } else { 0 }
    }
    try { Refresh-UsagePanel } catch {}
    try { Refresh-SetApiStatus } catch {}
}

function Save-SettingsPage {
    $cfgPath = $script:settingsCfg
    # ★ 以内存里的 $script:cfg 为准：文本框（接口/模型等）是即时改在内存里的，
    #   以前从磁盘重读会把它们丢掉（聊天地址改了不生效）
    $root = $script:cfg
    if (-not $root) {
        if (Test-Path $cfgPath) {
            try { $root = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        }
    }
    if (-not $root) { $root = [pscustomobject]@{} }

    foreach ($it in $script:setItems) {
        $v = [Math]::Round($it.slider.Value, $it.dec)
        Set-CfgValue $root $it.path $v
    }
    foreach ($ck in $script:setChecks) {
        Set-CfgValue $root $ck.path ([bool]$ck.toggle.Checked)
    }
    if ($script:setSeg) {
        Set-CfgValue $root '聊天.模式' $(if ($script:setSeg.SelectedIndex -eq 1) { 'api' } else { 'offline' })
    }
    $json = $root | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    $script:cfg = $root
    try { if ($script:setForm) { $script:setForm.Close() } } catch {}
    try { Say-Something 0 @('设置好了，谢谢。') 60 } catch {}
}

function Reset-SettingsDefaults {
    $defs = @{
        '物理.重力' = 0.85; '物理.弹跳' = 0.52; '物理.摔疼冲击门槛' = 13
        '行为.蹦跳概率百分比' = 22; '行为.蹦跳高度' = 20; '行为.蹦跳次数' = 3; '行为.蹦跳水平速度' = 3.2
        '表情.最短切换秒数' = 1.2; '气泡.锁秒数' = 2.2; '气泡.最短间隔秒数' = 14; '行为.场景感知.检查秒数' = 90
        '碰撞.反应权重.吃痛' = 55; '碰撞.反应权重.生气' = 20; '碰撞.反应权重.抱怨' = 20; '碰撞.反应权重.惊讶' = 5
    }
    foreach ($k in $defs.Keys) {
        $it = $script:setItems | Where-Object { $_.path -eq $k } | Select-Object -First 1
        if ($it) {
            $it.slider.SetVal([double]$defs[$k])
            $it.val.Text = [Math]::Round($it.slider.Value, $it.dec).ToString()
        }
    }
    foreach ($ck in $script:setChecks) { $ck.toggle.Checked = $true }
    if ($script:setSeg) { $script:setSeg.SelectedIndex = 0 }
    try { Refresh-UsagePanel } catch {}
    try { Refresh-SetApiStatus } catch {}
}