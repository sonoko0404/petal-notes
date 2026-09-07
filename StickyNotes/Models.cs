using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace StickyNotes;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        return true;
    }
    public void Notify(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class Todo : Observable
{
    private string text = "";
    private bool done;
    public string Text { get => text; set => Set(ref text, value); }
    public bool Done { get => done; set => Set(ref done, value); }
    public Todo Copy() => new() { Text = Text, Done = Done };
}

public sealed class Note : Observable
{
    public Guid Id { get; set; } = Guid.NewGuid();
    private string title = "", body = "", theme = "cream", font = "Microsoft YaHei UI";
    private double size = 15, left = 100, top = 100, width = 300, height = 320;
    private bool pinned = true, hidden, collapsed;
    private DateTimeOffset? deletedAt;
    public string Title { get => title; set { if (Set(ref title, value)) Notify(nameof(DisplayTitle)); } }
    public string Body { get => body; set => Set(ref body, value); }
    public string Theme { get => theme; set => Set(ref theme, value); }
    public string Font { get => font; set => Set(ref font, value); }
    public double FontSize { get => size; set => Set(ref size, value); }
    public double Left { get => left; set => Set(ref left, value); }
    public double Top { get => top; set => Set(ref top, value); }
    public double Width { get => width; set => Set(ref width, value); }
    public double Height { get => height; set => Set(ref height, value); }
    public bool Pinned { get => pinned; set => Set(ref pinned, value); }
    public bool Hidden { get => hidden; set => Set(ref hidden, value); }
    public bool Collapsed { get => collapsed; set => Set(ref collapsed, value); }
    public DateTimeOffset? DeletedAt { get => deletedAt; set => Set(ref deletedAt, value); }
    public ObservableCollection<Todo> Todos { get; set; } = new();
    public Reminder Reminder { get; set; } = new();
    [JsonIgnore] public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? "无标题便签" : Title;
    public Note Copy() => new()
    {
        Id = Id, Title = Title, Body = Body, Theme = Theme, Font = Font, FontSize = FontSize,
        Left = Left, Top = Top, Width = Width, Height = Height, Pinned = Pinned, Hidden = Hidden,
        Collapsed = Collapsed, DeletedAt = DeletedAt,
        Todos = new(Todos.Select(t => t.Copy())), Reminder = Reminder.Copy()
    };
}

public sealed class Reminder
{
    public DateTimeOffset? Due { get; set; }
    public bool Daily { get; set; }
    public int Hour { get; set; } = 9;
    public int Minute { get; set; }
    public bool Pending { get; set; }
    public Reminder Copy() => (Reminder)MemberwiseClone();
}

public sealed class Settings
{
    public string DefaultTheme { get; set; } = "cream";
    public string DefaultFont { get; set; } = "Microsoft YaHei UI";
    public double DefaultFontSize { get; set; } = 15;
    public bool Sound { get; set; }
    public bool Animations { get; set; } = true;
    public int FocusMinutes { get; set; } = 25;
    public int BreakMinutes { get; set; } = 5;
    public int LongBreakMinutes { get; set; } = 15;
    public Settings Copy() => (Settings)MemberwiseClone();
}

public sealed class Pomodoro
{
    public string Phase { get; set; } = "focus";
    public int CompletedRounds { get; set; }
    public double RemainingSeconds { get; set; } = 1500;
    public DateTimeOffset? EndsAt { get; set; }
    public Guid? NoteId { get; set; }
    public bool Pending { get; set; }
    public string LastMessage { get; set; } = "";
    public Pomodoro Copy() => (Pomodoro)MemberwiseClone();
}

public sealed class AppState
{
    public int SchemaVersion { get; set; } = 1;
    public List<Note> Notes { get; set; } = new();
    public Settings Settings { get; set; } = new();
    public Pomodoro Pomodoro { get; set; } = new();
    public AppState Copy() => new() { SchemaVersion = SchemaVersion, Notes = Notes.Select(n => n.Copy()).ToList(), Settings = Settings.Copy(), Pomodoro = Pomodoro.Copy() };
}

public static class TimeLogic
{
    public static DateTimeOffset NextDaily(DateTimeOffset now, int hour, int minute)
    {
        var local = now.LocalDateTime;
        var next = local.Date.AddHours(hour).AddMinutes(minute);
        if (next <= local) next = next.AddDays(1);
        while (TimeZoneInfo.Local.IsInvalidTime(next)) next = next.AddMinutes(1);
        return new DateTimeOffset(next, TimeZoneInfo.Local.GetUtcOffset(next));
    }
    public static double Remaining(Pomodoro p, DateTimeOffset now) => p.EndsAt is { } end ? Math.Max(0, (end - now).TotalSeconds) : p.RemainingSeconds;
    public static bool Advance(Pomodoro p, Settings s, DateTimeOffset now)
    {
        if (p.EndsAt is not { } end || end > now) return false;
        if (p.Phase == "focus")
        {
            p.CompletedRounds++;
            p.Phase = p.CompletedRounds % 4 == 0 ? "longBreak" : "break";
            p.LastMessage = "这段专注完成啦，给自己一点休息时间。";
        }
        else { p.Phase = "focus"; p.LastMessage = "休息结束，准备好再开始下一段专注吧。"; }
        p.RemainingSeconds = Duration(p.Phase, s);
        p.EndsAt = null;
        p.Pending = true;
        return true;
    }
    public static double Duration(string phase, Settings s) => 60 * (phase == "focus" ? s.FocusMinutes : phase == "longBreak" ? s.LongBreakMinutes : s.BreakMinutes);
}
