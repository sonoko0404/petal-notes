using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace StickyNotes;

public partial class App : System.Windows.Application
{
    public static App CurrentApp => (App)Current;
    public AppState State { get; private set; } = new();
    public Storage Store { get; private set; } = null!;
    public string DataDirectory { get; private set; } = "";
    public bool IsExiting { get; private set; }
    public string SaveMessage { get; private set; } = "已保存到本机";
    public event Action? SaveStatusChanged;
    public event Action? StateChanged;
    public readonly Dictionary<Guid, NoteWindow> NoteWindows = new();
    private readonly DispatcherTimer saveTimer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private readonly DispatcherTimer scheduler = new();
    private Forms.NotifyIcon? tray;
    private Mutex? instanceMutex;
    private EventWaitHandle? wakeEvent;
    private RegisteredWaitHandle? wakeRegistration;
    private ManagerWindow? manager;
    private SettingsWindow? settings;
    private FocusWindow? focus;
    private ToastWindow? toast;
    private long revision;
    private bool purgeReady;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Resources[SystemParameters.VerticalScrollBarWidthKey] = 8d;
        DataDirectory = Environment.GetEnvironmentVariable("STICKYNOTES_DATA_DIR") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BianLiTie");
        var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(DataDirectory.ToLowerInvariant())))[..20];
        instanceMutex = new Mutex(true, "Local\\BianLiTie-" + key, out bool created);
        if (!created)
        {
            try { using var signal = EventWaitHandle.OpenExisting("Local\\BianLiTie-Wake-" + key); signal.Set(); } catch (WaitHandleCannotBeOpenedException) { }
            Shutdown(); return;
        }
        wakeEvent = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\BianLiTie-Wake-" + key);
        wakeRegistration = ThreadPool.RegisterWaitForSingleObject(wakeEvent, (_, _) => Dispatcher.BeginInvoke(new Action(ShowManager)), null, Timeout.Infinite, false);
        try { Store = new Storage(DataDirectory); State = Store.Load(); }
        catch (Exception ex) { MessageBox.Show(ex.Message + "\n\n数据目录：" + DataDirectory, "便利贴 · 无法读取", MessageBoxButton.OK, MessageBoxImage.Error); Shutdown(); return; }
        PurgeTrash();
        foreach (var note in State.Notes) Track(note);
        saveTimer.Tick += async (_, _) => { saveTimer.Stop(); await SaveNowAsync(); };
        scheduler.Tick += (_, _) => CheckDeadlines();
        SetupTray();
        SystemEvents.DisplaySettingsChanged += DisplaySettingsChanged;
        SystemEvents.PowerModeChanged += PowerModeChanged;
        SystemEvents.TimeChanged += SystemTimeChanged;
        if (State.Notes.Count == 0)
        {
            var first = NewNote();
            first.Title = "把小美好，贴在眼前";
            first.Body = "灵感、计划，还有今天的小期待，\n都可以放在这里。\n\n拖动顶部，把我放在喜欢的位置。";
            first.Todos.Add(new Todo { Text = "写下今天最想完成的一件事" });
        }
        else foreach (var n in State.Notes.Where(n => n.DeletedAt == null && !n.Hidden)) ShowNote(n, false);
        if (!NoteWindows.Values.Any(w => w.IsVisible)) ShowManager();
        CheckDeadlines();
        if (Store.LoadWarning != null) Dispatcher.BeginInvoke(new Action(() => MessageBox.Show(Store.LoadWarning, "便利贴 · 已恢复备份")));
        if (e.Args.Contains("--diagnostics")) Dispatcher.BeginInvoke(new Action(async () => await Diagnostics.RunAsync(this, e.Args)));
    }

    private void Track(Note note)
    {
        note.PropertyChanged += NoteChanged;
        foreach (var todo in note.Todos) todo.PropertyChanged += TodoChanged;
        note.Todos.CollectionChanged += (_, e) =>
        {
            if (e.OldItems != null) foreach (Todo t in e.OldItems) t.PropertyChanged -= TodoChanged;
            if (e.NewItems != null) foreach (Todo t in e.NewItems) t.PropertyChanged += TodoChanged;
            Changed();
        };
    }
    private void NoteChanged(object? sender, PropertyChangedEventArgs e) => Changed();
    private void TodoChanged(object? sender, PropertyChangedEventArgs e) => Changed();
    public void Changed()
    {
        if (IsExiting) return;
        revision++;
        SetSaveMessage("保存中…");
        saveTimer.Stop(); saveTimer.Start();
    }
    private void SetSaveMessage(string message)
    {
        if (SaveMessage == message) return;
        SaveMessage = message; SaveStatusChanged?.Invoke();
    }
    public async Task<bool> SaveNowAsync()
    {
        saveTimer.Stop();
        var savedRevision = revision;
        var snapshot = State.Copy();
        try
        {
            await Store.SaveAsync(snapshot);
            if (savedRevision == revision) SetSaveMessage("已保存到本机");
            StateChanged?.Invoke();
            return true;
        }
        catch (Exception ex)
        {
            SetSaveMessage("保存失败 · " + ex.Message);
            return false;
        }
    }

    public Note NewNote()
    {
        var offset = State.Notes.Count(n => n.DeletedAt == null) % 12 * 26;
        var area = SystemParameters.WorkArea;
        var n = new Note { Theme = State.Settings.DefaultTheme, Font = State.Settings.DefaultFont, FontSize = State.Settings.DefaultFontSize, Left = area.Left + 80 + offset, Top = area.Top + 70 + offset };
        State.Notes.Add(n); Track(n); ShowNote(n); Changed(); StateChanged?.Invoke(); return n;
    }
    public void ShowNote(Note n, bool activate = true)
    {
        if (n.DeletedAt != null) return;
        n.Hidden = false;
        if (!NoteWindows.TryGetValue(n.Id, out var window))
        {
            window = new NoteWindow(n); NoteWindows[n.Id] = window;
            window.Closed += (_, _) => NoteWindows.Remove(n.Id);
        }
        window.ShowActivated = activate;
        window.Show(); NativeWindow.EnsureVisible(window);
        if (activate) window.Activate();
    }
    public void HideNote(Note n) { n.Hidden = true; if (NoteWindows.TryGetValue(n.Id, out var w)) w.Hide(); Changed(); StateChanged?.Invoke(); }
    public void Delete(Note n)
    {
        n.DeletedAt = DateTimeOffset.Now; n.Hidden = true;
        if (NoteWindows.TryGetValue(n.Id, out var w)) w.ClosePermanently();
        if (State.Pomodoro.NoteId == n.Id) State.Pomodoro.NoteId = null;
        Changed(); StateChanged?.Invoke(); RefreshNotifications(); ScheduleNext();
    }
    public void Restore(Note n) { n.DeletedAt = null; ShowNote(n); Changed(); CheckDeadlines(); StateChanged?.Invoke(); }
    public void ShowAll() { foreach (var n in State.Notes.Where(n => n.DeletedAt == null)) ShowNote(n, false); }
    public void HideAll() { foreach (var n in State.Notes.Where(n => n.DeletedAt == null)) HideNote(n); }
    private void PurgeTrash()
    {
        var expired = State.Notes.Where(n => n.DeletedAt < DateTimeOffset.Now.AddDays(-30)).ToList();
        foreach (var n in expired) { n.PropertyChanged -= NoteChanged; foreach (var t in n.Todos) t.PropertyChanged -= TodoChanged; State.Notes.Remove(n); }
        if (purgeReady && expired.Count > 0) Changed();
        purgeReady = true;
    }
    public void ShowManager()
    {
        if (IsExiting) return;
        if (manager == null) { manager = new ManagerWindow(); manager.Closed += (_, _) => manager = null; }
        manager.Show(); manager.WindowState = WindowState.Normal; manager.Activate();
    }
    public void ShowSettings()
    {
        if (settings == null) { settings = new SettingsWindow(); settings.Closed += (_, _) => settings = null; }
        settings.Show(); settings.Activate();
    }
    public void ShowFocus(Note? note = null)
    {
        if (note != null) { State.Pomodoro.NoteId = note.Id; Changed(); }
        if (focus == null) { focus = new FocusWindow(); focus.Closed += (_, _) => focus = null; }
        focus.Show(); focus.Activate(); focus.Refresh();
    }
    public void SetReminder(Note n, DateTimeOffset? due, bool daily, int hour, int minute)
    {
        n.Reminder = new Reminder { Due = due, Daily = daily, Hour = hour, Minute = minute };
        Changed(); StateChanged?.Invoke(); RefreshNotifications(); ScheduleNext();
    }
    public void CompleteReminder(Note n)
    {
        n.Reminder.Pending = false;
        n.Reminder.Due = n.Reminder.Daily ? TimeLogic.NextDaily(DateTimeOffset.Now, n.Reminder.Hour, n.Reminder.Minute) : null;
        Changed(); StateChanged?.Invoke(); RefreshNotifications(); ScheduleNext();
    }
    public void SnoozeReminder(Note n)
    {
        n.Reminder.Pending = false; n.Reminder.Due = DateTimeOffset.Now.AddMinutes(5);
        Changed(); RefreshNotifications(); ScheduleNext();
    }
    public void CheckDeadlines()
    {
        scheduler.Stop();
        var now = DateTimeOffset.Now;
        bool changed = false;
        foreach (var n in State.Notes.Where(n => n.DeletedAt == null))
            if (!n.Reminder.Pending && n.Reminder.Due is { } due && due <= now) { n.Reminder.Pending = true; changed = true; }
        if (TimeLogic.Advance(State.Pomodoro, State.Settings, now)) changed = true;
        PurgeTrash();
        if (changed) { Changed(); if (State.Settings.Sound) System.Media.SystemSounds.Asterisk.Play(); }
        if (changed || toast == null && !notificationsShown) RefreshNotifications();
        focus?.Refresh(); ScheduleNext();
    }
    private bool notificationsShown;
    public void ScheduleNext()
    {
        scheduler.Stop();
        var now = DateTimeOffset.Now;
        var due = State.Notes.Where(n => n.DeletedAt == null && !n.Reminder.Pending && n.Reminder.Due.HasValue).Select(n => n.Reminder.Due!.Value).ToList();
        if (State.Pomodoro.EndsAt is { } end) due.Add(end);
        // Daily maintenance also expires old trash; otherwise no per-second polling.
        due.Add(now.AddHours(24));
        scheduler.Interval = TimeSpan.FromMilliseconds(Math.Max(50, (due.Min() - now).TotalMilliseconds)); scheduler.Start();
    }
    public void RefreshNotifications()
    {
        var pending = State.Notes.Where(n => n.DeletedAt == null && n.Reminder.Pending).ToList();
        if (pending.Count == 0 && !State.Pomodoro.Pending) { toast?.Close(); return; }
        if (toast == null) { toast = new ToastWindow(); toast.Closed += (_, _) => toast = null; }
        notificationsShown = true;
        toast.Refresh(pending); toast.Show();
    }
    public void ClearFocusNotification() { State.Pomodoro.Pending = false; Changed(); RefreshNotifications(); }
    private void SetupTray()
    {
        var stream = GetResourceStream(new Uri("pack://application:,,,/Assets/app.ico")).Stream;
        tray = new Forms.NotifyIcon { Icon = new System.Drawing.Icon(stream), Text = "便利贴 · 记下生活的小美好", Visible = true };
        var menu = new Forms.ContextMenuStrip();
        void Add(string label, Action action) => menu.Items.Add(label, null, (_, _) => Dispatcher.BeginInvoke(action));
        Add("＋ 新建便签", () => NewNote()); Add("全部显示", ShowAll); Add("全部隐藏", HideAll);
        menu.Items.Add(new Forms.ToolStripSeparator());
        Add("便签列表", ShowManager); Add("番茄钟", () => ShowFocus()); Add("待处理提醒", RefreshNotifications); Add("设置", ShowSettings);
        menu.Items.Add(new Forms.ToolStripSeparator()); Add("退出便利贴", async () => await ExitAsync());
        tray.ContextMenuStrip = menu; tray.DoubleClick += (_, _) => Dispatcher.BeginInvoke(new Action(ShowManager));
    }
    public async Task ExitAsync()
    {
        if (IsExiting) return;
        IsExiting = true; scheduler.Stop();
        foreach (Window w in Windows) w.IsEnabled = false;
        if (!await SaveNowAsync())
        {
            IsExiting = false; foreach (Window w in Windows) w.IsEnabled = true; ScheduleNext();
            MessageBox.Show("内容还没有成功保存，已取消退出。\n" + SaveMessage + "\n请释放磁盘空间或检查数据目录权限，然后重试。", "便利贴 · 保存失败");
            return;
        }
        Shutdown();
    }
    private void DisplaySettingsChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(new Action(() => { foreach (var w in NoteWindows.Values) if (w.IsVisible) NativeWindow.EnsureVisible(w); }));
    private void PowerModeChanged(object sender, PowerModeChangedEventArgs e) { if (e.Mode == PowerModes.Resume) Dispatcher.BeginInvoke(new Action(CheckDeadlines)); }
    private void SystemTimeChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(new Action(CheckDeadlines));
    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        try { if (Store != null) Store.SaveAsync(State.Copy()).GetAwaiter().GetResult(); }
        catch { e.Cancel = true; }
        base.OnSessionEnding(e);
    }
    protected override void OnExit(ExitEventArgs e)
    {
        IsExiting = true;
        SystemEvents.DisplaySettingsChanged -= DisplaySettingsChanged; SystemEvents.PowerModeChanged -= PowerModeChanged; SystemEvents.TimeChanged -= SystemTimeChanged;
        saveTimer.Stop(); scheduler.Stop(); tray?.Dispose(); wakeRegistration?.Unregister(null); wakeEvent?.Dispose(); instanceMutex?.Dispose();
        base.OnExit(e);
    }
}
