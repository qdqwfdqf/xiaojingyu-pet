# ============================================================
#  deskpet-lines.ps1 —— 台词包加载（台词包\*.json 自动追加）
#   用户可以自己往 台词包\ 里丢 json 扩充台词，不用改 config.json
#   格式：{ "普通": ["...", "..."], "开心": ["..."] }
# ============================================================

function Merge-LinePacks {
    param($Cfg, [string]$PackDir)

    $report = @{ files = 0; added = 0; byKey = @{} }
    if ($null -eq $Cfg) { return $report }
    if (-not $PackDir -or -not (Test-Path -LiteralPath $PackDir)) { return $report }

    $files = Get-ChildItem -LiteralPath $PackDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $files) { return $report }

    foreach ($f in $files) {
        try {
            $obj = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -eq $obj) { continue }
            $report.files++
            foreach ($p in $obj.PSObject.Properties) {
                $key = [string]$p.Name
                $vals = @($p.Value) | Where-Object { ($_ -is [string]) -and ($_.Trim().Length -gt 0) }
                if (-not $vals -or $vals.Count -eq 0) { continue }

                # 确保 台词 节点存在
                if ($null -eq $Cfg.台词) {
                    $Cfg | Add-Member -NotePropertyName '台词' -NotePropertyValue ([pscustomobject]@{}) -Force
                }
                $cur = @()
                $existing = $Cfg.台词.$key
                if ($null -ne $existing) { $cur = @($existing) }

                $add = @()
                foreach ($v in $vals) {
                    if ($cur -notcontains $v) { $add += $v }
                }
                if ($add.Count -gt 0) {
                    $merged = @($cur) + $add
                    $Cfg.台词 | Add-Member -NotePropertyName $key -NotePropertyValue $merged -Force
                    $report.added += $add.Count
                    if (-not $report.byKey.ContainsKey($key)) { $report.byKey[$key] = 0 }
                    $report.byKey[$key] += $add.Count
                }
            }
        }
        catch { }
    }
    return $report
}
