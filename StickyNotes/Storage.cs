using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace StickyNotes;

public sealed class Storage
{
    private readonly string directory;
    private readonly SemaphoreSlim gate = new(1);
    public string Path => System.IO.Path.Combine(directory, "notes.json");
    public string? LoadWarning { get; private set; }
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
    public Storage(string directory) { this.directory = directory; Directory.CreateDirectory(directory); }
    public AppState Load()
    {
        if (!File.Exists(Path) && !File.Exists(Path + ".bak")) return new();
        foreach (var file in new[] { Path, Path + ".bak" })
        {
            try
            {
                if (!File.Exists(file)) continue;
                var result = JsonSerializer.Deserialize<AppState>(File.ReadAllText(file), Options) ?? throw new InvalidDataException("数据为空");
                Validate(result);
                if (file.EndsWith(".bak")) LoadWarning = "上次的数据文件未能读取，已恢复上一份有效备份。";
                return result;
            }
            catch (NotSupportedException) { throw; }
            catch (Exception e) when (e is IOException or JsonException or InvalidDataException or UnauthorizedAccessException)
            {
                if (file == Path && File.Exists(Path))
                {
                    // Preserve evidence before a subsequent successful save can replace the bad file.
                    File.Copy(Path, Path + ".unreadable-" + DateTime.Now.ToString("yyyyMMddHHmmssfff"), true);
                }
            }
        }
        throw new InvalidDataException("便签和备份都无法读取。原文件已保留，请先备份数据目录再修复；应用不会覆盖它们。");
    }
    public static void Validate(AppState s)
    {
        if (s.SchemaVersion != 1) throw new NotSupportedException("此数据版本不受支持，请使用匹配版本的便利贴。");
        if (s.Notes == null || s.Settings == null || s.Pomodoro == null) throw new InvalidDataException("缺少数据字段");
        var ids = new System.Collections.Generic.HashSet<Guid>();
        foreach (var n in s.Notes)
        {
            if (n == null || n.Todos == null || n.Reminder == null || !ids.Add(n.Id)) throw new InvalidDataException("便签数据无效");
            if (!double.IsFinite(n.Left) || !double.IsFinite(n.Top)) { n.Left = 100; n.Top = 100; }
            n.Width = double.IsFinite(n.Width) ? Math.Clamp(n.Width, 260, 1600) : 300;
            n.Height = double.IsFinite(n.Height) ? Math.Clamp(n.Height, 240, 1600) : 320;
            n.FontSize = double.IsFinite(n.FontSize) ? Math.Clamp(n.FontSize, 12, 28) : 15;
            n.Title ??= ""; n.Body ??= "";
            n.Reminder.Hour = Math.Clamp(n.Reminder.Hour, 0, 23);
            n.Reminder.Minute = Math.Clamp(n.Reminder.Minute, 0, 59);
            foreach (var t in n.Todos) { if (t == null) throw new InvalidDataException("待办数据无效"); t.Text ??= ""; }
        }
        s.Settings.FocusMinutes = Math.Clamp(s.Settings.FocusMinutes, 1, 180);
        s.Settings.BreakMinutes = Math.Clamp(s.Settings.BreakMinutes, 1, 60);
        s.Settings.LongBreakMinutes = Math.Clamp(s.Settings.LongBreakMinutes, 1, 120);
        if (s.Pomodoro.Phase is not ("focus" or "break" or "longBreak")) s.Pomodoro.Phase = "focus";
        if (!double.IsFinite(s.Pomodoro.RemainingSeconds) || s.Pomodoro.RemainingSeconds < 0) s.Pomodoro.RemainingSeconds = TimeLogic.Duration(s.Pomodoro.Phase, s.Settings);
    }
    public async Task SaveAsync(AppState snapshot)
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                string temporary = Path + ".tmp";
                using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
                {
                    JsonSerializer.Serialize(stream, snapshot, Options);
                    stream.Flush(true);
                }
                if (File.Exists(Path))
                {
                    // Do not promote an invalid primary to the backup after recovery.
                    bool primaryValid;
                    try { var old = JsonSerializer.Deserialize<AppState>(File.ReadAllText(Path)); Validate(old!); primaryValid = true; }
                    catch { primaryValid = false; }
                    File.Replace(temporary, Path, primaryValid ? Path + ".bak" : null, true);
                }
                else File.Move(temporary, Path);
            }).ConfigureAwait(false);
        }
        finally { gate.Release(); }
    }
}
