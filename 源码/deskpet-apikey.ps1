# ============================================================
#  deskpet-apikey.ps1 —— API Key 管理（DPAPI 加密，绑定当前 Windows 账户）
#  被 deskpet.ps1 dot-source 引入
#  安全约定：key 不打印、不写日志、不进 git；解密后只在内存里用
# ============================================================

$script:keyDir = if ($PSScriptRoot) { Join-Path $PSScriptRoot '.secrets' } else { Join-Path (Get-Location).Path '.secrets' }
$script:keyEncFile = Join-Path $script:keyDir 'deepseek.key.enc'
$script:keyPlainFile = Join-Path $script:keyDir 'deepseek.key'
$script:keyUsageFile = Join-Path $script:keyDir 'api_usage.json'
$script:chatLastApiMs = 0

function Ensure-KeyDir {
    if (-not (Test-Path $script:keyDir)) { New-Item -ItemType Directory -Path $script:keyDir -Force | Out-Null }
}

# ---- 保存 key（DPAPI 加密；同时删掉旧的明文 key）----
function Save-ApiKey {
    param([string]$Plain)
    if (-not $Plain) { return $false }
    Ensure-KeyDir
    try {
        $sec = $Plain | ConvertTo-SecureString -AsPlainText -Force
        $enc = ConvertFrom-SecureString $sec
        [System.IO.File]::WriteAllText($script:keyEncFile, $enc, (New-Object System.Text.UTF8Encoding($false)))
        # 老的明文文件删掉，避免遗留
        if (Test-Path -LiteralPath $script:keyPlainFile) { Remove-Item -LiteralPath $script:keyPlainFile -Force -ErrorAction SilentlyContinue }
        return $true
    } catch { return $false }
}

# ---- 读取 key（优先 DPAPI；兼容旧的明文文件）----
function Get-ApiKeyPlain {
    # 1) DPAPI 加密文件
    if (Test-Path -LiteralPath $script:keyEncFile) {
        try {
            $enc = Get-Content -LiteralPath $script:keyEncFile -Raw -Encoding UTF8
            $sec = $enc | ConvertTo-SecureString
            $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        } catch { return $null }
    }
    # 2) 兼容：老的明文文件（建议尽快用设置面板改存）
    if (Test-Path -LiteralPath $script:keyPlainFile) {
        try { return (Get-Content -LiteralPath $script:keyPlainFile -Raw -Encoding UTF8).Trim() } catch { return $null }
    }
    return $null
}

# ---- key 状态（给设置面板显示，绝不返回完整 key）----
function Get-ApiKeyState {
    $k = Get-ApiKeyPlain
    if (-not $k) { return @{ configured = $false; masked = ''; encrypted = $false } }
    $masked = if ($k.Length -ge 10) { $k.Substring(0, 3) + '****' + $k.Substring($k.Length - 4) } else { '****' }
    return @{
        configured = $true
        masked     = $masked
        encrypted  = (Test-Path -LiteralPath $script:keyEncFile)
    }
}

function Remove-ApiKey {
    foreach ($f in @($script:keyEncFile, $script:keyPlainFile)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

# ---- 用量记录（每天一条计数，防刷钱）----
function Get-ApiUsage {
    $today = Get-Date -Format 'yyyy-MM-dd'
    if (Test-Path -LiteralPath $script:keyUsageFile) {
        try {
            $u = Get-Content -LiteralPath $script:keyUsageFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($u.date -ne $today) { $u = [pscustomobject]@{ date = $today; count = 0; prompt = 0; completion = 0; total = 0 } }
            return $u
        } catch {}
    }
    return [pscustomobject]@{ date = $today; count = 0; prompt = 0; completion = 0; total = 0 }
}

function Add-ApiUsage {
    param([int]$PromptTokens = 0, [int]$CompletionTokens = 0)
    Ensure-KeyDir
    $u = Get-ApiUsage
    $u.count++
    $u.prompt     = [int]$u.prompt + $PromptTokens
    $u.completion = [int]$u.completion + $CompletionTokens
    $u.total      = [int]$u.total + $PromptTokens + $CompletionTokens
    try {
        [System.IO.File]::WriteAllText($script:keyUsageFile, ($u | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

# ---- 测试连接（真实调用一次，极短）----
function Test-ApiKey {
    $key = Get-ApiKeyPlain
    if (-not $key) { return @{ ok = $false; code = 0; msg = '没有配置 key' } }
    try {
        Add-Type -AssemblyName System.Net.Http
        $body = @{
            model      = [string](Cfg '聊天.模型' 'deepseek-chat')
            messages   = @(@{ role = 'user'; content = '在吗' })
            max_tokens = 8
        } | ConvertTo-Json -Depth 5
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
        $client.DefaultRequestHeaders.Authorization =
            [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $key)
        $resp = $client.PostAsync([string](Cfg '聊天.接口' 'https://api.deepseek.com/chat/completions'), $content).Result
        $code = [int]$resp.StatusCode
        if ($code -eq 200) {
            return @{ ok = $true; code = $code; msg = '连接正常' }
        }
        elseif ($code -eq 401) { return @{ ok = $false; code = $code; msg = 'key 无效或已过期' } }
        elseif ($code -eq 402) { return @{ ok = $false; code = $code; msg = '余额不足' } }
        elseif ($code -eq 429) { return @{ ok = $false; code = $code; msg = '请求太频繁' } }
        else { return @{ ok = $false; code = $code; msg = ('接口返回 ' + $code) } }
    } catch {
        return @{ ok = $false; code = -1; msg = '网络不通' }
    }
}

# ---- 调用失败时说的话（对用户友好，不暴露技术细节）----
function Get-ApiFailLine {
    param([int]$Code = 0)
    switch ($Code) {
        401 { return '我……好像认不出你了。[委屈]' }
        402 { return '我饿了，先充点吧。' }
        429 { return '等等，我喘口气……' }
        -1  { return '我脑袋有点晕……[委屈]' }
        default { return '我现在不想说话。' }
    }
}
