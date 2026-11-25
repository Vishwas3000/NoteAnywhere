using System.Diagnostics;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Windows;

namespace NoteAnywhere;

/// Sends a problem or a suggestion without leaving the app, as the Mac's FeedbackView: noteanywhere.app/api/feedback
/// emails it (D72). A failed send keeps the text and offers email instead.
public partial class FeedbackWindow : Window
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    string Kind => IdeaKind.IsChecked == true ? "idea" : "problem";

    public FeedbackWindow()
    {
        InitializeComponent();
        About.Text = $"Sent with {AppInfo.About}.";
    }

    void OnKind(object sender, RoutedEventArgs e)
    {
        if (Hint != null) Hint.Text = Kind == "problem" ? "What went wrong, and what were you doing?" : "What would make NoteAnywhere better?";
    }

    void OnText(object sender, RoutedEventArgs e)
    {
        Hint.Visibility = Message.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmailHint.Visibility = Email.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Send.IsEnabled = !string.IsNullOrWhiteSpace(Message.Text);
    }

    async void OnSend(object sender, RoutedEventArgs e)
    {
        Send.IsEnabled = false;
        Send.Content = "Sending…";
        try
        {
            var response = await Http.PostAsJsonAsync("https://noteanywhere.app/api/feedback",
                new { kind = Kind, message = Message.Text, email = Email.Text.Trim(), app = AppInfo.About });
            if (response.IsSuccessStatusCode)
            {
                Thanks.Text = Email.Text.Trim().Length == 0 ? "Thank you." : $"Thank you. Replies go to {Email.Text.Trim()}.";
                Form.Visibility = Visibility.Collapsed;
                Sent.Visibility = Visibility.Visible;
                return;
            }
            var reason = await response.Content.ReadFromJsonAsync<JsonElement>() is { ValueKind: JsonValueKind.Object } body
                         && body.TryGetProperty("error", out var error) ? error.GetString() : null;
            Fail(reason ?? $"The feedback server answered {(int)response.StatusCode}. Try again, or email instead.");
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
        {
            Fail($"Couldn't reach noteanywhere.app: {ex.Message}");
        }
        finally
        {
            Send.Content = "Send";
            Send.IsEnabled = !string.IsNullOrWhiteSpace(Message.Text);
        }
    }

    void Fail(string reason)
    {
        Failure.Text = reason;
        Failure.Visibility = EmailInstead.Visibility = Visibility.Visible;
    }

    void OnEmailInstead(object sender, RoutedEventArgs e)
    {
        var subject = Uri.EscapeDataString($"NoteAnywhere {(Kind == "idea" ? "suggestion" : "problem")}");
        var body = Uri.EscapeDataString($"{Message.Text}\n\n--\n{AppInfo.About}");
        Process.Start(new ProcessStartInfo($"mailto:timeupvishwa@gmail.com?subject={subject}&body={body}") { UseShellExecute = true });
    }

    void OnDone(object sender, RoutedEventArgs e) => Close();
}
