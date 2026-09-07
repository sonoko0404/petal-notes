using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace StickyNotes;

// Opt-in developer verification. Requires an explicitly isolated data directory.
internal static class Diagnostics
{
    public static async Task RunAsync(App app, string[] args)
    {
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("STICKYNOTES_DATA_DIR"))) return;
        string output = Path.Combine(app.DataDirectory, "diagnostics"); Directory.CreateDirectory(output);
        var results = new List<object>();
        async Task Report(string name, bool pass, string detail = "")
        {
            results.Add(new { name, pass, detail });
            await File.WriteAllTextAsync(Path.Combine(output, "checks.json"), JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true }));
            if (!pass) throw new InvalidOperationException(name + ": " + detail);
        }
        try
        {
            var process = Process.GetCurrentProcess();
            double startupMs = (DateTime.Now - process.StartTime).TotalMilliseconds;
            for (int i = app.State.Notes.Count; i < 10; i++) app.NewNote();
            var area = SystemParameters.WorkArea;
            int index = 0;
            foreach (var n in app.State.Notes)
            {
                n.Pinned = false; n.Theme = Themes.All[index % Themes.All.Length].Id;
                n.Title = new[] { "今天，也要慢慢来", "灵感收集处", "让生活轻一点", "周末的小计划", "留给自己的时间" }[index % 5];
                n.Body = "把想到的事情写下来，\n给大脑放个小小的假。";
                n.Todos.Add(new Todo { Text = "喝一杯水，伸个懒腰" });
                n.Todos.Add(new Todo { Text = "完成今天最重要的一件事", Done = index % 2 == 0 });
                var w = app.NoteWindows[n.Id]; w.Left = area.Left + 30 + (index % 5) * 305; w.Top = area.Top + 35 + (index / 5) * 330; NativeWindow.EnsureVisible(w); index++;
            }
            await app.SaveNowAsync(); await Task.Delay(2000);
            process.Refresh(); long tenMemory = process.WorkingSet64;
            var beforeCpu = process.TotalProcessorTime; var measure = Stopwatch.StartNew(); await Task.Delay(10000); process.Refresh();
            double tenCpu = (process.TotalProcessorTime - beforeCpu).TotalMilliseconds / measure.Elapsed.TotalMilliseconds / Environment.ProcessorCount * 100;
            var n0 = app.State.Notes[0]; var w0 = app.NoteWindows[n0.Id];
            var editor = (TextBox)w0.FindName("BodyInput");
            string longText = string.Concat(Enumerable.Repeat("中文输入、English、标点与换行。\n", 1200));
            var editWatch = Stopwatch.StartNew(); editor.Text = longText; await Dispatcher.Yield(DispatcherPriority.ApplicationIdle); editWatch.Stop();
            await Report("long text binding", n0.Body == longText, $"{longText.Length} characters, layout {editWatch.Elapsed.TotalMilliseconds:F1} ms");
            editor.Text = "保持一点热爱，\n把日子过得可可爱爱。";
            n0.Todos[0].Done = true; await app.SaveNowAsync();
            var roundtrip = app.Store.Load();
            await Report("save and reload Chinese text and todos", roundtrip.Notes[0].Body == n0.Body && roundtrip.Notes[0].Todos[0].Done);
            double expandedHeight = n0.Height; n0.Collapsed = true; await Dispatcher.Yield();
            await Report("collapse", w0.Height == 44 && n0.Height == expandedHeight);
            n0.Collapsed = false; await Dispatcher.Yield(); await Report("expand restores size", Math.Abs(w0.Height - expandedHeight) < 1);
            n0.Pinned = true; await Report("native topmost binding", w0.Topmost); n0.Pinned = false;
            app.HideNote(n0); await Report("hide preserves data", !w0.IsVisible && app.State.Notes.Contains(n0)); app.ShowNote(n0, false);
            var trash = app.State.Notes[9]; app.Delete(trash); await Report("trash removes native window", trash.DeletedAt != null && !app.NoteWindows.ContainsKey(trash.Id)); app.Restore(trash);
            await Report("restore trash", trash.DeletedAt == null && app.NoteWindows.ContainsKey(trash.Id));
            w0.Left = -30000; w0.Top = -30000; NativeWindow.EnsureVisible(w0); await Dispatcher.Yield();
            await Report("offscreen position recovery", w0.Left > -30000 && w0.Top > -30000);
            w0.Left = area.Left + 30; w0.Top = area.Top + 35;
            foreach (var theme in Themes.All) { n0.Theme = theme.Id; await Dispatcher.Yield(); }
            n0.Theme = "cream";
            foreach (string font in Themes.AvailableFonts) { n0.Font = font; await Dispatcher.Yield(); }
            n0.Font = "Microsoft YaHei UI";
            await Report("themes and installed fonts", true, $"5 themes, {Themes.AvailableFonts.Length} fonts");
            app.SetReminder(n0, DateTimeOffset.Now.AddSeconds(-1), false, 9, 0); app.CheckDeadlines();
            await Report("overdue reminder", n0.Reminder.Pending);
            app.SnoozeReminder(n0); await Report("snooze", !n0.Reminder.Pending && n0.Reminder.Due > DateTimeOffset.Now.AddMinutes(4));
            app.SetReminder(n0, DateTimeOffset.Now.AddSeconds(-1), true, 9, 0); app.CheckDeadlines(); app.CompleteReminder(n0);
            await Report("daily completion reschedules", !n0.Reminder.Pending && n0.Reminder.Due > DateTimeOffset.Now);
            app.SetReminder(n0, null, false, 9, 0);
            var pomo = app.State.Pomodoro; pomo.EndsAt = DateTimeOffset.Now.AddSeconds(-5); app.CheckDeadlines();
            await Report("pomodoro deadline recovery", pomo.Phase == "break" && pomo.EndsAt == null && pomo.Pending);
            app.ClearFocusNotification(); pomo.Phase = "focus"; pomo.RemainingSeconds = 1500; pomo.CompletedRounds = 0;
            foreach (var n in app.State.Notes.Take(5)) Capture(app.NoteWindows[n.Id], Path.Combine(output, "theme-" + n.Theme + ".png"));
            var manager = new ManagerWindow(); manager.Show(); await Dispatcher.Yield(DispatcherPriority.ApplicationIdle); Capture(manager, Path.Combine(output, "manager.png")); manager.Close();
            var settings = new SettingsWindow(); settings.Show(); await Dispatcher.Yield(DispatcherPriority.ApplicationIdle); Capture(settings, Path.Combine(output, "settings.png")); settings.Close();
            var focus = new FocusWindow(); focus.Show(); await Dispatcher.Yield(DispatcherPriority.ApplicationIdle); Capture(focus, Path.Combine(output, "focus.png")); focus.Close();
            for (int i = 10; i < 20; i++) { var n = app.NewNote(); n.Pinned = false; n.Title = "性能观察 " + (i + 1); n.Body = "多窗口运行中，保持输入与拖动顺畅。"; n.Todos.Add(new Todo { Text = "观察 CPU 与内存" }); }
            await app.SaveNowAsync(); await Task.Delay(3000);
            await Report("20 independent windows", app.NoteWindows.Count == 20);
            double minutes = 30;
            int durationIndex = Array.IndexOf(args, "--soak-minutes"); if (durationIndex >= 0 && durationIndex + 1 < args.Length) double.TryParse(args[durationIndex + 1], out minutes);
            var samples = new List<object>(); var soak = Stopwatch.StartNew(); double previousCpu = process.TotalProcessorTime.TotalMilliseconds, previousTime = 0;
            async Task SaveMetrics(bool completed)
            {
                var data = new { completed, startupMs, tenWindows = new { workingSetMiB = tenMemory / 1048576d, cpuPercent = tenCpu }, soakMinutes = soak.Elapsed.TotalMinutes, requestedMinutes = minutes, windows = app.NoteWindows.Count, samples };
                await File.WriteAllTextAsync(Path.Combine(output, "performance.json"), JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true }));
            }
            await SaveMetrics(false);
            while (soak.Elapsed.TotalMinutes < minutes)
            {
                // A worker posts a UI heartbeat to measure dispatcher availability independently of the UI timer.
                var latency = await Task.Run(async () => { await Task.Delay(15000); var watch = Stopwatch.StartNew(); await app.Dispatcher.InvokeAsync(() => { }); return watch.Elapsed.TotalMilliseconds; });
                process.Refresh(); double elapsed = soak.Elapsed.TotalMilliseconds, cpu = process.TotalProcessorTime.TotalMilliseconds;
                samples.Add(new { seconds = soak.Elapsed.TotalSeconds, workingSetMiB = process.WorkingSet64 / 1048576d, privateMiB = process.PrivateMemorySize64 / 1048576d, cpuPercent = (cpu - previousCpu) / (elapsed - previousTime) / Environment.ProcessorCount * 100, uiDispatchMs = latency, handles = process.HandleCount });
                previousCpu = cpu; previousTime = elapsed;
                await SaveMetrics(false);
            }
            await SaveMetrics(true); await Report("soak completed", true, $"{soak.Elapsed.TotalMinutes:F2} minutes, {samples.Count} samples");
            await app.ExitAsync();
        }
        catch (Exception ex) { await File.WriteAllTextAsync(Path.Combine(output, "failure.txt"), ex.ToString()); await app.ExitAsync(); }
    }
    private static void Capture(Window window, string path)
    {
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth * 1.5), (int)Math.Ceiling(window.ActualHeight * 1.5), 144, 144, PixelFormats.Pbgra32);
        bitmap.Render(window); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using var stream = File.Create(path); encoder.Save(stream);
    }
}
