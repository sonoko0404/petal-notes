using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Input;

namespace StickyNotes;

public sealed class ActionCommand : ICommand
{
    private readonly Action<object?> action;
    public ActionCommand(Action<object?> action) => this.action = action;
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => action(parameter);
    public event EventHandler? CanExecuteChanged { add { } remove { } }
}

// The editor binds to view state and commands; scheduling, storage and window lifetime live in App.
public sealed class NoteViewModel : Observable, IDisposable
{
    public Note Model { get; }
    public string Title { get => Model.Title; set => Model.Title = value; }
    public string Body { get => Model.Body; set => Model.Body = value; }
    public ObservableCollection<Todo> Todos => Model.Todos;
    public ICommand NewCommand { get; }
    public ICommand HideCommand { get; }
    public ICommand PinCommand { get; }
    public ICommand FoldCommand { get; }
    public ICommand RemoveTodoCommand { get; }
    public NoteViewModel(Note model, App app)
    {
        Model = model; Model.PropertyChanged += ModelChanged;
        NewCommand = new ActionCommand(_ => app.NewNote()); HideCommand = new ActionCommand(_ => app.HideNote(Model));
        PinCommand = new ActionCommand(_ => Model.Pinned = !Model.Pinned); FoldCommand = new ActionCommand(_ => Model.Collapsed = !Model.Collapsed);
        RemoveTodoCommand = new ActionCommand(value => { if (value is Todo todo) Model.Todos.Remove(todo); });
    }
    private void ModelChanged(object? sender, PropertyChangedEventArgs e) { if (e.PropertyName is not null) Notify(e.PropertyName); }
    public void Dispose() => Model.PropertyChanged -= ModelChanged;
}
