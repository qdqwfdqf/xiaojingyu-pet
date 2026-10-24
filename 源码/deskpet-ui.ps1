
# ---------- 统一字体（与主程序一致；主程序里也有一份）----------
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
# ============================================================
#  deskpet-ui.ps1 —— 设置界面的自绘控件（C#，冰蓝玻璃风）
#  被 deskpet-settings.ps1 引入
# ============================================================
if (-not ('PetUI.PetSlider' -as [type])) {
    $uiCode = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace PetUI {

    static class Draw {
        public static void RoundRect(Graphics g, Brush b, Rectangle r, int rad) {
            using (var p = new GraphicsPath()) {
                int d = rad * 2;
                if (d > r.Width) d = r.Width;
                if (d > r.Height) d = r.Height;
                p.AddArc(r.X, r.Y, d, d, 180, 90);
                p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
                p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
                p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
                p.CloseFigure();
                g.FillPath(b, p);
            }
        }
        public static void RoundRect(Graphics g, Pen pen, Rectangle r, int rad) {
            using (var p = new GraphicsPath()) {
                int d = rad * 2;
                if (d > r.Width) d = r.Width;
                if (d > r.Height) d = r.Height;
                p.AddArc(r.X, r.Y, d, d, 180, 90);
                p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
                p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
                p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
                p.CloseFigure();
                g.DrawPath(pen, p);
            }
        }
    }

    // ---------- 圆角滑块 ----------
    public class PetSlider : Control {
        public double Min = 0, Max = 100, Value = 0;
        public int Decimals = 1;
        public Color Tint = Color.FromArgb(72, 130, 220);
        public Color TrackColor = Color.FromArgb(226, 236, 249);                 // 深色主题下改成深色轨道
        public event EventHandler ValueChanged;
        bool dragging = false;
        int pad = 10;

        public PetSlider() { SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true); DoubleBuffered = true; Height = 28; Cursor = Cursors.Hand; BackColor = Color.Transparent; }

        public void SetVal(double v) {
            if (v < Min) v = Min;
            if (v > Max) v = Max;
            if (Math.Abs(v - Value) < 1e-9) return;
            Value = v;
            Invalidate();
            if (ValueChanged != null) ValueChanged(this, EventArgs.Empty);
        }

        int KnobX() {
            int avail = Math.Max(1, Width - pad * 2);
            double t = (Max - Min) <= 0 ? 0 : (Value - Min) / (Max - Min);
            return pad + (int)(avail * t);
        }

        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int cy = Height / 2;
            int r = 5;
            var track = new Rectangle(pad - 3, cy - r, Width - (pad - 3) * 2, r * 2);
            using (var b = new SolidBrush(TrackColor)) Draw.RoundRect(g, b, track, r);
            int kx = KnobX();
            int fw = Math.Max(4, kx - (pad - 3));
            var fill = new Rectangle(pad - 3, cy - r, fw, r * 2);
            using (var b = new SolidBrush(Tint)) Draw.RoundRect(g, b, fill, r);
            using (var b = new SolidBrush(Color.White)) g.FillEllipse(b, kx - 9, cy - 9, 18, 18);
            var kb = Color.FromArgb(255, Math.Max(0, Tint.R - 34), Math.Max(0, Tint.G - 12), Math.Min(255, Tint.B + 40));
            using (var p = new Pen(kb, 2)) g.DrawEllipse(p, kx - 9, cy - 9, 18, 18);
        }

        void SetFromX(int x) {
            int avail = Math.Max(1, Width - pad * 2);
            double t = (double)(x - pad) / avail;
            if (t < 0) t = 0;
            if (t > 1) t = 1;
            SetVal(Min + (Max - Min) * t);
        }
        protected override void OnMouseDown(MouseEventArgs e) { dragging = true; SetFromX(e.X); }
        protected override void OnMouseMove(MouseEventArgs e) { if (dragging) SetFromX(e.X); }
        protected override void OnMouseUp(MouseEventArgs e) { dragging = false; }
    }

    // ---------- 开关 ----------
    public class PetToggle : Control {
        bool _checked = true;
        public bool Checked { get { return _checked; } set { _checked = value; Invalidate(); } }
        public Color Tint = Color.FromArgb(72, 130, 220);
        public Color OffColor = Color.FromArgb(206, 214, 226);                   // 深色主题下改成深色
        public PetToggle() { SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true); DoubleBuffered = true; Size = new Size(46, 24); Cursor = Cursors.Hand; BackColor = Color.Transparent; }
        protected override void OnClick(EventArgs e) { _checked = !_checked; Invalidate(); base.OnClick(e); }
        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var rr = new Rectangle(1, 2, Width - 2, Height - 4);
            int rad = rr.Height / 2;
            using (var b = new SolidBrush(_checked ? Tint : OffColor)) Draw.RoundRect(g, b, rr, rad);
            int kd = rr.Height - 4;
            int kx = _checked ? (rr.Right - kd - 3) : (rr.X + 3);
            using (var b = new SolidBrush(Color.White)) g.FillEllipse(b, kx, rr.Y + 2, kd, kd);
        }
    }

    // ---------- 卡片 ----------
    public class PetCard : Panel {
        public Color FillColor = Color.FromArgb(253, 252, 250);      // 高级白（微暖，不是死白）
        public Color LineColor = Color.FromArgb(233, 229, 221);
        public Color DepthColor = Color.FromArgb(243, 240, 233);     // 底部实体厚度
        public int Radius = 16;
        public PetCard() { SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true); DoubleBuffered = true; BackColor = Color.Transparent; }
        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            // 柔光阴影：由外向内叠几层半透明圆角
            for (int i = 7; i >= 1; i--) {
                int a = 2 + (8 - i) * 4;   // 6..30
                using (var b = new SolidBrush(Color.FromArgb(a, 58, 68, 88)))
                    Draw.RoundRect(g, b, new Rectangle(i, i + 3, Width - 1 - i * 2, Height - 1 - i * 2 - 3), Radius + i);
            }
            // 实体厚度（底部深一档，做出"卡片有厚度"的感觉）
            using (var b = new SolidBrush(DepthColor))
                Draw.RoundRect(g, b, new Rectangle(0, 3, Width - 1, Height - 4), Radius);
            // 主体
            using (var b = new SolidBrush(FillColor))
                Draw.RoundRect(g, b, new Rectangle(0, 0, Width - 1, Height - 7), Radius);
            // 顶部高光
            using (var p = new Pen(Color.FromArgb(160, 255, 255, 255), 1f))
                Draw.RoundRect(g, p, new Rectangle(1, 1, Width - 3, Height - 10), Radius);
            // 外描边
            using (var p = new Pen(LineColor, 1.2f))
                Draw.RoundRect(g, p, new Rectangle(0, 0, Width - 1, Height - 7), Radius);
        }
    }

    // ---------- 按钮 ----------
    public class PetButton : Control {
        public bool Primary = false;
        public Color Tint = Color.FromArgb(72, 130, 220);
        public Color FillColor = Color.White;                                   // 深色主题下由设置面板改成卡片色
        public Color TextColor = Color.FromArgb(52, 78, 120);                   // 深色主题下改成浅色字
        public Color BorderColor = Color.FromArgb(196, 216, 240);
        bool hover = false;
        public PetButton() { SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true); DoubleBuffered = true; Height = 34; Cursor = Cursors.Hand; BackColor = Color.Transparent; Font = new Font("Microsoft YaHei UI", 9f); }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); }
        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var rr = new Rectangle(1, 1, Width - 3, Height - 3);
            if (Primary) {
                Color c = hover ? ControlPaint.Light(Tint, 0.12f) : Tint;
                using (var b = new SolidBrush(c)) Draw.RoundRect(g, b, rr, rr.Height / 2);
                TextRenderer.DrawText(g, Text, Font, rr, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            } else {
                Color bg = hover
                    ? Color.FromArgb(Math.Min(255, FillColor.R + 20), Math.Min(255, FillColor.G + 20), Math.Min(255, FillColor.B + 20))
                    : FillColor;
                using (var b = new SolidBrush(bg)) Draw.RoundRect(g, b, rr, rr.Height / 2);
                using (var p = new Pen(BorderColor, 1.2f)) Draw.RoundRect(g, p, rr, rr.Height / 2);
                TextRenderer.DrawText(g, Text, Font, rr, TextColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
        }
    }

    // ---------- 分段选择 ----------
    public class PetSegmented : Control {
        public int SelectedIndex = 0;
        public string[] Items = new string[0];
        public Color Tint = Color.FromArgb(72, 130, 220);
        public Color TrackColor = Color.FromArgb(232, 240, 252);                // 深色主题下改成深色轨道
        public Color TextColor = Color.FromArgb(80, 104, 140);                  // 未选中项文字色
        public event EventHandler SelectedChanged;
        public PetSegmented() { SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true); DoubleBuffered = true; Height = 30; Cursor = Cursors.Hand; BackColor = Color.Transparent; Font = new Font("Microsoft YaHei UI", 8.5f); }
        int SegWidth() { return Items.Length <= 0 ? Width : Width / Items.Length; }
        protected override void OnMouseDown(MouseEventArgs e) {
            int sw = SegWidth();
            if (sw <= 0) return;
            int idx = e.X / sw;
            if (idx < 0) idx = 0;
            if (idx >= Items.Length) idx = Items.Length - 1;
            if (idx != SelectedIndex) { SelectedIndex = idx; Invalidate(); if (SelectedChanged != null) SelectedChanged(this, EventArgs.Empty); }
        }
        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var rr = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var b = new SolidBrush(TrackColor)) Draw.RoundRect(g, b, rr, rr.Height / 2);
            int sw = SegWidth();
            var sel = new Rectangle(SelectedIndex * sw + 2, 2, sw - 4, Height - 4);
            using (var b = new SolidBrush(Tint)) Draw.RoundRect(g, b, sel, sel.Height / 2);
            for (int i = 0; i < Items.Length; i++) {
                var rc = new Rectangle(i * sw, 0, sw, Height);
                Color tc = (i == SelectedIndex) ? Color.White : TextColor;
                TextRenderer.DrawText(g, Items[i], Font, rc, tc, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $uiCode -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
}
