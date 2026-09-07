using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Animation;

namespace StickyNotes;

public partial class NoteWindow : Window
{
    public Note Note { get; }
    public NoteViewModel ViewModel { get; }
    private readonly App app = App.CurrentApp;
    private bool ready, closing, arranging;
    public NoteWindow(Note note)
    {
        Note = note; ViewModel = new NoteViewModel(note, app); InitializeComponent(); DataContext = ViewModel; NativeWindow.Chrome(this);
        if (Environment.GetEnvironmentVariable("STICKYNOTES_UI_TEST") == "1" && Environment.GetEnvironmentVariable("STICKYNOTES_DATA_DIR") != null) ShowInTaskbar = true;
        Left = note.Left; Top = note.Top; Width = note.Width; Height = note.Height;
        ApplyAppearance(); ApplyFold(); RefreshPin(); RefreshReminder();
        note.PropertyChanged += ModelChanged;
        app.SaveStatusChanged += RefreshSave;
        app.StateChanged += RefreshReminder;
        Loaded += (_, _) => { ready = true; NativeWindow.EnsureVisible(this); };
        ContentRendered += (_, _) =>
        {
            if (app.State.Settings.Animations) Root.BeginAnimation(OpacityProperty, new DoubleAnimation(0.65, 1, TimeSpan.FromMilliseconds(130)));
        };
        LocationChanged += (_, _) => SaveGeometry(); SizeChanged += (_, _) => SaveGeometry();
        Deactivated += async (_, _) => { if (!app.IsExiting) await app.SaveNowAsync(); };
        Closing += (_, e) => { if (!closing && !app.IsExiting) { e.Cancel = true; app.HideNote(Note); } };
        Closed += (_, _) => { ViewModel.Dispose(); note.PropertyChanged -= ModelChanged; app.SaveStatusChanged -= RefreshSave; app.StateChanged -= RefreshReminder; };
        TodoInput.TextChanged += (_, _) => TodoHint.Visibility = TodoInput.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.N && Keyboard.Modifiers == ModifierKeys.Control) { app.NewNote(); e.Handled = true; }
            if (e.Key == Key.W && Keyboard.Modifiers == ModifierKeys.Control) { app.HideNote(Note); e.Handled = true; }
            if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control) { _ = app.SaveNowAsync(); e.Handled = true; }
        };
        RefreshSave();
    }
    private void ModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(Note.Theme) or nameof(Note.Font) or nameof(Note.FontSize)) ApplyAppearance();
        if (e.PropertyName == nameof(Note.Pinned)) RefreshPin();
        if (e.PropertyName == nameof(Note.Collapsed)) ApplyFold();
        if (e.PropertyName is nameof(Note.Title) or nameof(Note.DisplayTitle)) { Title = Note.DisplayTitle + " · 便利贴"; HeaderLabel.Text = Note.Collapsed ? Note.DisplayTitle : "便利贴"; }
    }
    private void SaveGeometry()
    {
        if (!ready || arranging || WindowState != WindowState.Normal) return;
        Note.Left = Left; Note.Top = Top; Note.Width = Width; if (!Note.Collapsed) Note.Height = Height;
    }
    public void ApplyAppearance()
    {
        Themes.Apply(this, Note.Theme); System.Windows.Documents.TextElement.SetFontFamily(EditorPanel, Themes.Font(Note.Font)); System.Windows.Documents.TextElement.SetFontSize(EditorPanel, Note.FontSize);
        Title = Note.DisplayTitle + " · 便利贴";
    }
    private void RefreshPin() { Topmost = Note.Pinned; PinButton.Content = Note.Pinned ? "●" : "○"; PinButton.ToolTip = Note.Pinned ? "已置顶 · 点击取消" : "点击置顶"; }
    private void RefreshSave() { SaveStatus.Text = app.SaveMessage; SaveStatus.ToolTip = app.SaveMessage; }
    private void RefreshReminder()
    {
        ReminderButton.Content = Note.Reminder.Pending ? "◷ 待处理" : Note.Reminder.Due is { } due ? "◷ " + due.ToLocalTime().ToString("MM/dd HH:mm") : "◷ 提醒";
    }
    private void ApplyFold()
    {
        arranging = true;
        EditorScroll.Visibility = Footer.Visibility = SaveStatus.Visibility = Note.Collapsed ? Visibility.Collapsed : Visibility.Visible;
        Root.RowDefinitions[3].Height = new GridLength(Note.Collapsed ? 0 : 38);
        MinHeight = Note.Collapsed ? 44 : 240; MaxHeight = Note.Collapsed ? 44 : double.PositiveInfinity;
        Height = Note.Collapsed ? 44 : Note.Height;
        HeaderLabel.Text = Note.Collapsed ? Note.DisplayTitle : "便利贴";
        HeaderLabel.MaxWidth = Math.Max(45, Note.Width - 175); HeaderLabel.TextTrimming = TextTrimming.CharacterEllipsis;
        FoldButton.Content = Note.Collapsed ? "⌄" : "⌃"; FoldButton.ToolTip = Note.Collapsed ? "展开便签" : "折叠成标题条";
        arranging = false;
    }
    public void ClosePermanently() { closing = true; Close(); }
    private void DragHeader(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2) { Note.Collapsed = !Note.Collapsed; return; }
        if (e.LeftButton == MouseButtonState.Pressed) { DragMove(); NativeWindow.EnsureVisible(this); }
    }
    private void OpenReminder(object sender, RoutedEventArgs e) { var dialog = new ReminderWindow(Note) { Owner = this }; dialog.ShowDialog(); }
    private void OpenFocus(object sender, RoutedEventArgs e) => app.ShowFocus(Note);
    private void AddTodoKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && !string.IsNullOrWhiteSpace(TodoInput.Text)) { Note.Todos.Add(new Todo { Text = TodoInput.Text.Trim() }); TodoInput.Clear(); EditorScroll.ScrollToEnd(); e.Handled = true; }
    }
    private void OpenMenu(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        var themes = new MenuItem { Header = "便签风格" };
        foreach (var t in Themes.All)
        {
            var item = new MenuItem { Header = t.Name, IsCheckable = true, IsChecked = Note.Theme == t.Id };
            item.Click += (_, _) => Note.Theme = t.Id; themes.Items.Add(item);
        }
        menu.Items.Add(themes);
        var fonts = new MenuItem { Header = "字体" };
        foreach (var font in Themes.AvailableFonts)
        {
            var item = new MenuItem { Header = Themes.FontLabel(font), IsCheckable = true, IsChecked = Note.Font == font, FontFamily = Themes.Font(font) };
            item.Click += (_, _) => Note.Font = font; fonts.Items.Add(item);
        }
        menu.Items.Add(fonts);
        var sizes = new MenuItem { Header = "字号" };
        foreach (int size in new[] { 12, 14, 15, 16, 18, 20, 24, 28 })
        {
            var item = new MenuItem { Header = size.ToString(), IsCheckable = true, IsChecked = Note.FontSize == size };
            item.Click += (_, _) => Note.FontSize = size; sizes.Items.Add(item);
        }
        menu.Items.Add(sizes); menu.Items.Add(new Separator());
        var list = new MenuItem { Header = "全部便签" }; list.Click += (_, _) => app.ShowManager(); menu.Items.Add(list);
        var settings = new MenuItem { Header = "设置" }; settings.Click += (_, _) => app.ShowSettings(); menu.Items.Add(settings);
        menu.Items.Add(new Separator());
        var delete = new MenuItem { Header = "移入回收站（保留 30 天）" }; delete.Click += (_, _) => app.Delete(Note); menu.Items.Add(delete);
        menu.PlacementTarget = (UIElement)sender; menu.IsOpen = true;
    }
}
