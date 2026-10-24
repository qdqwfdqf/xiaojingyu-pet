# ============================================
#  桌宠  🐟  v6
#
#  渲染方式：分层窗口（每像素透明）
#    · 软阴影 → 有"站在桌面上"的感觉，不再像贴图
#    · 抗锯齿边缘 → 不再像抠图
#    · 会轻微摇曳 + 呼吸 → 静态图也灵动
#    · 透明区域的鼠标点击会穿透到桌面
#
#  新增：
#    · 随机游走（随机方向 / 随机速度 / 随机停顿）
#    · 点击 → 弹跳 + 爆出一簇星火
#
#  鼠标：左键拖（松手贴边）/ 单击星火 / 双击开关游走 / 右键菜单
# ============================================

# ★ 首次运行后把"程序本体/截图"设为隐藏，让文件夹看起来像成品（幂等）
try {
    $parentDir = Split-Path $PSScriptRoot -Parent
    foreach ($d in @($PSScriptRoot, (Join-Path $parentDir '截图'))) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            $it = Get-Item -LiteralPath $d -Force
            if ($it -and -not ($it.Attributes -band [System.IO.FileAttributes]::Hidden)) {
                $it.Attributes = $it.Attributes -bor [System.IO.FileAttributes]::Hidden
            }
        }
    }
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 单实例：已经开着的时候再双击，不会又冒出一条鱼
$script:mutex = New-Object System.Threading.Mutex($false, 'DSHDeskPet_SingleInstance')
if (-not $script:mutex.WaitOne(0)) {
    Write-Host "桌宠已经在运行了，不用再开。"
    Start-Sleep -Seconds 2
    exit 0
}

$script:selfPath = $PSCommandPath

# ============================================================
#  0.5 读配置（改 config.json 就能调她，不用动代码）
# ============================================================
$script:cfg = $null
$cfgPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $cfgPath) {
    try {
        $script:cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host "配置：config.json 已加载"

# ★ 台词包：台词包\*.json 自动追加（用户可自己丢 json 扩充，不用改 config）
try {
    $lpFile = Join-Path $PSScriptRoot 'deskpet-lines.ps1'
    if (Test-Path -LiteralPath $lpFile) {
        . $lpFile
        $lp = Merge-LinePacks $script:cfg (Join-Path $PSScriptRoot '台词包')
        if ($lp.files -gt 0) {
            $sum = 0
            foreach ($k in $lp.byKey.Keys) { $sum += $lp.byKey[$k] }
            Write-Host ("台词包：加载 " + $lp.files + " 个文件，追加 " + $lp.added + " 条台词")
        }
    }
} catch { }
    }
    catch {
        $script:cfg = $null
        Write-Host "配置：config.json 有问题，改用默认值" -ForegroundColor Yellow
    }
}
else {
    Write-Host "配置：没找到 config.json，用默认值"
}

# 取值：读不到就返回默认值。
# 所以 config.json 缺了 / 坏了 / 少写一项，她照样能跑。
function Cfg {
    param($Path, $Default)
    if (-not $script:cfg) { return $Default }
    $node = $script:cfg
    foreach ($k in ($Path -split '\.')) {
        if ($null -eq $node) { return $Default }
        $child = $node.$k
        if ($null -eq $child) { return $Default }
        $node = $child
    }
    if ($null -eq $node) { return $Default }
    return $node
}

# 从配置读「秒」，换算成「帧」——跟着帧率走，所以改了帧率她的节奏也不会乱
function CfgFrames {
    param($Path, [double]$DefSec)
    $sec = [double](Cfg $Path $DefSec)
    # ★ 定时器可能还没创建（启动阶段就会调用）→ 回退用配置帧率，避免除以 0 得到 ∞ ✗
    $iv = 16.0
    if ($null -ne $script:timer -and $script:timer.Interval -gt 0) {
        $iv = [double]$script:timer.Interval
    }
    else {
        $iv = [double](Cfg '显示.帧率毫秒' 16)
        if ($iv -le 0) { $iv = 16.0 }
    }
    $fr = [int]($sec * 1000.0 / $iv)
    if ($fr -lt 1) { $fr = 1 }
    return $fr
}

# ============================================================
#  0. 分层窗口辅助类
# ============================================================
$cs = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public class LW {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst,
        ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, uint crKey,
        ref BLENDFUNCTION pblend, uint dwFlags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hDC);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr hObj);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hWnd, int nIndex, int v);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    // 关掉系统对窗口的 DPI 拉伸 —— 不关的话，缩放不是 100% 的屏上整窗都是糊的
    public static void MakeDpiAware() {
        try { SetProcessDPIAware(); } catch { }
    }

    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);

    // 判断这个窗口是不是"录屏/工具类"窗口（录演示时会挡路，当成障碍物她会撞上去哭 ✗）
    // ★ 自家软件（DeepSeek Harness）不在这里排除了 —— 她撞上去也要有反应 ✓
    //   撞到自家软件时的特殊处理在碰撞逻辑里：不哭、只轻微摇晃 + 说认亲台词 ✓
    static bool IsToolWindow(IntPtr h) {
        try {
            var t = new System.Text.StringBuilder(160);
            GetWindowText(h, t, 160);
            string title = t.ToString();
            if (title.Length == 0) return false;
            string low = title.ToLowerInvariant();
            return low.Contains("screentogif") || low.Contains("recorder") ||
                   low.Contains("licecap") || low.Contains("sharex") ||
                   low.Contains("shotcut") || low.Contains("camstudio");
        } catch { return false; }
    }

    // ★ 只列"录屏工具"的窗口矩形（用来判断她是不是被框住了）
    //   这些框被 OtherRects 排除了（不撞），但她能"看见"，所以会发出疑问 ✓
    //   ⚠️ 尺寸门槛要低 —— ScreenToGif 的录制工具栏很小（约 200x40），
    //      用 220x170 会把它全滤掉 ✗
    public static int[] ToolRects() {
        int[] buf = new int[64];
        int n = 0;
        EnumWindows((h, p) => {
            if (n >= 60) return false;
            if (!IsWindowVisible(h)) return true;
            if (!IsToolWindow(h)) return true;
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            int w = r.Right - r.Left, hh = r.Bottom - r.Top;
            if (w < 80 || hh < 24) return true;
            buf[n] = r.Left; buf[n + 1] = r.Top; buf[n + 2] = r.Right; buf[n + 3] = r.Bottom;
            n += 4;
            return true;
        }, IntPtr.Zero);
        return buf;
    }

    // ★ v2.2：返回所有可见窗口信息（供"被框住"按配置过滤）
    //   格式： "l,t,r,b|tool|class|title"
    public static string[] WindowsInfo() {
        var list = new System.Collections.Generic.List<string>();
        EnumWindows((h, p) => {
            if (list.Count >= 80) return false;
            if (!IsWindowVisible(h)) return true;
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            if (r.Left <= -30000) return true;              // 最小化窗口跳过
            var tb = new System.Text.StringBuilder(200); GetWindowText(h, tb, 200);
            var cb = new System.Text.StringBuilder(120); GetClassName(h, cb, 120);
            int ex = GetWindowLong(h, -20);
            bool tool = (ex & 0x00000080) != 0;
            list.Add(string.Format("{0},{1},{2},{3}|{4}|{5}|{6}",
                r.Left, r.Top, r.Right, r.Bottom, tool ? 1 : 0,
                cb.ToString(), tb.ToString().Replace("|", "/")));
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    // ★ v2.5：读前台窗口信息（只读标题+进程名，不读内容，不上传）
    //   格式： "标题\u0001进程名"
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static string ForegroundInfo() {
        try {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return "";
            var sb = new System.Text.StringBuilder(300);
            GetWindowText(h, sb, 300);
            string title = sb.ToString();
            uint pid = 0;
            GetWindowThreadProcessId(h, out pid);
            string proc = "";
            try { proc = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
            return title + "\u0001" + proc;
        } catch { return ""; }
    }

    // ★ v2.2：按关键词找窗口矩形，返回 "l,t,r,b"，找不到返回 ""
    public static string FindWindowRect(string keyword) {
        string found = "";
        EnumWindows((h, p) => {
            if (!IsWindowVisible(h)) return true;
            var tb = new System.Text.StringBuilder(200); GetWindowText(h, tb, 200);
            string title = tb.ToString();
            if (title.Length == 0) return true;
            if (title.IndexOf(keyword, StringComparison.OrdinalIgnoreCase) < 0) return true;
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            if (r.Left <= -30000) return true;
            if ((r.Right - r.Left) < 60 || (r.Bottom - r.Top) < 40) return true;
            found = r.Left + "," + r.Top + "," + r.Right + "," + r.Bottom;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    // 列出"别人的窗口"矩形，扁平数组 [l,t,r,b, ...]（固定 128 个 int，够 32 个窗口）
    // 排除：桌面/任务栏/太小的/几乎占满屏幕的/录屏工具的框
    public static int[] OtherRects(IntPtr self, int sw, int sh) {
        int[] buf = new int[128];
        int n = 0;
        EnumWindows((h, p) => {
            if (n >= 124) return false;
            if (h == self || !IsWindowVisible(h)) return true;
            var sb = new System.Text.StringBuilder(80);
            GetClassName(h, sb, 80);
            string cls = sb.ToString();
            if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" ||
                cls == "Shell_SecondaryTrayWnd" || cls == "Windows.UI.Core.CoreWindow" ||
                cls == "SysShadow" || cls == "TaskListThumbnailWnd") return true;
            if (IsToolWindow(h)) return true;   // ★ 录屏工具不算障碍
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            int w = r.Right - r.Left, hh = r.Bottom - r.Top;
            if (w < 220 || hh < 170) return true;
            if (w >= (int)(sw * 0.92) && hh >= (int)(sh * 0.92)) return true;
            buf[n] = r.Left; buf[n + 1] = r.Top; buf[n + 2] = r.Right; buf[n + 3] = r.Bottom;
            n += 4;
            return true;
        }, IntPtr.Zero);
        return buf;
    }

    // ★ 判断她身体范围内【有没有】某个标题含关键字的窗口（不取最上层 ✗）
    //   因为和她的身体重叠的窗口可能不止一个，最上层常常不是目标窗口 ✗
    public static bool HasWindowInRect(int l, int t, int r, int b, IntPtr self, string keyword) {
        bool found = false;
        EnumWindows((h, p) => {
            if (found) return false;
            if (h == self || !IsWindowVisible(h)) return true;
            var cb = new System.Text.StringBuilder(256);
            GetWindowText(h, cb, 256);
            string title = cb.ToString();
            if (title.Length == 0) return true;
            if (title.IndexOf(keyword, StringComparison.OrdinalIgnoreCase) < 0) return true;
            RECT q;
            if (!GetWindowRect(h, out q)) return true;
            if (r > q.Left && l < q.Right && b > q.Top && t < q.Bottom) {
                found = true;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // 取某个屏幕点上的窗口标题（用来判断她是不是站在自家软件前面）
    [StructLayout(LayoutKind.Sequential)] public struct PT2 { public int X, Y; }
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(PT2 p);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    const uint GW_HWNDNEXT = 2;

    // ★ 跳过她自己的窗口往下找 —— WindowFromPoint 会返回最上面的，
    //   而在她身上取点时，最上面的永远是她自己 ✗
    public static string TitleUnderPoint(int x, int y, IntPtr self) {
        PT2 pt; pt.X = x; pt.Y = y;
        IntPtr h = WindowFromPoint(pt);
        int guard = 0;
        while (h != IntPtr.Zero && guard < 120) {
            if (h != self) {
                var sb = new System.Text.StringBuilder(256);
                GetWindowText(h, sb, 256);
                string t = sb.ToString();
                if (t.Length > 0) return t;
            }
            h = GetWindow(h, GW_HWNDNEXT);
            guard++;
        }
        return "";
    }

    public static string TitleAtPoint(int x, int y) {
        PT2 pt; pt.X = x; pt.Y = y;
        IntPtr h = WindowFromPoint(pt);
        if (h == IntPtr.Zero) return "";
        var sb = new System.Text.StringBuilder(256);
        GetWindowText(h, sb, 256);
        return sb.ToString();
    }

    // 取「和给定矩形重叠的最上层窗口」的标题（按 z 序，最上面优先）
    // 用来认出她撞到的是谁 —— 比 WindowFromPoint 准，因为用的是她真实的碰撞框
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);

    public static string TitleOverlapping(int l, int t, int r, int b, IntPtr self) {
        string found = "";
        EnumWindows((h, p) => {
            if (h == self || !IsWindowVisible(h)) return true;
            var cb = new System.Text.StringBuilder(80);
            GetClassName(h, cb, 80);
            string cls = cb.ToString();
            if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" ||
                cls == "Shell_SecondaryTrayWnd" || cls == "Windows.UI.Core.CoreWindow" ||
                cls == "SysShadow" || cls == "TaskListThumbnailWnd") return true;
            RECT q;
            if (!GetWindowRect(h, out q)) return true;
            if (q.Right <= l || q.Left >= r || q.Bottom <= t || q.Top >= b) return true;
            var tb = new System.Text.StringBuilder(256);
            GetWindowText(h, tb, 256);
            string title = tb.ToString();
            // 没有标题的窗口（比如 Fences）跳过，继续往下找有标题的
            if (title.Length == 0) return true;
            found = title;
            return false;                     // 找到有标题的就停
        }, IntPtr.Zero);
        return found;
    }

    const int GWL_EXSTYLE = -20;
    const int WS_EX_LAYERED = 0x00080000;

    public static void MakeLayered(IntPtr hwnd) {
        int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
    }

    public static bool SetBitmap(IntPtr hwnd, Bitmap bmp, int x, int y, byte constAlpha) {
        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memDc = CreateCompatibleDC(screenDc);
        IntPtr hBmp = IntPtr.Zero, oldBmp = IntPtr.Zero;
        try {
            hBmp = bmp.GetHbitmap(Color.FromArgb(0));
            oldBmp = SelectObject(memDc, hBmp);
            SIZE size; size.cx = bmp.Width; size.cy = bmp.Height;
            POINT src; src.X = 0; src.Y = 0;
            POINT dst; dst.X = x; dst.Y = y;
            BLENDFUNCTION bf;
            bf.BlendOp = 0; bf.BlendFlags = 0;
            bf.SourceConstantAlpha = constAlpha; bf.AlphaFormat = 1;
            return UpdateLayeredWindow(hwnd, screenDc, ref dst, ref size, memDc, ref src, 0, ref bf, 2);
        }
        finally {
            if (oldBmp != IntPtr.Zero) SelectObject(memDc, oldBmp);
            if (hBmp != IntPtr.Zero) DeleteObject(hBmp);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }
}
'@

$refs = @(
    [System.Drawing.Color].Assembly.Location
    [System.Drawing.Bitmap].Assembly.Location
    [System.Windows.Forms.Form].Assembly.Location
) | Where-Object { $_ } | Select-Object -Unique

# ★ 编译失败重试（杀软/临时目录偶发"拒绝访问"，重试 3 次基本都能过）
$compiled = $false
for ($tryN = 1; $tryN -le 3; $tryN++) {
    try {
        Add-Type -TypeDefinition $cs -ReferencedAssemblies $refs -ErrorAction Stop
        $compiled = $true
        break
    } catch {
        if ($tryN -ge 3) { $script:__compileErr = $_ }
        else { Start-Sleep -Milliseconds 800 }
    }
}
if (-not $compiled) {
    $msg = $script:__compileErr.Exception.Message
    Write-Host '分层窗口辅助类编译失败：' -ForegroundColor Red
    exit 1
}

# 必须在创建任何窗口之前调用
[LW]::MakeDpiAware()

# ============================================================
#  1. 形象
# ============================================================
$script:origImage = $null
$script:petImage  = $null
$script:petImageFlip = $null
$script:earL = $null
$script:earR = $null
$script:imgW = 0
$script:imgH = 0
$script:scale = [double](Cfg '显示.缩放' 0.75)     # 相对原图的显示比例

$imgPath = Join-Path $PSScriptRoot 'pet.png'
if (Test-Path $imgPath) {
    $script:origImage = [System.Drawing.Image]::FromFile($imgPath)
    Write-Host "形象：pet.png ($($script:origImage.Width) x $($script:origImage.Height))"
}
else {
    Write-Host "形象：内置手绘小鱼（没找到 pet.png）"
}

# 平滑缩放（分层窗口下不需要硬阈值，插值出来的软边正是我们要的）
function Update-PetBitmap {
    if ($script:petImage) { $script:petImage.Dispose(); $script:petImage = $null }
    if (-not $script:origImage) { return }

    $nw = [Math]::Max(1, [int]($script:origImage.Width  * $script:scale))
    $nh = [Math]::Max(1, [int]($script:origImage.Height * $script:scale))

    $bmp = New-Object System.Drawing.Bitmap($nw, $nh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gg = [System.Drawing.Graphics]::FromImage($bmp)
    $gg.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gg.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $gg.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $gg.DrawImage($script:origImage, 0, 0, $nw, $nh)
    $gg.Dispose()

    $script:petImage = $bmp

    # 镜像版（往左走时用）：预先翻转好，避免每帧做变换导致模糊
    if ($script:petImageFlip) { $script:petImageFlip.Dispose() }
    $fb = $bmp.Clone()
    $fb.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX)
    $script:petImageFlip = $fb

    # 耳朵精灵：从同一张缩放后的本体上裁下来，单独画 → 才能摆动
    if ($script:earL) { $script:earL.Dispose() }
    if ($script:earR) { $script:earR.Dispose() }
    $script:earL = $null; $script:earR = $null
    try {
        $rl = New-Object System.Drawing.Rectangle(
            [int]($nw * $script:earBoxL[0]), [int]($nh * $script:earBoxL[1]),
            [int]($nw * $script:earBoxL[2]), [int]($nh * $script:earBoxL[3]))
        $rr = New-Object System.Drawing.Rectangle(
            [int]($nw * $script:earBoxR[0]), [int]($nh * $script:earBoxR[1]),
            [int]($nw * $script:earBoxR[2]), [int]($nh * $script:earBoxR[3]))
        $script:earL = $bmp.Clone($rl, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $script:earR = $bmp.Clone($rr, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    }
    catch {
        $script:earL = $null; $script:earR = $null
    }

    # 头部精灵（吃痛时低头用）
    if ($script:headSprite) { $script:headSprite.Dispose() }
    $script:headSprite = $null
    try {
        $rh = New-Object System.Drawing.Rectangle(
            [int]($nw * $script:headX), [int]($nh * $script:headY),
            [int]($nw * $script:headW), [int]($nh * $script:headH))
        $script:headSprite = $bmp.Clone($rh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    }
    catch { $script:headSprite = $null }

    $script:imgW = $nw
    $script:imgH = $nh

    # ★ 表情整张 sprite（AI 生成后抠好的，288x382，脚底对齐）
    #   长状态（开心/生气/…）直接换整张图，不做任何叠加 → 没有接缝 ✓
    if ($script:exprSprites) {
        foreach ($k in @($script:exprSprites.Keys)) {
            if ($script:exprSprites[$k]) { $script:exprSprites[$k].Dispose() }
        }
    }
    $script:exprSprites = @{}
    $esDir = Join-Path $PSScriptRoot 'assets\sprites'
    if (Test-Path $esDir) {
        $ratio2 = $script:scale
        # ★ 自动扫描 assets\sprites\ 下所有 png → 用户丢新图进来即可用（自定义动作）
        $spriteNames = @()
        try { $spriteNames = @(Get-ChildItem $esDir -Filter '*.png' -File | ForEach-Object { $_.BaseName } | Where-Object { $_ -ne '基准' }) } catch {}
        foreach ($n in $spriteNames) {
            $ep = Join-Path $esDir "$n.png"
            if (-not (Test-Path $ep)) { continue }
            try {
                $raw2 = [System.Drawing.Image]::FromFile($ep)
                $enw = [Math]::Max(1, [int][Math]::Round($raw2.Width  * $ratio2))
                $enh = [Math]::Max(1, [int][Math]::Round($raw2.Height * $ratio2))
                $esc = New-Object System.Drawing.Bitmap $enw, $enh, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $esg = [System.Drawing.Graphics]::FromImage($esc)
                $esg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $esg.DrawImage($raw2, 0, 0, $enw, $enh)
                $esg.Dispose(); $raw2.Dispose()
                $script:exprSprites[$n] = $esc
                # 镜像版（往左走时用）
                $efl = $esc.Clone()
                $efl.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX)
                $script:exprSprites[$n + '_flip'] = $efl
            } catch { }
        }
    }

    # ★ 滚动球：算 36 个方向的轮廓半径（贴地精确用，避免"颠"）
    $script:rollRadii = @()
    try {
        if ($script:exprSprites -and $script:exprSprites.ContainsKey('pose_团')) {
            $bm = $script:exprSprites['pose_团']
            $bw = $bm.Width; $bh = $bm.Height
            $rect = New-Object System.Drawing.Rectangle 0, 0, $bw, $bh
            $data = $bm.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $bytes = New-Object byte[] ($data.Stride * $bh)
            [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
            $bm.UnlockBits($data)
            $cxx = $bw / 2.0; $cyy = $bh / 2.0
            $buckets = New-Object 'double[]' 36
            for ($yy = 0; $yy -lt $bh; $yy++) {
                $row = $yy * $data.Stride
                for ($xx = 0; $xx -lt $bw; $xx++) {
                    $al = $bytes[$row + $xx * 4 + 3]
                    if ($al -le 32) { continue }
                    $dx = $xx + 0.5 - $cxx; $dy = $yy + 0.5 - $cyy
                    $r = [Math]::Sqrt($dx * $dx + $dy * $dy)
                    $deg = [Math]::Atan2($dy, $dx) * 180.0 / [Math]::PI
                    if ($deg -lt 0) { $deg += 360.0 }
                    $bi = [int]($deg / 10.0) % 36
                    if ($r -gt $buckets[$bi]) { $buckets[$bi] = $r }
                }
            }
            # 空桶用邻居插值补齐
            for ($i = 0; $i -lt 36; $i++) {
                if ($buckets[$i] -le 0) {
                    for ($k = 1; $k -le 18; $k++) {
                        $a1 = $buckets[(($i - $k + 36) % 36)]; $a2 = $buckets[(($i + $k) % 36)]
                        if ($a1 -gt 0 -or $a2 -gt 0) { $buckets[$i] = [Math]::Max($a1, $a2); break }
                    }
                }
            }
            $script:rollRadii = @($buckets)
            $mn = ($buckets | Measure-Object -Minimum).Minimum
            $mx = ($buckets | Measure-Object -Maximum).Maximum
            Write-Host ("滚动半径表：36 方向，最小 " + [Math]::Round($mn,1) + "px 最大 " + [Math]::Round($mx,1) + "px")
        }
    } catch { $script:rollRadii = @() }
    # 眼睑线是按图像坐标画的，粗细也要跟着缩放走（不然改大小就会变粗/变细）
    if ($script:eyeLidPen) {
        $script:eyeLidPen.Width = [single][Math]::Max(2.0, 4.5 * ($script:scale / 0.75))
    }
}

if ($script:origImage) { Update-PetBitmap }

# ============================================================
#  2. 画布 + 窗口
# ============================================================
# 画布：下方给摇曳 / 跳跃 / 星火留空，上方给说话气泡留空
$script:cw = if ($script:petImage) { [Math]::Max($script:imgW + 90, 300) } else { 300 }
$script:ch = if ($script:petImage) { $script:imgH + 300 } else { 330 }

$script:canvas = New-Object System.Drawing.Bitmap(
    $script:cw, $script:ch, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

$script:form = New-Object System.Windows.Forms.Form
$script:form.FormBorderStyle = 'None'
$script:form.ShowInTaskbar   = $false
$script:form.TopMost         = [bool](Cfg '显示.始终置顶' $true)
$script:form.StartPosition   = 'Manual'
$script:form.ClientSize      = [System.Drawing.Size]::new($script:cw, $script:ch)

# 多显示器：用「虚拟屏幕」= 所有显示器合起来的大矩形
# （以前只认主屏，双屏用户她会走不出第一块屏）
$script:scr = [System.Windows.Forms.SystemInformation]::VirtualScreen
# ★ 底部边界用"工作区"（扣掉任务栏）：防止她钻到任务栏下面
try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:floorBottom = [Math]::Min($script:scr.Bottom, $wa.Bottom)
} catch { $script:floorBottom = $script:scr.Bottom }
$script:wallCool = 0   # 撞墙冷却（帧）
$script:px = $script:scr.Right  - $script:cw - 40
$script:py = $script:floorBottom - $script:ch - 40
$script:form.Location = [System.Drawing.Point]::new($script:px, $script:py)

# ============================================================
#  3. 预建画笔（避免每帧新建 GDI 对象）
# ============================================================
# 软阴影：9 层递减 alpha
$script:shadowBrushes = @()
for ($i = 0; $i -lt 9; $i++) {
    $a = [int](9 * (9 - $i) / 9) + 1
    $script:shadowBrushes += New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::FromArgb($a, 0, 0, 0))
}

# 星火：3 种颜色 × 8 级 alpha
$sparkCols = @(
    [System.Drawing.Color]::FromArgb(255, 150, 210, 255)
    [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
    [System.Drawing.Color]::FromArgb(255, 255, 190, 225)
)
$script:sparkBrushes = @()
foreach ($c in $sparkCols) {
    $row = @()
    for ($b = 0; $b -lt 8; $b++) {
        $a = [int](255 * ($b + 1) / 8)
        $row += New-Object System.Drawing.SolidBrush(
            [System.Drawing.Color]::FromArgb($a, $c.R, $c.G, $c.B))
    }
    $script:sparkBrushes += , $row
}

# ---------- 统一字体（中文 Noto Sans SC / 数字 Segoe UI Semibold）----------
$script:fontCN = 'DengXian'
$script:fontCNBold = 'DengXian'
$script:fontNum = 'Segoe UI'
try {
    $famNames = @()
    $ic = New-Object System.Drawing.Text.InstalledFontCollection
    foreach ($ff in $ic.Families) { $famNames += $ff.Name }
    if ($famNames -contains 'Noto Sans SC') { $script:fontCN = 'Noto Sans SC' }
    if ($famNames -contains 'Noto Sans SC Medium') { $script:fontCNBold = 'Noto Sans SC Medium' } elseif ($famNames -contains 'Noto Sans SC') { $script:fontCNBold = 'Noto Sans SC' }
    if ($famNames -contains 'Segoe UI Semibold') { $script:fontNum = 'Segoe UI Semibold' }
} catch {}
function UiFont {
    param([single]$Size = 9, [int]$Style = 0, [switch]$Num)
    $fam = $script:fontCN
    $st = [System.Drawing.FontStyle]::Regular
    if ($Num) { $fam = $script:fontNum }
    elseif ($Style -gt 0) {
        $fam = $script:fontCNBold
        if ($fam -eq $script:fontCN) { $st = [System.Drawing.FontStyle]::Bold }
    }
    try { return (New-Object System.Drawing.Font($fam, $Size, $st)) } catch { return (New-Object System.Drawing.Font('Microsoft YaHei UI', $Size, $st)) }
}

# 说话气泡
$script:bubbleFont  = UiFont 11.5 1
$script:bubbleText  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 38, 56, 104))
$script:bubbleFill  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 240, 247, 255))
$script:bubblePen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 58, 86, 156), 2.8)
$script:bubbleIn    = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 255, 255, 255), 1.4)
$script:bubbleSf    = New-Object System.Drawing.StringFormat
$script:bubbleSf.Alignment     = [System.Drawing.StringAlignment]::Center
$script:bubbleSf.LineAlignment = [System.Drawing.StringAlignment]::Center
$script:bubbleBmp   = $null
$script:bubbleW     = 0
$script:bubbleH     = 0
$script:bubbleIA    = New-Object System.Drawing.Imaging.ImageAttributes

# 手绘小鱼用色
$script:brushBody  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 78, 138, 205))
$script:brushFin   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 130, 185, 235))
$script:brushEyeW  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$script:brushDark  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 20, 25, 45))
$script:brushBlush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 230, 150, 170))
$script:penDark    = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 20, 25, 45), 2)

