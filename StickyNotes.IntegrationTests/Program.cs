using StickyNotes;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Threading;
using System.Windows.Media;
using System.Windows.Media.Imaging;

public static class IntegrationRunner
{
    private static readonly List<object> results = new();
    private static string output = "";
    [STAThread]
    public static void Main(string[] args)
    {
        if (args.Length is < 1 or > 2) return;
        output = Path.GetFullPath(args[0]); Directory.CreateDirectory(output);
        Environment.SetEnvironmentVariable("STICKYNOTES_DATA_DIR", Path.Combine(output, "data"));
        try
        {
            var app = new App(); app.InitializeComponent();
            app.DispatcherUnhandledException += (_, e) => { File.WriteAllText(Path.Combine(output, "unhandled.txt"), e.Exception.ToString()); };
            app.Startup += (_, _) => app.Dispatcher.BeginInvoke(new Action(async () => { if (args.Length == 2 && args[1] == "--preview") await Preview(app); else await Run(app); }));
            app.Run();
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(output, "startup-failure.txt"), ex.ToString()); Environment.ExitCode = 1; }
    }
    private static void Check(string name, bool condition, string detail = "")
    {
        results.Add(new { name, pass = condition, detail });
        File.WriteAllText(Path.Combine(output, "integration-results.json"), JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true }));
        if (!condition) throw new Exception(name + ": " + detail);
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>()) foreach (var descendant in Descendants(child)) yield return descendant;
    }
    private static T Named<T>(DependencyObject root, string name) where T : DependencyObject => Descendants(root).OfType<T>().Single(x => AutomationProperties.GetName(x) == name);
    private static Button Button(DependencyObject root, string content) => Descendants(root).OfType<Button>().First(x => x.Content?.ToString() == content);
    private static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
    private static bool HasText(DependencyObject root, string fragment) => Descendants(root).OfType<TextBlock>().Any(t => t.Text.Contains(fragment));

    private static async Task Preview(App app)
    {
        try
        {
            app.HideAll(); var note = app.State.Notes[0]; note.Title = "今天，也要慢慢来";
            note.Body = "留一点时间，给喜欢的事情。\n\n灵感和小计划，都贴在这里。";
            note.Font = "Microsoft YaHei UI"; note.FontSize = 15; note.Pinned = true; note.Todos.Clear();
            note.Todos.Add(new Todo { Text = "喝杯水，伸个懒腰", Done = true });
            note.Todos.Add(new Todo { Text = "做完今天最重要的一件事" });
            app.ShowNote(note); var window = app.NoteWindows[note.Id]; window.Width = 320; window.Height = 360;
            foreach (var theme in Themes.All)
            {
                note.Theme = theme.Id; await app.SaveNowAsync(); await Dispatcher.Yield(DispatcherPriority.ApplicationIdle); await Task.Delay(180);
                var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth * 1.5), (int)Math.Ceiling(window.ActualHeight * 1.5), 144, 144, PixelFormats.Pbgra32);
                bitmap.Render(window); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using var file = File.Create(Path.Combine(output, theme.Name + ".png")); encoder.Save(file);
            }
            await app.ExitAsync();
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(output, "preview-failure.txt"), ex.ToString()); await app.ExitAsync(); }
    }

    private static async Task Run(App app)
    {
        try
        {
            var note = app.State.Notes[0]; note.Title = "集成测试便签"; note.Pinned = false;
            var reminder = new ReminderWindow(note); reminder.Show();
            var time = Named<TextBox>(reminder, "提醒时间"); time.Text = "24:99"; Click(Button(reminder, "保存提醒"));
            Check("reminder rejects invalid time without closing", reminder.IsVisible && HasText(reminder, "24 小时制"));
            time.Text = "09:30"; Named<DatePicker>(reminder, "提醒日期").SelectedDate = DateTime.Today.AddDays(-1); Click(Button(reminder, "保存提醒"));
            Check("reminder rejects past date", reminder.IsVisible && HasText(reminder, "未来时间"));
            Named<DatePicker>(reminder, "提醒日期").SelectedDate = DateTime.Today.AddDays(1); Click(Button(reminder, "保存提醒"));
            Check("reminder form saves future local date and time", !reminder.IsVisible && note.Reminder.Due?.LocalDateTime == DateTime.Today.AddDays(1).AddHours(9).AddMinutes(30));
            reminder = new ReminderWindow(note); reminder.Show();
            var daily = Descendants(reminder).OfType<CheckBox>().Single(); daily.IsChecked = true;
            Check("daily mode disables specific date", !Named<DatePicker>(reminder, "提醒日期").IsEnabled);
            Click(Button(reminder, "保存提醒"));
            Check("daily form schedules next occurrence", note.Reminder.Daily && note.Reminder.Due > DateTimeOffset.Now);
            reminder = new ReminderWindow(note); reminder.Show(); Click(Button(reminder, "取消提醒"));
            Check("cancel reminder clears pending schedule", note.Reminder.Due == null && !note.Reminder.Pending);
            app.SetReminder(note, DateTimeOffset.Now.AddSeconds(-2), false, 9, 30); app.CheckDeadlines();
            var toast = app.Windows.OfType<ToastWindow>().Single();
            Check("notification does not activate or enter taskbar", !toast.ShowActivated && !toast.ShowInTaskbar && toast.Topmost);
            Click(Button(toast, "5 分钟后"));
            Check("notification snooze button persists future due", !note.Reminder.Pending && note.Reminder.Due > DateTimeOffset.Now.AddMinutes(4));
            app.SetReminder(note, DateTimeOffset.Now.AddSeconds(-2), false, 9, 30); app.CheckDeadlines(); toast = app.Windows.OfType<ToastWindow>().Single(); Click(Button(toast, "完成"));
            Check("notification completion closes card", note.Reminder.Due == null && !app.Windows.OfType<ToastWindow>().Any());

            var settings = new SettingsWindow(); settings.Show();
            var fonts = Named<ComboBox>(settings, "默认字体"); var originalFont = note.Font;
            Check("localized fonts are available", Themes.AvailableFonts.Contains("KaiTi") && Themes.AvailableFonts.Contains("DengXian"));
            fonts.SelectedValue = "KaiTi"; Named<ComboBox>(settings, "默认字号").SelectedItem = 18d;
            var next = app.NewNote(); next.Pinned = false;
            Check("new-note font defaults do not modify existing notes", next.Font == "KaiTi" && next.FontSize == 18 && note.Font == originalFont);
            Check("unavailable fonts fall back", Themes.Font("MissingFont-12345").Source == "Microsoft YaHei UI");
            Named<TextBox>(settings, "专注 / 分钟").Text = "0"; Click(Button(settings, "保存计时时长"));
            Check("invalid focus duration rejected", app.State.Settings.FocusMinutes == 25 && HasText(settings, "1–180"));
            Named<TextBox>(settings, "专注 / 分钟").Text = "40"; Click(Button(settings, "保存计时时长"));
            Check("valid focus duration persisted", app.State.Settings.FocusMinutes == 40);
            settings.Close();

            var focus = new FocusWindow(); focus.Show(); var p = app.State.Pomodoro; p.RemainingSeconds = 90; p.EndsAt = null; focus.Refresh();
            Click(Button(focus, "开始 / 继续专注")); await Task.Delay(1200); Click(Button(focus, "暂停"));
            double paused = p.RemainingSeconds; await Task.Delay(1200);
            Check("focus pause freezes remaining time", p.EndsAt == null && Math.Abs(TimeLogic.Remaining(p, DateTimeOffset.Now) - paused) < 0.01 && paused < 90);
            Click(Button(focus, "重置")); Check("focus reset applies configured duration", p.RemainingSeconds == 2400);
            p.RemainingSeconds = 0.5; focus.Refresh(); Click(Button(focus, "开始 / 继续专注")); focus.Close(); await Task.Delay(1400);
            Check("focus continues after window closes, next phase stays stopped", p.Phase == "break" && p.EndsAt == null && p.Pending && p.CompletedRounds == 1);
            app.ClearFocusNotification();

            var manager = new ManagerWindow(); manager.Show(); Named<TextBox>(manager, "搜索便签").Text = "不可能匹配的查询";
            Check("manager search empty state", HasText(manager, "还没有找到便签"));
            Named<TextBox>(manager, "搜索便签").Text = "集成测试便签";
            Check("manager searches title", HasText(manager, "我的便签 · 1 张"));
            Click(Button(manager, "回收")); Check("manager delete moves note to recoverable trash", note.DeletedAt != null);
            Click(Button(manager, "♧  回收站")); Check("trash filter lists removed note", HasText(manager, "回收站 · 1 张"));
            Click(Button(manager, "恢复便签")); Check("manager restore opens note", note.DeletedAt == null && app.NoteWindows[note.Id].IsVisible); manager.Close();

            while (app.State.Notes.Count < 20) { var created = app.NewNote(); created.Pinned = false; }
            await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
            var watch = Stopwatch.StartNew();
            foreach (var window in app.NoteWindows.Values.ToList())
            {
                window.ViewModel.Body = "20 张便签同时编辑：" + new string('好', 300);
                window.Left += 4; window.Top += 3; window.Width += 12; window.Height += 8;
                window.Note.Todos.Add(new Todo { Text = "待移除项" }); var last = window.Note.Todos.Last(); window.ViewModel.RemoveTodoCommand.Execute(last);
                if (window.Note.Todos.Contains(last)) throw new Exception("RemoveTodoCommand did not remove item");
            }
            await Dispatcher.Yield(DispatcherPriority.ApplicationIdle); watch.Stop();
            Check("20-window edit, move, resize and viewmodel commands", app.NoteWindows.Count == 20 && app.State.Notes.All(n => n.Body.StartsWith("20 张便签")), $"Batch layout {watch.Elapsed.TotalMilliseconds:F1} ms");
            await app.SaveNowAsync(); var restored = app.Store.Load();
            Check("20-window state roundtrip", restored.Notes.Count == 20 && restored.Notes.All(n => n.Width >= 312 && n.Height >= 328));
            app.HideAll(); Check("hide all retains resident app and note records", app.NoteWindows.Values.All(w => !w.IsVisible) && app.State.Notes.Count == 20);
            app.ShowAll(); Check("show all restores 20 independent windows", app.NoteWindows.Values.All(w => w.IsVisible));
            await app.ExitAsync();
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(output, "failure.txt"), ex.ToString()); await app.ExitAsync(); Environment.ExitCode = 1; }
    }
}
