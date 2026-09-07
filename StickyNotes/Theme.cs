using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;

namespace StickyNotes;

public sealed record Palette(string Id, string Name, string Paper, string Tint, string Accent, string Ink, string Line);
public static class Themes
{
    public static readonly Palette[] All =
    {
        new("cream", "奶油手帐", "#FFF9EC", "#F3E4CE", "#9B623F", "#493F38", "#EBDDCB"),
        new("mint", "薄荷清新", "#F0F8F0", "#D9ECDD", "#4C7A65", "#364C41", "#D4E4D8"),
        new("pink", "樱花粉", "#FFF3F4", "#F3DDE3", "#A56176", "#594049", "#ECD6DC"),
        new("blue", "天空蓝", "#F0F7FD", "#DCEAF6", "#507AA4", "#364A61", "#D4E2F0"),
        new("paper", "极简纸张", "#FAFAF7", "#EAEAE3", "#657263", "#41483F", "#DEDFD7")
    };
    public static Palette Get(string? id) => All.FirstOrDefault(t => t.Id == id) ?? All[0];
    public static SolidColorBrush Brush(string hex) { var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)); b.Freeze(); return b; }
    public static void Apply(FrameworkElement element, string id)
    {
        var t = Get(id);
        element.Resources["Paper"] = Brush(t.Paper); element.Resources["Tint"] = Brush(t.Tint);
        element.Resources["Accent"] = Brush(t.Accent); element.Resources["Ink"] = Brush(t.Ink); element.Resources["Line"] = Brush(t.Line);
    }
    private static readonly Lazy<HashSet<string>> InstalledFonts = new(() =>
    {
        using var fonts = new System.Drawing.Text.InstalledFontCollection();
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var family in fonts.Families) { names.Add(family.Name); names.Add(family.GetName(1033)); family.Dispose(); }
        return names;
    });
    public static FontFamily Font(string? name) => new(name is "Microsoft YaHei UI" or "Microsoft YaHei" or "Segoe UI" ? name : InstalledFonts.Value.Contains(name ?? "") ? name! : "Microsoft YaHei UI");
    public static string[] AvailableFonts => new[] { "Microsoft YaHei UI", "Microsoft YaHei", "DengXian", "KaiTi", "SimSun", "Segoe UI" }.Where(InstalledFonts.Value.Contains).ToArray();
    public static string FontLabel(string font) => font switch { "Microsoft YaHei UI" => "微软雅黑 UI", "Microsoft YaHei" => "微软雅黑", "DengXian" => "等线", "KaiTi" => "楷体", "SimSun" => "宋体", _ => font };
}

public static class NativeWindow
{
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)] private struct MONITORINFO { public int Size; public RECT Monitor, Work; public uint Flags; }
    public static void Chrome(Window window)
    {
        window.WindowStyle = WindowStyle.None;
        WindowChrome.SetWindowChrome(window, new WindowChrome { CaptionHeight = 0, ResizeBorderThickness = new Thickness(6), GlassFrameThickness = new Thickness(0), CornerRadius = new CornerRadius(12) });
        window.SourceInitialized += (_, _) => { int corner = 2; DwmSetWindowAttribute(new WindowInteropHelper(window).Handle, 33, ref corner, sizeof(int)); };
    }
    public static void EnsureVisible(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero || !GetWindowRect(hwnd, out var r)) return;
        var mi = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
        if (!GetMonitorInfo(MonitorFromWindow(hwnd, 2), ref mi)) return;
        int w = Math.Min(r.Right - r.Left, mi.Work.Right - mi.Work.Left);
        int h = Math.Min(r.Bottom - r.Top, mi.Work.Bottom - mi.Work.Top);
        int x = Math.Clamp(r.Left, mi.Work.Left, mi.Work.Right - w);
        int y = Math.Clamp(r.Top, mi.Work.Top, mi.Work.Bottom - h);
        SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h, 0x0014); // Keep z-order and input focus.
    }
}
