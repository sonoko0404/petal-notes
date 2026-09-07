using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;

namespace StickyNotes;

internal static class UI
{
    public static TextBlock Text(string text, double size = 13, string? color = null) => new() { Text = text, FontSize = size, Foreground = Themes.Brush(color ?? "#493F38"), TextWrapping = TextWrapping.Wrap };
    public static Button Button(string label, Action click, bool primary = false)
    {
        var b = new Button { Content = label, Margin = new Thickness(0, 0, 8, 0) };
        if (primary) b.SetResourceReference(FrameworkElement.StyleProperty, "Primary");
        b.Click += (_, _) => click(); AutomationProperties.SetName(b, label); return b;
    }
    public static TextBox Input(string value, string name)
    {
        var t = new TextBox { Text = value, Margin = new Thickness(0, 5, 0, 12) }; AutomationProperties.SetName(t, name); return t;
    }
    public static void Label(Panel panel, string title, string? subtitle = null)
    {
        var t = Text(title, 14); t.FontWeight = FontWeights.SemiBold; t.Margin = new Thickness(0, 16, 0, 6); panel.Children.Add(t);
        if (subtitle != null) { var s = Text(subtitle, 11, "#8D7D6E"); s.Margin = new Thickness(0, 0, 0, 8); panel.Children.Add(s); }
    }
    public static Border Card(UIElement content, string background = "#FFFFFF", Thickness? padding = null) => new() { Child = content, CornerRadius = new CornerRadius(12), Background = Themes.Brush(background), BorderBrush = Themes.Brush("#EBE4D9"), BorderThickness = new Thickness(1), Padding = padding ?? new Thickness(18) };
    public static Grid Frame(Window window, string title, string subtitle, double width, double height)
    {
        window.Style = (Style)System.Windows.Application.Current.FindResource(typeof(Window));
        window.Title = title + " · 便利贴"; window.Width = width; window.Height = height; window.MinWidth = width - 60; window.MinHeight = Math.Min(height, 400);
        window.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var grid = new Grid { Margin = new Thickness(24) };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var head = new StackPanel { Margin = new Thickness(0, 0, 0, 15) };
        var heading = Text(title, 26); heading.FontWeight = FontWeights.SemiBold; head.Children.Add(heading);
        var sub = Text(subtitle, 12, "#8D7D6E"); sub.Margin = new Thickness(0, 8, 0, 0); head.Children.Add(sub); grid.Children.Add(head);
        window.Content = grid; return grid;
    }
}

