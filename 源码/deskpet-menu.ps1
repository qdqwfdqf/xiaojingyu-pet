# ============================================================
#  deskpet-menu.ps1 —— 右键菜单自绘样式（深蓝卡片风）
#   · 统一字体 / 圆角高亮 / 分隔线 / 勾选色
#   · 和图标、工具挂件、看板同一套配色
# ============================================================

$script:menuStyleInstalled = $false

function Install-DshMenuStyle {
    param($Menu)
    if (-not $Menu) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $refs = @(
            [System.Drawing.Color].Assembly.Location
            [System.Windows.Forms.Form].Assembly.Location
        ) | Where-Object { $_ } | Select-Object -Unique
        Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class DshColorTable : ProfessionalColorTable
{
    public override Color MenuItemSelected { get { return Color.FromArgb(58, 84, 132); } }
    public override Color MenuItemSelectedGradientBegin { get { return Color.FromArgb(58, 84, 132); } }
    public override Color MenuItemSelectedGradientEnd { get { return Color.FromArgb(58, 84, 132); } }
    public override Color MenuItemBorder { get { return Color.Transparent; } }
    public override Color MenuBorder { get { return Color.FromArgb(56, 78, 118); } }
    public override Color ToolStripDropDownBackground { get { return Color.FromArgb(28, 40, 66); } }
    public override Color ImageMarginGradientBegin { get { return Color.FromArgb(28, 40, 66); } }
    public override Color ImageMarginGradientMiddle { get { return Color.FromArgb(28, 40, 66); } }
    public override Color ImageMarginGradientEnd { get { return Color.FromArgb(28, 40, 66); } }
    public override Color SeparatorDark { get { return Color.FromArgb(52, 70, 104); } }
    public override Color SeparatorLight { get { return Color.FromArgb(52, 70, 104); } }
    public override Color CheckBackground { get { return Color.FromArgb(84, 130, 210); } }
    public override Color CheckSelectedBackground { get { return Color.FromArgb(84, 130, 210); } }
    public override Color CheckPressedBackground { get { return Color.FromArgb(84, 130, 210); } }
}

public class DshMenuRenderer : ToolStripProfessionalRenderer
{
    public static Font ItemFont = new Font("Microsoft YaHei UI", 10f, FontStyle.Regular);
    public DshMenuRenderer() : base(new DshColorTable()) { }

    static GraphicsPath RoundRect(Rectangle r, int radius)
    {
        var p = new GraphicsPath();
        int d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d - 1, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d - 1, r.Bottom - d - 1, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d - 1, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
    {
        using (var b = new SolidBrush(Color.FromArgb(28, 40, 66)))
            e.Graphics.FillRectangle(b, e.AffectedBounds);
    }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        if (!e.Item.Selected || !e.Item.Enabled) { return; }
        var r = new Rectangle(4, 1, e.Item.Width - 8, e.Item.Height - 2);
        using (var path = RoundRect(r, 8))
        using (var b = new SolidBrush(Color.FromArgb(58, 84, 132)))
            e.Graphics.FillPath(b, path);
    }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        e.TextColor = e.Item.Enabled ? Color.FromArgb(230, 238, 252) : Color.FromArgb(145, 160, 190);
        try { e.TextFont = ItemFont; } catch {}
        base.OnRenderItemText(e);
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    {
        var y = e.Item.Height / 2;
        using (var pen = new Pen(Color.FromArgb(56, 74, 108)))
            e.Graphics.DrawLine(pen, 12, y, e.Item.Width - 12, y);
    }

    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
    {
        e.ArrowColor = Color.FromArgb(200, 216, 245);
        base.OnRenderArrow(e);
    }

    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e)
    {
        using (var b = new SolidBrush(Color.FromArgb(24, 34, 56)))
            e.Graphics.FillRectangle(b, e.AffectedBounds);
    }
}
'@ -ReferencedAssemblies $refs -ErrorAction SilentlyContinue

        $Menu.Renderer = New-Object DshMenuRenderer
        $Menu.ShowImageMargin = $false
        $Menu.ShowCheckMargin = $true
        try {
            # ★ 字体：Noto Sans SC Medium（更宽更饱满），10.5pt
            $Menu.Font = UiFont 10.5 1
            [DshMenuRenderer]::ItemFont = $Menu.Font
        } catch {
            $Menu.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
        }
        $Menu.BackColor = [System.Drawing.Color]::FromArgb(28, 40, 66)
        $Menu.ForeColor = [System.Drawing.Color]::FromArgb(230, 238, 252)
        $Menu.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 10)
        $Menu.DropShadowEnabled = $true
        $script:menuStyleInstalled = $true
    } catch {
        try { Log-Err $_ 'menu-style' } catch {}
    }
}
