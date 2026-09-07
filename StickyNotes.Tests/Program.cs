using StickyNotes;
using System.Text.Json;

var checks = new List<object>();
string root = Path.GetFullPath(args.Length > 0 ? args[0] : Path.Combine(Path.GetTempPath(), "StickyNotesTests-" + Guid.NewGuid()));
Directory.CreateDirectory(root);
void Assert(string name, bool condition)
{
    checks.Add(new { name, passed = condition }); Console.WriteLine((condition ? "PASS " : "FAIL ") + name);
    if (!condition) throw new Exception(name);
}
try
{
    var store = new Storage(Path.Combine(root, "roundtrip"));
    var state = new AppState(); var note = new Note { Title = "中文与 Emoji 🌼", Body = "第一行\nsecond line\t第三行", Theme = "mint" }; state.Notes.Add(note);
    note.Todos.Add(new Todo { Text = "准备好", Done = true });
    note.Reminder.Due = DateTimeOffset.Now.AddHours(2); note.Reminder.Daily = true; note.Reminder.Hour = 11; note.Reminder.Minute = 17;
    state.Pomodoro.EndsAt = DateTimeOffset.Now.AddMinutes(24); state.Pomodoro.NoteId = note.Id;
    await store.SaveAsync(state.Copy());
    var restored = store.Load();
    Assert("Unicode, todos, reminder and timer roundtrip", restored.Notes[0].Title == note.Title && restored.Notes[0].Body == note.Body && restored.Notes[0].Todos[0].Done && restored.Pomodoro.EndsAt == state.Pomodoro.EndsAt && restored.Notes[0].Reminder.Due == note.Reminder.Due);
    var snapshot = state.Copy(); note.Body = "changed after snapshot"; note.Todos[0].Text = "changed";
    Assert("save snapshot isolated from edits", snapshot.Notes[0].Body != note.Body && snapshot.Notes[0].Todos[0].Text != note.Todos[0].Text);
    await store.SaveAsync(state.Copy());
    await File.WriteAllTextAsync(store.Path, "{broken json");
    var recovered = store.Load();
    Assert("invalid primary recovers backup", recovered.Notes[0].Body == snapshot.Notes[0].Body && store.LoadWarning != null);
    await store.SaveAsync(recovered.Copy()); await File.WriteAllTextAsync(store.Path, "broken again");
    Assert("recovery does not replace good backup with corrupt primary", store.Load().Notes[0].Title == note.Title);
    var bad = new Storage(Path.Combine(root, "unreadable")); await File.WriteAllTextAsync(bad.Path, "bad"); await File.WriteAllTextAsync(bad.Path + ".bak", "bad");
    bool failed = false; try { bad.Load(); } catch (InvalidDataException) { failed = true; }
    Assert("two unreadable files fail without overwriting", failed && await File.ReadAllTextAsync(bad.Path) == "bad");
    var future = new Storage(Path.Combine(root, "future")); await File.WriteAllTextAsync(future.Path, "{\"SchemaVersion\":2}");
    failed = false; try { future.Load(); } catch (NotSupportedException) { failed = true; }
    Assert("future schema refused", failed);
    var ordered = new Storage(Path.Combine(root, "ordered")); var tasks = new List<Task>();
    for (int i = 0; i < 40; i++) { state.Notes[0].Title = i.ToString(); tasks.Add(ordered.SaveAsync(state.Copy())); }
    await Task.WhenAll(tasks);
    Assert("concurrent saves serialized, latest state retained", ordered.Load().Notes[0].Title == "39");
    Assert("atomic writes leave no temp file", !File.Exists(ordered.Path + ".tmp"));
    var now = new DateTimeOffset(2026, 9, 6, 16, 0, 0, TimeSpan.Zero).ToLocalTime();
    var daily = TimeLogic.NextDaily(now, now.Hour, now.Minute);
    Assert("daily scheduling strictly future", daily > now && daily <= now.AddHours(26));
    var p = new Pomodoro { RemainingSeconds = 90, EndsAt = now.AddSeconds(90) };
    Assert("timer uses absolute timestamps", TimeLogic.Remaining(p, now.AddSeconds(15)) == 75);
    p.RemainingSeconds = TimeLogic.Remaining(p, now.AddSeconds(15)); p.EndsAt = null;
    Assert("paused timer does not drift", TimeLogic.Remaining(p, now.AddHours(5)) == 75);
    var s = new Settings(); p.EndsAt = now.AddSeconds(-3);
    Assert("overdue focus advances once", TimeLogic.Advance(p, s, now) && p.Phase == "break" && p.RemainingSeconds == 300 && p.CompletedRounds == 1 && p.EndsAt == null && p.Pending);
    Assert("repeated deadline checks do not double count", !TimeLogic.Advance(p, s, now.AddHours(1)) && p.CompletedRounds == 1);
    p.Phase = "focus"; p.CompletedRounds = 3; p.EndsAt = now.AddSeconds(-1);
    Assert("fourth focus yields long break", TimeLogic.Advance(p, s, now) && p.Phase == "longBreak" && p.RemainingSeconds == 900);
    p.EndsAt = now.AddSeconds(-1);
    Assert("break ends ready for manual focus start", TimeLogic.Advance(p, s, now) && p.Phase == "focus" && p.EndsAt == null && p.RemainingSeconds == 1500);
    s.FocusMinutes = 40; p.EndsAt = now.AddSeconds(60); TimeLogic.Advance(p, s, now);
    Assert("settings preserve running deadline", p.EndsAt == now.AddSeconds(60));
    state.Notes[0].Width = -4; state.Notes[0].Height = double.NaN; state.Notes[0].FontSize = 300; Storage.Validate(state);
    Assert("invalid geometry normalized", state.Notes[0].Width == 260 && state.Notes[0].Height == 320 && state.Notes[0].FontSize == 28);
    state.Notes.Add(state.Notes[0].Copy()); failed = false;
    try { Storage.Validate(state); } catch (InvalidDataException) { failed = true; }
    Assert("duplicate identifiers rejected", failed);
    var denied = new Storage(Path.Combine(root, "locked")); await denied.SaveAsync(new AppState());
    using (var fileLock = File.Open(denied.Path + ".tmp", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
    {
        failed = false; try { await denied.SaveAsync(new AppState()); } catch (IOException) { failed = true; }
        Assert("write failure surfaced to caller", failed);
    }
    await denied.SaveAsync(new AppState()); Assert("saving recovers after transient failure", denied.Load().SchemaVersion == 1);
    await File.WriteAllTextAsync(Path.Combine(root, "test-results.json"), JsonSerializer.Serialize(checks, new JsonSerializerOptions { WriteIndented = true }));
    Console.WriteLine($"{checks.Count} checks passed. Results: {root}");
}
catch (Exception ex) { Console.Error.WriteLine(ex); Environment.ExitCode = 1; }