public sealed class ManagerWindow : Window
{
    private readonly App app = App.CurrentApp;
    private readonly WrapPanel cards = new();
    private readonly TextBox search;
    private readonly TextBlock count = UI.Text("", 12, "#8D7D6E");
    private bool trash;
    public ManagerWindow()
    {
        var grid = UI.Frame(this, "每一件小事，都值得记住。", "便利贴  /  MY LITTLE NOTES", 840, 620);
        var body = new Grid(); body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(155) }); body.ColumnDefinitions.Add(new ColumnDefinition()); Grid.SetRow(body, 1); grid.Children.Add(body);
        var sidebar = new StackPanel { Margin = new Thickness(0, 0, 19, 0) };
        void Nav(string text, Action action, bool primary = false) { var b = UI.Button(text, action, primary); b.HorizontalContentAlignment = HorizontalAlignment.Left; b.Margin = new Thickness(0, 0, 0, 9); sidebar.Children.Add(b); }
        Nav("＋ 新建便签", () => app.NewNote(), true);
        Nav("▤  全部便签", () => { trash = false; Refresh(); });
        Nav("◷  番茄钟", () => app.ShowFocus());
        Nav("♧  回收站", () => { trash = true; Refresh(); });
        Nav("⚙  设置", app.ShowSettings);
        var hint = UI.Text("留一点空间，\n给今天的小美好。", 12, "#9A8A77"); hint.Margin = new Thickness(5, 25, 0, 24); sidebar.Children.Add(hint);
        Nav("全部显示", app.ShowAll); Nav("全部隐藏", app.HideAll);
        sidebar.Children.Add(UI.Text("关闭此窗口后，\n便利贴仍在托盘运行。", 11, "#9A8A77"));
        var exit = UI.Button("退出便利贴", async () => await app.ExitAsync()); exit.Margin = new Thickness(0, 18, 0, 0); sidebar.Children.Add(exit);
        body.Children.Add(sidebar);
        var right = new DockPanel(); Grid.SetColumn(right, 1); body.Children.Add(right);
        search = UI.Input("", "搜索便签"); search.ToolTip = "搜索标题、正文和待办";
        var searchGrid = new Grid { Margin = new Thickness(0, 0, 0, 5) }; searchGrid.Children.Add(search);
        var placeholder = UI.Text("⌕  搜索标题、正文或待办", 12, "#9A8A77"); placeholder.Margin = new Thickness(12, 14, 0, 0); placeholder.IsHitTestVisible = false; searchGrid.Children.Add(placeholder);
        search.TextChanged += (_, _) => { placeholder.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; Refresh(); };
        DockPanel.SetDock(searchGrid, Dock.Top); right.Children.Add(searchGrid);
        count.Margin = new Thickness(2, 0, 0, 10); DockPanel.SetDock(count, Dock.Top); right.Children.Add(count);
        right.Children.Add(new ScrollViewer { Content = cards, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
        app.StateChanged += Refresh; Closed += (_, _) => app.StateChanged -= Refresh; Refresh();
    }
    private void Refresh()
    {
        if (!IsLoaded && search == null) return;
        var query = search.Text.Trim();
        var notes = app.State.Notes.Where(n => (n.DeletedAt != null) == trash && (query.Length == 0 || n.Title.Contains(query, StringComparison.OrdinalIgnoreCase) || n.Body.Contains(query, StringComparison.OrdinalIgnoreCase) || n.Todos.Any(t => t.Text.Contains(query, StringComparison.OrdinalIgnoreCase)))).Reverse().ToList();
        count.Text = trash ? $"回收站 · {notes.Count} 张  /  删除后保留 30 天" : $"我的便签 · {notes.Count} 张  /  点击即可回到桌面";
        cards.Children.Clear();
        if (notes.Count == 0) { var empty = UI.Text(trash ? "回收站空空的，真好。" : "还没有找到便签，试试换个关键词。", 15, "#9A8A77"); empty.Margin = new Thickness(20, 65, 20, 0); cards.Children.Add(empty); }
        foreach (var n in notes)
        {
            var palette = Themes.Get(n.Theme);
            var content = new StackPanel();
            var tag = UI.Text(trash ? "等待重新出发" : n.Hidden ? "已收起" : n.Pinned ? "● 桌面置顶" : "桌面便签", 10, palette.Accent); content.Children.Add(tag);
            var title = UI.Text(n.DisplayTitle, 16, palette.Ink); title.FontWeight = FontWeights.SemiBold; title.Margin = new Thickness(0, 9, 0, 6); title.TextWrapping = TextWrapping.NoWrap; title.TextTrimming = TextTrimming.CharacterEllipsis; content.Children.Add(title);
            var previewText = n.Body.Length > 160 ? n.Body[..160] + "…" : n.Body;
            var preview = UI.Text(string.IsNullOrWhiteSpace(previewText) ? "给灵感留个位置…" : previewText, 12, palette.Ink); preview.Height = 52; preview.Opacity = 0.75; preview.TextTrimming = TextTrimming.CharacterEllipsis; content.Children.Add(preview);
            var details = UI.Text(n.Todos.Count > 0 ? $"☑ {n.Todos.Count(t => t.Done)} / {n.Todos.Count} 项完成" : palette.Name, 10, palette.Accent); details.Margin = new Thickness(0, 9, 0, 12); content.Children.Add(details);
            var actions = new StackPanel { Orientation = Orientation.Horizontal };
            actions.Children.Add(UI.Button(trash ? "恢复便签" : "打开", () => { if (trash) app.Restore(n); else app.ShowNote(n); }));
            if (!trash) { var del = UI.Button("回收", () => app.Delete(n)); del.Background = Brushes.Transparent; actions.Children.Add(del); }
            content.Children.Add(actions);
            var card = UI.Card(content, palette.Paper, new Thickness(16)); card.Width = 258; card.Margin = new Thickness(0, 0, 12, 12); cards.Children.Add(card);
        }
    }
}

