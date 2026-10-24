# ============================================================
#  deskpet-physics.ps1 —— 物理拖拽（甩飞、重力、弹跳、撞墙）
#  被 deskpet.ps1 dot-source 引入
# ============================================================

$script:physEnable  = [bool](Cfg '物理.启用' $true)
$script:physActive  = $false     # 是否处于"飞出去"状态
$script:physVX      = 0.0
$script:physVY      = 0.0
$script:dragTrail   = New-Object System.Collections.ArrayList
$script:physCool    = -9999
$script:physLandTap = 0

function Reset-DragTrail {
    $script:dragTrail.Clear()
    [void]$script:dragTrail.Add(@{ x = $script:px; y = $script:py; t = [Environment]::TickCount })
}

function Push-DragTrail {
    $now = [Environment]::TickCount
    [void]$script:dragTrail.Add(@{ x = $script:px; y = $script:py; t = $now })
    while ($script:dragTrail.Count -gt 8) { $script:dragTrail.RemoveAt(0) }
}

function Start-Fling {
    if (-not $script:physEnable) { return }
    if ($script:dragTrail.Count -lt 2) { return }

    $last = $script:dragTrail[$script:dragTrail.Count - 1]
    $ref  = $script:dragTrail[0]
    for ($i = $script:dragTrail.Count - 1; $i -ge 0; $i--) {
        if (($last.t - $script:dragTrail[$i].t) -ge 70) { $ref = $script:dragTrail[$i]; break }
    }
    $dt = [Math]::Max(16, ($last.t - $ref.t))
    $vx = ($last.x - $ref.x) / $dt * 16.0
    $vy = ($last.y - $ref.y) / $dt * 16.0
    $sp = [Math]::Sqrt($vx * $vx + $vy * $vy)

    # ★ 只拦"点一下就走"的误触（100ms 以内）；往下甩也是正常甩飞，不再拦
    $dragMs = 0
    if ($script:dragTrail.Count -ge 2) {
        $dragMs = $script:dragTrail[$script:dragTrail.Count - 1].t - $script:dragTrail[0].t
    }
    if ($dragMs -lt 100) { return }
    # ★ 甩之前先把旧物理速度清零（避免叠加出"弹簧爆发" ✗）
    $script:physVX = 0.0
    $script:physVY = 0.0
    $script:physActive = $false

    $thr = [double](Cfg '物理.甩出阈值' 1.1)
    if ($sp -lt $thr) { return }

    $cap = [double](Cfg '物理.最大速度' 36)
    if ($sp -gt $cap) {
        $vx = $vx / $sp * $cap
        $vy = $vy / $sp * $cap
    }
    $script:physVX = $vx
    $script:physVY = $vy
    $script:physActive = $true
    $script:surprise = 26
    $script:sqV = [Math]::Min(0.9, 0.25 + $sp * 0.06)   # 被甩出去时拉长一下
    $script:earV += 1.6
    if ($script:physCool -lt 0) { $script:physCool = 0 }
    try { Spawn-Sparkles 10 } catch {}
    Log-Phys ("甩出 vx=" + [math]::Round($vx, 1) + " vy=" + [math]::Round($vy, 1))
}

function Log-Phys {
    param([string]$Msg)
    if (-not [bool](Cfg '物理.调试日志' $false)) { return }
    try {
        "$(Get-Date -Format 'HH:mm:ss') [phys] $Msg" |
            Out-File -FilePath (Join-Path $PSScriptRoot 'deskpet-phys.log') -Append -Encoding utf8
    } catch {}
}

function Update-Physics {
    # ★ 被抓住时物理必须停（否则物理和鼠标同时改位置 → 鬼畜抖动 ✗）
    if ($script:dragging) {
        if ($script:physActive) {
            $script:physActive = $false
            $script:physVX = 0.0
            $script:physVY = 0.0
        }
        return $false
    }
    if (-not $script:physActive) { return $false }

    $g      = [double](Cfg '物理.重力' 0.85)
    $bounce = [double](Cfg '物理.弹跳' 0.52)
    $fric   = [double](Cfg '物理.摩擦' 0.992)
    $scr    = $script:scr

    $script:physVY += $g
    $script:physVX *= $fric

    $nx = $script:px + $script:physVX
    $ny = $script:py + $script:physVY
    $hit = $false

    # 左右墙
    if ($nx -lt $scr.Left) {
        $nx = $scr.Left
        $script:physVX = -$script:physVX * $bounce
        $hit = $true
    }
    elseif (($nx + $script:cw) -gt $scr.Right) {
        $nx = $scr.Right - $script:cw
        $script:physVX = -$script:physVX * $bounce
        $hit = $true
    }

    # 天花板
    if ($ny -lt $scr.Top) {
        $ny = $scr.Top
        $script:physVY = -$script:physVY * $bounce
        $hit = $true
    }

    # 地板
    # ★ 用图像脚底判断（窗口底还有 164px 留白）——以前用整个窗口高，落地时被拽到上面 ✗
    if (($ny + $script:ch - 164) -gt $script:floorBottom) {
        $ny = $script:floorBottom - ($script:ch - 164)
        $impact = [Math]::Abs($script:physVY)
        $script:physVY = -$script:physVY * $bounce
        if ([Math]::Abs($script:physVY) -lt 1.1) { $script:physVY = 0.0 }
        $script:physVX *= 0.90
        if ($impact -gt 2.0) {
            $script:sqV = -0.22 - [Math]::Min(0.30, $impact * 0.02)   # 落地压扁
            try { Spawn-Sparkles ([int](6 + [Math]::Min(14, $impact))) } catch {}
        }
        # ★ 摔疼要有"高度门槛"：冲击速度 ≈ √(1.7 × 下落像素)
        #   默认 13 ≈ 从 100px 高砸下来才疼；轻轻掉下来只压扁+火花，不哭 ✓
        $hurtImpact = [double](Cfg '物理.摔疼冲击门槛' 13)
        if ($hurtImpact -lt 4) { $hurtImpact = 4 }
        if ($impact -gt $hurtImpact -and ($script:tick - $script:physCool) -gt 55) {
            $script:physCool = $script:tick
            if ([bool](Cfg '物理.摔疼会说话' $true)) {
                try { Invoke-Hurt '' } catch {}
            }
        }
        $hit = $true
    }

    # 撞墙时的小反馈（不打断，只晃一下）
    if ($hit) { $script:earV += 0.8 }

    $script:px = $nx
    $script:py = $ny

    # 静止判定：贴地且速度很小 → 结束物理模式
    $onFloor = (($script:py + $script:ch - 164) -ge ($script:floorBottom - 2))
    if ($onFloor -and $script:physVY -eq 0.0 -and [Math]::Abs($script:physVX) -lt 0.15) {
        $script:physActive = $false
        $script:physVX = 0.0
        $script:physVY = 0.0
        $script:physCool = $script:tick
    }
    return $true
}

function Toggle-Physics {
    param([bool]$on)
    $script:physEnable = $on
    if (-not $on) {
        $script:physActive = $false
        $script:physVX = 0.0
        $script:physVY = 0.0
    }
}
