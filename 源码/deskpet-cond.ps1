# ============================================================
#  deskpet-cond.ps1 —— 条件台词引擎（只在条件成立时说话，避免"瞎说话"）
#   条件（全部可测）：
#     cond.mouse     鼠标快速乱晃
#     cond.lonely    长时间无操作
#     cond.night     深夜还在活动
#     cond.approach  鼠标凑近她又跑开
#     cond.longcode  长时间在看代码
#   规则：每个条件 3 分钟冷却 + 25% 概率 + 池子专属（非空只用专属）
# ============================================================

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DSHIdle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint IdleMs() {
        var lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(lii);
        if (!GetLastInputInfo(ref lii)) return 0;
        return ((uint)Environment.TickCount) - lii.dwTime;
    }
}
'@ -ErrorAction SilentlyContinue

$script:condCursorX   = 0
$script:condCursorY   = 0
$script:condShake     = 0.0     # 晃动累积
$script:condCool      = @{}     # 条件名 -> 冷却到的 tick
$script:condApproach  = 0       # 靠近计时
$script:condCodeSince = 0
$script:condLastSpeak = 0

function Get-CondCoolFrames { return (CfgFrames '条件.冷却秒数' 180) }
function Get-CondChance     { return [double](Cfg '条件.触发概率百分比' 25) }

function Test-ConditionAllowed {
    param([string]$Name)
    if (-not [bool](Cfg '条件.启用' $true)) { return $false }
    $cool = $script:condCool[$Name]
    if ($null -eq $cool) { $cool = 0 }
    if ($script:tick -lt $cool) { return $false }
    # 全局最小间隔（别连续冒条件台词）
    if (($script:tick - $script:condLastSpeak) -lt (CfgFrames '条件.全局间隔秒数' 120)) { return $false }
    return $true
}

function Invoke-Condition {
    param([string]$Name, [string]$PoolName)
    if (-not (Test-ConditionAllowed $Name)) { return $false }
    $chance = Get-CondChance
    if ((Get-Random -Minimum 0.0 -Maximum 100.0) -gt $chance) {
        $script:condCool[$Name] = $script:tick + [int]((Get-CondCoolFrames) / 3)   # 没中，稍后再试
        return $false
    }
    if (-not (Test-PoolHas $PoolName)) { return $false }
    $line = Get-PoolLine $PoolName
    if (-not $line) { return $false }
    try { Say-Something 0 @($line) 22 } catch { return $false }
    $script:condCool[$Name] = $script:tick + (Get-CondCoolFrames)
    $script:condLastSpeak = $script:tick
    return $true
}

# 每帧调用（内部自己降频到 ~0.5 秒一次）
function Update-Conditions {
    if (-not [bool](Cfg '条件.启用' $true)) { return }
    if ($script:sleep -gt 0 -or $script:paused -or $script:dragging) { return }
    if (($script:tick % (CfgFrames '条件.采样间隔秒数' 0.5)) -ne 0) { return }

    # --- 鼠标位置与晃动 ---
    $cx = [System.Windows.Forms.Cursor]::Position.X
    $cy = [System.Windows.Forms.Cursor]::Position.Y
    $dx = [Math]::Abs($cx - $script:condCursorX)
    $dy = [Math]::Abs($cy - $script:condCursorY)
    $script:condCursorX = $cx; $script:condCursorY = $cy
    $move = $dx + $dy
    if ($move -gt 40) { $script:condShake = [Math]::Min(100.0, $script:condShake + 1.0) }
    else { $script:condShake = [Math]::Max(0.0, $script:condShake - 0.25) }

    if ($script:condShake -ge 4.0) {
        $script:condShake = 0.0
        [void](Invoke-Condition 'mouse' 'cond.mouse')
    }

    # --- 久无操作 ---
    try {
        $idleMs = [DSHIdle]::IdleMs()
        $needMs = [double](Cfg '条件.无操作秒数' 300) * 1000.0
        if ($idleMs -ge $needMs) { [void](Invoke-Condition 'lonely' 'cond.lonely') }
    } catch {}

    # --- 深夜 ---
    $h = (Get-Date).Hour
    if (($h -ge 23 -or $h -lt 4)) {
        $script:condNightTicks = [int]$script:condNightTicks + 1
        if ($script:condNightTicks -gt 200) {     # 深夜待满 ~1 分钟才说
            $script:condNightTicks = 0
            [void](Invoke-Condition 'night' 'cond.night')
        }
    } else { $script:condNightTicks = 0 }

    # --- 鼠标凑近又跑开 ---
    $mx = $cx - ($script:px + $script:cw / 2.0)
    $my = $cy - ($script:py + $script:ch / 2.0)
    $dist = [Math]::Sqrt($mx * $mx + $my * $my)
    if ($dist -lt 130) { $script:condApproach = 1 }
    elseif ($dist -gt 320 -and $script:condApproach -eq 1) {
        $script:condApproach = 2
        [void](Invoke-Condition 'approach' 'cond.approach')
    }
    if ($dist -gt 460) { $script:condApproach = 0 }

    # --- 长时间看代码 ---
    $sc = [string]$script:sceneCur
    if ($sc -eq 'code') {
        if ($script:condCodeSince -eq 0) { $script:condCodeSince = $script:tick }
        elseif (($script:tick - $script:condCodeSince) -gt (CfgFrames '条件.看代码多久秒数' 600)) {
            $script:condCodeSince = $script:tick
            [void](Invoke-Condition 'longcode' 'cond.longcode')
        }
    } else { $script:condCodeSince = 0 }
}