# 眨眼：盖住眼睛的皮肤色 + 闭眼弧线
$script:skinBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 246, 217, 222))
$script:lidPen    = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 42, 46, 78), 2.6)
$script:lidPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$script:lidPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round

# 眼泪 / 怒符
$script:tearBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(228, 118, 188, 255))
$script:tearHi    = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(225, 255, 255, 255))
$script:angerPen  = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(235, 235, 70, 90), 3.4)
$script:angerPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$script:angerPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
$script:heartBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220, 255, 120, 160))

# 两只眼睛的位置（相对图片宽高的比例 → 缩放和镜像都能用）
$script:eyeL = @(0.29167, 0.40052, 0.42014, 0.50262)
$script:eyeR = @(0.53819, 0.40052, 0.67014, 0.50262)
$script:eyeInset = 0.011

# ★ 眼皮色必须是【她自己脸上的颜色】——
#   以前写死 RGB(246,217,222)，实测她眼睛上方是 RGB(249,232,227)：偏粉偏暗 ✗
#   眨眼时那一块会显出一块粉色补丁，看起来就像"眼皮连着眉毛一起掉下来" ✗
# ★ 眼睑线也必须是【她自己睫毛的颜色 + 粗细】——
#   实测她的睫毛是 RGB(约 8,1,2)、约 5px 宽（在 0.75 缩放下）。
#   以前画的是 2.6px 灰蓝线 → 眨眼一开始，粗黑睫毛"瞬间变成细灰线"，一眼就不对 ✗
$script:eyeLidPen = $null
if ($script:petImage) {
    try {
        $exMid = $script:imgW * (($script:eyeL[0] + $script:eyeL[2]) / 2.0)

        # 眼皮色：眼睛正上方那块（眨眼时正是它被盖住）
        $eyUp = $script:imgH * ($script:eyeL[1] - 0.020)
        $skc = $script:petImage.GetPixel([int]$exMid, [int]$eyUp)
        if ($skc.A -gt 200 -and $skc.R -gt 215 -and $skc.G -gt 195) {
            if ($script:skinBrush) { $script:skinBrush.Dispose() }
            $script:skinBrush = New-Object System.Drawing.SolidBrush($skc)
            Write-Host "眼皮色：取样 RGB($($skc.R),$($skc.G),$($skc.B))"
        }

        # 睫毛色：眼睛框上沿往下一点点，那里是粗睫毛
        $eyLash = $script:imgH * ($script:eyeL[1] + 0.012)
        $lc = $script:petImage.GetPixel([int]$exMid, [int]$eyLash)
        $lashCol = if ($lc.A -gt 200 -and ($lc.R + $lc.G + $lc.B) -lt 260) {
            $lc
        } else {
            [System.Drawing.Color]::FromArgb(255, 20, 18, 30)   # 兜底：深黑
        }
        $script:eyeLidPen = New-Object System.Drawing.Pen($lashCol, 4.5)
        $script:eyeLidPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $script:eyeLidPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
        Write-Host "眼睑线：取样 RGB($($lashCol.R),$($lashCol.G),$($lashCol.B))，粗 4.5px"
    } catch { }
}

# ============================================================
#  4. 状态
# ============================================================
$script:tick      = 0
$script:happy     = 0
$script:autoWalk  = [bool](Cfg '行为.自动游走' $false)
$script:quiet = 0   # 动作/吃痛后的安静期（帧），期间不自动游走
$script:idleHop   = [bool](Cfg '行为.随机小动作' $true)
$script:translucent = [bool](Cfg '显示.启动时半透明' $false)
$script:paused      = $false     # 暂停：她定住不动，但还看得见
$script:pauseFixFrames = 0       # 暂停后先跑几帧把姿态扶正
$script:hovered   = $false
$script:dragging  = $false
$script:constAlpha = 255
$script:particles = New-Object System.Collections.ArrayList
$script:groundY   = 0.0      # 地面线（画布坐标），粒子落地时统一画在这条线上

# 说话气泡
$script:bubbleText_  = ''
$script:bubbleLife   = 0
$script:bubbleTotal  = 1
$script:talkCount    = 0
$script:talkNext     = if ([bool](Cfg '气泡.启动先打个招呼' $true)) { 170 } else { 99999999 }      # 启动约 3 秒后先打个招呼，之后 15~35 秒随机说一句

# 台词池（前 12 条取自你那个 whale-widget 的默认台词，后面是我加的）
$script:lines = @(
    '我能去你家吃饭吗？就一碗！'
    '欺负我的人等着，等几天我就忘了...'
    '上班让我意识到时间是可以被浪费的...'
    '地球online的金币也太难获取了...'
    '老大，压力只会转化成病例，别太勉强了...'
    '命运的齿轮开始转动了，丝毫不在意你夹在中间...'
    '视力下降到无可救药的地步了，打开钱包也看不到钱...'
    'oi，夏天还会变成暑假来救你吗？'
    '我来看看那个AI改了什么导致插件又崩了...'
    'token 来！'
    '再无话说，请速速动手！'
    '你知道吗？我删过作者的库哦...'
    '今天也别太累了，我在这儿陪你。'
    '写代码要记得存盘哦。'
    '摸鱼也是正经工作的一部分。'
    '你盯着屏幕的样子，挺认真的。'
    '要不要起来走两步？'
    '别熬太晚，我可不会替你睡觉。'
    '我是一条鲸鱼，但是我不太会游泳...'
    '刚刚那句话我排练了三遍。'
    '你忙你的，我就在这儿飘着。'
    '这个bug看起来比我还倔。'
    '喝口水吧，我等你。'
    '别皱眉，会变老的。'
    '我也想要一杯奶茶。'
    '刚才那个函数名我念了三遍才念对。'
    '你的鼠标移过来的时候，我心跳快了一下。'
    '别看我，看代码。'
    '这条日志我看了三遍也没看懂。'
    '我也想去海边。'
    '你今天笑了吗？没有的话现在笑一个。'
    '我数了数，你今天已经叹了四口气了。'
    '再坚持一下，马上就下班了。'
    '其实我不太懂，但我支持你。'
    '这个配色我挺喜欢的。'
    '要不要我给你唱首歌？...算了，我不会。'
    '我发现你打字的时候会皱眉。'
    '外面天黑了，记得开灯。'
    '偶尔也要抬头看看别的地方。'
    '我在这儿，不吵你。'
)

# 被慢慢顺毛顺舒服了
$script:happyLines = @(
    '嗯...舒服...'
    '再摸摸嘛...'
    '嘿嘿，你手法不错。'
    '就这样，别停。'
    '我今天心情很好哦。'
    '谢谢你呀。'
)

# 被摸到会害羞（悬停时说）
$script:shyLines = @(
    '别、别摸头啦...'
    '唔...有点痒...'
    '你干嘛呀...'
    '我、我才没脸红！'
    '再摸我要跑了哦...'
    '哼，就这一次哦。'
    '手拿开啦...'
    '诶...?!'
)

# 被摸太多次时说的
$script:angryLines = @(
    '别摸了！我头发要乱了！'
    '再摸我就咬你了哦。'
    '你手怎么这么闲啊...'
    '我生气了，真的。'
    '住手！我要报警了。'
    '哼，不理你了。'
)

# 撞到窗口时说的
$script:hurtLines = @(
    '唔...好痛...'
    '撞到了啦...'
    '呜...谁把窗口放这儿的...'
    '我的头...好晕...'
    '呜呜呜...'
)

# 配置里有台词就用配置里的；没有就用上面这些默认值
$script:lines      = @(Cfg '台词.普通' $script:lines)
$script:shyLines   = @(Cfg '台词.害羞' $script:shyLines)
$script:happyLines = @(Cfg '台词.开心' $script:happyLines)
$script:angryLines = @(Cfg '台词.生气' $script:angryLines)
$script:hurtLines  = @(Cfg '台词.吃痛' $script:hurtLines)

# 认出「这是我自己的软件」时说的
$script:dsLines = @(
    '这不是我么！'
    '诶？这是我们家的窗口。'
    '我第一次见到我自己...'
    '原来我住在这里面呀。'
)
$script:dsLines = @(Cfg '台词.认亲' $script:dsLines)

# ★ 被"碰不到的框"框住时说的（比如 ScreenToGif 的录制框）
#   —— 这些框被她当成"不存在的墙"，走进去碰不到，所以她会疑惑 ✓
$script:trappedLines = @(
    '这个框我怎么碰不到呀...'
    '你把我框起来了！'
    '诶？这框是透明的？'
    '碰不到...这是结界吗？'
    '你框我干嘛，我又不会跑。'
    '这框子...有点不对劲。'
)
$script:trappedLines = @(Cfg '台词.被框住' $script:trappedLines)

# 随机游走（vx/vy = 当前速度，tvx/tvy = 目标速度，靠缓动逼近）
$script:vx = 0.0
$script:vy = 0.0
$script:tvx = 0.0
$script:tvy = 0.0
$script:wanderCount = 0
$script:wanderNext  = 20

# —— 「像生物」的游走状态 ——
# 不是每 N 帧重抽方向（那样一眼就是程序），而是：心里那个方向【连续地】慢慢变。
$script:wanderAng     = (Get-Random -Minimum 0 -Maximum 628) / 100.0   # 当前朝向（弧度）
$script:wanderBias    = $script:wanderAng                              # 基准朝向：缓慢回归的目标
$script:wanderSpd     = 1.2                                            # 当前"想走多快"
$script:wanderBreath  = (Get-Random -Minimum 0 -Maximum 628) / 100.0   # 呼吸相位
$script:wanderImpulse = 60                                             # 距下次"小脾气"还有几帧

# 一次跳跃持续多少帧（30ms/帧 → 26 帧 ≈ 0.78 秒）
$script:hopLen = 26

# 眨眼
$script:blink     = 0
$script:blinkLen  = 7
$script:blinkCount = 0
$script:blinkNext  = 200

# ---------- Q弹（弹性形变）----------
# sq > 0 = 纵向拉长（起跳），sq < 0 = 压扁（落地）
$script:sq    = 0.0
$script:sqV   = 0.0
$script:sqHit = 0.0        # 落地时的一次性冲击

# 耳朵
$script:earAng = 0.0
$script:earV   = 0.0
$script:earBoxL   = @(0.0347, 0.3874, 0.1806, 0.1047)   # x, y, 宽, 高（比例）
$script:earBoxR   = @(0.7639, 0.3874, 0.1944, 0.1047)
$script:earPivotL = 1.0     # 支点在精灵宽度上的位置（耳朵根部）
$script:earPivotR = 0.0
$script:earPivotY = 0.55

# 时不时做动作
$script:actCount = 0
$script:actNext  = Get-Random -Minimum 220 -Maximum 700
$script:lastHover = -9999

# ---------- 被摸太多会生气 ----------
$script:petHeat = 0.0        # 手感热度（衰减快：摸太急就生气）
$script:petSlow = 0.0        # 慢慢顺毛的次数（凑够 5 次就开心）
$script:mood    = 0          # 开心剩余帧
$script:angry   = 0          # 生气剩余帧
$script:angryCD = 0          # 生气后的冷却
$script:shy     = 0          # 害羞剩余帧（悬停时）
$script:menuOpen = $false    # 右键菜单开着 → 暂停一切"摸"的反应

# ---------- 撞窗口吃痛 ----------
$script:hurt    = 0          # 吃痛剩余帧
$script:tears   = 0.0        # 眼泪量 0..1
$script:winRects = @()       # 其他窗口的矩形
$script:bumpCount = 0        # 连续撞了几次（撞满 4 次会生气）
$script:trappedCool = -9999  # 上次"被框住"说话的时刻（防重复）
$script:dsSaid  = 0          # 本轮认亲说了几句（最多 3 句）
$script:dsCool  = -9999      # 上次认亲说话的时刻
$script:dsLeave = 0          # 离开自家软件后的帧数（累计够久就重置计数）
$script:lastBump  = -9999    # 上次撞的时间（tick），用来做冷却
$script:edgeCool  = 0        # 撞屏幕边缘的冷却
$script:winTick  = 0
$script:surprise = 0         # 被摸到时"!"剩余帧
$script:recoilX  = 0.0       # 撞到后往后退的速度
$script:recoilY  = 0.0
$script:earPh    = 0.0       # 左右耳相位差（让两只耳朵不同步）

# ---- 说话/表情总线（v2 新增：解决"表情和台词互相覆盖"）----
$script:sayLock     = 0     # 说话锁剩余帧
$script:sayLockPrio = 0     # 当前锁的优先级
$script:sayLast     = -9999 # 上次说话时刻
$script:emoLock     = 0     # 表情切换冷却帧
$script:emoName     = ''    # 当前主表情
$script:emoPrio     = 0

# ---- 碰撞 v2：进入检测 / 困住 / 认亲停留 ----
$script:prevBody     = $null  # 上一帧身体矩形（l,t,r,b）
$script:insideWin    = ''     # 当前所在的窗口标题
$script:insideFrames = 0      # 在里面待了多少帧
$script:enterCool    = -9999  # 进入碰撞冷却
$script:trappedCool2 = -9999  # 困住说话冷却
$script:trappedHold = 0      # 贴边持续帧数（被框住判定）
$script:dsDwell      = 0      # 在 Harness 里待了多少帧（认亲用）

# ---- 蹦跳 / 转身 ----
$script:hopActive = $false    # 大跳进行中
$script:hopPhase  = 0.0       # 大跳相位 0..1
$script:hopCount  = 0         # 还剩几次弹跳
$script:hopH      = 20.0      # 本次跳多高
$script:hopFlip   = 0.0       # 翻转角度（度）
$script:spinSquash = 1.0       # 转圈时的横向压扁（模拟竖轴转身）
$script:spinMirror = $false    # 转圈背向时镜像
$script:spinBob = 0.0          # 转圈时的上下起伏
$script:hopJump   = 0.0       # 当前跳跃抬升像素
$script:hopTotal  = 3         # 本次共跳几次
$script:hopDone   = 0         # 已完成几次
$script:turnSx    = 1.0       # 转身横向缩放
$script:sleep     = 0         # 睡觉剩余帧（被指令触发）
$script:poseTmp   = $null     # 临时姿势覆盖 @{name=;frames=}
$script:xfKey    = ''          # 当前精灵 key（用于过渡）
$script:xfPrev   = $null      # 上一张精灵（过渡用）
$script:xf       = 1.0        # 过渡进度 0=旧 1=新
$script:swapTo   = $null      # 待换的姿势 @{name;frames}
$script:swapLeft = 0          # 换图倒计时
$script:sleepPending = 0      # 待睡（先下蹲再睡）

# ★★ 表情切换：先眨眼遮住再换脸（整张换脸不遮会很突兀）
$script:emoShown    = 'base'   # 当前实际显示的表情名
$script:emoMask     = 0        # 眨眼遮罩剩余帧
$script:emoPending  = ''       # 遮罩结束后要显示的表情
$script:emoTrans    = 0        # 过渡表情剩余帧
$script:emoTransName = ''      # 过渡表情名（如 含泪笑）
$script:emoNextAt   = 0        # 下次允许遮罩的 tick（冷却）
$script:emoTransMap = @{}
try {
    $m = Cfg '表情.过渡表情' $null
    if ($m) {
        if ($m -is [System.Collections.IDictionary]) { foreach ($k in $m.Keys) { $script:emoTransMap[[string]$k] = [string]$m[$k] } }
        else { foreach ($pp in $m.PSObject.Properties) { $script:emoTransMap[[string]$pp.Name] = [string]$pp.Value } }
    }
} catch { $script:emoTransMap = @{} }
$script:sleepWait  = 0
$script:sitIdle   = 0         # 待机坐倒计时
$script:peekNext  = 0         # 下次张望时刻
$script:facing    = 1         # 朝向：1=默认，-1=镜像
$script:turnT     = 0         # 转身动画剩余帧

# 头部精灵（吃痛时低头/捂头用）
$script:headX = 0.1910; $script:headY = 0.3089; $script:headW = 0.6285; $script:headH = 0.3194
$script:headSprite = $null
$script:headAng = 0.0

# 随机小动作
$script:idleCount = 0
$script:idleNext  = Get-Random -Minimum (CfgFrames '行为.duang最短秒数' 22) -Maximum (CfgFrames '行为.duang最长秒数' 50)

# ============================================================
#  4.5 眨眼
# ============================================================
# 吃痛：撞到东西时的统一反应（窗口碰撞和屏幕边缘都调它）
function Invoke-Hurt {
    param([string]$Who = '', [string]$Source = 'fall')

    $script:hurtSrc = $Source
    $null = Set-Emotion 'hurt' -Force
    $script:poseTmp = $null
    # ★ 撞到东西先"站起来"：清掉滚动/蹦跳状态
    #   不然她会维持"团成球"的滚动姿势贴着窗口哭，看起来像卡住/穿模 ✗
    $script:rollHold   = 0
    $script:rollActive = $false
    $script:rollAngle  = 0.0
    if ($script:hopActive) { $script:hopActive = $false; $script:hopFlip = 0.0; $script:hopSettle = 0 }
    $script:hurt  = CfgFrames '互动.吃痛持续秒数' 2
    $script:tears = 0.0
    $script:sqV   = -0.60
    $script:earV += 2.6
    $script:quiet = [int]([double](Cfg '行为.动作后安静秒数' 5) * 1000.0 / [double]$script:timer.Interval)

    # 往后退（用撞上那一刻的速度方向）
    $script:recoilX = [Math]::Max(-6.0, [Math]::Min(6.0, -$script:vx * 3.2))
    $script:recoilY = [Math]::Max(-6.0, [Math]::Min(6.0, -$script:vy * 3.2))
    $script:tvx = -$script:tvx;  $script:tvy = -$script:tvy
    $script:vx  = -$script:vx * 0.5; $script:vy = -$script:vy * 0.5

    # ★ 按来源选台词：撞窗口/撞屏幕说「撞」类，被甩飞/摔下才说「摔」类
    try {
        if ($Source -eq 'bump') {
            $pl = Get-PoolLine 'collision.bump'
            if ($pl) { Say-Something 0 @($pl) 60 } else { Say-Something 0 $script:hurtLines 60 }
        } else {
            $pl = Get-PoolLine 'expr.sad'
            if ($pl) { Say-Something 0 @($pl) 60 } else { Say-Something 0 $script:hurtLines 60 }
        }
    } catch { Log-Err $_ 'hurt' }
}

# 眨眼：$cover 0=全睁、1=全闭（在"图片坐标系"里画，调用方负责定位）
function Draw-Blink {
    param($g, [double]$cover, [double]$iw, [double]$ih, [bool]$mirror)
    # ★ 停用：改用 闭眼 sprite
    return



    if ($cover -le 0.01) { return }
    if ($cover -gt 1.0) { $cover = 1.0 }

    foreach ($e in @($script:eyeL, $script:eyeR)) {
        $x1 = $e[0] + $script:eyeInset
        $x2 = $e[2] - $script:eyeInset
        $y1 = $e[1] + $script:eyeInset
        $y2 = $e[3] - $script:eyeInset

        if ($mirror) { $t = $x1; $x1 = 1.0 - $x2; $x2 = 1.0 - $t }

        $ex = $x1 * $iw
        $ey = $y1 * $ih
        $ew = ($x2 - $x1) * $iw
        $eh = ($y2 - $y1) * $ih

        # 眼睑从上往下盖
        # ★ 遮盖进度稍微提前满（cover≈0.74 就到底）——
        #   三角波的顶点一闪而过，$cover 很少真的到 1.0，不提前就会留缝 ✗
        $coverF = [Math]::Min(1.0, $cover * 1.35)
        $ch = $eh * $coverF

        # ★ 裁剪圈要比"眼睛框"放大一圈 —— 尤其是【往下】。
        #   精灵图上她的眼睛比这个框更高，不放大就会在眼睛最底下
        #   露出一条没盖住的蓝月牙（定格全闭时看得很清楚）✗
        $padX = $ew * 0.06
        $padY = $eh * 0.18
        $ex2 = $ex - $padX;  $ey2 = $ey - $padY
        $ew2 = $ew + $padX * 2
        $eh2 = $eh + $padY * 2

        # ★ 整段（肤色 + 眼睑线）都裁进这个放大的椭圆。
        #   以前只裁了肤色，眼睑线没裁 → 弧的两端伸到眼睛外面上方，
        #   正好压在她上眼睑/眉骨那一带 → 看起来像"眉毛跟着眼皮一起掉下来" ✗
        $st = $g.Save()
        $clip = New-Object System.Drawing.Drawing2D.GraphicsPath
        $clip.AddEllipse([single]$ex2, [single]$ey2, [single]$ew2, [single]$eh2)
        $g.SetClip($clip)

        # 填充高度要够到放大圈的最底下（$padY*2），否则放大后底部又留一条 ✗
        $g.FillRectangle($script:skinBrush,
            [single]$ex2, [single]$ey2, [single]$ew2, [single]($ch + $padY * 2))

        # ★ 闭眼线【必须正好压在肤色填充的下沿上】——
        #   以前它比填充高了一段，于是填充的下边界没人盖，
        #   放大 6 倍就能看到一条明显的"补丁边界"横在脸上 ✗
        $ly = $ey + $ch

        # ★ 闭眼线：照着素材图的样子画 —— 一条【扁平的上凸弧，两端微下垂】，
        #   而不是简单的半圆（半圆看着像在笑，不像闭眼）✗
        $lidP = if ($script:eyeLidPen) { $script:eyeLidPen } else { $script:lidPen }
        $b1 = New-Object System.Drawing.PointF(([single]$ex),              ([single]($ly - $eh * 0.02)))
        $b2 = New-Object System.Drawing.PointF(([single]($ex + $ew * 0.33)), ([single]($ly - $eh * 0.22)))
        $b3 = New-Object System.Drawing.PointF(([single]($ex + $ew * 0.67)), ([single]($ly - $eh * 0.22)))
        $b4 = New-Object System.Drawing.PointF(([single]($ex + $ew)),       ([single]($ly - $eh * 0.02)))
        $g.DrawBezier($lidP, $b1, $b2, $b3, $b4)

        # 外侧几根小睫毛（素材图上就有）—— 只有闭到一定程度才画
        if ($coverF -gt 0.55) {
            $lashA = 1.0 - [Math]::Abs($coverF - 0.85) / 0.30
            if ($lashA -gt 0.0) {
                $lx0 = $ex + $ew * 0.86
                $ly0 = $ly - $eh * 0.10
                $g.DrawLine($lidP,
                    [single]$lx0, [single]$ly0,
                    [single]($lx0 + $ew * 0.10), [single]($ly0 - $eh * 0.10))
                $g.DrawLine($lidP,
                    [single]$lx0, [single]($ly0 + $eh * 0.03),
                    [single]($lx0 + $ew * 0.09), [single]($ly0 - $eh * 0.01))
            }
        }

        $g.Restore($st)
        $clip.Dispose()
    }
}