public sealed class ReminderWindow : Window
{
    public ReminderWindow(Note note)
    {
        var app = App.CurrentApp;
        var grid = UI.Frame(this, "给未来的自己捎个信", note.DisplayTitle, 410, 440);
        ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var stack = new StackPanel(); Grid.SetRow(stack, 1); grid.Children.Add(stack);
        var when = note.Reminder.Due?.LocalDateTime ?? DateTime.Now.AddHours(1);
        UI.Label(stack, "提醒日期与时间");
        var date = new DatePicker { SelectedDate = when.Date, Margin = new Thickness(0, 0, 0, 6), FirstDayOfWeek = DayOfWeek.Monday };
        AutomationProperties.SetName(date, "提醒日期"); stack.Children.Add(date);
        var time = UI.Input(when.ToString("HH:mm"), "提醒时间"); stack.Children.Add(time);
        var daily = new CheckBox { Content = "每天这个时间提醒我", IsChecked = note.Reminder.Daily };
        daily.Checked += (_, _) => date.IsEnabled = false; daily.Unchecked += (_, _) => date.IsEnabled = true; date.IsEnabled = !note.Reminder.Daily; stack.Children.Add(daily);
        var hint = UI.Text("默认静音，不打断正在输入的内容。\n完全退出应用后不会提醒，下次启动会补报。", 11, "#8D7D6E"); hint.Margin = new Thickness(0, 12, 0, 12); stack.Children.Add(hint);
        var error = UI.Text("", 11, "#AD4848"); error.Margin = new Thickness(0, 0, 0, 8); stack.Children.Add(error);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(UI.Button("保存提醒", () =>
        {
            if (!TimeSpan.TryParseExact(time.Text.Trim(), new[] { @"h\:mm", @"hh\:mm" }, CultureInfo.InvariantCulture, out var tod) || tod.TotalHours >= 24) { error.Text = "请输入 24 小时制时间，例如 09:30。"; return; }
            DateTimeOffset due;
            if (daily.IsChecked == true) due = TimeLogic.NextDaily(DateTimeOffset.Now, tod.Hours, tod.Minutes);
            else
            {
                if (date.SelectedDate == null) { error.Text = "请选择提醒日期。"; return; }
                var local = date.SelectedDate.Value.Date.Add(tod);
                if (TimeZoneInfo.Local.IsInvalidTime(local)) { error.Text = "这个时间处于夏令时跳变，请选择另一个时间。"; return; }
                due = new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local));
                if (due <= DateTimeOffset.Now) { error.Text = "请选择一个未来时间。"; return; }
            }
            app.SetReminder(note, due, daily.IsChecked == true, tod.Hours, tod.Minutes); Close();
        }, true));
        buttons.Children.Add(UI.Button("取消提醒", () => { app.SetReminder(note, null, false, 9, 0); Close(); }));
        stack.Children.Add(buttons);
    }
}

