# ============================================================
#  deskpet-llm.ps1 —— 聊天直连（任意 OpenAI 兼容接口）
#  预设：DeepSeek / 硅基流动 / OpenRouter / Ollama / 自定义
#  被 deskpet.ps1 dot-source 引入（在 deskpet-chat.ps1 之前）
#
#  设计：
#   - 只管"连哪家 / 怎么发 / 怎么测 / key 存哪"
#   - 人设和气泡在 deskpet-chat.ps1，不在这里
#   - key 每家各存一份：.secrets\llm-<预设>.key.enc（DPAPI，本机账户绑定）
#   - 失败不抛给用户看，聊天那边直接回离线台词（见 deskpet-chat.ps1）
# ============================================================

# ---------------- 预设表 ----------------
$script:llmPresets = [ordered]@{
    deepseek    = @{ name = 'DeepSeek';    url = 'https://api.deepseek.com/v1/chat/completions';    model = 'deepseek-chat';            needKey = $true;  tip = '官方，最便宜' }
    siliconflow = @{ name = '硅基流动';    url = 'https://api.siliconflow.cn/v1/chat/completions'; model = 'Qwen/Qwen2.5-7B-Instruct'; needKey = $true;  tip = '国内，有免费额度' }
    openrouter  = @{ name = 'OpenRouter'; url = 'https://openrouter.ai/api/v1/chat/completions';   model = 'deepseek/deepseek-chat';   needKey = $true;  tip = '聚合站，美元结算' }
    ollama      = @{ name = 'Ollama';     url = 'http://127.0.0.1:11434/v1/chat/completions';      model = 'qwen2.5:7b';               needKey = $false; tip = '本机跑，真免费' }
    custom      = @{ name = '自定义';     url = '';                                                  model = '';                         needKey = $true;  tip = '任意 OpenAI 兼容网关' }
}

$script:llmDownUntil = 0      # 失败冷却到什么时候（TickCount）
$script:llmWaitMs    = 60000  # 失败后 60 秒内不再联网，直接用离线台词

# ---------------- 选的是哪家 ----------------
function Get-LlmPresetId {
    $id = [string](Cfg '聊天.直连.预设' 'deepseek')
    $mode = [string](Cfg '聊天.模式' 'offline')
    # 兼容旧配置：local = 本地模型，relay = 转发网关
    if ($mode -eq 'local') { $id = 'ollama' }
    elseif ($mode -eq 'relay') { $id = 'custom' }
    if (-not $script:llmPresets.Contains($id)) { $id = 'deepseek' }
    return $id
}

function Get-LlmPresetName {
    param([string]$Preset)
    try { return [string]$script:llmPresets[$Preset].name } catch { return [string]$Preset }
}

# ---------------- key 目录 / 文件 ----------------
function Get-LlmKeyDir {
    if ($PSScriptRoot) { return (Join-Path $PSScriptRoot '.secrets') }
    return (Join-Path (Get-Location).Path '.secrets')
}

function Get-LlmKeyFile {
    param([string]$Preset)
    return (Join-Path (Get-LlmKeyDir) ('llm-' + $Preset + '.key.enc'))
}

# ---------------- key 读写（DPAPI） ----------------
function Get-LlmKey {
    param([string]$Preset)
    $f = Get-LlmKeyFile $Preset
    if (Test-Path -LiteralPath $f) {
        try {
            $enc = Get-Content -LiteralPath $f -Raw -Encoding UTF8
            $sec = $enc | ConvertTo-SecureString
            $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { return ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)).Trim() }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        } catch { }
    }
    # 兼容旧版：DeepSeek 用原来的 .secrets\deepseek.key.enc
    if ($Preset -eq 'deepseek' -and (Get-Command Get-ApiKeyPlain -ErrorAction SilentlyContinue)) {
        try {
            $k = Get-ApiKeyPlain
            if ($k) { return ([string]$k).Trim() }
        } catch { }
    }
    return ''
}

