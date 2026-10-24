# ============================================================
#  deskpet-voice.ps1 —— 语音合成（她真的开口说话）
#   引擎：edge（微软免费接口，质量好，需联网）/ sapi（Windows 自带，离线）
#   机制：缓存 + 异步播放（不卡桌宠）+ 失败静默
# ============================================================

$script:voiceDir    = if ($PSScriptRoot) { Join-Path $PSScriptRoot '.cache\voice' } else { Join-Path (Get-Location).Path '.cache\voice' }
$script:voicePy     = 'C:\Users\Administrator\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
$script:voiceFF     = 'D:\AI\tools\ffmpeg\ffmpeg.exe'
$script:voicePlayer = $null
$script:voicePend   = New-Object System.Collections.ArrayList   # 待合成 {text;wav;proc}
$script:voiceLastMs = 0
$script:voiceSpeaking = $false
$script:voiceSynth    = $null

function Get-VoiceConfig {
    $on   = [bool](Cfg '语音.启用' $false)
    $eng  = [string](Cfg '语音.引擎' 'edge')
    $vc   = [string](Cfg '语音.音色' 'zh-CN-XiaoxiaoNeural')
    $pth  = [string](Cfg '语音.音调' '+25Hz')
    $rate = [string](Cfg '语音.语速' '+3%')
    $vol  = [int](Cfg '语音.音量' 85)
    $cool = [int](Cfg '语音.冷却毫秒' 1500)
    return @{ on = $on; engine = $eng; voice = $vc; pitch = $pth; rate = $rate; volume = $vol; cool = $cool }
}

function Ensure-VoiceDir {
    if (-not (Test-Path $script:voiceDir)) { New-Item -ItemType Directory -Path $script:voiceDir -Force | Out-Null }
}

# 去掉表情标签和括号动作，只念出来的字
function Get-SpeakableText {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text
    $t = $t -replace '\[[^\]]{1,6}\]', ''      # [开心] 之类
    $t = $t -replace '（[^）]{0,20}）', ''      # （小声）之类
    $t = $t -replace '\([^)]{0,20}\)', ''
    $t = $t.Trim()
    return $t
}

# 试听 / 直接说一句（同步合成，供设置面板用）
function Test-Voice {
    param([string]$Text = '你好呀，我是小鲸鱼。')
    $cfg = Get-VoiceConfig
    Ensure-VoiceDir
    if ($cfg.engine -eq 'sapi') {
        try {
            Add-Type -AssemblyName System.Speech
            $sp = New-Object System.Speech.Synthesis.SpeechSynthesizer
            $cn = $sp.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -like 'zh*' } | Select-Object -First 1
            if ($cn) { $sp.SelectVoice($cn.VoiceInfo.Name) }
            $sp.Rate = 1
            $sp.Volume = $cfg.volume
            $sp.SpeakAsync((Get-SpeakableText $Text)) | Out-Null
            return @{ ok = $true; msg = 'SAPI 已播放' }
        } catch { return @{ ok = $false; msg = $_.Exception.Message } }
    }
    # edge：合成到缓存后播放
    try {
        $wav = ConvertTo-VoiceWav $Text $cfg
        if ($wav -and (Test-Path $wav)) {
            Play-VoiceWav $wav
            return @{ ok = $true; msg = 'Edge 已播放' }
        }
        return @{ ok = $false; msg = '合成失败' }
    } catch { return @{ ok = $false; msg = $_.Exception.Message } }
}