# 耳朵摆动（同样在"图片坐标系"里画）
function Draw-Ears {
    param($g, [double]$ang, [double]$iw, [double]$ih, [bool]$mirror)
    # ★ 停用：旧坐标
    return



    if (-not $script:earL -or -not $script:earR) { return }
    # 两只耳朵都几乎没动时不重画：本体上的耳朵本来就在，画一遍反而会重采样
    if ([Math]::Abs($ang) -lt 0.35 -and [Math]::Abs($script:earPh) -lt 0.35) { return }

    $sgn = if ($mirror) { -1.0 } else { 1.0 }

    $k = 0
    foreach ($p in @(
            @($script:earBoxL, $script:earPivotL, $script:earL),
            @($script:earBoxR, $script:earPivotR, $script:earR))) {

        # 左右耳给一点相位差 → 不同步，更生动
        $angE = if ($k -eq 0) { $ang + $script:earPh } else { $ang - $script:earPh }
        $k++
        $box = $p[0]; $pv = [double]$p[1]; $spr = $p[2]
        # 取整 → 不动时是精确复制
        $bw = [Math]::Round($box[2] * $iw)
        $bh = [Math]::Round($box[3] * $ih)
        $bx = [Math]::Round($box[0] * $iw)
        $by = [Math]::Round($box[1] * $ih)
        if ($mirror) { $bx = [Math]::Round($iw - $bx - $bw); $pv = 1.0 - $pv }

        $px = [Math]::Round($bx + $bw * $pv)
        $py = [Math]::Round($by + $bh * $script:earPivotY)

        $st = $g.Save()
        $g.TranslateTransform([single]$px, [single]$py)
        $g.RotateTransform([single]($angE * $sgn))
        $g.TranslateTransform([single](-$bw * $pv), [single](-$bh * $script:earPivotY))
        $g.DrawImage($spr, [single]$bx, [single]$by, [single]$bw, [single]$bh)
        $g.Restore($st)
    }
}

# 头部（吃痛时低头）—— 角度接近 0 就不画，保持像素级
function Draw-Head {
    param($g, [double]$ang, [double]$iw, [double]$ih, [bool]$mirror)
    if (-not $script:headSprite) { return }
    if ([Math]::Abs($ang) -lt 0.35) { return }

    $bw = [Math]::Round($iw * $script:headW)
    $bh = [Math]::Round($ih * $script:headH)
    $bx = [Math]::Round($iw * $script:headX)
    $by = [Math]::Round($ih * $script:headY)
    if ($mirror) { $bx = [Math]::Round($iw - $bx - $bw) }

    $px = $bx + $bw / 2.0
    $py = $by + $bh

    $st = $g.Save()
    $g.TranslateTransform([single]$px, [single]$py)
    $g.RotateTransform([single]$ang)
    $g.TranslateTransform([single](-$bw / 2.0), [single](-$bh))
    $g.DrawImage($script:headSprite, [single]$bx, [single]$by, [single]$bw, [single]$bh)
    $g.Restore($st)
}

# 眼泪
function Draw-Tears {
    param($g, [double]$amt, [double]$iw, [double]$ih, [bool]$mirror)
    # ★ 停用：AI sprite 自带眼泪
    return


        if ($amt -le 0.02) { return }
    foreach ($e in @($script:eyeL, $script:eyeR)) {
        $cxE = ($e[0] + $e[2]) / 2.0
        if ($mirror) { $cxE = 1.0 - $cxE }
        $x = $cxE * $iw
        $y = ($e[3] - 0.01) * $ih + $amt * $ih * 0.085
        $r = 3.0 + $amt * 3.5
        $g.FillEllipse($script:tearBrush, [single]($x - $r / 2), [single]$y, [single]$r, [single]($r * 1.6))
        $g.FillEllipse($script:tearHi,    [single]($x - $r / 4), [single]($y + $r * 0.3), [single]($r * 0.34), [single]($r * 0.5))
    }
}

# 表情（嘴 + 腮红）—— 同样在"图片坐标系"里画
# 表情贴片（AI 画的脸）—— 按状态盖在她脸上
# 返回 $true 表示"这次用了贴片"，调用方就不再画代码那些表情了
function Draw-FacePlate {
    param($g, [double]$iw, [double]$ih, [bool]$mirror, [double]$cover)

    # ★ 贴脸方案【已停用】
    #   原因：AI 画的脸和原画法不同（线条/阴影/肤色），
    #        不管蒙版怎么羽化，边界都看得出来 —— "一看就是贴上去的" ✗
    #   正解：直接用【整张 AI 全身图】当 sprite 切换，不做任何叠加 ✓
    #       （见 assets\sprites\，等 5 张全身表情图齐了再接线）
    return $false

    if (-not $script:facePlates -or $script:facePlates.Count -eq 0) { return $false }

    $name = $null; $alpha = 0.0
    if     ($script:hurt -gt 0)        { $name = '伤心'; $alpha = 1.0 }
    elseif ($script:angry -gt 0)       { $name = '生气'; $alpha = 1.0 }
    elseif ($script:surprise -gt 0.15) { $name = '惊讶'; $alpha = 1.0 }
    elseif ($script:mood -gt 0)        { $name = '开心'; $alpha = 1.0 }
    elseif ($cover -gt 0.06)           { $name = '闭眼'; $alpha = [Math]::Min(1.0, $cover * 1.4) }

    if (-not $name) { return $false }
    $plate = $script:facePlates[$name]
    if (-not $plate) { return $false }

    # 贴片位置：144x93 贴在 pet.png 的 (74,135) 处（288x382 坐标系）
    $px  = $iw * (74.0 / 288.0)
    $py  = $ih * (135.0 / 382.0)
    $pw2 = $iw * (144.0 / 288.0)
    $ph2 = $ih * (93.0 / 382.0)
    if ($mirror) { $px = $iw - $px - $pw2 }

    try {
        if ($alpha -lt 0.999) {
            $cm = New-Object System.Drawing.Imaging.ColorMatrix
            $cm.Matrix33 = [single]$alpha
            $ia = New-Object System.Drawing.Imaging.ImageAttributes
            $ia.SetColorMatrix($cm)
            $dstRect = New-Object System.Drawing.Rectangle ([int]$px), ([int]$py), ([int]$pw2), ([int]$ph2)
            $g.DrawImage($plate, $dstRect, 0, 0, $plate.Width, $plate.Height,
                [System.Drawing.GraphicsUnit]::Pixel, $ia)
            $ia.Dispose()
        } else {
            $g.DrawImage($plate, [single]$px, [single]$py, [single]$pw2, [single]$ph2)
        }
        return $true
    } catch {
        return $false
    }
}

function Draw-Face {
    param($g, [double]$iw, [double]$ih, [bool]$mirror)
    # ★ 停用：AI sprite 自带腮红/嘴
    return


    
    $mx = 0.500 * $iw
    $my = 0.552 * $ih          # 嘴的高度
    $by2 = 0.512 * $ih         # 腮红：脸颊上（比嘴高一点）
    if ($mirror) { $mx = $iw - $mx }

    # 腮红：开心 / 生气 / 害羞时泛红
    #   ★ 以前是纯色实心椭圆（又扁又硬，像贴了两条粉色胶带 ✗）
    #     现在改成径向渐变：中心浓、边缘透明 → 柔和的腮红 ✓
    if ($script:mood -gt 0 -or $script:angry -gt 0 -or $script:shy -gt 0) {
        $a = if ($script:angry -gt 0) { 180 } elseif ($script:shy -gt 0) { 165 } else { 145 }
        foreach ($cxo in @(0.300, 0.700)) {
            $bx = $cxo * $iw
            if ($mirror) { $bx = $iw - $bx }
            $bw2 = [single]($iw * 0.082)
            $bh2 = [single]($ih * 0.046)
            $brx = [single]($bx - $bw2 / 2.0)
            $bry = [single]($by2 - $bh2 / 2.0)
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $path.AddEllipse($brx, $bry, $bw2, $bh2)
            $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
            $pgb.CenterPoint = New-Object System.Drawing.PointF([single]$bx, [single]$by2)
            $pgb.CenterColor = [System.Drawing.Color]::FromArgb($a, 255, 128, 152)
            $pgb.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 255, 128, 152))
            $g.FillPath($pgb, $path)
            $pgb.Dispose()
            $path.Dispose()
        }
    }

    if ($script:hurt -gt 0) {
        # 哭：★ 专属表情 —— 眼角泪痕 + 张开的小嘴
        #   （以前只有一个圆嘴、眼睛还睁得大大的，看着像"惊讶"不像哭 ✗）
        #   另一半在 Render-Frame 里：哭的时候眼睑压到 0.55，眼睛是眯着的 ✓
        #   注：她刘海盖住额头，所以【画不了眉毛】—— 会画到头发上 ✗
        # ★ 泪痕取消了：竖着的泪条和原画风格不搭，显得像"画上去的" ✗
        #   现在眼泪只靠粒子（Spawn-Tears）表现 ✓ 更自然
        # 嘴：张开的小嘴
        $g.FillEllipse($script:bubbleText,
            [single]($mx - $iw * 0.022), [single]($my - $ih * 0.008),
            [single]($iw * 0.044), [single]($ih * 0.030))
    }
    elseif ($script:angry -gt 0) {
        # 生气：嘴角向下
        $g.DrawArc($script:lidPen,
            [single]($mx - $iw * 0.038), [single]($my - $ih * 0.002),
            [single]($iw * 0.076), [single]($ih * 0.030), 180, 180)
    }
    elseif ($script:mood -gt 0) {
        # 开心：嘴角向上
        $g.DrawArc($script:lidPen,
            [single]($mx - $iw * 0.040), [single]($my - $ih * 0.012),
            [single]($iw * 0.080), [single]($ih * 0.034), 0, 180)
    }
    elseif ($script:surprise -gt 0) {
        # 惊讶：小圆嘴
        $g.FillEllipse($script:bubbleText,
            [single]($mx - $iw * 0.016), [single]($my - $ih * 0.006),
            [single]($iw * 0.032), [single]($ih * 0.024))
    }
    elseif ($script:shy -gt 0) {
        # 害羞：小小的抿嘴
        $g.DrawLine($script:lidPen,
            [single]($mx - $iw * 0.017), [single]$my,
            [single]($mx + $iw * 0.017), [single]$my)
    }
}

# 小爱心（开心时往上飘）
function Draw-Heart {
    param($g, [double]$x, [double]$y, [double]$r)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddBezier([single]$x, [single]($y + $r * 0.95),
                 [single]($x - $r * 1.7), [single]($y - $r * 0.55),
                 [single]($x - $r * 0.65), [single]($y - $r * 1.55),
                 [single]$x, [single]($y - $r * 0.45))
    $p.AddBezier([single]$x, [single]($y - $r * 0.45),
                 [single]($x + $r * 0.65), [single]($y - $r * 1.55),
                 [single]($x + $r * 1.7), [single]($y - $r * 0.55),
                 [single]$x, [single]($y + $r * 0.95))
    $p.CloseFigure()
    $g.FillPath($script:heartBrush, $p)
    $p.Dispose()
}

# 怒气符（十字）
function Draw-AngerMark {    param($g, [double]$cx, [double]$cy, [double]$s)
    if ($s -le 0.5) { return }
    $g.DrawLine($script:angerPen, [single]($cx - $s), [single]($cy - $s), [single]($cx + $s), [single]($cy + $s))
    $g.DrawLine($script:angerPen, [single]($cx + $s), [single]($cy - $s), [single]($cx - $s), [single]($cy + $s))
    $g.DrawLine($script:angerPen, [single]($cx - $s), [single]($cy - $s * 0.72), [single]($cx - $s * 0.72), [single]($cy - $s))
    $g.DrawLine($script:angerPen, [single]($cx + $s * 0.72), [single]($cy + $s), [single]($cx + $s), [single]($cy + $s * 0.72))
}

# 惊讶的"!"（被摸到时冒出来）
function Draw-Surprise {
    param($g, [double]$cx, [double]$cy, [double]$amt)
    if ($amt -le 0.02) { return }
    $a = [int](255 * [Math]::Min(1.0, $amt))
    $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, 238, 88, 112))
    $sz = 4.5 + $amt * 3.0
    $g.FillEllipse($br, [single]($cx - $sz / 2), [single]($cy - $sz * 2.4), [single]$sz, [single]($sz * 1.9))
    $g.FillEllipse($br, [single]($cx - $sz / 2), [single]($cy - $sz * 0.1), [single]$sz, [single]$sz)
    $br.Dispose()
}