public sealed class SettingsWindow : Window
{
    private const string RunPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunName = "BianLiTie";
    public SettingsWindow()
    {
        var app = App.CurrentApp; var settings = app.State.Settings;
        var grid = UI.Frame(this, "调成你喜欢的样子", "舒服一点，记录就会自然一点。", 530, 690);
        var stack = new StackPanel { Margin = new Thickness(0, 0, 12, 15) }; var scroll = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }; Grid.SetRow(scroll, 1); grid.Children.Add(scroll);
        UI.Label(stack, "新便签的默认风格", "每张便签也可以在右下角单独调整。");
        var themeRow = new WrapPanel();
        foreach (var t in Themes.All)
        {
            var radio = new RadioButton { Content = t.Name, Tag = t.Id, IsChecked = settings.DefaultTheme == t.Id, GroupName = "themes", Margin = new Thickness(0, 0, 13, 10), Padding = new Thickness(5), Foreground = Themes.Brush(t.Accent) };
            radio.Checked += (_, _) => { settings.DefaultTheme = t.Id; app.Changed(); };
            var chip = UI.Card(radio, t.Paper, new Thickness(8, 8, 0, 0)); chip.Margin = new Thickness(0, 0, 7, 7); themeRow.Children.Add(chip);
        }
        stack.Children.Add(themeRow);
        UI.Label(stack, "字体与字号");
        var fonts = new ComboBox { DisplayMemberPath = "Value", SelectedValuePath = "Key" };
        foreach (var f in Themes.AvailableFonts) fonts.Items.Add(new KeyValuePair<string, string>(f, Themes.FontLabel(f)));
        fonts.SelectedValue = Themes.Font(settings.DefaultFont).Source;
        fonts.SelectionChanged += (_, _) => { if (fonts.SelectedValue is string f) { settings.DefaultFont = f; app.Changed(); } };
        AutomationProperties.SetName(fonts, "默认字体"); stack.Children.Add(fonts);
        var sizes = new ComboBox { ItemsSource = new[] { 12d, 14, 15, 16, 18, 20, 24, 28 }, SelectedItem = settings.DefaultFontSize };
        sizes.SelectionChanged += (_, _) => { if (sizes.SelectedItem is double s) { settings.DefaultFontSize = s; app.Changed(); } }; AutomationProperties.SetName(sizes, "默认字号"); stack.Children.Add(sizes);
        UI.Label(stack, "节奏与提醒");
        void Check(string text, bool value, Action<bool> action) { var c = new CheckBox { Content = text, IsChecked = value }; c.Click += (_, _) => { action(c.IsChecked == true); app.Changed(); }; stack.Children.Add(c); }
        Check("提醒和番茄钟结束时播放短提示音", settings.Sound, v => settings.Sound = v);
        Check("启用轻柔的界面过渡", settings.Animations, v => settings.Animations = v);
        var durations = new Grid { Margin = new Thickness(0, 12, 0, 0) };
        for (int i = 0; i < 3; i++) durations.ColumnDefinitions.Add(new ColumnDefinition());
        TextBox DurationBox(int column, string label, int value)
        {
            var part = new StackPanel { Margin = new Thickness(0, 0, column < 2 ? 10 : 0, 0) }; part.Children.Add(UI.Text(label, 11, "#8D7D6E")); var input = UI.Input(value.ToString(), label); part.Children.Add(input); Grid.SetColumn(part, column); durations.Children.Add(part); return input;
        }
        var focus = DurationBox(0, "专注 / 分钟", settings.FocusMinutes); var rest = DurationBox(1, "短休息 / 分钟", settings.BreakMinutes); var longRest = DurationBox(2, "长休息 / 分钟", settings.LongBreakMinutes); stack.Children.Add(durations);
        var durationStatus = UI.Text("时长修改应用于下一阶段；重置可立即应用。", 11, "#8D7D6E"); stack.Children.Add(durationStatus);
        var apply = UI.Button("保存计时时长", () =>
        {
            if (!int.TryParse(focus.Text, out int f) || !int.TryParse(rest.Text, out int r) || !int.TryParse(longRest.Text, out int l) || f is < 1 or > 180 || r is < 1 or > 60 || l is < 1 or > 120)
            { durationStatus.Text = "专注 1–180，短休息 1–60，长休息 1–120 分钟。"; return; }
            settings.FocusMinutes = f; settings.BreakMinutes = r; settings.LongBreakMinutes = l; app.Changed(); durationStatus.Text = "已保存，将应用于下一阶段；重置可立即应用。";
        }); apply.HorizontalAlignment = HorizontalAlignment.Left; apply.Margin = new Thickness(0, 10, 0, 0); stack.Children.Add(apply);
        UI.Label(stack, "启动与数据");
        bool auto = false;
        try { using var key = Registry.CurrentUser.OpenSubKey(RunPath); auto = key?.GetValue(RunName) is string; } catch { }
        var startup = new CheckBox { Content = "登录 Windows 后自动启动", IsChecked = auto };
        startup.Click += (_, _) =>
        {
            try
            {
                using var key = Registry.CurrentUser.CreateSubKey(RunPath);
                if (startup.IsChecked == true) key.SetValue(RunName, "\"" + Environment.ProcessPath + "\""); else key.DeleteValue(RunName, false);
            }
            catch (Exception ex) { startup.IsChecked = !startup.IsChecked; MessageBox.Show("未能修改开机启动：" + ex.Message, "便利贴"); }
        };
        stack.Children.Add(startup);
        var data = UI.Text("数据只保存在本机，无需登录。\n开机启动开启后，请保持程序所在文件夹位置不变。", 11, "#8D7D6E"); data.Margin = new Thickness(0, 8, 0, 8); stack.Children.Add(data);
        var openData = UI.Button("打开数据文件夹", () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(app.DataDirectory) { UseShellExecute = true })); openData.HorizontalAlignment = HorizontalAlignment.Left; stack.Children.Add(openData);
        var save = UI.Text(app.SaveMessage, 11, "#8D7D6E"); save.Margin = new Thickness(0, 16, 0, 0); stack.Children.Add(save);
        void Saved() => save.Text = app.SaveMessage;
        app.SaveStatusChanged += Saved; Closed += async (_, _) => { app.SaveStatusChanged -= Saved; await app.SaveNowAsync(); };
    }
}

