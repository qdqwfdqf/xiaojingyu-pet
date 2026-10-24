# ============================================================
#  deskpet-pools.ps1 —— 台词池系统（专属池 + 通用兜底 + 语义近似）
#   设计：
#     · 每个"状态/动作/条件"有自己的专属池，非空时【只用专属池】✗ 不混通用池
#     · 专属池为空 → 才回落到 默认池（通用/场景）
#     · 池内不重复：记住最近说过的 N 条
#   数据：台词包\pools.json  { "pools": { "expr.happy": ["..."], ... } }
# ============================================================

$script:pools        = @{}    # name -> ArrayList
$script:poolRecent   = @{}    # name -> ArrayList(最近说的)
$script:poolLast     = @{}    # name -> tick
$script:poolSemantic = $null  # 语义示例表

function Initialize-Pools {
    param([string]$PackDir)
    $script:pools = @{}
    $script:poolRecent = @{}
    if (-not $PackDir -or -not (Test-Path -LiteralPath $PackDir)) { return 0 }
    $n = 0
    Get-ChildItem -LiteralPath $PackDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        try {
            $obj = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -eq $obj) { return }
            if ($null -ne $obj.pools) {
                foreach ($p in $obj.pools.PSObject.Properties) {
                    $key = [string]$p.Name
                    $vals = @($p.Value) | Where-Object { ($_ -is [string]) -and $_.Trim() }
                    if ($vals.Count -eq 0) { continue }
                    if (-not $script:pools.ContainsKey($key)) { $script:pools[$key] = New-Object System.Collections.ArrayList }
                    foreach ($v in $vals) {
                        if (-not $script:pools[$key].Contains($v)) { [void]$script:pools[$key].Add($v); $n++ }
                    }
                }
            }
        } catch { }
    }
    return $n
}

function Get-PoolNames { return @($script:pools.Keys | Sort-Object) }
function Test-PoolHas { param([string]$Name) return ($script:pools.ContainsKey($Name) -and $script:pools[$Name].Count -gt 0) }

# 取一句：专属池优先，空了才回落
function Get-PoolLine {
    param([string]$Name, [string]$Fallback = '', [int]$NoRepeat = 6)
    $useName = $Name
    if (-not (Test-PoolHas $useName)) {
        if ($Fallback -and (Test-PoolHas $Fallback)) { $useName = $Fallback }
        else { return '' }
    }
    $pool = $script:pools[$useName]
    if ($pool.Count -eq 0) { return '' }
    if (-not $script:poolRecent.ContainsKey($useName)) { $script:poolRecent[$useName] = New-Object System.Collections.ArrayList }
    $recent = $script:poolRecent[$useName]
    $cands = @()
    foreach ($l in $pool) { if (-not $recent.Contains($l)) { $cands += $l } }
    if ($cands.Count -eq 0) { $cands = @($pool) }
    $line = [string]$cands[(Get-Random -Minimum 0 -Maximum $cands.Count)]
    [void]$recent.Add($line)
    while ($recent.Count -gt $NoRepeat) { $recent.RemoveAt(0) }
    return $line
}

# ---------------- 语义近似意图 ----------------
# 每个意图给几个"示例句"，用户输入与示例做字符 bigram 相似度
function Get-SemanticTable {
    if ($script:poolSemantic) { return $script:poolSemantic }
    $script:poolSemantic = @(
        @{ name = 'sleep';  ex = @('我去睡了', '困了想躺一会儿', '该睡觉了吧', '晚安我先睡'); words = @('睡', '困', '躺', '晚安', '眯', '休息') },
        @{ name = 'tired';  ex = @('今天好累啊', '我快撑不住了', '加班到现在', '累死我了', '我扛不住了', '真的要崩了', '脑子跟浆糊一样', '脑子转不动了', '整个人都是懵的', '脑子一片空白'); words = @('累', '乏', '加班', '熬夜', '撑', '扛', '崩', '不行了', '没力气', '脑子', '浆糊', '转不动', '懵', '糊了', '没劲', '疲惫') },
        @{ name = 'hungry'; ex = @('我饿了', '想吃点东西', '叫个外卖吧'); words = @('饿', '吃', '饭', '外卖', '零食') },
        @{ name = 'praise'; ex = @('你好可爱啊', '你真厉害', '好喜欢你'); words = @('可爱', '好看', '漂亮', '厉害', '棒', '喜欢') },
        @{ name = 'scold';  ex = @('你真笨', '好烦别烦我', '滚开', '你去死吧', '闭嘴吧你'); words = @('笨', '丑', '烦', '讨厌', '滚', '傻', '死', '闭嘴', '蠢') },
        @{ name = 'help';   ex = @('帮我看看怎么办', '我不会做这个', '教教我', '这个我不会'); words = @('帮我', '怎么办', '不会', '教我', '建议', '帮个忙') },
        @{ name = 'token';  ex = @('token 来', '我的 token 呢', '余额还剩多少', '上下文好长', '缓存命中率'); words = @('token', '余额', '上下文', '缓存', '推理', '用量', '充值') },
        @{ name = 'pet';    ex = @('摸摸头', '让我摸摸你', '顺顺毛'); words = @('摸', '揉', '顺毛', '撸') },
        @{ name = 'greet';  ex = @('你好呀', '在吗', '我回来了'); words = @('你好', '在吗', '嗨', '回来', '早') }
    )
    return $script:poolSemantic
}

function Get-Bigrams {
    param([string]$Text)
    $t = ($Text -replace '[\s\p{P}\p{S}]', '')
    $set = @{}
    if ($t.Length -eq 0) { return $set }
    if ($t.Length -eq 1) { $set[$t] = $true; return $set }
    for ($i = 0; $i -lt $t.Length - 1; $i++) { $set[$t.Substring($i, 2)] = $true }
    return $set
}

function Get-BigramSim {
    param([string]$A, [string]$B)
    $sa = Get-Bigrams $A; $sb = Get-Bigrams $B
    if ($sa.Count -eq 0 -or $sb.Count -eq 0) { return 0.0 }
    $inter = 0
    foreach ($k in $sa.Keys) { if ($sb.ContainsKey($k)) { $inter++ } }
    $union = $sa.Count + $sb.Count - $inter
    if ($union -le 0) { return 0.0 }
    return ($inter / [double]$union)
}

# 返回 @{ intent; score }（关键词命中 + 语义相似度）
function Get-SemanticIntent {
    param([string]$Text, [double]$Threshold = 0.34)
    $t = ([string]$Text).Trim()
    if (-not $t) { return @{ intent = ''; score = 0.0 } }
    $low = $t.ToLowerInvariant()
    $best = ''; $bestScore = 0.0
    foreach ($row in (Get-SemanticTable)) {
        $score = 0.0
        foreach ($w in $row.words) {
            if ($low.Contains($w.ToLowerInvariant())) { $score += 0.55 }
        }
        foreach ($ex in $row.ex) {
            $sim = Get-BigramSim $t $ex
            if ($sim -gt $score) { $score = $sim }
        }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $row.name }
    }
    if ($bestScore -lt $Threshold) { return @{ intent = ''; score = $bestScore } }
    return @{ intent = $best; score = $bestScore }
}