# ============================================================
#  5. 渲染一帧
# ============================================================
# ★ 按 alpha 画图（过渡用）
function Draw-ImageAlpha {
    param($g, $img, [int]$x, [int]$y, [double]$alpha)
    if (-not $img -or $alpha -le 0.01) { return }
    try {
        $ia = New-Object System.Drawing.Imaging.ImageAttributes
        $cm = New-Object System.Drawing.Imaging.ColorMatrix
        $cm.Matrix33 = [single][Math]::Min(1.0, [Math]::Max(0.0, $alpha))
        $ia.SetColorMatrix($cm)
        $rect = New-Object System.Drawing.Rectangle($x, $y, $img.Width, $img.Height)
        $g.DrawImage($img, $rect, 0, 0, $img.Width, $img.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $ia.Dispose()
    } catch {}
}

# ★ 姿势切换走"过渡动作"：先下蹲 → 换图 → 回弹（人眼盯运动，看不见换图）
# ---------- 动作序列器（一个动作 = 多帧序列）----------
$script:seq      = $null
$script:seqIdx   = 0
$script:seqNext  = 0
$script:dragLean = 0.0
$script:dragLastX = 0
$script:faceStable  = 0       # 同向连续帧数
$script:bounceFlag  = 0       # 撞墙标记
$script:gaitBob    = 0        # 走路起伏像素
$script:hoverCount = 0.0      # 悬停摸了几次（够数才害羞）
$script:faceLastDir = 0       # 上帧的期望朝向
$script:faceCool    = 0       # 转身冷却
$script:facingPending = 0     # 待转朝向（鼠标等外部请求）

function Start-PoseSeq {
    param([object[]]$Steps)
    if (-not $Steps -or $Steps.Count -eq 0) { return }
    $script:seq     = @($Steps)
    $script:seqIdx  = 0
    $script:seqNext = $script:tick
}

function Update-PoseSeq {
    if (-not $script:seq) { return }
    if ($script:tick -lt $script:seqNext) { return }
    if ($script:seqIdx -ge $script:seq.Count) { $script:seq = $null; return }
    $step = $script:seq[$script:seqIdx]
    $script:seqIdx++
    $ms = [int]$step.ms
    $frames = [Math]::Max(24, [int]($ms * 1000.0 / 1000.0 / [double]$script:timer.Interval))
    if ($frames -gt 900) { $frames = 900 }
    if ($step.name) {
        $script:poseTmp = @{ name = [string]$step.name; frames = $frames; total = $frames }
    }
    if ($step.say) {
        try { Say-Something 0 @([string]$step.say) ([int]($(if ($step.prio) { $step.prio } else { 20 }))) } catch {}
    }
    $script:seqNext = $script:tick + $frames
}

# ---------- 状态守卫：优先级 hurt > angry > sleep > 动作 ----------
function Test-ActionAllowed {
    if ($script:hurt -gt 0)  { return $false }
    if ($script:angry -gt 0) { return $false }
    if ($script:sleep -gt 0) { return $false }
    return $true
}

function Queue-PoseSwap {
    param([string]$Name, [int]$Frames = 0, [string]$Via = '')
    # ★ 状态守卫：吃痛/生气/睡觉时不换姿势（别打架）
    if (-not (Test-ActionAllowed)) { return }
    # ★ 最短时长：当前姿势还在前 1/3，不许打断（防"动作连播抽筋"）
    if ($script:poseTmp -and $script:poseTmp.total -gt 0) {
        $elapsed = $script:poseTmp.total - $script:poseTmp.frames
        if ($elapsed -lt [Math]::Min(20, [int]($script:poseTmp.total / 3))) { return }
    }
    $script:swapTo      = @{ name = $Name; frames = $Frames; via = $Via }
    $script:swapLeft    = 5            # 先压 5 帧（≈80ms）
    $script:swapViaUsed = $false
    $script:sqV         = -0.22        # 下蹲
    $script:earV       += 0.5
}

function Render-Frame {
    $g = [System.Drawing.Graphics]::FromImage($script:canvas)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    # 关键：角色是 1:1 整数直贴，用 NearestNeighbor 才是像素级精确
    # （原来用 Bilinear + 每帧旋转/缩放，等于每帧都把她糊一遍）
    $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::AssumeLinear

    $t = [double]$script:tick

    # ---- 有机运动：三个不同周期叠加，避免机械的循环感 ----
    $o1 = [math]::Sin($t / 9.7)        * 0.55 +
          [math]::Sin($t / 3.3 + 1.7)  * 0.30 +
          [math]::Sin($t / 23.0 + 0.9) * 0.15

    $o2 = [math]::Sin($t / 11.3 + 2.4) * 0.50 +
          [math]::Sin($t / 4.1 + 0.3)  * 0.32 +
          [math]::Sin($t / 19.0 + 3.1) * 0.18

    $o3 = [math]::Sin($t / 7.9 + 4.2)  * 0.60 +
          [math]::Sin($t / 3.7 + 2.0)  * 0.25 +
          [math]::Sin($t / 27.0)       * 0.15

    # 上下浮动（像素）。★ 默认 0 = 待机时完全不动 ★
    #   以前写死 $o1 * 6.5，她会一直上下漂 ±6.5px —— 看着像"被绳子吊着"，
    #   而且静止的画面本来就已经像素级清晰，一漂就模糊 ✗
    #   想让她重新飘起来，把 config 里 行为.待机浮动像素 改成 6.5 就行 ✓
    $bobAmp = [double](Cfg '行为.待机浮动像素' 0)
    $bob = $o1 * $bobAmp

    # 呼吸：纵向多、横向少 → 有体积感，不是整体缩放
    $pulseY = 1.0 + $o3 * 0.020
    $pulseX = 1.0 - $o3 * 0.011

    # 摇曳：和浮动错开相位，像身体被带着走
    $swayDeg = $o2 * 3.0

    # 朝移动方向微微倾斜
    $lean = [math]::Max(-4.5, [math]::Min(4.5, $script:vx * 1.6))

    # 跳跃：干净的弹跳曲线 + 挤压回弹
    $jump = 0.0
    if ($script:happy -gt 0) {
        $prog   = 1.0 - ($script:happy / [double]$script:hopLen)
        $jump   = [math]::Sin($prog * [math]::PI) * 19.0
        $sq     = 1.0 + [math]::Sin($prog * [math]::PI * 2.0) * 0.07
        $pulseY = $pulseY * $sq
        $pulseX = $pulseX / $sq
    }
    # v2：大跳的抬升
    if ($script:hopJump -gt 0.01) { $jump += $script:hopJump }

    # 极轻微的高频微颤：破除"太丝滑"的假感
    #   ★ 但只有开了浮动才有意义 —— 待机完全不动时它会让画面一直在 1px 级别抖，
    #     导致"静止时像素级 1:1 直贴"失效 ✗
    $jitA = [math]::Sin($t * 0.62) * 0.30
    $jitY = 0.0
    if ($bobAmp -gt 0) { $jitY = [math]::Sin($t * 0.85 + 1.1) * 0.45 }

    # 吃痛 / 生气时会抖
    $shakeX = 0.0
    if ($script:hurt -gt 0)      { $shakeX = [math]::Sin($t * 2.7) * 2.4 }
    elseif ($script:angry -gt 0) { $shakeX = [math]::Sin($t * 3.1) * 1.7 }

    # 左右耳相位差（慢慢晃，让两只耳朵不同步）
    $script:earPh = [math]::Sin($t * 0.19) * 2.6

    $angle = $swayDeg + $lean + $jitA

    $cx = $script:cw / 2.0 + $shakeX
    $cy = $script:ch / 2.0 - 14.0 + $bob - $jump + $jitY

    # ---------- 手绘小鱼模式 ----------
    if (-not $script:petImage) {
        $sway = [math]::Sin($t / 5.0) * 9
        # 影子
        $i = 0
        foreach ($br in $script:shadowBrushes) {
            $g.FillEllipse($br, ($cx - 34 - $i), ($cy + 46 - $i), (68 + $i * 2), (16 + $i))
            $i++
        }
        $tail = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new(($cx - 22), $cy),
            [System.Drawing.PointF]::new(($cx - 54), ($cy - 17 + $sway)),
            [System.Drawing.PointF]::new(($cx - 54), ($cy + 17 + $sway))
        )
        $g.FillPolygon($script:brushFin, $tail)
        $fin = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new(($cx - 8),  ($cy - 18)),
            [System.Drawing.PointF]::new(($cx + 6),  ($cy - 42)),
            [System.Drawing.PointF]::new(($cx + 18), ($cy - 15))
        )
        $g.FillPolygon($script:brushFin, $fin)
        $fin2 = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new(($cx - 4),  ($cy + 16)),
            [System.Drawing.PointF]::new(($cx + 4),  ($cy + 32)),
            [System.Drawing.PointF]::new(($cx + 16), ($cy + 14))
        )
        $g.FillPolygon($script:brushFin, $fin2)
        $g.FillEllipse($script:brushBody, ($cx - 28), ($cy - 22), 58, 44)
        $g.FillEllipse($script:brushBlush, ($cx - 16), ($cy + 4), 13, 8)
        $g.FillEllipse($script:brushEyeW, ($cx + 4),  ($cy - 11), 15, 15)
        $g.FillEllipse($script:brushEyeW, ($cx + 18), ($cy - 11), 15, 15)
        $g.FillEllipse($script:brushDark, ($cx + 8),  ($cy - 7), 7, 7)
        $g.FillEllipse($script:brushDark, ($cx + 22), ($cy - 7), 7, 7)
        $g.DrawArc($script:penDark, ($cx + 8), ($cy + 2), 14, 9, 0, 180)
    }
    else {
        # ---------- 图片模式 ----------
        $iw = $script:imgW
        $ih = $script:imgH

        # Q弹形变：sq>0 拉长、sq<0 压扁；横向取倒数 → 体积守恒，像果冻
        $sy = 1.0 + $script:sq
        $sx = 1.0 / $sy
        # v2：转身时横向压扁
        if ($script:turnSx -lt 0.999) { $sx = $sx * $script:turnSx }
        # 倾斜：只有真的在走才给（走得慢/站住 → 完全竖直，不再"歪着站着"）
        $leanA = 0.0
        if ([Math]::Abs($script:vx) -gt 0.20) {
            $leanA = [Math]::Max(-4.0, [Math]::Min(4.0, $script:vx * 1.5))
        }
        # ★ 拎着她的时候像钟摆一样轻微摆动
        if ($script:dragging) {
            # ★ 拖拽摆动：按水平速度算倾斜（钟摆感）
            try {
                $mcx = [System.Windows.Forms.Cursor]::Position.X
                $dxm = $mcx - $script:dragLastX
                $script:dragLastX = $mcx
                $script:dragLean = $script:dragLean * 0.7 + ($dxm * 0.55) * 0.3
            } catch {}
            $leanA = [Math]::Max(-9.0, [Math]::Min(9.0, $script:dragLean))
        }
        else {
            $script:dragLean *= 0.90
        }

        # 阴影：随离地高度缩小变淡、随形变压扁、随倾斜偏移
        #   ★ 再补上"移动时"的变化：影子往运动反方向拖一点 + 沿运动方向轻微拉长，
        #     不然滑行时地上的影子一动不动，"像贴纸不像生物" ✗
        $shrink  = 1.0 - [math]::Min(0.55, $jump / 30.0)
        $feetY   = $cy + ($ih * 0.5 * $sy) - 4.0
        $shDrag    = [Math]::Max(-7.0, [Math]::Min(7.0, -$script:vx * 2.2))
        # ★ 滚动时影子跟着球变（宽度=球直径，位置=球底）
        $rollShadow = ($script:rollActive -and $script:rollShadowW -gt 0)
        if ($rollShadow) {
            $feetY = $script:rollShadowY
            $shW = $script:rollShadowW
            $shH = 14.0
        }
        $shStretch = 1.0 + [Math]::Min(0.16, [Math]::Abs($script:vx) * 0.022)
        $shW     = $iw * 0.54 * $sx * $shrink * $shStretch
        $shH     = 15.0 * $shrink * $sy
        $shShift = -$leanA * 1.6 + $shDrag
        $layers  = [int]($script:shadowBrushes.Count * (0.40 + 0.60 * $shrink))
        if ($layers -lt 2) { $layers = 2 }

        for ($i = 0; $i -lt $layers; $i++) {
            $br  = $script:shadowBrushes[$i]
            $pad = [double]$i
            $g.FillEllipse($br,
                ($cx - $shW / 2.0 - $pad + $shShift),
                ($feetY - $shH / 2.0 - $pad / 2.0),
                ($shW + $pad * 2.0),
                ($shH + $pad))
        }

        # v2：朝向由 $script:facing 决定（带迟滞 + 转身动画）
        $faceOn = [bool](Cfg '行为.朝向翻转' $true)
        $useMirror = [bool]($faceOn -and ($script:facing -lt 0) -and $script:petImageFlip)
        if (-not $faceOn) {
            $useMirror = [bool]($script:vx -lt -0.18 -and $script:petImageFlip)
        }
        $useImg = if ($useMirror) { $script:petImageFlip } else { $script:petImage }

        # ★ 表情【整张 sprite 换】—— 不做贴脸（画法不同，怎么羽化都有接缝 ✗）
        #   只在"长状态"换：开心 / 生气；眨眼太快，换整张会跳，继续用代码画 ✓
        #   伤心 / 惊讶 还没有整张素材 → 回退到代码画 ✓
        # ★ AI 整张 sprite 切换（已取消表情锁定，先用最简单的版本）
        $exprName = $null
        # ★ 优先级：睡 > 吃痛 > 生气 > 姿势图 > 惊讶 > 开心 > 闭眼
        #   （原来姿势图排在建前面 → 坐着生气还是"平静脸"，和怒气符打架 ✗）
        if     ($script:poseTmp -and $script:poseTmp.name -in @('pose_躺下','pose_起身','pose_蹲下')) { $exprName = $script:poseTmp.name }
        elseif ($script:sleep -gt 0 -and $script:hurt -le 0) { $exprName = 'pose_睡' }
        elseif ($script:hurt  -gt 0)        { $exprName = '伤心' }
        elseif ($script:angry -gt 0)        { $exprName = '生气' }
        elseif ($script:poseTmp -and $script:poseTmp.frames -gt 0) { $exprName = $script:poseTmp.name }
        elseif ($script:rollHold -gt 0 -and $script:exprSprites -and $script:exprSprites.ContainsKey('pose_团')) { $exprName = 'pose_团' }
        elseif ($script:autoWalk -and -not $script:hopActive -and -not $script:dragging -and -not $script:physActive -and ([Math]::Abs($script:vx) -gt 0.35) -and [bool](Cfg '行为.走路用姿势帧' $false)) {
            # ★ 走路步态：4 拍循环（走1/走2 各占两拍，第二拍带起落）→ 比 2 拍交替自然
            $gaitMs = [double](Cfg '行为.走路步频毫秒' 260)
            $gaitFrames = [Math]::Max(6, [int]($gaitMs / [double]$script:timer.Interval))
            $gaitPhase = [int]($script:tick / $gaitFrames) % 4
            if ($gaitPhase -eq 0 -or $gaitPhase -eq 1) { $exprName = 'pose_走1' } else { $exprName = 'pose_走2' }
            # 起伏：每两拍轻微上浮 1~2px（奇数拍抬起）
            if ($gaitPhase % 2 -eq 1) { $script:gaitBob = 1 } else { $script:gaitBob = 0 }
        }
        elseif ($script:autoWalk -and -not $script:hopActive -and -not $script:dragging -and -not $script:physActive -and ([Math]::Abs($script:vx) -gt 0.35)) {
            # ★ 默认走法：不换图，只做"小碎步起伏"（干净、不丑）
            $stepMs = [double](Cfg '行为.走路步频毫秒' 300)
            $stepFrames = [Math]::Max(8, [int]($stepMs / [double]$script:timer.Interval))
            if (([int]($script:tick / $stepFrames)) % 2 -eq 1) { $script:gaitBob = 1 } else { $script:gaitBob = 0 }
        }
        elseif ($script:surprise -gt 0.15)  { $exprName = '惊讶' }
        elseif ($script:mood  -gt 0)        { $exprName = '开心' }
        elseif ($cover -gt 0.5)             { $exprName = '闭眼' }

        # ★★ 表情切换状态机：遮罩（眨眼）→ 过渡表情（可选）→ 目标表情
        $faceSet = @('开心','生气','伤心','惊讶')
        if ($script:emoMask -gt 0) {
            $script:emoMask--
            $exprName = '闭眼'
            if ($script:emoMask -le 0) {
                if ($script:emoTransName -and $script:exprSprites -and $script:exprSprites.ContainsKey($script:emoTransName)) {
                    $script:emoTrans = [Math]::Max(3, [int]([double](Cfg '表情.过渡表情毫秒' 300) / [double]$script:timer.Interval))
                } else {
                    $script:emoShown = $script:emoPending
                    $script:emoPending = ''
                    $script:emoTransName = ''
                }
            }
        }
        elseif ($script:emoTrans -gt 0) {
            $script:emoTrans--
            $exprName = $script:emoTransName
            if ($script:emoTrans -le 0) {
                $script:emoShown = $script:emoPending
                $script:emoPending = ''
                $script:emoTransName = ''
            }
        }
        elseif ($exprName -and $exprName -ne $script:emoShown) {
            $prevEmo = [string]$script:emoShown
            if (($faceSet -contains $exprName) -and ($faceSet -contains $prevEmo) -and ($script:tick -ge $script:emoNextAt)) {
                $script:emoPending = $exprName
                $script:emoMask = [Math]::Max(3, [int]([double](Cfg '表情.眨眼遮罩毫秒' 110) / [double]$script:timer.Interval))
                $pair = $prevEmo + '>' + $exprName
                $script:emoTransName = ''
                if ($script:emoTransMap -and $script:emoTransMap.ContainsKey($pair)) { $script:emoTransName = [string]$script:emoTransMap[$pair] }
                $script:emoNextAt = $script:tick + [int](CfgFrames '表情.切换冷却秒数' 0.4)
                $script:emoShown = $exprName
            } else {
                $script:emoShown = $exprName
            }
        }
        $useArt = $true
        if ($exprName -and $script:exprSprites) {
            $ekey = if ($useMirror) { $exprName + '_flip' } else { $exprName }
            # ★ 兜底：新姿势图没准备好 → 退回闭眼
            if (-not $script:exprSprites.ContainsKey($ekey) -and $exprName -notin @('开心','生气','伤心','惊讶','闭眼')) {
                $exprName = '闭眼'
                $ekey = if ($useMirror) { '闭眼_flip' } else { '闭眼' }
            }
            if ($script:exprSprites.ContainsKey($ekey)) {
                $useImg = $script:exprSprites[$ekey]
                $useArt = $false
            }
        }

        # 眼睑遮盖比例（0=全睁，1=全闭）：闭 → 睁 的三角波
        $cover = 0.0
        if ($script:blink -gt 0) {
            $p = 1.0 - ($script:blink / [double]$script:blinkLen)
            if ($p -le 0.45) { $cover = $p / 0.45 } else { $cover = (1.0 - $p) / 0.55 }
            if ($cover -lt 0) { $cover = 0.0 }
            if ($cover -gt 1) { $cover = 1.0 }
        }
                # ★ 哭的时候眼睛眯着（代码画表情的一部分）
        # ★ 哭的时候眼睛眯着：cover 要够大，否则 coverF 上不去，
        #   眼皮只盖住一部分、下面原始瞳孔露出来 → 看着像冲突 ✗
        #   0.55×1.35=0.74（没盖满）→ 0.78×1.35≈1.0（完全盖住 ✓）
        if ($script:hurt -gt 0 -and $cover -lt 0.78) { $cover = 0.78 }

        if (-not $script:autoWalk) { $script:gaitBob = 0 }
        $still = ([Math]::Abs($script:sq) -lt 0.004) -and ([Math]::Abs($leanA) -lt 0.25) -and
                 ($script:hopJump -lt 0.05) -and ([Math]::Abs($script:hopFlip) -lt 0.5) -and
                 ($script:turnSx -gt 0.995)

        # ★ 姿势/表情切换 → 交叉淡入（0.16 秒），不再硬切
        if ($exprName -ne 'pose_团') { $script:rollLastPx = $null; $script:py0 = $script:py }   # 不滚时记住当前落脚点

        $curKey = if ($exprName) { [string]$exprName } else { 'base' }
        if ($script:xfKey -ne $curKey) {
            if ($script:xfKey -ne '' -and $useImg -and -not [object]::ReferenceEquals($script:xfPrev, $useImg)) {
                $script:xfPrev = $useImg
            }
            $script:xfKey = $curKey
            $script:xf = 0.0
        }
        if ($script:xf -lt 1.0) {
            $xfPer = [Math]::Max(3.0, [double](Cfg '行为.姿势过渡毫秒' 160) / [double]$script:timer.Interval)
            $script:xf = [Math]::Min(1.0, $script:xf + 1.0 / $xfPer)
        }

        $script:rollActive = $false   # 先清零，滚动分支里再置 true
        # ★ 滚动：球体绕自身中心旋转，底边贴地（角度 = 位移/半径，不打滑）
        if ($useImg -and $exprName -eq 'pose_团' -and $useArt -eq $false) {
            # ★ 接触半径：按当前旋转角度查表（旋转后"朝下"方向对应原图 -angle）
            # ★ 固定半径（用 36 方向轮廓的平均值）→ 球心高度恒定，不再随角度上下"飞"
            $rBall = $ih / 3.0
            if ($script:rollRadii -and $script:rollRadii.Count -eq 36) {
                $sumR = 0.0
                foreach ($v in $script:rollRadii) { $sumR += [double]$v }
                $rBall = $sumR / 36.0
            }
            if ($script:rollLastPx -ne $null -and $rBall -gt 1) {
                $dxRoll = $script:px - [double]$script:rollLastPx
                if ([Math]::Abs($dxRoll) -gt 900) { $dxRoll = 0 }   # 瞬移（换位）不转
                $script:rollAngle += ($dxRoll / $rBall) * 57.29578
                $script:rollAngle = $script:rollAngle % 360.0
            }
            $script:rollLastPx = $script:px
            # ★ 贴地：用"当前绘制中心 + 半高"（和站姿同一套坐标，不受压扁/弹簧/尺寸影响）
            #   注意：不再强改 py（强改会在你挪过她之后瞬移回旧位置 → 看起来"消失/跳走"）
            if ($script:vy -ne 0) { $script:vy *= 0.55 }   # 纵向速度慢慢收住
            $groundBall = ($script:ch / 2.0 - 14.0) + $ih / 2.0 - 4.0   # 固定地面（不吃呼吸/跳跃/jitY）
            # ★ 球用 1:1 原始尺寸（最清晰；不再缩放）
            $scaleBall = 1.0
            if ($scaleBall -lt 0.5) { $scaleBall = 1.0 }
            $rDraw = $rBall * $scaleBall
            $bcy = $groundBall - $rDraw
            $bw = $iw * $scaleBall
            $bh = $ih * $scaleBall
            $script:rollShadowW = $rDraw * 1.9
            $script:rollShadowY = $groundBall
            # ★ 横向限幅：别滚出屏幕（跑出去 = "人不见了"）
            $pxMin = $script:scr.Left + 8
            $pxMax = $script:scr.Right - $script:cw - 8
            if ($script:px -lt $pxMin) { $script:px = $pxMin; $script:vx = [Math]::Abs($script:vx); $script:wanderBias = (Get-Random -Minimum 5 -Maximum 60) / 100.0 }
            if ($script:px -gt $pxMax) { $script:px = $pxMax; $script:vx = -[Math]::Abs($script:vx); $script:wanderBias = [Math]::PI - (Get-Random -Minimum 5 -Maximum 60) / 100.0 }
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $stRoll = $g.Save()
            $g.TranslateTransform([single]$cx, [single]$bcy)
            $g.RotateTransform([single]$script:rollAngle)
            $g.DrawImage($useImg, [single](-$bw / 2.0), [single](-$bh / 2.0), [single]$bw, [single]$bh)
            $g.Restore($stRoll)
            $script:rollActive = $true   # 本帧在滚（下一帧让待机动作让行）
            $fading = $false
        }
        elseif ($still) {
            # 静止 → 像素级 1:1 直贴，绝对清晰
            $ix = [int][Math]::Round($cx - $iw / 2.0)
            # ★ 呼吸：静止时轻微上下浮动 1px（整数，保持 1:1 清晰）
            $breath = 0
            if ($script:sleep -le 0 -and $script:xf -ge 1.0) {
                $breath = [int][Math]::Round([Math]::Sin($script:tick / 46.0) * 1.2)
            }
            $iy = [int][Math]::Round($cy - $ih / 2.0) + $breath - [int]$script:gaitBob
            # 过渡中：新图"下滑 + 微放大"进入，旧图"上移淡出"——比纯淡入自然
            if ($script:xfPrev -and $script:xf -lt 1.0 -and -not [object]::ReferenceEquals($script:xfPrev, $useImg)) {
                $k        = $script:xf
                $kEase    = 1.0 - [Math]::Pow(1.0 - $k, 2.2)      # ease-out
                $slide    = [int][Math]::Round((1.0 - $kEase) * 14.0)   # 新图从下 14px 滑入
                $scaleF   = 0.965 + 0.035 * $kEase                      # 新图 0.965→1.0
                $dw       = [int][Math]::Round($iw * $scaleF)
                $dh       = [int][Math]::Round($ih * $scaleF)
                $dx       = [int][Math]::Round($cx - $dw / 2.0)
                $dy       = [int][Math]::Round($cy - $dh / 2.0) + $slide
                # 旧图：上移 6px + 淡出
                $oldY     = $iy - [int][Math]::Round((1.0 - $kEase) * 6.0)
                Draw-ImageAlpha $g $script:xfPrev $ix $oldY (1.0 - $kEase)
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.DrawImage($useImg, $dx, $dy, $dw, $dh)
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
                $fading = $true
            } else {
                $g.DrawImage($useImg, $ix, $iy)
                $fading = $false
            }
            $st = $g.Save()
            $g.TranslateTransform([single]$ix, [single]$iy)
            if ($useArt -and -not $fading) { Draw-Ears $g $script:earAng $iw $ih $useMirror }
            if ($useArt) { Draw-Blink $g $cover $iw $ih $useMirror }
            if ($script:tears -gt 0.02) { Draw-Tears $g $script:tears $iw $ih $useMirror }
            if ($useArt) { Draw-Face $g $iw $ih $useMirror }
            $g.Restore($st)
        }
        else {
            # 弹跳/倾斜中 → 走变换（动作本身掩盖了轻微柔化，换来 Q弹）
            $mx = if ($useMirror) { -1.0 } else { 1.0 }
            if ($script:spinMirror) { $mx = -$mx }
            $spinSy = 1.0 + 0.09 * (1.0 - $script:spinSquash)
            $fading = $false          # 运动中不做交叉淡入（动作本身掩盖）
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $st = $g.Save()
            $g.TranslateTransform([single]$cx, [single]($cy + $ih / 2.0 + $script:spinBob))
            $g.RotateTransform([single](-$leanA + $script:hopFlip))
            $g.ScaleTransform([single]($sx * $mx * $script:spinSquash), [single]($sy * $spinSy))
            $g.TranslateTransform([single](-$iw / 2.0), [single](-$ih))
            $g.DrawImage($useImg, 0, 0, $iw, $ih)
            # 变换已经把镜像做掉了，所以这里传 $false
            if ($useArt) { Draw-Ears $g $script:earAng $iw $ih $false }
            if ($useArt) { Draw-Blink $g $cover $iw $ih $false }
            if ($script:tears -gt 0.02) { Draw-Tears $g $script:tears $iw $ih $false }
            if ($useArt) { Draw-Face $g $iw $ih $false }
            $g.Restore($st)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        }
    }

    # ---------- 说话气泡 ----------
    if ($script:bubbleLife -gt 0 -and $script:bubbleBmp) {
        $prog = $script:bubbleLife / [double]$script:bubbleTotal
        # 淡入 ~0.35 秒、淡出 ~0.5 秒，中间保持
        $fadeIn  = [Math]::Min(1.0, (1.0 - $prog) / 0.09)
        $fadeOut = [Math]::Min(1.0, $prog / 0.13)
        $a = [Math]::Min($fadeIn, $fadeOut)
        if ($a -lt 0) { $a = 0.0 } elseif ($a -gt 1) { $a = 1.0 }

        $cm = New-Object System.Drawing.Imaging.ColorMatrix
        $cm.Matrix33 = [single]$a
        $script:bubbleIA.SetColorMatrix($cm)

        $bx = [int]($cx - $script:bubbleW / 2.0)
        $by = [int]($cy - ($ih * $pulseY / 2.0) - $script:bubbleH - 2)
    if ($by -lt 2) { $by = 2 }
        if ($by -lt 2) { $by = 2 }
        if ($bx -lt 2) { $bx = 2 }
        if (($bx + $script:bubbleW) -gt ($script:cw - 2)) { $bx = $script:cw - $script:bubbleW - 2 }

        $g.DrawImage($script:bubbleBmp,
            (New-Object System.Drawing.Rectangle($bx, $by, $script:bubbleW, $script:bubbleH)),
            0, 0, $script:bubbleW, $script:bubbleH,
            [System.Drawing.GraphicsUnit]::Pixel, $script:bubbleIA)
    }

    # ---------- 星火粒子（落地会摊平）----------
    foreach ($p in $script:particles) {
        if ($p.type -eq 1) {
            # 眼泪：竖着的水滴；落到地面摊成一小滩
            if ($p.land -gt 0) {
                $g.FillEllipse($script:tearBrush, [single]($p.x - 6.0), [single]($script:groundY - 1.8), 12.0, 3.6)
            }
            else {
                $g.FillEllipse($script:tearBrush, [single]($p.x - 2.8), [single]($p.y - 5.6), 5.6, 11.2)
                $g.FillEllipse($script:tearHi,    [single]($p.x - 1.2), [single]($p.y - 4.2), 2.1, 3.4)
            }
            continue
        }
        $bucket = [int]($p.life / $p.max * 8.0)
        if ($bucket -gt 7) { $bucket = 7 }
        if ($bucket -lt 0) { $bucket = 0 }
        $br = $script:sparkBrushes[$p.c][$bucket]
        $sz = 2.0 + $bucket * 0.35
        if ($p.land -gt 0) {
            $g.FillEllipse($br, [single]($p.x - $sz * 0.95), [single]($script:groundY - $sz * 0.26),
                           [single]($sz * 1.9), [single]($sz * 0.52))
        }
        else {
            $g.FillEllipse($br, [single]($p.x - $sz / 2), [single]($p.y - $sz / 2),
                           [single]$sz, [single]$sz)
        }
    }

    # ---------- 表情标记 ----------
    $topY = $cy - $script:imgH / 2.0
    if ($script:hurt -gt 0) {
        # 吃痛：头顶转一圈星
        for ($k = 0; $k -lt 5; $k++) {
            $a2 = ($t / 5.5) + $k * 1.2566
            $rx = $cx + [Math]::Cos($a2) * 27
            $ry = $topY - 4 + [Math]::Sin($a2) * 7
            $g.FillEllipse($script:heartBrush, [single]($rx - 3), [single]($ry - 3), 6.0, 6.0)
        }
    }
    if ($script:mood -gt 0) {
        # 开心：往上飘的小爱心
        for ($k = 0; $k -lt 6; $k++) {
            $rx = $cx + [Math]::Sin($t / 17.0 + $k * 1.1) * (24 + $k * 5)
            $ry = $topY + 14 - ((($t * 1.15) + $k * 21) % 72)
            Draw-Heart $g $rx $ry (3.0 + ($k % 3) * 1.2)
        }
    }
    if ($script:angry -gt 0) {
        # 生气：头上一圈怒气符
        for ($k = 0; $k -lt 4; $k++) {
            $a3 = ($t / 9.0) + $k * 1.5708
            $rx = $cx + [Math]::Cos($a3) * 35
            $ry = $topY + [Math]::Sin($a3) * 9
            Draw-AngerMark $g $rx $ry (6.5 + ($k % 2) * 2.5)
        }
    }
    if ($script:surprise -gt 0) {
        Draw-Surprise $g ($cx + $iw * 0.24) ($topY + 2) ($script:surprise / 26.0)
    }

    # ★ 睡觉呼噜：头上飘 Z（三个，错开上浮+淡出）
    if ($script:sleep -gt 0) {
        try {
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
            for ($k = 0; $k -lt 3; $k++) {
                $ph = ((($script:tick * 0.85) + $k * 30) % 90)
                $kf = 1.0 - ($ph / 90.0)
                $zx = $cx + $iw * 0.28 + ($ph * 0.26) + ($k * 11)
                $zy = $topY + ($ih * 0.02) - ($ph * 0.75)
                $za = [int](235 * $kf)
                if ($za -lt 8) { continue }
                $zb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($za, 70, 105, 175))
                $zf = New-Object System.Drawing.Font('Arial', [single](15.0 + $k * 4.5), [System.Drawing.FontStyle]::Bold)
                $g.DrawString('Z', $zf, $zb, [single]$zx, [single]$zy)
                $zf.Dispose(); $zb.Dispose()
            }
        } catch {}
    }

    $g.Dispose()
}