public sealed class FocusWindow : Window
{
    private readonly App app = App.CurrentApp;
    private readonly TextBlock clock = UI.Text("25:00", 58, "#986343");
    private readonly TextBlock phase = UI.Text("专注时光", 13, "#986343");
    private readonly TextBlock rounds = UI.Text("", 11, "#8D7D6E");
    private readonly Button start;
    private readonly ComboBox association;
    private readonly DispatcherTimer ticker = new() { Interval = TimeSpan.FromSeconds(1) };
    public FocusWindow()
    {
        var grid = UI.Frame(this, "一次，只做一件事。", "留一段安静的时间，给重要的事。", 405, 485);
        var stack = new StackPanel(); Grid.SetRow(stack, 1); grid.Children.Add(stack);
        var dial = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 20) };
        phase.HorizontalAlignment = clock.HorizontalAlignment = rounds.HorizontalAlignment = HorizontalAlignment.Center;
        clock.FontFamily = new FontFamily("Segoe UI"); clock.FontWeight = FontWeights.Light; clock.Margin = new Thickness(0, 7, 0, 9);
        dial.Children.Add(phase); dial.Children.Add(clock); dial.Children.Add(rounds); stack.Children.Add(UI.Card(dial, "#FFF9EC"));
        association = new ComboBox { DisplayMemberPath = "Value", SelectedValuePath = "Key", Margin = new Thickness(0, 15, 0, 12) };
        association.SelectionChanged += (_, _) => { if (association.SelectedItem is KeyValuePair<Guid?, string> selected) { app.State.Pomodoro.NoteId = selected.Key; app.Changed(); } };
        AutomationProperties.SetName(association, "关联便签"); stack.Children.Add(association);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        start = UI.Button("开始专注", Toggle, true); start.MinWidth = 130; buttons.Children.Add(start);
        buttons.Children.Add(UI.Button("重置", () => { var p = app.State.Pomodoro; p.EndsAt = null; p.RemainingSeconds = TimeLogic.Duration(p.Phase, app.State.Settings); p.Pending = false; app.Changed(); app.RefreshNotifications(); app.ScheduleNext(); Refresh(); })); stack.Children.Add(buttons);
        var caption = UI.Text("每 4 轮安排一次长休息 · 下一阶段由你开始", 10, "#8D7D6E"); caption.Margin = new Thickness(0, 18, 0, 0); caption.HorizontalAlignment = HorizontalAlignment.Center; stack.Children.Add(caption);
        ticker.Tick += (_, _) => RefreshClock();
        IsVisibleChanged += (_, _) => { if (IsVisible) { ticker.Start(); Refresh(); } else ticker.Stop(); };
        app.StateChanged += RefreshAssociations;
        Closed += (_, _) => { ticker.Stop(); app.StateChanged -= RefreshAssociations; };
        Refresh();
    }
    private void Toggle()
    {
        var p = app.State.Pomodoro;
        if (p.EndsAt != null) { p.RemainingSeconds = TimeLogic.Remaining(p, DateTimeOffset.Now); p.EndsAt = null; }
        else { p.EndsAt = DateTimeOffset.Now.AddSeconds(p.RemainingSeconds); p.Pending = false; }
        app.Changed(); app.RefreshNotifications(); app.CheckDeadlines(); Refresh();
    }
    private void RefreshAssociations()
    {
        var id = app.State.Pomodoro.NoteId;
        var list = new List<KeyValuePair<Guid?, string>> { new(null, "不关联便签") };
        list.AddRange(app.State.Notes.Where(n => n.DeletedAt == null).Select(n => new KeyValuePair<Guid?, string>(n.Id, n.DisplayTitle)));
        // Avoid reopening/rebuilding a list the user is navigating.
        if (association.IsDropDownOpen) return;
        if (association.ItemsSource is List<KeyValuePair<Guid?, string>> old && old.SequenceEqual(list)) return;
        association.ItemsSource = list; association.SelectedIndex = Math.Max(0, list.FindIndex(x => x.Key == id));
    }
    public void Refresh() { RefreshAssociations(); RefreshClock(); }
    private void RefreshClock()
    {
        var p = app.State.Pomodoro;
        int seconds = (int)Math.Ceiling(TimeLogic.Remaining(p, DateTimeOffset.Now));
        clock.Text = $"{seconds / 60:00}:{seconds % 60:00}";
        phase.Text = p.Phase == "focus" ? "✿  专注时光" : p.Phase == "longBreak" ? "♧  好好休息一下" : "♧  伸个懒腰吧";
        rounds.Text = $"已完成 {p.CompletedRounds} 轮专注";
        start.Content = p.EndsAt != null ? "暂停" : p.Phase == "focus" ? "开始 / 继续专注" : "开始 / 继续休息";
    }
}