function Save-LlmKey {
    param([string]$Preset, [string]$Plain)
    $p = ([string]$Plain).Trim()
    if (-not $p) { return $false }
    try {
        $dir = Get-LlmKeyDir
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $sec = $p | ConvertTo-SecureString -AsPlainText -Force
        $enc = ConvertFrom-SecureString $sec
        [System.IO.File]::WriteAllText((Get-LlmKeyFile $Preset), $enc, (New-Object System.Text.UTF8Encoding($false)))
        Clear-LlmDown
        return $true
    } catch { return $false }
}

function Remove-LlmKey {
    param([string]$Preset)
    try {
        $f = Get-LlmKeyFile $Preset
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Get-LlmKeyState {
    param([string]$Preset)
    $k = Get-LlmKey $Preset
    if (-not $k) { return @{ configured = $false; masked = '' } }
    $masked = if ($k.Length -ge 10) { $k.Substring(0, 3) + '****' + $k.Substring($k.Length - 4) } else { '****' }
    return @{ configured = $true; masked = $masked }
}

# ---------------- 失败冷却（失败自动回离线，不每句都等超时） ----------------
function Get-LlmDownRemainMs {
    $r = [long]$script:llmDownUntil - [long][Environment]::TickCount
    if ($r -lt 0) { return [long]0 }
    return $r
}

function Set-LlmDown {
    param([int]$Ms = 60000)
    if ($Ms -lt 1000) { $Ms = 1000 }
    $script:llmDownUntil = [Environment]::TickCount + $Ms
}

function Clear-LlmDown {
    $script:llmDownUntil = 0
}

# ---------------- 解析后端 ----------------
function Get-LlmBackend {
    $mode = [string](Cfg '聊天.模式' 'offline')
    if ($mode -eq 'offline' -or $mode -eq '' ) {
        return @{ mode = 'offline'; preset = ''; presetName = '离线'; url = ''; model = ''; key = ''; needKey = $false }
    }
    $id = Get-LlmPresetId
    $p = $script:llmPresets[$id]
    $needKey = [bool]$p.needKey

    $url = [string](Cfg '聊天.直连.接口' '')
    $model = [string](Cfg '聊天.直连.模型' '')

    # 兼容旧配置（老版本把地址/模型存在别的键里）
    if (-not $url) {
        if ($mode -eq 'local') { $url = [string](Cfg '聊天.本地接口' '') }
        elseif ($mode -eq 'relay') { $url = [string](Cfg '聊天.转发接口' '') }
        elseif ($mode -eq 'api') { $url = [string](Cfg '聊天.接口' '') }
    }
    if (-not $model) {
        if ($mode -eq 'local') { $model = [string](Cfg '聊天.本地模型' '') }
        elseif ($mode -eq 'relay') { $model = [string](Cfg '聊天.转发模型' '') }
        elseif ($mode -eq 'api') { $model = [string](Cfg '聊天.模型' '') }
    }
    if (-not $url) { $url = [string]$p.url }
    if (-not $model) { $model = [string]$p.model }
    if ($mode -eq 'local') { $needKey = $false }   # 旧的"本地模型"不要求 key

    $key = ''
    if ($needKey) { $key = [string](Get-LlmKey $id) }

    return @{
        mode       = 'direct'
        rawMode    = $mode
        preset     = $id
        presetName = [string]$p.name
        url        = $url.Trim()
        model      = $model.Trim()
        key        = $key
        needKey    = $needKey
    }
}

# ---------------- 是否具备发请求的条件 ----------------
function Test-LlmReady {
    param($Backend)
    if (-not $Backend) { return @{ ok = $false; why = '没有后端' } }
    if ($Backend.mode -eq 'offline') { return @{ ok = $false; why = '离线模式' } }
    if (-not $Backend.url) { return @{ ok = $false; why = '没填接口地址' } }
    if ($Backend.needKey -and -not $Backend.key) { return @{ ok = $false; why = '没填 API Key' } }
    return @{ ok = $true; why = '' }
}

# ---------------- 组请求体 ----------------
function New-LlmBody {
    param([string]$UserText, [switch]$Test)
    try {
        $be = Get-LlmBackend
        $ready = Test-LlmReady $be
        if (-not $ready.ok) { return @{ ok = $false; err = [string]$ready.why; backend = $be } }

        $msgs = New-Object System.Collections.ArrayList
        [void]$msgs.Add(@{ role = 'system'; content = (Get-ChatSystemPrompt) })

        if ($Test) {
            [void]$msgs.Add(@{ role = 'user'; content = '在吗' })
            $maxTok = 8
        } else {
            # 历史条数限制：只带最近 N 条，防止上下文越来越贵
            $limit = [int](Cfg '聊天.直连.历史条数' 8)
            if ($limit -lt 0) { $limit = 0 }
            if ($limit -gt 24) { $limit = 24 }
            $hist = $script:chatHistory
            if ($hist) {
                $start = [Math]::Max(0, $hist.Count - $limit)
                for ($i = $start; $i -lt $hist.Count; $i++) { [void]$msgs.Add($hist[$i]) }
            }
            if ($UserText) { [void]$msgs.Add(@{ role = 'user'; content = [string]$UserText }) }
            $maxTok = [int](Cfg '聊天.最大字数' 80)
            if ($maxTok -lt 8) { $maxTok = 8 }
        }

        $temp = [double](Cfg '聊天.温度' 1.1)
        if ($temp -lt 0) { $temp = 0.7 }
        if ($temp -gt 2.0) { $temp = 1.5 }

        $body = @{
            model       = [string]$be.model
            messages    = $msgs.ToArray()
            max_tokens  = $maxTok
            temperature = $temp
            stream      = $false
        } | ConvertTo-Json -Depth 6

        return @{ ok = $true; json = $body; backend = $be }
    } catch {
        return @{ ok = $false; err = ('组包失败：' + $_.Exception.Message) }
    }
}

# ---------------- 发请求（异步，交给聊天定时器轮询） ----------------
function Start-LlmTask {
    param($Backend, [string]$Json, [int]$TimeoutSec = 0)
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $timeout = 0.0
    if ($TimeoutSec -gt 0) { $timeout = [double]$TimeoutSec }
    else { $timeout = [double](Cfg '聊天.直连.超时秒数' 20) }
    if ($timeout -lt 5) { $timeout = 5 }
    if ($timeout -gt 120) { $timeout = 120 }
    # ★ 本地 Ollama 冷启动要 30~60 秒（加载模型进显存），默认 20 秒必超时 → 单独放宽
    if (([string]$Backend.preset) -eq 'ollama') { $timeout = 120 }
    $client.Timeout = [TimeSpan]::FromSeconds($timeout)
    if ($Backend.needKey -and $Backend.key) {
        $client.DefaultRequestHeaders.Authorization =
            [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', [string]$Backend.key)
    }
    try {
        $client.DefaultRequestHeaders.Add('X-Title', 'xiaojingyu-deskpet')
        $client.DefaultRequestHeaders.Add('HTTP-Referer', 'https://github.com/')
    } catch { }
    $content = New-Object System.Net.Http.StringContent($Json, [System.Text.Encoding]::UTF8, 'application/json')
    $task = $client.PostAsync([string]$Backend.url, $content)
    return @{ client = $client; task = $task }
}

# ---------------- 读结果（统一成一个结构，异常不外抛） ----------------
function Read-LlmTask {
    param($Task)
    $r = @{ ok = $false; code = 0; text = ''; promptTokens = 0; completionTokens = 0; err = '' }
    try {
        $resp = $Task.Result
        $r.code = [int]$resp.StatusCode
        $raw = $resp.Content.ReadAsStringAsync().Result
        if ($r.code -ne 200) {
            $r.err = ('HTTP ' + $r.code)
            try {
                $objErr = $raw | ConvertFrom-Json
                if ($objErr.error -and $objErr.error.message) {
                    $r.err = ('HTTP ' + $r.code + '：' + [string]$objErr.error.message)
                }
            } catch { }
            return $r
        }
        $obj = $raw | ConvertFrom-Json
        if ($obj.choices -and $obj.choices.Count -gt 0) { $r.text = [string]$obj.choices[0].message.content }
        try {
            $r.promptTokens = [int]$obj.usage.prompt_tokens
            $r.completionTokens = [int]$obj.usage.completion_tokens
        } catch { }
        if (([string]$r.text).Trim().Length -gt 0) { $r.ok = $true }
        else { $r.err = '返回内容为空' }
        return $r
    } catch {
        $r.err = ('网络不通：' + $_.Exception.Message)
        return $r
    }
}

# ---------------- 错误翻译（给设置面板看，不吓人） ----------------
function Get-LlmFriendlyError {
    param($R)
    if (-not $R) { return '未知错误' }
    $err = [string]$R.err
    $c = [int]$R.code
    if ($err -like '网络不通*') { return '连不上：检查接口地址 / 网络 / 代理' }
    if ($c -eq 0) { return ('连不上：' + $err) }
    switch ($c) {
        401 { return 'HTTP 401：Key 不对或已过期' }
        402 { return 'HTTP 402：余额不足' }
        403 { return 'HTTP 403：没有权限（Key 和地址可能不是同一家）' }
        404 { return 'HTTP 404：接口地址不对（一般要写到 /v1/chat/completions）' }
        429 { return 'HTTP 429：请求太频繁 / 额度用完了' }
        default {
            if ($c -ge 500) { return ('HTTP ' + $c + '：服务端错误，等会再试') }
            return ('HTTP ' + $c + '：' + $err)
        }
    }
}

# ---------------- 测试连接（同步，设置面板用） ----------------
function Test-LlmBackend {
    $be = Get-LlmBackend
    if ($be.mode -eq 'offline') { return @{ ok = $true; msg = '离线模式：不联网，用内置台词库' } }
    $b = New-LlmBody -Test
    if (-not $b.ok) { return @{ ok = $false; msg = [string]$b.err } }
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $h = Start-LlmTask -Backend $b.backend -Json $b.json -TimeoutSec 10
        $r = Read-LlmTask -Task $h.task
        $sw.Stop()
        try { $h.client.Dispose() } catch { }
        if ($r.ok) {
            Clear-LlmDown
            $msg = '连接成功（' + [string]$b.backend.presetName + ' / ' + [string]$b.backend.model + '，' + [int]$sw.ElapsedMilliseconds + 'ms）'
            $t = ([string]$r.text).Trim()
            if ($t) { $msg = $msg + '：' + $t }
            return @{ ok = $true; msg = $msg }
        }
        if ($r.code -eq 404 -and ([string]$b.backend.preset) -eq 'ollama') {
            return @{ ok = $false; msg = ('本机 Ollama 里没有这个模型：先 ollama pull ' + [string]$b.backend.model) }
        }
        return @{ ok = $false; msg = (Get-LlmFriendlyError $r) }
    } catch {
        return @{ ok = $false; msg = ('连不上：' + $_.Exception.Message) }
    }
}

# ---------------- 立即写回 config.json（预设/模式点完就存） ----------------
function Save-CfgNow {
    try {
        if (-not $script:cfg) { return $false }
        $p = [string]$script:settingsCfg
        if (-not $p) {
            if ($PSScriptRoot) { $p = Join-Path $PSScriptRoot 'config.json' }
            else { $p = Join-Path (Get-Location).Path 'config.json' }
        }
        [System.IO.File]::WriteAllText($p, ($script:cfg | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}