# ============================================================
#  5.5 说话气泡
# ============================================================
function Render-BubbleBitmap {
    param([string]$Text, [string]$Big = '', [string]$Sub = '', [string]$Tag = '')
    if ($script:bubbleBmp) { $script:bubbleBmp.Dispose(); $script:bubbleBmp = $null }
    if (-not $Text -and -not $Big) { return }

    $fTag = UiFont 8.5 1
    $fBig = UiFont 22 1 -Num
    $fSub = UiFont 8.5
    $cInk = [System.Drawing.Color]::FromArgb(255, 30, 48, 86)
    $cSub = [System.Drawing.Color]::FromArgb(255, 104, 128, 170)
    $cTag = [System.Drawing.Color]::FromArgb(255, 70, 106, 168)
    $bInk = New-Object System.Drawing.SolidBrush($cInk)
    $bSub = New-Object System.Drawing.SolidBrush($cSub)
    $bTag = New-Object System.Drawing.SolidBrush($cTag)

    $probe = New-Object System.Drawing.Bitmap(1, 1)
    $pg = [System.Drawing.Graphics]::FromImage($probe)
    $pg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $maxTextW = 176.0
    $card = [bool]$Big
    $padX = 17.0; $padY = 10.0
    if ($card) {
        $szTag = $pg.MeasureString($Tag, $fTag)
        $szBig = $pg.MeasureString($Big, $fBig)
        $szSub = $pg.MeasureString($Sub, $fSub)
        $contentW = [Math]::Max($szTag.Width, [Math]::Max($szBig.Width, $szSub.Width))
        $contentH = $szTag.Height + $szBig.Height + $szSub.Height
        $bw = [int]([Math]::Max(152.0, $contentW + $padX * 2))
        $bh = [int]($contentH + $padY * 2 + 6)
    } else {
        $sz = $pg.MeasureString($Text, $script:bubbleFont, [int]$maxTextW)
        $bw = [int]([Math]::Min($maxTextW, $sz.Width) + $padX * 2)
        # ★ 最小宽度：打字机刚开始只有 1~2 个字时，气泡别细成一条（"最窄帧偏薄"）
        if ($bw -lt 86) { $bw = 86 }
        $bh = [int]($sz.Height + $padY * 2 + 6)
    }
    $pg.Dispose(); $probe.Dispose()

    $mgn = 15
    $tailH = 34
    $cvW = $bw + $mgn * 2
    $cvH = $bh + $mgn * 2 + $tailH
    $bmp = New-Object System.Drawing.Bitmap($cvW, $cvH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $bx = $mgn; $by = $mgn
    $r = [Math]::Min(($bh / 2.0) + 1, 26.0)
    $d = $r * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($bx, $by, $d, $d, 180, 90)
    $path.AddArc(($bx + $bw - $d), $by, $d, $d, 270, 90)
    $path.AddArc(($bx + $bw - $d), ($by + $bh - $d), $d, $d, 0, 90)
    $path.AddArc($bx, ($by + $bh - $d), $d, $d, 90, 90)
    $path.CloseFigure()

    $shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(24, 40, 60, 120))
    for ($i = 0; $i -lt 4; $i++) {
        $g.TranslateTransform((1.2 + $i * 0.7), (2.0 + $i * 0.9))
        $g.FillPath($shadow, $path)
        $g.ResetTransform()
    }
    $shadow.Dispose()

    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF($bx, $by)),
        (New-Object System.Drawing.PointF($bx, ($by + $bh))),
        [System.Drawing.Color]::FromArgb(255, 255, 255, 255),
        [System.Drawing.Color]::FromArgb(255, 222, 234, 252))
    $g.FillPath($lg, $path)
    $lg.Dispose()

    $outer = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 64, 94, 160), 2.4)
    $g.DrawPath($outer, $path)
    $outer.Dispose()

    $r2 = [Math]::Max(4.0, $r - 4.0)
    $pi = New-Object System.Drawing.Drawing2D.GraphicsPath
    $pi.AddArc(($bx + 3.5), ($by + 3.5), ($r2 * 2), ($r2 * 2), 180, 90)
    $pi.AddArc(($bx + $bw - $r2 * 2 - 3.5), ($by + 3.5), ($r2 * 2), ($r2 * 2), 270, 90)
    $pi.AddArc(($bx + $bw - $r2 * 2 - 3.5), ($by + $bh - $r2 * 2 - 3.5), ($r2 * 2), ($r2 * 2), 0, 90)
    $pi.AddArc(($bx + 3.5), ($by + $bh - $r2 * 2 - 3.5), ($r2 * 2), ($r2 * 2), 90, 90)
    $pi.CloseFigure()
    $innerPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 255, 255, 255), 1.3)
    $g.DrawPath($innerPen, $pi)
    $innerPen.Dispose(); $pi.Dispose()

    $glossH = $bh * 0.44
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gr = [Math]::Max(6.0, $r * 0.9)
    $gp.AddArc(($bx + 2), ($by + 2), ($gr * 2), ($gr * 2), 180, 90)
    $gp.AddArc(($bx + $bw - $gr * 2 - 2), ($by + 2), ($gr * 2), ($gr * 2), 270, 90)
    $gp.AddLine(($bx + $bw - 2), ($by + $glossH), ($bx + 2), ($by + $glossH))
    $gp.CloseFigure()
    $gl = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF($bx, $by)),
        (New-Object System.Drawing.PointF($bx, ($by + $glossH))),
        [System.Drawing.Color]::FromArgb(150, 255, 255, 255),
        [System.Drawing.Color]::FromArgb(0, 255, 255, 255))
    $g.FillPath($gl, $gp)
    $gl.Dispose(); $gp.Dispose()
    $path.Dispose()

    # 点状尾巴（不用三角，更像"想想"）
    $fillDot = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 244, 249, 255))
    $dotPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 72, 104, 168), 2.0)
    $tailX = $bx + $bw * 0.30
    $dots = @(@(9.0, 0.0), @(7.0, 15.0), @(5.0, 27.0))
    $dy = $by + $bh - 3
    $dx = $tailX
    foreach ($dt in $dots) {
        $rr = $dt[0]
        $g.FillEllipse($fillDot, ($dx - $rr), ($dy - $rr + 2), ($rr * 2), ($rr * 2))
        $g.DrawEllipse($dotPen, ($dx - $rr), ($dy - $rr + 2), ($rr * 2), ($rr * 2))
        $dx += 13
        $dy += 12
    }
    $fillDot.Dispose(); $dotPen.Dispose()

    $x0 = [single]($bx + $padX)
    $w0 = [single]($bw - $padX * 2)
    if ($card) {
        $y = [single]($by + $padY)
        $rt = [System.Drawing.RectangleF]::FromLTRB($x0, $y, ($x0 + $w0), ($y + [single]$szTag.Height))
        $g.DrawString($Tag, $fTag, $bTag, $rt, $script:bubbleSf)
        $y = $y + [single]$szTag.Height
        $rb = [System.Drawing.RectangleF]::FromLTRB($x0, $y, ($x0 + $w0), ($y + [single]$szBig.Height))
        $g.DrawString($Big, $fBig, $bInk, $rb, $script:bubbleSf)
        $y = $y + [single]$szBig.Height
        $rs = [System.Drawing.RectangleF]::FromLTRB($x0, $y, ($x0 + $w0), ($y + [single]$szSub.Height))
        $g.DrawString($Sub, $fSub, $bSub, $rs, $script:bubbleSf)
    } else {
        $yt = [single]($by + $padY - 2)
        $rect = [System.Drawing.RectangleF]::FromLTRB([single]($x0 - 3), $yt, [single]($x0 + $w0 + 3), [single]($by + $bh - $padY + 2))
        $g.DrawString($Text, $script:bubbleFont, $script:bubbleText, $rect, $script:bubbleSf)
    }

    $g.Dispose()
    $fTag.Dispose(); $fBig.Dispose(); $fSub.Dispose()
    $bInk.Dispose(); $bSub.Dispose(); $bTag.Dispose()

    $script:bubbleBmp = $bmp
    $script:bubbleW = $cvW
    $script:bubbleH = $cvH
}

function Say-Something {
    param([int]$frames = 0, $pool = $null, [int]$prio = 20, [switch]$force)
    # ★ v2：说话锁 —— 低优先级不许打断高优先级，同类说话要过最小间隔
    if (-not $force -and $script:sayLock -gt 0) {
        if ($prio -lt $script:sayLockPrio) { return }
        # ★ 只有"同优先级"才受最小间隔限制；更高优先级可立即打断
        #   （否则：害羞话刚说完 2 帧就吃痛 → 哭脸配害羞台词 ✗）
        if ($prio -eq $script:sayLockPrio) {
            $gap = CfgFrames '气泡.同优先级最小间隔秒数' 2.5
            if (($script:tick - $script:sayLast) -lt $gap) { return }
        }
    }
    if (-not $pool -or $pool.Count -eq 0) { $pool = $script:lines }
    $line = $pool[(Get-Random -Minimum 0 -Maximum $pool.Count)]
    if ($pool.Count -gt 1 -and $line -eq $script:bubbleText_) {
        $line = $pool[(Get-Random -Minimum 0 -Maximum $pool.Count)]
    }

    # ★ 工具模式：不主动说话（非 force）
    if ($script:toolMode -and -not $force) { return }
    # ★ 首次见面独占：她说话期间其它台词一律让行（非 force）
    if ($script:introQuiet -and -not $force) { return }

    # ★ 情绪守卫（全状态）：状态和台词必须一致，除非 -force
    if (-not $force) {
        # 睡着了 → 完全不说话
        if ($script:sleep -gt 0) { return }
        $emoPool = ''
        if     ($script:hurt  -gt 0) { $emoPool = if ($script:hurtSrc -eq 'bump') { 'collision.bump' } else { 'expr.sad' } }
        elseif ($script:angry -gt 0) { $emoPool = 'expr.angry' }
        elseif ($script:mood  -gt 0) { $emoPool = 'expr.happy' }
        elseif ($script:shy   -gt 0) { $emoPool = 'expr.shy' }
        # ☆ 惊讶不再劫持台词（普通状态冒"心跳停了半拍"很怪）
        if ($emoPool) {
            $emoLine = ''
            try { $emoLine = Get-PoolLine $emoPool } catch {}
            if (-not $emoLine) {
                $arr = switch ($emoPool) {
                    'expr.sad'       { $script:hurtLines }
                    'collision.bump' { $script:hurtLines }
                    'expr.angry'     { $script:angryLines }
                    'expr.happy'     { $script:happyLines }
                    'expr.shy'       { $script:shyLines }
                    default          { $null }
                }
                if ($arr -and $arr.Count -gt 0) { $emoLine = [string]$arr[(Get-Random -Minimum 0 -Maximum $arr.Count)] }
            }
            if ($emoLine) { $line = $emoLine }
        }
    }
        # ★ 台词槽位：{时段}
    if ($line.Contains('{时段}')) {
        $hh = (Get-Date).Hour
        $slot = if ($hh -lt 5) { '凌晨' } elseif ($hh -lt 9) { '早上' } elseif ($hh -lt 12) { '上午' } elseif ($hh -lt 18) { '下午' } elseif ($hh -lt 23) { '晚上' } else { '深夜' }
        $line = $line.Replace('{时段}', $slot)
    }
    $script:bubbleText_ = $line
    $bBig = ''; $bSub = ''; $bTag = ''
    try {
        if ($line -match '余额') {
            if ($line -match '¥\s*([0-9]+(?:\.[0-9]+)?)') {
                $bBig = '¥' + $Matches[1]
                $bTag = 'DeepSeek 余额'
                try {
                    $uu = Get-DshUsage
                    if ($uu.ok) { $bSub = '今日已用 ¥' + [Math]::Round([double]$uu.cost, 2) }
                } catch {}
            }
        }
    } catch {}
    Render-BubbleBitmap $line $bBig $bSub $bTag

    $fps = 1000.0 / $timer.Interval
    $script:bubbleTotal = if ($frames -gt 0) { $frames } else { [int]([double](Cfg '气泡.持续秒数' 4.2) * $fps) }
    $script:bubbleLife = $script:bubbleTotal

    # 上锁
    $script:sayLock     = CfgFrames '气泡.锁秒数' 2.2
    $script:sayLockPrio = $prio
    $script:sayLast     = $script:tick

    # ★ 念出来（开关在设置里，默认关）
    try { if (Get-Command Speak-Line -ErrorAction SilentlyContinue) { Speak-Line $line } } catch {}
}

# ★ 热重载台词包（导入新台词后不用重启）
function Reload-Lines {
    try {
        $cfgP = Join-Path $PSScriptRoot 'config.json'
        if (Test-Path $cfgP) {
            $script:cfg = Get-Content $cfgP -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        # 重新合并台词包
        try {
            $lpDir = Join-Path $PSScriptRoot '台词包'
            $lp = Merge-LinePacks $script:cfg $lpDir
        } catch {}
        # 重新赋值给运行时数组
        $script:lines        = @(Cfg '台词.普通'   $script:lines)
        $script:shyLines     = @(Cfg '台词.害羞'   $script:shyLines)
        $script:happyLines   = @(Cfg '台词.开心'   $script:happyLines)
        $script:angryLines   = @(Cfg '台词.生气'   $script:angryLines)
        $script:hurtLines    = @(Cfg '台词.吃痛'   $script:hurtLines)
        $script:dsLines      = @(Cfg '台词.认亲'   $script:dsLines)
        $script:trappedLines = @(Cfg '台词.被框住' $script:trappedLines)
        return @{ ok = $true; total = ($script:lines.Count + $script:shyLines.Count + $script:happyLines.Count + $script:angryLines.Count + $script:hurtLines.Count + $script:dsLines.Count + $script:trappedLines.Count) }
    } catch { return @{ ok = $false; error = $_.Exception.Message } }
}

# ★ 清空气泡（睡觉/暂停/瞬移时用，避免残留台词）
function Clear-Bubble {
    try {
        $script:bubbleText_  = ''
        $script:bubbleLife   = 0
        $script:bubbleTotal  = 0
        $script:sayLock      = 0
        $script:sayLockPrio  = 0
    } catch {}
}

# ★ v2：统一设置表情（带冷却 + 优先级，避免同一帧多个表情打架）
function Set-Emotion {
    param([string]$Name, [switch]$Force)
    $prioMap = @{ 'hurt' = 60; 'angry' = 50; 'shy' = 30; 'mood' = 25; 'surprise' = 20 }
    $p = if ($prioMap.ContainsKey($Name)) { $prioMap[$Name] } else { 10 }
    if (-not $Force -and $script:emoLock -gt 0) {
        if ($p -lt $script:emoPrio) { return $false }
    }
    # 清掉其它表情，避免叠加
    switch ($Name) {
        'hurt'     { $script:angry = 0; $script:shy = 0; $script:mood = 0 }
        'angry'    { $script:hurt = 0;  $script:shy = 0; $script:mood = 0; $script:tears = 0.0 }
        'shy'      { $script:angry = 0 }
        'mood'     { $script:angry = 0; $script:hurt = 0; $script:tears = 0.0 }
        'surprise' { }
    }
    $script:emoName = $Name
    $script:emoPrio = $p
    $script:emoLock = CfgFrames '表情.最短切换秒数' 1.2
    return $true
}

# ★ v2.1：这个表情现在允许出现吗（特效/表情门槛）
function Test-EmotionAllowed {
    param([string]$Name)
    $prioMap = @{ 'hurt' = 60; 'angry' = 50; 'shy' = 30; 'mood' = 25; 'surprise' = 20 }
    $p = if ($prioMap.ContainsKey($Name)) { $prioMap[$Name] } else { 10 }
    # 哭/吃痛期间，除了更强的（强制项）都不允许
    if ($script:hurt -gt 0 -and $p -lt 60) { return $false }
    if ($script:emoLock -gt 0 -and $p -lt $script:emoPrio) { return $false }
    return $true
}

# ★ v2.1：互斥兜底 —— 每帧保证"同一时间只有一个主表情"
#   以前会出现 hurt 和 mood 同时 > 0 → 星星 + 爱心一起画 ✗
function Sync-EmotionExclusive {
    if ($script:hurt -gt 0) {
        $script:mood = 0
        $script:shy  = 0
        return
    }
    if ($script:angry -gt 0) {
        $script:mood = 0
        $script:shy  = 0
        return
    }
    if ($script:shy -gt 0 -and $script:mood -gt 0) { $script:mood = 0 }
}

# ★ v2.2 被框住检测
#   旧版：她的身体和"框"的矩形重叠就算 → 只要站在录屏区域里就一直触发 ✗
#   新版：① 她的中心在框内  ② 身体某条边离框边 ≤ 带宽（= 贴着边）才触发 ✓
#         ③ 必须持续 N 帧（拖拽时瞬时窗口不算）④ 关键词/开关/冷却都可配 ⑤ 日志默认关
function Check-Trapped {
    if (-not [bool](Cfg '行为.被框检测.启用' $true)) { return }
    if ($script:dragging -or $script:physActive) { return }

    $cool = CfgFrames '行为.被框检测.冷却秒数' 20
    if (($script:tick - $script:trappedCool) -lt $cool) { return }

    $kws   = @(Cfg '行为.被框检测.关键词' @('screentogif','recorder','licecap','sharex','shotcut','camstudio'))
    $onlyTool = [bool](Cfg '行为.被框检测.只认工具窗口' $true)
    $band  = [double](Cfg '行为.被框检测.边框带宽像素' 70)
    $need  = CfgFrames '行为.被框检测.持续秒数' 0.4
    $dbgOn = [bool](Cfg '行为.被框检测.调试日志' $false)

    $bx1 = $script:px + $script:cw * 0.30
    $by1 = $script:py + $script:ch * 0.22
    $bx2 = $script:px + $script:cw * 0.70
    $by2 = $script:py + $script:ch * 0.80
    $bcx = ($bx1 + $bx2) / 2.0
    $bcy = ($by1 + $by2) / 2.0

    $hit = $null
    try { $wins = [LW]::WindowsInfo() } catch { $wins = @() }
    foreach ($s in $wins) {
        $p = ([string]$s).Split('|')
        if ($p.Count -lt 4) { continue }
        $rc = $p[0].Split(',')
        if ($rc.Count -lt 4) { continue }
        $l = [double]$rc[0]; $tp = [double]$rc[1]; $rr = [double]$rc[2]; $bt = [double]$rc[3]
        $isTool = ($p[1] -eq '1')
        if ($onlyTool -and -not $isTool) { continue }
        $low = (($p[3] + ' ' + $p[2])).ToLowerInvariant()
        $matched = $false
        foreach ($k in $kws) {
            if (-not $k) { continue }
            if ($low.Contains(([string]$k).ToLowerInvariant())) { $matched = $true; break }
        }
        if (-not $matched) { continue }
        if (($rr - $l) -lt 80 -or ($bt - $tp) -lt 40) { continue }
        # 中心在框内
        if ($bcx -lt $l -or $bcx -gt $rr -or $bcy -lt $tp -or $bcy -gt $bt) { continue }
        # 身体边缘离框边最近距离（贴边判定）
        $d1 = [Math]::Abs($bx1 - $l); $d2 = [Math]::Abs($bx2 - $rr)
        $d3 = [Math]::Abs($by1 - $tp); $d4 = [Math]::Abs($by2 - $bt)
        $near = [Math]::Min([Math]::Min($d1, $d2), [Math]::Min($d3, $d4))
        if ($near -gt $band) { continue }
        $hit = $s
        break
    }

    if ($hit) {
        $script:trappedHold++
        if ($dbgOn -and ($script:trappedHold % 20) -eq 1) {
            try {
                "$(Get-Date -Format 'HH:mm:ss') 贴边帧=$($script:trappedHold) 窗口=$hit 她的位置=$([int]$bx1),$([int]$by1)" |
                    Out-File -FilePath (Join-Path $PSScriptRoot 'deskpet-trapped.log') -Append -Encoding utf8
            } catch {}
        }
        if ($script:trappedHold -ge $need) {
            $script:trappedHold = 0
            $script:trappedCool = $script:tick
            $script:surprise    = 110
            try { $pl = Get-PoolLine 'act.trapped'; if ($pl) { Say-Something 0 @($pl) 40 } else { Say-Something 0 $script:trappedLines 40 } } catch { Log-Err $_ 'trapped' }
        }
    }
    else {
        $script:trappedHold = 0
    }
}

# ★ v2：撞到窗口后的随机反应（吃痛/生气/抱怨/惊讶，权重可配）
function Invoke-CollisionReaction {
    param([double]$Speed = 1.0, [string]$Title = '')

    # 弹开：水平/垂直倍率不同（各向异性）+ 随机抖动
    $bx = [double](Cfg '碰撞.水平弹开倍率' 1.0)
    $by = [double](Cfg '碰撞.垂直弹开倍率' 0.85)
    $jr = [double](Cfg '碰撞.随机抖动倍率' 0.35)
    $jx = 1.0 + (Get-Random -Minimum (-$jr) -Maximum $jr)
    $jy = 1.0 + (Get-Random -Minimum (-$jr) -Maximum $jr)
    $script:tvx = -$script:tvx;  $script:tvy = -$script:tvy
    $script:vx  = -$script:vx * 0.55 * $bx * $jx
    $script:vy  = -$script:vy * 0.55 * $by * $jy

    # 加权抽签
    $wHurt = [double](Cfg '碰撞.反应权重.吃痛' 55)
    $wAng  = [double](Cfg '碰撞.反应权重.生气' 20)
    $wComp = [double](Cfg '碰撞.反应权重.抱怨' 20)
    $wSur  = [double](Cfg '碰撞.反应权重.惊讶' 5)
    $total = $wHurt + $wAng + $wComp + $wSur
    if ($total -le 0) { $total = 1 }
    $pick = Get-Random -Minimum 0.0 -Maximum $total
    $kind = '吃痛'
    if ($pick -lt $wHurt)               { $kind = '吃痛' }
    elseif ($pick -lt $wHurt + $wAng)   { $kind = '生气' }
    elseif ($pick -lt $wHurt + $wAng + $wComp) { $kind = '抱怨' }
    else                                { $kind = '惊讶' }

    switch ($kind) {
        '吃痛' {
            Invoke-Hurt $Title -Source 'bump'
        }
        '生气' {
            $null = Set-Emotion 'angry' -Force
            $script:angry = CfgFrames '互动.生气持续秒数' 4.2
            $script:hurt = 0; $script:tears = 0.0
            $script:sqV  = 0.56
            try { $pl = Get-PoolLine 'expr.angry'; if ($pl) { Say-Something 0 @($pl) 50 } else { Say-Something 0 $script:angryLines 50 } } catch { Log-Err $_ 'angry' }
        }
        '抱怨' {
            $script:sqV = -0.30
            $script:earV += 1.8
            try { $pl = Get-PoolLine 'expr.sad'; if ($pl) { Say-Something 0 @($pl) 40 } else { Say-Something 0 $script:hurtLines 40 } } catch { Log-Err $_ 'complain' }
        }
        '惊讶' {
            $null = Set-Emotion 'surprise' -Force
            $script:surprise = 70
            $script:sqV = -0.18
            try { Say-Something 0 $script:lines 30 } catch { Log-Err $_ 'surprise' }
        }
    }
}

# ★ v2：开始一次"大跳"（会整体翻转，落地再弹）
# ★ v2.4 大跳：真正的"蹦跳移动" —— 水平位移 + 每次落地头朝下 + 反弹一次
function Start-BigHop {
    # ★ 蹦跳时配一句自己的话（动作-台词绑定）
    try { $jl = Get-PoolLine 'act.jump'; if ($jl) { Say-Something 0 @($jl) 30 } } catch {}
    $script:hopActive = $true
    $script:hopPhase  = 0.0
    $script:hopTotal  = [Math]::Max(1, [int](Cfg '行为.蹦跳次数' 3))
    $script:hopDone   = 0
    $script:hopH      = [double](Cfg '行为.蹦跳高度' 20)
    $script:hopJump   = 0.0
    $script:hopFlip   = 0.0
    $script:hopSettle = 0
    $script:hopVX     = [double](Cfg '行为.蹦跳水平速度' 3.2)
    # 方向：优先当前朝向；朝向上随机摆动一点，别有机械感
    $dir = if ($script:facing -lt 0) { -1.0 } else { 1.0 }
    if ([Math]::Abs($script:vx) -gt 0.2) { $dir = [Math]::Sign($script:vx) }
    $script:hopVX = $script:hopVX * $dir
    $script:sqV       = 0.45
    $script:earV     += 1.2
}

function Update-Hop {
    if (-not $script:hopActive) {
        $script:hopJump = 0.0
        if ($script:spinLeft -le 0) { $script:hopFlip = 0.0 }   # 转圈时别清角度
        return
    }

    # ---- 收尾：把剩余角度平滑转回 360 的倍数（避免停在头朝下）----
    if ($script:hopSettle -gt 0) {
        $script:hopSettle--
        $script:hopJump = 0.0
        $k = 1.0 - ($script:hopSettle / 10.0)
        $script:hopFlip = $script:hopSettleFrom + ($script:hopSettleEnd - $script:hopSettleFrom) * $k
        if ($script:hopSettle -le 0) {
            $script:hopActive = $false
            $script:hopFlip   = 0.0
        }
        return
    }

    $per = [Math]::Max(6, [int]([double](Cfg '行为.蹦跳单次毫秒' 300) / $script:timer.Interval))
    $script:hopPhase += 1.0 / $per
    if ($script:hopPhase -ge 1.0) {
        $script:hopPhase = 0.0
        $script:hopDone++
        # 落地：压扁 + 火花 + 水平减速
        $script:sqV = -0.42
        try { Spawn-Sparkles 8 } catch {}
        $decay = [double](Cfg '行为.蹦跳落地反弹' 0.55)
        $script:hopVX *= $decay
        $script:hopH  *= [Math]::Max(0.25, $decay + 0.25)   # 越跳越低
        if ([Math]::Abs($script:hopVX) -lt 0.25) { $script:hopVX = 0.0 }
        if ($script:hopDone -ge $script:hopTotal) {
            $script:hopSettleFrom = $script:hopFlip
            $script:hopSettleEnd  = if ([Math]::Abs($script:hopFlip) -lt 30) { 0.0 } else { 360.0 * [Math]::Ceiling($script:hopFlip / 360.0) }
            $script:hopSettle = 10
            return
        }
    }

    # 垂直：抛物线
    $script:hopJump = [Math]::Sin($script:hopPhase * [Math]::PI) * $script:hopH
    # 水平：每跳都往前走一段
    if ($script:hopVX -ne 0.0) {
        $nx = $script:px + $script:hopVX
        $lft = $script:scr.Left
        $rgt = $script:scr.Right - $script:cw
        if ($nx -lt $lft) { $nx = $lft; $script:hopVX = -$script:hopVX * 0.6 }
        elseif ($nx -gt $rgt) { $nx = $rgt; $script:hopVX = -$script:hopVX * 0.6 }
        $script:px = $nx
    }
    # ★ 旋转模式：倾斜(默认，自然) / 翻滚(整段转一整圈，落地回正) / 关
    $flipMode = [string](Cfg '行为.蹦跳翻转模式' '倾斜')
    switch ($flipMode) {
        '翻滚' {
            # 整段动作转 360°，落地正好回正 ✓
            $total = [Math]::Max(1, $script:hopTotal)
            $script:hopFlip = 360.0 * (($script:hopDone + $script:hopPhase) / $total)
        }
        '关' { $script:hopFlip = 0.0 }
        default {
            # 倾斜：起跳后仰、落地前回正（±16°，不头朝下）
            $tiltDir = if ($script:hopVX -ge 0) { 1.0 } else { -1.0 }
            $script:hopFlip = 16.0 * [Math]::Sin($script:hopPhase * [Math]::PI) * $tiltDir
        }
    }
}

function Update-Facing {
    if (-not [bool](Cfg '行为.朝向翻转' $true)) { $script:turnSx = 1.0; return }
    if ($script:faceCool -gt 0) { $script:faceCool-- }

    # 真正执行一次转身（带冷却）
    $doTurn = {
        param([int]$Target)
        if ($Target -eq $script:facing) { return }
        if ($script:faceCool -gt 0 -or $script:turnT -gt 0) { return }
        $script:facing    = $Target
        $script:turnT     = [Math]::Max(4, [int]([double](Cfg '行为.转身动画毫秒' 220) / [double]$script:timer.Interval))
        $script:faceCool  = [Math]::Max(6, (CfgFrames '行为.转身冷却秒数' 2.5))
        $script:faceStable = 0
        $script:faceLastDir = 0
    }

    if ($script:dragging -or $script:physActive -or $script:hopActive) {
        if ($script:turnT -gt 0) { $script:turnT-- }
        $script:faceStable = 0
        $script:faceLastDir = 0
    }
    else {
        # ★ 外部请求（如看鼠标）：走正常转身动画，不再瞬间翻
        if ($script:facingPending -ne 0) {
            $pend = $script:facingPending
            $script:facingPending = 0
            & $doTurn $pend
        }

        # ★ 撞墙反弹：方向明确变了，允许立刻转身（但受冷却限制）
        if ($script:bounceFlag -eq 1) {
            $script:bounceFlag = 0
            $bd = 0
            if     ($script:vx -lt -0.3) { $bd = -1 }
            elseif ($script:vx -gt  0.3) { $bd = 1 }
            if ($bd -ne 0) { & $doTurn $bd }
        }

        # ★ 走动方向：必须"持续 20 帧同向且够快"才允许转身（防来回掉头）
        if (-not $script:autoWalk) {
            $script:faceStable = 0
            $script:faceLastDir = 0
        }
        else {
            $dir = 0
            if     ($script:vx -gt 1.2) { $dir = 1 }
            elseif ($script:vx -lt -1.2) { $dir = -1 }
            if ($dir -ne 0) {
                if ($dir -eq $script:faceLastDir) { $script:faceStable++ }
                else { $script:faceLastDir = $dir; $script:faceStable = 0 }
                if ($script:faceStable -ge 24) { & $doTurn $dir }   # ★ 0.4 秒同向才转，防来回抽
            }
            else {
                $script:faceStable = 0
                $script:faceLastDir = 0
            }
        }
        if ($script:turnT -gt 0) { $script:turnT-- }
    }
    # 转身过程：横向压扁成一条线再展开（读数就是"转过身"）
    if ($script:turnT -gt 0) {
        $den = [Math]::Max(1, [int]([double](Cfg '行为.转身动画毫秒' 220) / $script:timer.Interval))
        $p = 1.0 - ($script:turnT / [double]$den)     # 0..1
        $script:turnSx = [Math]::Abs([Math]::Cos($p * [Math]::PI))
        if ($script:turnSx -lt 0.06) { $script:turnSx = 0.06 }
    }
    else {
        $script:turnSx = 1.0
    }
}

function Log-Err {
    param($Err, [string]$Where)
    $p = Join-Path $PSScriptRoot 'deskpet-err.log'
    "$(Get-Date -Format 'HH:mm:ss') [$Where] $($Err.Exception.Message)" |
        Out-File -FilePath $p -Append -Encoding utf8
    "$($Err.ScriptStackTrace)" | Out-File -FilePath $p -Append -Encoding utf8
}

# ============================================================
#  6. 星火
# ============================================================
function Spawn-Sparkles {
    param([int]$n = 16, [double]$originY = 0.0, [double]$power = 1.0)
    $cx = $script:cw / 2
    $cy = if ($originY -gt 0) { $originY } else { $script:ch / 2 - 14 }
    for ($i = 0; $i -lt $n; $i++) {
        $ang = (Get-Random -Minimum 0 -Maximum 360) * [Math]::PI / 180
        $spd = ((Get-Random -Minimum 12 -Maximum 58) / 10.0) * $power
        $lf  = 22 + (Get-Random -Minimum 0 -Maximum 18)
        $null = $script:particles.Add([PSCustomObject]@{
                x    = $cx + (Get-Random -Minimum -10 -Maximum 10)
                y    = $cy
                vx   = [Math]::Cos($ang) * $spd
                vy   = [Math]::Sin($ang) * $spd - 2.2 * $power
                life = $lf
                max  = [double]$lf
                c    = (Get-Random -Minimum 0 -Maximum 3)
                land = 0
                type = 0
            })
    }
}

# 眼泪：从她眼睛的位置往下掉，会落到桌面上的地面线
function Spawn-Tears {
    param([int]$n = 1)
    $eyeLx = 0.3559; $eyeRx = 0.6042; $eyeY = 0.5026
    for ($i = 0; $i -lt $n; $i++) {
        $ex = if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) { $eyeLx } else { $eyeRx }
        $null = $script:particles.Add([PSCustomObject]@{
                x    = $script:cw / 2.0 + ($ex - 0.5) * $script:imgW
                y    = ($script:ch / 2.0 - 14.0 - $script:imgH / 2.0) + $eyeY * $script:imgH
                vx   = (Get-Random -Minimum -7 -Maximum 7) / 10.0
                vy   = 1.2
                life = 80
                max  = 80.0
                c    = 0
                land = 0
                type = 1
            })
    }
}