function Get-VoiceCacheKey {
    param([string]$Text, $Cfg)
    $raw = ($Cfg.engine + '|' + $Cfg.voice + '|' + $Cfg.pitch + '|' + $Cfg.rate + '|' + $Text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $hash = $md5.ComputeHash($bytes)
    $md5.Dispose()
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

# 合成（edge）→ 返回 wav 路径；已缓存直接返回
function ConvertTo-VoiceWav {
    param([string]$Text, $Cfg)
    Ensure-VoiceDir
    $plain = Get-SpeakableText $Text
    if (-not $plain) { return $null }
    $key = Get-VoiceCacheKey $plain $Cfg
    $wav = Join-Path $script:voiceDir ($key + '.wav')
    if (Test-Path -LiteralPath $wav) { return $wav }

    $mp3 = Join-Path $script:voiceDir ($key + '.mp3')
    $pyScript = Join-Path $script:voiceDir '_synth.py'
    $pyCode = @'
import asyncio, sys, edge_tts
async def main():
    text, voice, pitch, rate, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
    c = edge_tts.Communicate(text, voice, pitch=pitch, rate=rate)
    await c.save(out)
asyncio.run(main())
'@
    [System.IO.File]::WriteAllText($pyScript, $pyCode, (New-Object System.Text.UTF8Encoding($false)))

    $p = Start-Process -FilePath $script:voicePy `
        -ArgumentList @($pyScript, $plain, $Cfg.voice, $Cfg.pitch, $Cfg.rate, $mp3) `
        -WindowStyle Hidden -Wait -PassThru
    if (-not (Test-Path -LiteralPath $mp3)) { return $null }

    # mp3 → wav（SoundPlayer 只认 wav）
    Start-Process -FilePath $script:voiceFF -ArgumentList @('-y', '-i', $mp3, '-ar', '22050', '-ac', '1', $wav) -WindowStyle Hidden -Wait | Out-Null
    Remove-Item -LiteralPath $mp3 -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $wav) { return $wav }
    return $null
}

function Play-VoiceWav {
    param([string]$Wav)
    if (-not (Test-Path -LiteralPath $Wav)) { return }
    try {
        if (-not $script:voicePlayer) { $script:voicePlayer = New-Object System.Media.SoundPlayer }
        $script:voicePlayer.Stop()
        $script:voicePlayer.SoundLocation = $Wav
        $script:voicePlayer.Load()
        $script:voicePlayer.Play()          # 异步
        $script:voiceSpeaking = $true
    } catch { }
}

# 主入口：说一句（由 Say-Something 调用）
function Speak-Line {
    param([string]$Text)
    $cfg = Get-VoiceConfig
    if (-not $cfg.on) { return }
    $plain = Get-SpeakableText $Text
    if (-not $plain) { return }
    if ($plain.Length -gt [int](Cfg '语音.最长字数' 40)) { return }   # 太长不念（容易吵）

    $now = [Environment]::TickCount
    if (($now - $script:voiceLastMs) -lt $cfg.cool) { return }        # 冷却，防刷屏
    $script:voiceLastMs = $now

    if ($cfg.engine -eq 'sapi') {
        try {
            Add-Type -AssemblyName System.Speech -ErrorAction SilentlyContinue
            $sp = New-Object System.Speech.Synthesis.SpeechSynthesizer
            $cn = $sp.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -like 'zh*' } | Select-Object -First 1
            if ($cn) { $sp.SelectVoice($cn.VoiceInfo.Name) }
            $sp.Rate = 1
            $sp.Volume = $cfg.volume
            $sp.SpeakAsync($plain) | Out-Null
            $script:sapiSp = $sp   # ★ 必须留引用：否则对象被 GC，语音直接断掉/不出声
        } catch { }
        return
    }

    # edge：先查缓存，命中就播；未命中就后台合成（不阻塞）
    try {
        $key = Get-VoiceCacheKey $plain $cfg
        Ensure-VoiceDir
        $wav = Join-Path $script:voiceDir ($key + '.wav')
        if (Test-Path -LiteralPath $wav) {
            Play-VoiceWav $wav
            return
        }
        foreach ($item in $script:voicePend) {
            if ($item.wav -eq $wav) { return }     # 已在合成中
        }
        $mp3 = Join-Path $script:voiceDir ($key + '.mp3')
        $pyScript = Join-Path $script:voiceDir '_synth.py'
        if (-not (Test-Path -LiteralPath $pyScript)) {
            $pyCode = @'
import asyncio, sys, edge_tts
async def main():
    text, voice, pitch, rate, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
    c = edge_tts.Communicate(text, voice, pitch=pitch, rate=rate)
    await c.save(out)
asyncio.run(main())
'@
            [System.IO.File]::WriteAllText($pyScript, $pyCode, (New-Object System.Text.UTF8Encoding($false)))
        }
        $proc = Start-Process -FilePath $script:voicePy `
            -ArgumentList @($pyScript, $plain, $cfg.voice, $cfg.pitch, $cfg.rate, $mp3) `
            -WindowStyle Hidden -PassThru
        [void]$script:voicePend.Add(@{ wav = $wav; mp3 = $mp3; proc = $proc; t = $now })
    } catch { }
}

# 每帧调用：合成完成后播放
function Update-Voice {
    if ($script:voicePend.Count -eq 0) { return }
    $done = @()
    foreach ($item in $script:voicePend) {
        if (Test-Path -LiteralPath $item.wav) {
            Play-VoiceWav $item.wav
            $done += $item
        }
        elseif ($item.proc -and $item.proc.HasExited -and (Test-Path -LiteralPath $item.mp3)) {
            # 合成完了但还没转 wav → 直接播 mp3 不行，转一次
            try {
                Start-Process -FilePath $script:voiceFF -ArgumentList @('-y', '-i', $item.mp3, '-ar', '22050', '-ac', '1', $item.wav) -WindowStyle Hidden | Out-Null
            } catch {}
        }
        elseif (([Environment]::TickCount - $item.t) -gt 20000) {
            $done += $item    # 超时放弃
        }
    }
    foreach ($d in $done) { [void]$script:voicePend.Remove($d) }
}