public sealed class ToastWindow : Window
{
    private readonly App app = App.CurrentApp;
    private readonly StackPanel items = new();
    public ToastWindow()
    {
        Style = (Style)app.FindResource(typeof(Window));
        Title = "到时间啦 · 便利贴"; Width = 355; SizeToContent = SizeToContent.Height; MaxHeight = 540; ResizeMode = ResizeMode.NoResize;
        ShowActivated = false; ShowInTaskbar = false; Topmost = true; NativeWindow.Chrome(this);
        var outer = new DockPanel { Margin = new Thickness(18) };
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        var close = UI.Button("×", Close); close.Padding = new Thickness(8, 2, 8, 2); close.Background = Brushes.Transparent; DockPanel.SetDock(close, Dock.Right); head.Children.Add(close);
        var title = UI.Text("✿  到时间啦", 18, "#986343"); head.Children.Add(title); DockPanel.SetDock(head, Dock.Top); outer.Children.Add(head);
        outer.Children.Add(new ScrollViewer { Content = items, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }); Content = UI.Card(outer, "#FFF9EC", new Thickness(0));
        Loaded += (_, _) => Place(); SizeChanged += (_, _) => Place();
    }
    private void Place() { var area = SystemParameters.WorkArea; Left = area.Right - ActualWidth - 18; Top = Math.Max(area.Top + 12, area.Bottom - ActualHeight - 18); }
    public void Refresh(List<Note> notes)
    {
        items.Children.Clear();
        foreach (var note in notes)
        {
            var part = new StackPanel { Margin = new Thickness(0, 0, 0, 16) };
            var title = UI.Text(note.DisplayTitle, 15); title.FontWeight = FontWeights.SemiBold; part.Children.Add(title);
            var due = UI.Text(note.Reminder.Due?.ToLocalTime().ToString("MM月dd日 HH:mm") ?? "", 11, "#8D7D6E"); due.Margin = new Thickness(0, 5, 0, 10); part.Children.Add(due);
            var row = new WrapPanel(); row.Children.Add(UI.Button("完成", () => app.CompleteReminder(note), true)); row.Children.Add(UI.Button("5 分钟后", () => app.SnoozeReminder(note))); row.Children.Add(UI.Button("打开", () => app.ShowNote(note))); part.Children.Add(row); items.Children.Add(part);
        }
        if (app.State.Pomodoro.Pending)
        {
            var part = new StackPanel(); var message = UI.Text(app.State.Pomodoro.LastMessage, 14); message.Margin = new Thickness(0, 0, 0, 12); part.Children.Add(message);
            var row = new WrapPanel(); row.Children.Add(UI.Button("知道啦", app.ClearFocusNotification)); row.Children.Add(UI.Button("打开番茄钟", () => { app.ClearFocusNotification(); app.ShowFocus(); }, true)); part.Children.Add(row); items.Children.Add(part);
        }
    }
}