# ============================================================
#  7. 定时器：动画 + 游走 + 粒子 + 上屏
# ============================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [int](Cfg '显示.帧率毫秒' 16)        # 62 帧/秒（50→20 帧、30→33 帧，都还是顿）
$timer.Add_Tick({
    # 使用统计：暂停时也要记（人还在用电脑）
    try { Update-TimeTrack } catch {}
    # 暂停时保留最后一帧；但按下暂停后的前几帧继续跑一下，把姿态扶正再冻住
    if ($script:paused) {
        if ($script:pauseFixFrames -gt 0) { $script:pauseFixFrames-- } else { return }
    }
    $script:tick++
    if ($script:quiet -gt 0) { $script:quiet-- }

    # 开发者命令通道（_dev\cmd.txt，发布包无此目录）
    if (($script:tick % 20) -eq 0) { try { Check-DevCommand } catch {} }

    if (-not $script:toolAutoApplied) { $script:toolAutoApplied = $true; try { if ([bool](Cfg '模式.工具模式' $false) -and (Get-Command Set-ToolMode -ErrorAction SilentlyContinue)) { Set-ToolMode $true } } catch {} }
    if ($script:spinLeft -gt 0) {
        $script:spinLeft--
        if ($script:spinLeft -le 0) {
            $script:hopFlip = 0.0
            $script:spinSquash = 1.0
            $script:spinMirror = $false
            $script:spinBob = 0.0
        } else {
            $prog = 1.0 - ($script:spinLeft / [double]$script:spinTotal)      # 0 → 1
            $ph = $prog * 2.0 * [Math]::PI
            $c = [Math]::Cos($ph)
            $script:spinSquash = 0.40 + 0.60 * [Math]::Abs($c)
            $script:spinMirror = ($c -lt 0)
            $script:spinBob = -[Math]::Abs([Math]::Sin($ph)) * 12.0
            $script:hopFlip = 6.0 * [Math]::Sin($ph * 2.0 + 0.6)
        }
    }

    # ★ v2.2 被框住检测（贴在框的边才算，在框里面不算；不再每帧写日志）
    if ($script:sleep -le 0) { try { Check-Trapped } catch { Log-Err $_ 'trapped-check' } }

    # ★ v2.3 认亲：必须【部分重叠】（撞到/蹭到边），而且停留够久才说
    #   全身都在 Harness 里面时反而不说（那样太容易触发 ✗）
    if ([bool](Cfg '碰撞.认亲启用' $true)) {
        try {
            $dcx1 = [double]($script:px + $script:cw * 0.30)
            $dcy1 = [double]($script:py + $script:ch * 0.28)
            $dcx2 = [double]($script:px + $script:cw * 0.70)
            $dcy2 = [double]($script:py + $script:ch * 0.85)

            $dsRect = [LW]::FindWindowRect('DeepSeek')
            $ratio = 0.0
            if ($dsRect) {
                $rr = $dsRect.Split(',')
                $rl = [double]$rr[0]; $rt = [double]$rr[1]
                $rb = [double]$rr[2]; $rb2 = [double]$rr[3]
                $ox = [Math]::Max(0.0, [Math]::Min($dcx2, $rb) - [Math]::Max($dcx1, $rl))
                $oy = [Math]::Max(0.0, [Math]::Min($dcy2, $rb2) - [Math]::Max($dcy1, $rt))
                $area = [Math]::Max(1.0, ($dcx2 - $dcx1) * ($dcy2 - $dcy1))
                $ratio = ($ox * $oy) / $area
            }

            $minR = [double](Cfg '碰撞.认亲最小重叠' 0.15)
            $maxR = [double](Cfg '碰撞.认亲最大重叠' 0.85)
            $partial = ($ratio -ge $minR -and $ratio -le $maxR)

            if ($partial -and -not $script:dragging -and -not $script:physActive) {
                $script:dsDwell++
                $need = CfgFrames '碰撞.认亲停留秒数' 0.4
                if ($script:dsDwell -ge $need -and ($script:tick - $script:dsCool) -gt 300 -and $script:sleep -le 0) {
                    # ★ 场景台词刚说完 → 认亲等一会再说（避免两套台词交替刷屏）
                    if ($script:tick -lt $script:sceneQuietUntil) { } else {
                        $script:dsCool = $script:tick
                        $script:surprise = 60
                        try { $pl = Get-PoolLine 'act.dsmooch'; if ($pl) { Say-Something 0 @($pl) 60 } else { Say-Something 0 $script:dsLines 60 } } catch { Log-Err $_ 'ds' }
                        $script:dsQuietUntil = $script:tick + (CfgFrames '碰撞.认亲后静音秒数' 20)
                    }
                }
            }
            else {
                $script:dsDwell = 0
            }
        } catch { Log-Err $_ 'ds-check' }
    }

    # 跳跃结束那一帧 = 落地冲击（Q弹的关键）
    if ($script:happy -gt 0) {
        $script:happy--
        if ($script:happy -eq 0) {
            $script:sqV  = -0.75
            $script:earV += 1.5
        }
    }

    # ---------- Q弹弹簧（更软、阻尼更小 → duang 更明显）----------
    $script:sqV += -$script:sq * 0.175
    $script:sqV *= 0.878
    $script:sq  += $script:sqV
    if ($script:sq -gt 0.22)  { $script:sq = 0.22;  $script:sqV = 0 }
    if ($script:sq -lt -0.22) { $script:sq = -0.22; $script:sqV = 0 }

    # ---------- 耳朵弹簧（被形变带着甩）----------
    $script:earV += (-$script:earAng * 0.18) - ($script:sq * 0.045)
    $script:earV *= 0.86
    $script:earAng += $script:earV
    if ($script:earAng -gt 16)  { $script:earAng = 16 }
    if ($script:earAng -lt -16) { $script:earAng = -16 }

    # ---------- 眨眼（渐进闭合）----------
    if ($script:blink -gt 0) {
        $script:blink--
        if ($script:blink -eq 0 -and (Get-Random -Minimum 0 -Maximum 100) -lt [int](Cfg '互动.双眨概率百分比' 30)) {
            $script:blinkNext  = Get-Random -Minimum 8 -Maximum 14
            $script:blinkCount = 0
        }
    }
    else {
        $script:blinkCount++
        if ($script:blinkCount -ge $script:blinkNext) {
            $script:blinkLen = Get-Random -Minimum 6 -Maximum 11
            $script:blink    = $script:blinkLen
            $script:blinkCount = 0
            $script:blinkNext = Get-Random -Minimum (CfgFrames '互动.眨眼最短秒数' 1.8) -Maximum (CfgFrames '互动.眨眼最长秒数' 6)
        }
    }

    # ---------- 时不时做个小动作 ----------
    if ($script:happy -le 0) {
        $script:actCount++
        if ($script:actCount -ge $script:actNext) {
            $r = Get-Random -Minimum 0 -Maximum 100
            if ($r -lt 30) {
                $script:happy = [int]($script:hopLen * 0.7)     # 小蹦
                $script:sqV   = 0.60
                $script:earV += 0.8
            }
            elseif ($r -lt 62) {
                $script:earV += 2.0                             # 甩耳朵
            }
            elseif ($r -lt 84) {
                $script:sqV  += 0.45                            # 抖一下
                $script:earV += 1.2
            }
            else {
                $script:earV -= 1.6                             # 耳朵往后压
                $script:sqV  -= 0.30
            }
            $script:actCount = 0
            $script:actNext  = Get-Random -Minimum 200 -Maximum 700
        }
    }

    # ---------- 被摸：摸太急会生气，慢慢顺毛会开心 ----------
    $script:petHeat *= 0.972                       # 热度衰减快 → 决定"摸太急"
    if ($script:petHeat -lt 0.05) { $script:petHeat = 0.0 }

    if ($script:angry -gt 0) {
        $script:angry--
        if ($script:angry -eq 0) {
            # ★ 生气结束后的"冷落期"从 3 秒改成可配（默认 1 秒），太长了点击像死了一样 ✗
            $script:angryCD = CfgFrames '互动.生气后冷落秒数' 1.0
        }
    }
    elseif ($script:angryCD -gt 0) { $script:angryCD-- }

    if ($script:mood -gt 0) { $script:mood-- }
    if ($script:shy -gt 0)  { $script:shy-- }

    # 撞到后往后退
    if ($script:hurt -gt 0 -and ($script:recoilX -ne 0.0 -or $script:recoilY -ne 0.0)) {
        $script:px += $script:recoilX
        $script:py += $script:recoilY
        $script:recoilX *= 0.88
        $script:recoilY *= 0.88
        if ([Math]::Abs($script:recoilX) -lt 0.15) { $script:recoilX = 0.0 }
        if ([Math]::Abs($script:recoilY) -lt 0.15) { $script:recoilY = 0.0 }
    }

    # ---------- 撞窗口后的吃痛恢复 ----------
    if ($script:hurt -gt 0) {
        $script:hurt--
        $p = 1.0 - ($script:hurt / 120.0)
        if ($p -lt 0.25)     { $script:tears = $p / 0.25 }
        elseif ($p -gt 0.80) { $script:tears = (1.0 - $p) / 0.20 }
        else                 { $script:tears = 1.0 }
        # 每隔几帧掉一滴眼泪，会一路落到桌面上的地面线
        if ($script:hurt -lt 108 -and ($script:hurt % 6) -eq 0) { Spawn-Tears 1 }
        if ($script:hurt -eq 0) { $script:tears = 0.0 }
    }

    # ★ 吃痛结束 → 立刻清眼泪（避免"哭完了还在哭"的残留）
    if ($script:hurt -le 0 -and $script:tears -gt 0.0) { $script:tears = 0.0 }

    # 惊讶"!"淡出
    if ($script:surprise -gt 0) { $script:surprise-- }

    # ---------- 其他窗口列表（每约 1 秒刷一次）----------
    $script:winTick++
    if ($script:winTick -ge 60) {
        $script:winTick = 0
        try { $script:winRects = [LW]::OtherRects($script:form.Handle, $script:scr.Right, $script:scr.Bottom) }
        catch { $script:winRects = @() }
    }

    # ★ 入睡/醒来也走过渡动作（先下蹲/先顶起）
    if ($script:sleepWait -gt 0) {
        $script:sleepWait--
        if ($script:sleepWait -le 0 -and $script:sleepPending -gt 0) {
            $script:sleep = $script:sleepPending
            $script:sleepPending = 0
            try { Clear-Bubble } catch {}
        }
    }
    if ($script:sleepWakeWait -gt 0) {
        $script:sleepWakeWait--
        if ($script:sleepWakeWait -le 0) { $script:sleep = 0 }
    }

    # ★ 过渡动作：蹲到底的瞬间换图，然后回弹
    if ($script:swapLeft -gt 0) {
        $script:swapLeft--
        if ($script:swapLeft -le 0 -and $script:swapTo) {
            $via = [string]$script:swapTo.via
            if ($via -and -not $script:swapViaUsed -and $script:exprSprites -and $script:exprSprites.ContainsKey($via)) {
                # ★ 先亮"中间帧"（如蹲下），再切目标姿势
                $script:poseTmp = @{ name = $via; frames = 6; total = 6 }
                $script:swapViaUsed = $true
                $script:swapLeft = 7
                $script:sqV = 0.10
            }
            else {
                $nm = [string]$script:swapTo.name
                if ($nm) {
                    $f2 = [Math]::Max(24, [int]$script:swapTo.frames); $script:poseTmp = @{ name = $nm; frames = $f2; total = $f2 }
                } else {
                    $script:poseTmp = $null
                }
                $script:sqV = 0.20      # 回弹
                $script:swapTo = $null
            }
        }
    }

    # ★ 临时姿势倒计时（伸懒腰/吃/坐/看）
    if ($script:poseTmp) {
        $script:poseTmp.frames--
        if ($script:poseTmp.frames -le 0) {
            $script:poseTmp = $null
            # ★ 只有当没有"待切目标"时才回站姿（中间帧播完不能把目标冲掉）
            # ★ 不再闪 pose_起身（那张是跪姿抬腿，看着像断腿）→ 直接淡回站姿
        }
    }

    # ★ 长时间待机 → 随机小动作（坐/坐2/托腮/伸懒腰），不固定跪坐
    # ★ 待机动作：单一调度器（间隔 + 概率 + 可配动作池），只在完全正常时触发
    if (-not $script:poseTmp -and $script:sleep -le 0 -and -not $script:hopActive -and -not $script:dragging -and $script:angry -le 0 -and $script:hurt -le 0 -and [Math]::Abs($script:vx) -lt 0.55) {
        if ($script:tick -ge $script:sitIdleNext) {
            $script:sitIdleNext = $script:tick + (CfgFrames '行为.待机动作间隔秒数' 80)
            if ((Get-Random -Minimum 0 -Maximum 100) -lt [int](Cfg '行为.待机动作概率百分比' 40)) {
                # 动作池 = 配置里的列表 ∩ 已加载的姿势图（用户导入的 pose_xxx 也能自动加入）
                $want = @()
                if ([bool](Cfg '行为.允许坐下' $true))   { $want += @('pose_坐','pose_坐2') }
                if ([bool](Cfg '行为.允许张望' $true))   { $want += @('pose_看') }
                if ([bool](Cfg '行为.允许伸懒腰' $true)) { $want += @('pose_伸懒腰') }
                # 额外动作（可在 config 行为.额外动作列表 里填任何已导入的 pose_xxx）
                $want += @(Cfg '行为.额外动作列表' @())
                $pool = @()
                foreach ($w in $want) {
                    if ($script:exprSprites -and $script:exprSprites.ContainsKey([string]$w)) { $pool += [string]$w }
                }
                if ($pool.Count -gt 0) {
                    $pick = $pool[(Get-Random -Minimum 0 -Maximum $pool.Count)]
                    $sec  = 2.5 + (Get-Random -Minimum 0 -Maximum 250) / 100.0
                    Queue-PoseSwap $pick ([int]($sec * 1000.0 / [double]$script:timer.Interval)) 'pose_蹲下'
                    # 动作-台词绑定
                    try {
                        $pn = if ($pick -like '*坐*') { 'act.sit' }
                              elseif ($pick -like '*看*') { 'act.peek' }
                              elseif ($pick -like '*伸懒腰*') { 'act.stretch' }
                              else { '' }
                        if ($pn) { $pl = Get-PoolLine $pn; if ($pl) { Say-Something 0 @($pl) 18 } }
                    } catch {}
                    $script:sqV = -0.10
                }
            }
        }
    }
    if ($script:sitIdle -gt 0) { $script:sitIdle-- }

    # （张望已并入上面的待机动作池，这里关闭独立调度）
    if ($false -and -not $script:poseTmp -and $script:sleep -le 0 -and $script:tick -ge $script:peekNext) {
        $script:peekNext = $script:tick + (CfgFrames '行为.张望间隔秒数' 20)
        if ((Get-Random -Minimum 0 -Maximum 100) -lt [int](Cfg '行为.张望概率百分比' 45)) {
            Queue-PoseSwap 'pose_看' ([int](1.2 * 1000.0 / [double]$script:timer.Interval))
            $script:sqV = -0.06
            # ★ 看向鼠标：朝鼠标那一侧转头
            try {
                $mc = [System.Windows.Forms.Cursor]::Position
                $myCx = $script:px + $script:cw / 2.0
                if ([Math]::Abs($mc.X - $myCx) -gt 40) { $script:facingPending = if ($mc.X -gt $myCx) { 1 } else { -1 } }
            } catch {}
        }
    }

    # ★ 动作序列推进
    try { Update-PoseSeq } catch { Log-Err $_ 'pose-seq' }

    # ★ 首次见面：按节奏说那 10 句
    try { if (Get-Command Update-Intro -ErrorAction SilentlyContinue) { Update-Intro } } catch {}

    # ★ 条件台词（只在条件成立时说话）
    try { if (Get-Command Update-Conditions -ErrorAction SilentlyContinue) { Update-Conditions } } catch {}
        try { if (Get-Command Update-ToneState -ErrorAction SilentlyContinue) { Update-ToneState } } catch {}

    # ★ 用量阈值提醒（每 5 分钟查一次）
    try { if (Get-Command Check-UsageAlert -ErrorAction SilentlyContinue) { Check-UsageAlert } } catch {}
    try { if (Get-Command Update-BalanceBroadcast -ErrorAction SilentlyContinue) { Update-BalanceBroadcast } } catch {}

    # ★ 语音：合成完成的排队播放
    try { if (Get-Command Update-Voice -ErrorAction SilentlyContinue) { Update-Voice } } catch {}

    # ★ v2.5 窗口感知：偶尔根据你在用什么软件说一句
    if ($script:sleep -le 0) { try { Update-Scene } catch { Log-Err $_ 'scene' } }

    # ★ 睡觉时不允许有气泡残留（说一半睡着的台词要清掉）
    if ($script:sleep -gt 0 -and $script:bubbleText_) { try { Clear-Bubble } catch {} }

    # ★ 睡觉倒计时（睡够了自己醒）
    if ($script:sleep -gt 0) {
        $script:sleep--
        if ($script:sleep -le 0) {
            try { $l = Get-PoolLine 'act.wake'; if ($l) { Say-Something 0 @($l) 30 } } catch {}
            try { $l2 = Get-PoolLine 'act.stretch'; if ($l2) { Say-Something 0 @($l2) 26 } } catch {}
            Queue-PoseSwap 'pose_伸懒腰' ([int](1.6 * 1000.0 / [double]$script:timer.Interval))
        }
    }

    # v2：说话锁 / 表情锁衰减 + 表情互斥兜底
    # ★ 抚摸累计：鼠标停在她身上就累积，够了才害羞；离开慢慢清零
    if ([bool](Cfg '互动.悬停害羞' $true) -and $script:hovered -and -not $script:dragging -and $script:sleep -le 0 -and $script:hurt -le 0 -and $script:angry -le 0) {
        $script:hoverCount += (1.0 / 20.0)     # 每 20 帧 ≈ 0.32 秒 = 摸 1 次
        $needTouch = [int](Cfg '互动.害羞需要次数' 3)
        if ($script:hoverCount -ge $needTouch) {
            $script:hoverCount = 0.0
            try {
                $null = Set-Emotion 'shy'
                $script:shy      = 34
                $script:sqV      = -0.42
                $script:earV    += 2.4
                Spawn-Sparkles 8 ($script:ch / 2.0 - $script:imgH * 0.34) 1.0
                Queue-PoseSwap 'pose_被摸' ([int](1.2 * 1000.0 / [double]$script:timer.Interval))
                $pl = Get-PoolLine 'expr.shy'
                if (-not $pl) { $pl = Get-PoolLine 'act.pet' }
                if ($pl) { Say-Something 0 @($pl) 25 }
            } catch {}
        }
    }
    elseif (-not $script:hovered -and $script:hoverCount -gt 0) { $script:hoverCount = [Math]::Max(0.0, $script:hoverCount - 0.01) }
    if ($script:sayLock -gt 0) { $script:sayLock-- }
    if ($script:emoLock -gt 0) { $script:emoLock-- }
    try { Sync-EmotionExclusive } catch { Log-Err $_ 'emo-sync' }

    # v2：蹦跳 + 朝向翻转
    try { Update-Hop; Update-Facing } catch { Log-Err $_ 'hop-facing' }

    # 说话气泡计时
    if ($script:bubbleLife -gt 0) {
        $script:bubbleLife--
    }
    else {
        $script:talkCount++
        if ($script:talkCount -ge $script:talkNext -and -not $script:introActive) {
            try { Say-Something 0 $null 5 } catch { Log-Err $_ 'Say-Something' }
            $script:talkCount = 0
            $script:talkNext = Get-Random -Minimum (CfgFrames '气泡.最短间隔秒数' 14) -Maximum (CfgFrames '气泡.最长间隔秒数' 35)
        }
    }

    # 随机小动作（有一定概率改成"大跳 + 整体翻转"）
    if ($script:idleHop -and $script:happy -le 0 -and -not $script:hopActive -and -not $script:rollActive -and $script:sleep -le 0 -and $script:angry -le 0 -and $script:hurt -le 0 -and [Math]::Abs($script:vx) -lt 0.55) {
        $script:idleCount++
        if ($script:idleCount -ge $script:idleNext) {
            $hopP = [double](Cfg '行为.蹦跳概率百分比' 22)
            if ((Get-Random -Minimum 0.0 -Maximum 100.0) -lt $hopP) {
                Start-BigHop
            }
            else {
                $script:happy = [int]($script:hopLen * 0.65)
            }
            $script:idleCount = 0
            $script:idleNext = Get-Random -Minimum (CfgFrames '行为.duang最短秒数' 22) -Maximum (CfgFrames '行为.duang最长秒数' 50)
        }
    }

    # ★ 拖拽看门狗：鼠标已经松开、但没收到 MouseUp（在窗口外松手 / 在球状态下抓她）
    #   以前会卡成 dragging=true → 之后她再也不自己走（"移动她一下就不动了"）
    try {
        if ($script:dragging -and [System.Windows.Forms.Control]::MouseButtons -eq [System.Windows.Forms.MouseButtons]::None) {
            $script:dragging   = $false
            $script:physActive = $false
            $script:rollHold   = 0
            $script:rollActive = $false
            $script:rollAngle  = 0.0
        }
    } catch {}

    # ★ 滚动滞后：起步要快（|vx|>0.5），维持只需 0.15 → 边界/慢速时不会球↔站抽风
    try {
        $wantRoll = ([bool](Cfg '行为.滚动移动' $true) -and $script:autoWalk -and -not $script:hopActive -and -not $script:dragging -and -not $script:physActive -and -not $script:poseTmp -and $script:sleep -le 0 -and $script:hurt -le 0)
        $thr = if ($script:rollHold -gt 0) { 0.35 } else { 0.60 }
        if ($wantRoll -and ([Math]::Abs($script:vx) -gt $thr)) { $script:rollHold = 10 }
        elseif ($script:rollHold -gt 0) { $script:rollHold-- }
        # ★ 几乎不动时立刻站起来：以前慢速抖动会一直维持"球"姿势，看着像卡住不动
        if ((-not $wantRoll) -or ([Math]::Abs($script:vx) -lt 0.15)) { $script:rollHold = 0 }
    } catch {}

    # 随机游走：随机换向 / 随机停顿（吃痛时不走）
    # ---------- 物理拖拽：被甩出去后由物理接管移动 ----------
    $physMoved = $false
    try { $physMoved = Update-Physics } catch { Log-Err $_ 'phys' }

    if (-not $physMoved -and $script:autoWalk -and -not $script:dragging -and $script:hurt -le 0 -and $script:sleep -le 0 -and $script:quiet -le 0 -and $script:scale -le 0.45 -and -not $script:poseTmp) {
        # ---------- 像生物的游走 ----------
        # 核心区别：方向【不是重抽的，是转过去的】。
        # 每帧只微调一点点 → 像"心里那个念头在慢慢变"，而不是"程序又选了一个方向"。
        $spdMul = [double](Cfg '行为.游走速度倍率' 1.0)
        if ($script:rollActive) {
            # ★ 速度档位：1 慢 / 2 中 / 3 快 / 4 很快
            $lvl = [int](Cfg '行为.滚动速度档位' 3)
            if ($lvl -lt 1) { $lvl = 1 }; if ($lvl -gt 4) { $lvl = 4 }
            $lvlMap = @(0.8, 1.1, 1.6, 2.4)
            $spdMul = $spdMul * [double]$lvlMap[$lvl - 1] * [double](Cfg '行为.滚动速度倍率' 1.0)
        }
        $spdMax = 2.3

        # 1) 朝向：小随机游移 + 朝基准朝向缓慢回归
        $script:wanderAng += ((Get-Random -Minimum -1000 -Maximum 1000) / 1000.0) * 0.018
        $script:wanderAng += ($script:wanderBias - $script:wanderAng) * 0.0035
        if ($script:wanderAng -gt  [Math]::PI) { $script:wanderAng -= 2 * [Math]::PI }
        if ($script:wanderAng -lt -[Math]::PI) { $script:wanderAng += 2 * [Math]::PI }

        # 2) 速度也慢慢变，不会忽快忽慢
        $script:wanderSpd += ((Get-Random -Minimum -1000 -Maximum 1000) / 1000.0) * 0.012
        $script:wanderSpd += (1.4 - $script:wanderSpd) * 0.010   # 缓慢回归"舒服的速度"（不然会一直贴着上下限）
        if ($script:wanderSpd -lt 0.30)   { $script:wanderSpd = 0.30 }
        if ($script:wanderSpd -gt $spdMax) { $script:wanderSpd = $spdMax }

        # 3) 偶尔来点"小脾气"：停一下 / 窜一下 / 换个想去的大方向
        $script:wanderImpulse--
        if ($script:wanderImpulse -le 0) {
            $r = Get-Random -Minimum 0 -Maximum 100
            if ($r -lt 24) {
                $script:wanderSpd = 0.0                                        # 站住发会儿呆
                $script:wanderImpulse = if ($script:rollActive) { Get-Random -Minimum 70 -Maximum 180 } else { Get-Random -Minimum 130 -Maximum 340 }   # 滚动时少发呆
            }
            elseif ($r -lt 42) {
                $script:wanderSpd = $spdMax * 1.4                              # 窜一下
                $script:wanderImpulse = Get-Random -Minimum 80 -Maximum 180
            }
            else {
                # 换个"大方向" —— 但她是慢慢转过去的，不是瞬间掉头
                $script:wanderBias = (Get-Random -Minimum 0 -Maximum 628) / 100.0
                $script:wanderImpulse = Get-Random -Minimum 400 -Maximum 1100
            }
        }

        # 4) 呼吸：速度缓慢起伏 —— "活着"最便宜的一招
        $script:wanderBreath += 0.035
        $breathe = 1.0 + [Math]::Sin($script:wanderBreath) * 0.22

        $script:tvx = [Math]::Cos($script:wanderAng) * $script:wanderSpd * $breathe * $spdMul
        $script:tvy = 0.0   # ★ 只横向走：纵向漂移会让球"突然往上飘"（桌面宠物不该飞）

        # 5) 平滑跟随（比原来的 0.05 更柔和，加减速有"重量感"）
        $script:vx += ($script:tvx - $script:vx) * 0.045
        $script:vy += ($script:tvy - $script:vy) * 0.045

        $nx = $script:px + $script:vx
        $ny = $script:py + $script:vy

        # 屏幕边缘：反弹；撞得狠的时候也会吃痛
        # ★ 阈值从 1.6 降到 0.9 —— 原来她平时速度根本到不了 1.6，撞边缘永远不触发 ✗
        #   （撞到边缘会"眯眼+流泪"是这个演示的重点之一）
        # ⚠️ 必须反射 wanderAng/Bias —— 因为 tvx/tvy 每帧都从 wanderAng 重算，
        #    只反转 tvx 的话下一帧就被覆盖，她会一直顶着墙推。
        # ★ 撞墙冷却：冷却期内只夹住位置、不再反弹/吃痛（防止"顶着墙一直撞"）
        $wallCd = CfgFrames '行为.撞墙冷却秒数' 1.2
        $inCool = ($script:tick -lt $script:wallCool)
        if ($nx -lt $script:scr.Left -or ($nx + $script:cw) -gt $script:scr.Right) {
            $nx = [Math]::Max($script:scr.Left, [Math]::Min($script:scr.Right - $script:cw, $nx))
            if (-not $inCool) {
                $script:wallCool = $script:tick + $wallCd
                if ([Math]::Abs($script:vx) -gt 0.9 -and ($script:tick - $script:edgeCool) -gt 90) {
                    $script:edgeCool = $script:tick
                    Invoke-Hurt '' -Source 'bump'
                }
                $script:wanderAng  = [Math]::PI - $script:wanderAng
    $script:bounceFlag = 1
                $script:wanderBias = [Math]::PI - $script:wanderBias
                $script:vx  = -$script:vx * 0.55
            }
        }
        # ★ 用"图像底部"判断（图像在窗口里居中，窗口底还有 150px 留白）——以前用整个窗口高，往下拖会被拽回上面 ✗
        $footY = $ny + $script:ch - 164
        if ($ny -lt $script:scr.Top -or $footY -gt $script:floorBottom) {
            $ny = [Math]::Max($script:scr.Top, [Math]::Min($script:floorBottom - ($script:ch - 164), $ny))
            if (-not $inCool) {
                $script:wallCool = $script:tick + $wallCd
                if ([Math]::Abs($script:vy) -gt 0.7 -and ($script:tick - $script:edgeCool) -gt 90) {
                    $script:edgeCool = $script:tick
                    Invoke-Hurt '' -Source 'bump'
                }
                $script:wanderAng  = -$script:wanderAng
    $script:bounceFlag = 1
                $script:wanderBias = -$script:wanderBias
                $script:vy  = -$script:vy * 0.55
            }
        }

        # （被框住检测已统一到 tick 开头的 Check-Trapped，这里不再重复）


        # （碰撞检测已移到自动游走分支外面 —— 每帧都跑 ✓）
        $script:px = $nx
        $script:py = $ny
    }

    # ================= v2 碰撞：进入检测 + 随机反应 + 困住状态 =================
    if ([bool](Cfg '碰撞.启用' $true) -and $script:winRects.Count -ge 4) {
        $cbx = $script:px + $script:cw * 0.24
        $cby = $script:py + $script:ch * 0.16
        $cbr = $script:px + $script:cw * 0.76
        $cbb = $script:py + $script:ch * 0.88

        # 当前压在哪一个窗口上
        $hitIdx = -1
        for ($w = 0; $w + 3 -lt $script:winRects.Count; $w += 4) {
            if ($cbr -gt $script:winRects[$w] -and $cbx -lt $script:winRects[$w+2] -and
                $cbb -gt $script:winRects[$w+1] -and $cby -lt $script:winRects[$w+3]) { $hitIdx = $w; break }
        }

        if ($hitIdx -ge 0) {
            $inDS = [LW]::HasWindowInRect([int]$cbx, [int]$cby, [int]$cbr, [int]$cbb, $script:form.Handle, 'DeepSeek')

            # 这一帧是不是"从外面刚进来"
            $entered = $true
            if ($script:prevBody) {
                $pl = $script:prevBody[0]; $pt = $script:prevBody[1]
                $pr = $script:prevBody[2]; $pb = $script:prevBody[3]
                if ($pr -gt $script:winRects[$hitIdx] -and $pl -lt $script:winRects[$hitIdx+2] -and
                    $pb -gt $script:winRects[$hitIdx+1] -and $pt -lt $script:winRects[$hitIdx+3]) { $entered = $false }
            }

            $spd = [Math]::Sqrt($script:vx * $script:vx + $script:vy * $script:vy)

            if ($entered -and -not $script:dragging -and $spd -ge [double](Cfg '碰撞.速度门槛' 0.9) -and ($script:tick - $script:enterCool) -gt 45) {
                $script:enterCool = $script:tick
                if ($inDS) {
                    # 在自家软件里 → 不哭不眯眼，只有撞击特效 + 震惊（认亲台词由停留判定负责）
                    $script:hurt  = 0
                    $script:tears = 0.0
                    # ★ 同样先站起来（清滚动状态），否则会以球形态贴着自家窗口
                    $script:rollHold   = 0
                    $script:rollActive = $false
                    $script:rollAngle  = 0.0
                    $script:sqV   = -0.45
                    $script:earV += 2.2
                    $script:surprise = 90
                    $null = Set-Emotion 'surprise' -Force
                }
                else {
                    $hitTitle = [LW]::TitleOverlapping([int]$cbx, [int]$cby, [int]$cbr, [int]$cbb, $script:form.Handle)
                    if ($script:sleep -le 0) { Invoke-CollisionReaction $spd $hitTitle }
                }
            }
            elseif (-not $entered -and [bool](Cfg '碰撞.困住会说话' $false) -and $script:sleep -le 0) {
                # 已经在窗口里 → 很久才小声嘀咕一次（原来 9 秒一次，太吵 ✗）
                if (($script:tick - $script:trappedCool2) -gt (CfgFrames '碰撞.困住说话间隔秒数' 45)) {
                    $script:trappedCool2 = $script:tick
                    if ((Get-Random -Minimum 0 -Maximum 100) -lt 30) {
                        $script:earV += 1.2
                        try { $pl = Get-PoolLine 'act.trapped'; if ($pl) { Say-Something 0 @($pl) 40 } else { Say-Something 0 $script:trappedLines 40 } } catch { Log-Err $_ 'trapped2' }
                    }
                }
            }
        }
        $script:prevBody = @($cbx, $cby, $cbr, $cbb)
    }
    else {
        $script:prevBody = $null
    }

    # 粒子更新（带重力，落到地面就摊平）
    $script:groundY = $script:ch / 2.0 - 14.0 + $script:imgH * 0.5 + 6.0
    for ($i = $script:particles.Count - 1; $i -ge 0; $i--) {
        $p = $script:particles[$i]
        $p.x += $p.vx
        $p.y += $p.vy
        $p.vy += 0.34
        $p.vx *= 0.985

        if ($p.y -ge $script:groundY -and $p.vy -gt 0) {
            # 【不要】把 y 拉回地面线！
            # 眼泪落地前速度约 10px/帧，硬拉回去会让它"倒着跳一下" —— 就是你说的回缩。
            # 位置保持原样，渲染时统一画在地面线上即可。
            $p.vy   = 0.0
            $p.land = 1
        }
        if ($p.land -gt 0) {
            $p.vx *= 0.78
            $p.life -= 2.5            # 落地后消失更快
        }
        $p.life--
        if ($p.life -le 0) { $script:particles.RemoveAt($i) }
    }

    # 渲染并上屏
    try { Render-Frame } catch { Log-Err $_ 'Render-Frame' }
    $null = [LW]::SetBitmap($script:form.Handle, $script:canvas,
        [int][Math]::Round($script:px), [int][Math]::Round($script:py),
        [byte]$script:constAlpha)
})
$timer.Start()

# ============================================================
#  8. 鼠标
# ============================================================
$script:form.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragging   = $true
        $script:mouseStart = [System.Windows.Forms.Cursor]::Position
        $script:formStartX = $script:px
        $script:formStartY = $script:py
        # ★ 抓住的瞬间：停掉物理（否则她一边飞一边被你拖 → 鬼畜抖动 ✗）
        try {
            if ($script:physActive -or $script:physVX -ne 0.0 -or $script:physVY -ne 0.0) {
                $script:physActive = $false
                $script:physVX = 0.0
                $script:physVY = 0.0
                $script:physCool = $script:tick
                $script:sqV = -0.18
            }
        } catch {}
        try { Reset-DragTrail } catch {}
    }
})

$script:form.Add_MouseMove({
    param($sender, $e)
    if ($script:dragging) {
        $p = [System.Windows.Forms.Cursor]::Position
        $script:px = $script:formStartX + $p.X - $script:mouseStart.X
        $script:py = $script:formStartY + $p.Y - $script:mouseStart.Y
        try { Push-DragTrail } catch {}
    }
})

# 松手：先判断是不是"甩"，不是才贴边吸附
$script:form.Add_MouseUp({
    param($sender, $e)
    if (-not $script:dragging) { return }
    $script:dragging = $false

    $flung = $false
    try { Start-Fling; $flung = $script:physActive 
    try { $script:quiet = [int]([double](Cfg '行为.动作后安静秒数' 5) * 1000.0 / [double]$script:timer.Interval) } catch {}} catch {}
    if ($flung) {
        # 刚甩出去：先给一小段冷却，避免"松手立刻摔疼"
        $script:physCool = $script:tick
        return
    }
    # 轻轻放下：也清掉残留状态，避免"松手弹簧"
    try { $script:physActive = $false; $script:physVX = 0.0; $script:physVY = 0.0 } catch {}

    $snap = [int](Cfg '行为.贴边吸附像素' 26)
    $b = $script:scr
    if ([Math]::Abs($script:px - $b.Left) -lt $snap) { $script:px = $b.Left }
    if ([Math]::Abs(($script:px + $script:cw) - $b.Right) -lt $snap) { $script:px = $b.Right - $script:cw }
    if ([Math]::Abs($script:py - $b.Top) -lt $snap) { $script:py = $b.Top }
    if ([Math]::Abs(($script:py + $script:ch - 164) - $b.Bottom) -lt $snap) { $script:py = $b.Bottom - ($script:ch - 164) }
})

# 单击：蹦一下 + 星火
$script:form.Add_MouseClick({
    param($sender, $e)
    # ★ 点击音效（她本身的操作声，不是视频里的）
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { try { Play-Sfx 'click' } catch {} }
    # ★ 首次见面：点一下把她叫醒，然后开始说那 10 句
    try { if (Get-Command Wake-Intro -ErrorAction SilentlyContinue) { if (Wake-Intro) { return } } } catch {}
    if ($script:paused) { return }
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        # ★ 睡觉时点不动她（只有"喂她吃饭"能叫醒）
        if ($script:sleep -gt 0) { return }

        # 生气中 → 不理你
        if ($script:angry -gt 0) {
            $script:sqV   = 0.35
            $script:earV += 2.0
            return
        }

        # ★ 冷落期（生气刚结束）→ 摸一下就消气，不再"点了没反应" ✗
        if ($script:angryCD -gt 0) {
            $script:angryCD = 0
            $script:sqV     = 0.24
            $script:earV   += 1.6
            try { $pl = Get-PoolLine 'expr.shy'; if ($pl) { Say-Something 0 @($pl) 30 } else { Say-Something 0 $script:shyLines 30 } } catch { Log-Err $_ 'calm' }
            return
        }

        # ★ v2.1 哭/吃痛中 → 戳她只会更委屈：给一点点反应，不冒开心特效
        if ($script:hurt -gt 0) {
            $script:sqV   = 0.20
            $script:earV += 1.2
            return
        }

        # 左键 = 戳她；戳太多次会生气
        try { Mark-Interact } catch {}
        $script:petHeat += 2.0
        $script:happy    = $script:hopLen
        $script:sqV      = 0.62                # 起跳时拉长
        $script:shy      = 20                  # ★ 被戳 = 脸红，不是惊讶（原来会"惊讶脸+害羞话"✗）
        Spawn-Sparkles 16 ($script:ch / 2.0 - $script:imgH * 0.34) 1.20

        if ($script:petHeat -ge [double](Cfg '互动.戳几下会生气' 6.0)) {
            # 戳太多了 → 生气 + 生气气泡
            $null = Set-Emotion 'angry' -Force
            $script:poseTmp = $null
            $script:angry   = CfgFrames '互动.生气持续秒数' 4.2
            $script:mood    = 0
            $script:shy     = 0
            $script:hurt    = 0
            $script:tears   = 0.0
            $script:petHeat = 0.0
            $script:petSlow = 0.0
            $script:sqV     = 0.58
            $script:earV   += 3.4
            try { $pl = Get-PoolLine 'expr.angry'; if ($pl) { Say-Something 0 @($pl) 50 } else { Say-Something 0 $script:angryLines 50 } } catch { Log-Err $_ 'angry' }
        }
        else {
            # ★ 每次点击都要有反应：清掉说话锁 + 用"被戳"专属池（0.35 秒节流防连点刷屏）
            if (($script:tick - $script:lastPetSay) -gt 22) {
                $script:lastPetSay = $script:tick
                $script:sayLock = 0
                try {
                    $petLine = Get-PoolLine 'act.pet'
                    if ($petLine) { Say-Something 0 @($petLine) 35 -force }
                    else { Say-Something 0 $null 20 }
                } catch { Log-Err $_ 'click' }
            }
        }
    }
})

# 双击：可配多种反应（摸头 / 转圈 / 躲开 / 喂饭 / 无 / 随机）——聊天只在右键菜单
$script:form.Add_MouseDoubleClick({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    try { Play-Sfx 'click' } catch {}
    if ($script:paused) { return }
    $act = [string](Cfg '互动.双击行为' '随机')
    if ($act -eq '无') { return }
    if ($act -eq '聊天') { $script:happy = $script:hopLen; Spawn-Sparkles 10; try { Show-ChatInput } catch { Log-Err $_ 'chat-open' }; return }
    if ($act -eq '随机') {
        $r = Get-Random -Minimum 0 -Maximum 100
        if     ($r -lt 50) { $act = '摸头' }
        elseif ($r -lt 75) { $act = '转圈' }
        elseif ($r -lt 88) { $act = '躲开' }
        else               { $act = '喂饭' }
    }
    if ($script:sleep -gt 0 -or $script:hurt -gt 0) { return }
    # ★ 生气中 / 刚消气：双击也不给好脸色（以前双击会直接跳开心，生气像假的）
    if ($script:angry -gt 0) { $script:sqV = 0.35; $script:earV += 2.0; return }
    if ($script:angryCD -gt 0) { $script:sqV = 0.24; $script:earV += 1.6; return }
    # ★ 原「双击扣 2.6 热度」已删：它会让连点永远攒不到生气阈值
    #   （现在的顺序是：点两下 → 转圈/摸头，再点几下 → 生气）
    switch ($act) {
        '喂饭' {
            try { Mark-Feed } catch {}
            try { Queue-PoseSwap 'pose_吃' ([int](3.2 * 1000.0 / [double]$script:timer.Interval)) } catch {}
            $script:happy = $script:hopLen
            try { $script:sayLock = 0; $l = Get-PoolLine 'act.eat'; if ($l) { Say-Something 0 @($l) 40 -force } } catch {}
        }
        '躲开' {
            $script:petHeat += 1.2
            $script:sqV   = 0.30
            $script:earV += 2.2
            $away = if (($script:px + $script:cw / 2) -lt ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Width / 2)) { 1 } else { -1 }
            $script:vx = $away * 1.5
            try { $script:sayLock = 0; $l = Get-PoolLine 'act.pet'; if ($l) { Say-Something 0 @($l) 38 -force } } catch {}
        }
        '转圈' {
            $script:happy = $script:hopLen
            $script:spinTotal = 30
            $script:spinLeft  = 30
            Spawn-Sparkles 12
            try { Queue-PoseSwap 'pose_跳' ([int](0.35 * 1000.0 / [double]$script:timer.Interval)) } catch {}
            try { $script:sayLock = 0; $l = Get-PoolLine 'expr.happy'; if ($l) { Say-Something 0 @($l) 36 -force } } catch {}
        }
        default {
            # 摸头
            $script:happy = $script:hopLen
            $script:shy   = [Math]::Max([int]$script:shy, 26)
            Spawn-Sparkles 8
            $null = Set-Emotion 'shy'
            try { Queue-PoseSwap 'pose_被摸' ([int](0.9 * 1000.0 / [double]$script:timer.Interval)) } catch {}
            try { $script:sayLock = 0; $pl = Get-PoolLine 'expr.shy'; if ($pl) { Say-Something 0 @($pl) 32 -force } else { Say-Something 0 $script:shyLines 32 -force } } catch { Log-Err $_ 'dblclick-pet' }
        }
    }
})

# 半透明（改的是上屏时用的全局 alpha，不再用 Form.Opacity）
$script:form.Add_MouseEnter({
    $script:hovered = $true
    try { Mark-Interact } catch {}
    if ($script:paused) { return }
    $script:constAlpha = 255

    # 右键菜单开着时别乱动（菜单会反复触发进出事件，这就是"右键冲突"的根源）
    if ($script:menuOpen) { return }

    if (($script:tick - $script:lastHover) -gt 38) {
        $script:lastHover = $script:tick

        # 生气中 → 躲开，不给好脸色（冷落期算已消气，可以摸）
        if ($script:angry -gt 0) {
            $script:sqV   = 0.30
            $script:earV += 2.0
            return
        }

        # ★ v2.1 哭/吃痛中 → 不给摸反应（否则爱心会和哭脸/星星打架 ✗）
        if ($script:hurt -gt 0) { return }
        # ★ 悬停害羞开关（设置里可关）
        if (-not [bool](Cfg '互动.悬停害羞' $true)) { return }
        # ★ 刚碰到：只有轻微反应（耳朵抖），不立刻害羞；害羞由 tick 里"摸够时间"决定
        $script:earV += 1.2
        $script:sqV  = -0.10
        return

        # 悬停＝害羞：脸红 + 缩一下 + 耳朵弹起 + 小星火 + 冒"!"
        # （悬停永远不会生气，生气只归左键管）
        if (-not (Set-Emotion 'shy')) { return }
        $script:shy      = 34
        $script:sqV      = -0.42
        $script:earV    += 2.4
        # ★ 悬停不设惊讶（否则害羞状态显示惊讶脸 ✗）
        Spawn-Sparkles 8 ($script:ch / 2.0 - $script:imgH * 0.34) 1.0

        if ((Get-Random -Minimum 0 -Maximum 100) -lt 45) {
            try { $pl = Get-PoolLine 'expr.shy'; if ($pl) { Say-Something 0 @($pl) 30 } else { Say-Something 0 $script:shyLines 30 } } catch { Log-Err $_ 'shy' }
        }

        # 顺毛：慢慢凑够 5 下 → 开心起来
        $script:petSlow += 1
        if ($script:petSlow -ge [int](Cfg '互动.顺毛几下会开心' 5)) {
            $script:petSlow = 0.0
            if (Test-EmotionAllowed 'mood') {
                $null = Set-Emotion 'mood'
                $script:shy     = 0
                $script:mood    = 420
                $script:angry   = 0
                $script:sqV     = -0.36
                $script:earV   += 1.6
                Spawn-Sparkles 20 ($script:ch / 2.0 - $script:imgH * 0.36) 1.30
                try { $pl = Get-PoolLine 'expr.happy'; if ($pl) { Say-Something 0 @($pl) 25 } else { Say-Something 0 $script:happyLines 25 } } catch { Log-Err $_ 'happy' }
            }
        }
    }
})
$script:form.Add_MouseLeave({
    $script:hovered = $false
    if (-not $script:menuOpen) {
        $script:constAlpha = if ($script:translucent) { 165 } else { 255 }
    }
})

# ============================================================
# 右键菜单自绘样式
$menuFile = Join-Path $PSScriptRoot 'deskpet-menu.ps1'
if (Test-Path -LiteralPath $menuFile) { try { . $menuFile } catch { Log-Err $_ 'menu-load' } }

#  9. 右键菜单
# ============================================================
$menu = New-Object System.Windows.Forms.ContextMenuStrip
try { Install-DshMenuStyle $menu } catch {}

# ★ 喂饭：她用 pose_吃 吃 4 秒
$script:itemFeed = $menu.Items.Add("喂她吃饭")
$script:itemFeed.Add_Click({
    try {
        $wasSleep = ($script:sleep -gt 0)
        if ($wasSleep) {
            # ★ 只有饭能吵醒她
            $script:sleep = 0
            $script:sqV = 0.26
            # ★ 被饭叫醒：先伸懒腰，再说「被香醒了」类台词（没有才回落到吃的台词）
            $l = $null
            try { $l = Get-PoolLine 'act.wakeFood' } catch {}
            if (-not $l) { try { $l = Get-PoolLine 'act.eat' } catch {} }
            if ($l) { try { Say-Something 0 @($l) 45 -force } catch {} }
            try { Mark-Feed } catch {}
            # ★ 被香醒的完整动作：先伸懒腰 → 再抱着饭（pose_吃）
            try {
                Start-PoseSeq @(
                    @{ name = 'pose_伸懒腰'; ms = 1100 },
                    @{ name = 'pose_吃';     ms = 4500 }
                )
            } catch {
                Queue-PoseSwap 'pose_伸懒腰' ([int](1.0 * 1000.0 / [double]$script:timer.Interval))
            }
            return
        }
        try { Mark-Feed } catch {}
        Queue-PoseSwap 'pose_吃' ([int](4.0 * 1000.0 / [double]$script:timer.Interval))
        $script:happy = $script:hopLen
        try { $l = Get-PoolLine 'act.eat'; if ($l) { Say-Something 0 @($l) 30 } } catch {}
    } catch {}
})

# ★ 让她睡觉
$script:itemSleep = $menu.Items.Add("让她睡觉")
$script:itemSleep.Add_Click({
    try {
        # ★ 先用"躺下"过渡帧，再进入睡眠
        try { Queue-PoseSwap 'pose_睡' 0 '' } catch {}
        $script:sleep = [int](30.0 * 1000.0 / [double]$script:timer.Interval)
        try { Clear-Bubble } catch {}   # 睡着立刻闭嘴
        $script:poseTmp = $null
        try { Say-Something 0 @('那我睡一会……') 30 } catch {}
    } catch {}
})

$null = $menu.Items.Add("-")

$script:itemAuto = $menu.Items.Add("自动游走")
$script:itemAuto.CheckOnClick = $true
$script:itemAuto.Checked = $script:autoWalk

$script:itemIdle = $menu.Items.Add("随机小动作")
$script:itemIdle.CheckOnClick = $true
$script:itemIdle.Checked = $script:idleHop

# 暂停：她定住不动，但还看得见（窗口保留最后一帧）
$script:itemPause = $menu.Items.Add("暂停")
$script:itemPause.CheckOnClick = $true
$script:itemPause.Checked = $false
$script:itemPause.Add_Click({
    try {
        if ($script:itemPause.Checked) {
            # ★ 暂停前先"扶正"：清掉倾斜/翻转/转圈/滚动/弹簧残留，再冻住
            #   不然她可能停在半个动作里（歪着、压扁、翻着）被冻成截图 ✗
            $script:hopActive   = $false
            $script:hopFlip     = 0.0
            $script:hopSettle   = 0
            $script:spinLeft    = 0
            $script:spinSquash  = 1.0
            $script:spinMirror  = $false
            $script:spinBob     = 0.0
            $script:dragLean    = 0.0
            $script:turnSx      = 1.0
            $script:rollHold    = 0
            $script:rollActive  = $false
            $script:rollAngle   = 0.0
            $script:sq          = 0.0
            $script:sqV         = 0.0
            $script:vx          = 0.0
            $script:tvx         = 0.0
            $script:pauseFixFrames = 3
        }
        $script:paused = $script:itemPause.Checked
    } catch {}
})

$script:itemToolMode = $menu.Items.Add("工具模式")
$script:itemToolMode.CheckOnClick = $true
$script:itemToolMode.Checked = [bool](Cfg '模式.工具模式' $false)
$script:itemToolMode.Add_Click({ try { Set-ToolMode $script:itemToolMode.Checked } catch { Log-Err $_ 'toolmode' } })

$null = $menu.Items.Add("-")

# ★ 用量 / 余额：收进子菜单，顶层不再堆 4 行
$subUsage = $menu.Items.Add("用量 / 余额")
$script:itemUsage = $subUsage.DropDownItems.Add("今日用量")
$script:itemUsage.Add_Click({
    try {
        $u = Get-DshUsage
        $txt = Format-UsageText $u
        try { Say-Something 0 @($txt) 55 -force } catch {}
    } catch {}
})
$script:itemBoard = $subUsage.DropDownItems.Add("用量看板…")
$script:itemBoard.Add_Click({ try { Show-UsageBoard } catch { Log-Err $_ 'board-open' } })
$script:itemUsageWeek = $subUsage.DropDownItems.Add("本周用量")
$script:itemUsageWeek.Add_Click({
    try {
        $w = Get-DshUsageWeek
        if (-not $w.ok) { Say-Something 0 @('读不到历史数据。') 50; return }
        $txt = '最近七天一共 ¥' + [Math]::Round($w.total, 2) + '，平均每天 ¥' + $w.avg + '。'
        try { Say-Something 0 @($txt) 55 -force } catch {}
    } catch {}
})
# ★ 充值：一键打开充值页（默认 DeepSeek 平台，设置里可改网址）
$script:itemRecharge = $subUsage.DropDownItems.Add("充值…")
$script:itemRecharge.Add_Click({ try { Open-Recharge } catch { Log-Err $_ 'recharge' } })
# ★ 今天用了多久 ▸ 打开时动态列出每个应用用了多久（只算"前台 + 有操作"的时间）
$script:subTimeTrack = $menu.Items.Add("今天用了多久")
$script:ttMenu = $script:subTimeTrack

# ★ 外观：大小/透明度/置顶/自启/物理 都收进来
$subLook = $menu.Items.Add("外观")
$script:itemScaleS = $subLook.DropDownItems.Add("大小：小")
$script:itemScaleM = $subLook.DropDownItems.Add("大小：中")
$script:itemScaleL = $subLook.DropDownItems.Add("大小：大")
$script:itemScaleXL = $subLook.DropDownItems.Add("大小：特大")
foreach ($it in @($script:itemScaleS, $script:itemScaleM, $script:itemScaleL, $script:itemScaleXL)) {
    $it.CheckOnClick = $false
}
$script:itemTrans = $subLook.DropDownItems.Add("半透明")
$script:itemTrans.CheckOnClick = $true
$script:itemTrans.Checked = $script:translucent
$script:itemTop = $subLook.DropDownItems.Add("始终置顶")
$script:itemTop.CheckOnClick = $true
$script:itemTop.Checked = $true
$script:itemStartup = $subLook.DropDownItems.Add("开机自动启动")
$script:itemStartup.CheckOnClick = $true
$script:itemPhys = $subLook.DropDownItems.Add("物理拖拽")
$script:itemPhys.CheckOnClick = $true
$script:itemPhys.Checked = $true

$null = $menu.Items.Add("-")

# --- 聊天 ---
$script:itemChat = $menu.Items.Add("聊天…")
$script:itemChatEnable = $menu.Items.Add("启用聊天")
$script:itemChatEnable.CheckOnClick = $true
$script:itemChatEnable.Checked = $true

# --- 设置 ---
$script:itemSettings = $menu.Items.Add("设置…")

$null = $menu.Items.Add("-")

$script:itemExit = $menu.Items.Add("退出")

# --- 事件 ---
$script:itemAuto.Add_Click({
    param($sender, $e)
    $script:autoWalk = $sender.Checked
    $script:happy = $script:hopLen
})

$script:itemIdle.Add_Click({
    param($sender, $e)
    $script:idleHop = $sender.Checked
    $script:idleCount = 0
})

$script:itemTrans.Add_Click({
    param($sender, $e)
    $script:translucent = $sender.Checked
    $script:constAlpha = if ($script:translucent -and -not $script:hovered) { 165 } else { 255 }
})

# --- 聊天菜单事件 ---
$script:itemChat.Add_Click({
    param($sender, $e)
    try { Show-ChatInput } catch { Log-Err $_ 'chat-menu' }
})

$script:itemChatEnable.Add_Click({
    param($sender, $e)
    try { Toggle-ChatEnable ([bool]$sender.Checked) } catch { Log-Err $_ 'chat-toggle' }
})

$script:itemPhys.Add_Click({
    param($sender, $e)
    try { Toggle-Physics ([bool]$sender.Checked) } catch { Log-Err $_ 'phys-toggle' }
})

$script:itemSettings.Add_Click({
    param($sender, $e)
    try {
        # 设置面板居中弹出：先把她挪到屏幕右侧，别让面板压住她
        $script:px = [double]$script:scr.Right - [double]$script:cw - 26
        if ($script:px -lt $script:scr.Left) { $script:px = $script:scr.Left }
    } catch {}
    try { Show-Settings } catch { Log-Err $_ 'settings' }
})

function Set-PetScale {
    param([double]$s)
    if (-not $script:origImage) { return }
    $script:scale = $s
    # ★ 特大号降刷新率：666x1065 每帧全量重绘太重，30fps 足够（画面不卡）
    try {
        if ($script:timer) {
            $script:timer.Interval = if ($s -gt 0.39) { 33 } else { [int](Cfg '显示.帧率毫秒' 16) }
        }
    } catch {}
    Update-PetBitmap

    $script:cw = [Math]::Max($script:imgW + 90, 300)
    $script:ch = $script:imgH + 300

    if ($script:canvas) { $script:canvas.Dispose() }
    $script:canvas = New-Object System.Drawing.Bitmap(
        $script:cw, $script:ch, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $script:form.ClientSize = [System.Drawing.Size]::new($script:cw, $script:ch)

    $x = [Math]::Min($script:px, $script:scr.Right  - $script:cw)
    $y = [Math]::Min($script:py, $script:floorBottom - ($script:ch - 164))
    $script:px = [int][Math]::Max($x, $script:scr.Left)
    $script:py = [int][Math]::Max($y, $script:scr.Top)

    # 特大号：安静站着（录素材用；不改开关，切回中/大就恢复游走）
    if ($s -gt 0.39) { $script:quiet = 600 } else { $script:quiet = 0 }   # 切回中/大：立刻恢复能走

    # ★ 缩放值要跟着【当前基准图分辨率】走 —— 以前 pet.png 是 288×382，
    #   写死 0.6/0.75/1.0 没问题；现在基准是 1152×1530，
    #   0.6 出来就是 691px，比默认的 323px 大一倍多 ✗
    #   所以改成 0.18 / 0.23 / 0.28（对应 207 / 265 / 323 宽）✓
    $script:itemScaleS.Checked = ($s -le 0.205)
    $script:itemScaleM.Checked = ($s -gt 0.205 -and $s -le 0.255)
    $script:itemScaleL.Checked = ($s -gt 0.255 -and $s -le 0.4)
    if ($script:itemScaleXL) { $script:itemScaleXL.Checked = ($s -gt 0.4) }

    # ★ 把选择写进 config.json —— 不然重启就变回默认值 ✗
    try {
        $cfgP = Join-Path $PSScriptRoot 'config.json'
        if (Test-Path $cfgP) {
            $raw = Get-Content $cfgP -Raw -Encoding UTF8
            $raw = $raw -replace '("缩放"\s*:\s*)[0-9.]+', ('${1}' + $s.ToString([System.Globalization.CultureInfo]::InvariantCulture))
            [System.IO.File]::WriteAllText($cfgP, $raw, (New-Object System.Text.UTF8Encoding($true)))
        }
    } catch { }
}

# 默认勾选要跟 config 里的实际缩放一致（不能写死"中"✗）
$script:itemScaleS.Checked = ($script:scale -le 0.205)
$script:itemScaleM.Checked = ($script:scale -gt 0.205 -and $script:scale -le 0.255)
$script:itemScaleL.Checked = ($script:scale -gt 0.255 -and $script:scale -le 0.4)
$script:itemScaleXL.Checked = ($script:scale -gt 0.4)
$script:itemScaleS.Add_Click({ Set-PetScale 0.18 })
$script:itemScaleM.Add_Click({ Set-PetScale 0.23 })
$script:itemScaleL.Add_Click({ Set-PetScale 0.28 })
$script:itemScaleXL.Add_Click({ Set-PetScale 0.50 })

$script:itemTop.Add_Click({
    param($sender, $e)
    $script:form.TopMost = $sender.Checked
})

# 开机自启（用户级启动项，不需要管理员）
$script:itemStartup.Add_Click({
    param($sender, $e)
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $name   = 'DSHDeskPet'
    if ($sender.Checked) {
        $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
               $script:selfPath + '"'
        New-ItemProperty -Path $runKey -Name $name -Value $cmd -PropertyType String -Force | Out-Null
    }
    else {
        Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
    }
})

$script:itemExit.Add_Click({
    param($sender, $e)
    try { if (Get-Command Save-TimeTrack -ErrorAction SilentlyContinue) { Save-TimeTrack } } catch {}
    $script:form.Close()
})

# 菜单打开前同步"开机启动"的勾，同时暂停一切"摸"的反应（右键冲突的根源就在这）
$menu.Add_Opening({
    $script:menuOpen = $true
    try { Play-Sfx 'click' } catch {}
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $v = (Get-ItemProperty -Path $runKey -Name 'DSHDeskPet' -ErrorAction SilentlyContinue).DSHDeskPet
    $script:itemStartup.Checked = [bool]$v
    # 每次打开菜单都刷新"今天用了多久"的列表
    try { Update-TimeTrackMenu } catch {}
})

# 菜单关闭 → 恢复，并把"刚被摸过"的状态清掉，免得关完菜单又被判定为摸了一下
$menu.Add_Closed({
    $script:menuOpen  = $false
    $script:lastHover = $script:tick
    $script:shy       = 0
    $script:constAlpha = if ($script:translucent -and -not $script:hovered) { 165 } else { 255 }
})

$script:form.ContextMenuStrip = $menu

# ============================================================
#  9.5 聊天模块（独立文件，缺失也不影响主程序）
# ============================================================
# 用量看板（读 DSH 本地用量文件）
$usageFile = Join-Path $PSScriptRoot 'deskpet-usage.ps1'
if (Test-Path -LiteralPath $usageFile) {
    try { . $usageFile } catch { Log-Err $_ 'usage-load' }
}

# 台词池系统（专属池 + 通用兜底 + 语义近似）
$poolFile = Join-Path $PSScriptRoot 'deskpet-pools.ps1'
if (Test-Path -LiteralPath $poolFile) {
    try {
        . $poolFile
        $poolN = Initialize-Pools (Join-Path $PSScriptRoot '台词包')
        Write-Host ("台词池：加载 " + $poolN + " 条（" + (Get-PoolNames).Count + " 个池）")
    } catch { Log-Err $_ 'pools-load' }
}

# 首次见面（只触发一次）
$introFile = Join-Path $PSScriptRoot 'deskpet-intro.ps1'
if (Test-Path -LiteralPath $introFile) {
    try { . $introFile } catch { Log-Err $_ 'intro-load' }
}

# 条件台词引擎（鼠标乱晃/久无操作/深夜/凑近又跑/看代码太久）
$condFile = Join-Path $PSScriptRoot 'deskpet-cond.ps1'
if (Test-Path -LiteralPath $condFile) {
    try { . $condFile } catch { Log-Err $_ 'cond-load' }
}

# 状态语气（饿/困/吃醋/被戳烦）
$toneFile = Join-Path $PSScriptRoot 'deskpet-tone.ps1'
if (Test-Path -LiteralPath $toneFile) {
    try { . $toneFile } catch { Log-Err $_ 'tone-load' }
}
# 语音合成（她真的开口说话）
$voiceFile = Join-Path $PSScriptRoot 'deskpet-voice.ps1'
if (Test-Path -LiteralPath $voiceFile) {
    try { . $voiceFile } catch { Log-Err $_ 'voice-load' }
}

# 离线对话大脑（意图/指令/记忆）
$brainFile = Join-Path $PSScriptRoot 'deskpet-brain.ps1'
if (Test-Path -LiteralPath $brainFile) {
    try { . $brainFile } catch { Log-Err $_ 'brain-load' }
}

# 窗口感知（场景台词）
$sceneFile = Join-Path $PSScriptRoot 'deskpet-scene.ps1'
if (Test-Path -LiteralPath $sceneFile) {
    try { . $sceneFile } catch { Log-Err $_ 'scene-load' }
}

# 聊天直连（OpenAI 兼容：DeepSeek / 硅基流动 / OpenRouter / Ollama）
# 必须在 deskpet-chat.ps1 之前加载：后端解析、组包、测试连接都在这里
$llmFile = Join-Path $PSScriptRoot 'deskpet-llm.ps1'
if (Test-Path -LiteralPath $llmFile) {
    try { . $llmFile } catch { Log-Err $_ 'llm-load' }
}

# 交互音效（本地 wav，点她/开菜单时响）
$sfxFile = Join-Path $PSScriptRoot 'deskpet-sfx.ps1'
if (Test-Path -LiteralPath $sfxFile) {
    try { . $sfxFile } catch { Log-Err $_ 'sfx-load' }
}

# 开发者命令（录素材用；发布包无 _dev 目录，不影响用户）
$devFile = Join-Path $PSScriptRoot 'deskpet-devcmd.ps1'
if (Test-Path -LiteralPath $devFile) { try { . $devFile } catch { Log-Err $_ 'devcmd-load' } }

# 使用时长统计（只记进程名 + 秒数，不记标题、不上传）
$ttFile = Join-Path $PSScriptRoot 'deskpet-timetrack.ps1'
if (Test-Path -LiteralPath $ttFile) {
    try { . $ttFile } catch { Log-Err $_ 'timetrack-load' }
}

$chatFile = Join-Path $PSScriptRoot 'deskpet-chat.ps1'
if (Test-Path -LiteralPath $chatFile) {
    try {
        . $chatFile
        if ($script:chatEnable -ne [bool](Cfg '聊天.启用' $true)) {
            $script:chatEnable = $script:chatEnable
        }
        $script:itemChatEnable.Checked = $script:chatEnable
        Start-ChatTimer
    }
    catch {
        Log-Err $_ 'chat-load'
    }
}

# API Key 模块（DPAPI 加密，供设置面板和聊天共用）
$keyFile2 = Join-Path $PSScriptRoot 'deskpet-apikey.ps1'
if (Test-Path -LiteralPath $keyFile2) {
    try { . $keyFile2 } catch { Log-Err $_ 'apikey-load' }
}

# 自绘 UI 控件（设置界面用）
$uiFile = Join-Path $PSScriptRoot 'deskpet-ui.ps1'
if (Test-Path -LiteralPath $uiFile) {
    try { . $uiFile } catch { Log-Err $_ 'ui-load' }
}

# 用量看板小窗
$boardFile = Join-Path $PSScriptRoot 'deskpet-board.ps1'
if (Test-Path -LiteralPath $boardFile) {
    try { . $boardFile } catch { Log-Err $_ 'board-load' }
}
# 设置面板模块
$setFile = Join-Path $PSScriptRoot 'deskpet-settings.ps1'
if (Test-Path -LiteralPath $setFile) {
    try { . $setFile } catch { Log-Err $_ 'settings-load' }
}

# 工具模式（缩成小挂件）
$toolFile = Join-Path $PSScriptRoot 'deskpet-toolmode.ps1'
if (Test-Path -LiteralPath $toolFile) {
    try { . $toolFile } catch { Log-Err $_ 'tool-load' }
}
# 物理拖拽模块
$physFile = Join-Path $PSScriptRoot 'deskpet-physics.ps1'
if (Test-Path -LiteralPath $physFile) {
    try {
        . $physFile
        if ($script:itemPhys) { $script:itemPhys.Checked = $script:physEnable }
    }
    catch {
        Log-Err $_ 'phys-load'
    }
}

# ============================================================
#  10. 启动
# ============================================================
$script:form.Show()
try { if ([bool](Cfg '模式.工具模式' $false) -and (Get-Command Set-ToolMode -ErrorAction SilentlyContinue)) { Set-ToolMode $true } } catch {}
Start-Sleep -Milliseconds 250
[LW]::MakeLayered($script:form.Handle)

Render-Frame
$null = [LW]::SetBitmap($script:form.Handle, $script:canvas,
    [int][Math]::Round($script:px), [int][Math]::Round($script:py), 255)

# ★ 首次启动：先睡着，点她才会醒来说初次见面的话
try {
    if (Get-Command Start-Intro -ErrorAction SilentlyContinue) {
        if (Start-Intro $PSScriptRoot) {
            Write-Host "首次启动：她睡着了，点一下把她叫醒"
        }
    }
} catch { Log-Err $_ 'intro-start' }

[System.Windows.Forms.Application]::Run($script:form)
