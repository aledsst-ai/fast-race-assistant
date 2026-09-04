#requires -Version 5.1

param(
    [switch]$ValidateOnly,
    [string]$IconPath = (Join-Path $PSScriptRoot 'fast-emblem.png'),
    [string]$UploadFile = '',
    [string]$ResultFile = '',
    [switch]$Reviewed,
    [string]$RaceKey = '',
    [int]$Position = 0,
    [string]$RaceTime = '',
    [switch]$CheckUpdate,
    [string]$UpdateResultFile = '',
    [string]$AnalyzeImage = '',
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
$script:AppName = 'FAST Race Assistant'
$script:AppVersion = '1.0.2'
try {
    $versionConfig = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'version.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string]$versionConfig.version -match '^\d+\.\d+\.\d+$') { $script:AppVersion = [string]$versionConfig.version }
} catch {}
$script:ApiOrigin = 'https://fastdivision.com.br'
$script:DataDirectory = Join-Path $env:LOCALAPPDATA 'FAST\RaceAssistant\data'
if ($SmokeTest) { $script:DataDirectory = Join-Path $env:TEMP 'FAST-RaceAssistant-SmokeTest' }
$script:ConfigPath = Join-Path $script:DataDirectory 'assistant.json'
$script:PendingUpdatePath = Join-Path $script:DataDirectory 'pending-update.zip'
$script:ManifestUrl = 'https://github.com/aledsst-ai/fast-race-assistant/releases/latest/download/fast-race-assistant-latest.json'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class FastRaceCapture
{
    private const string AnnouncementPayloadPrefix = "FAST_ANNOUNCEMENT_QUEUE_V1|";
    private const int WhKeyboardLl = 13;
    private const int WmKeyDown = 0x0100;
    private const int WmKeyUp = 0x0101;
    private const int WmSysKeyDown = 0x0104;
    private const int WmSysKeyUp = 0x0105;
    private const int VkControl = 0x11;
    private const int VkV = 0x56;
    private const uint LlkhfInjected = 0x10;
    private const uint KeyeventfKeyup = 0x0002;
    private static readonly List<string> PasteQueue = new List<string>();
    private static LowLevelKeyboardProc pasteHookProc;
    private static IntPtr pasteHookId = IntPtr.Zero;
    private static Mutex pasteMutex;
    private static int pasteQueueIndex;
    private static bool pasteActive;
    private static bool pasteHandledVDown;

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr handle, out RECT rect);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr handle, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    public static void EnableDpiAwareness()
    {
        try { SetProcessDPIAware(); } catch { }
    }

    public static bool InstallAnnouncementPasteHook()
    {
        bool createdNew;
        pasteMutex = new Mutex(true, "Local\\FAST_Announcement_Paste_Helper_V1", out createdNew);
        if (!createdNew)
        {
            pasteMutex.Dispose();
            pasteMutex = null;
            return false;
        }
        pasteHookProc = PasteHookCallback;
        pasteHookId = SetWindowsHookEx(WhKeyboardLl, pasteHookProc, GetModuleHandle(null), 0);
        if (pasteHookId != IntPtr.Zero) return true;
        pasteMutex.ReleaseMutex();
        pasteMutex.Dispose();
        pasteMutex = null;
        return false;
    }

    public static void ShutdownAnnouncementPasteHook()
    {
        if (pasteHookId != IntPtr.Zero)
        {
            UnhookWindowsHookEx(pasteHookId);
            pasteHookId = IntPtr.Zero;
        }
        PasteQueue.Clear();
        pasteActive = false;
        if (pasteMutex != null)
        {
            try { pasteMutex.ReleaseMutex(); } catch { }
            pasteMutex.Dispose();
            pasteMutex = null;
        }
    }

    public static int PollAnnouncementQueue()
    {
        return TryLoadAnnouncementQueue() ? PasteQueue.Count : 0;
    }

    private static bool TryLoadAnnouncementQueue()
    {
        string clipboardText;
        if (!TryReadAnnouncementPayload(out clipboardText)) return false;
        string[] encodedFields = clipboardText.Substring(AnnouncementPayloadPrefix.Length).Split('|');
        if (encodedFields.Length < 3) return false;
        var decoded = new List<string>();
        for (int index = 0; index < encodedFields.Length && index < 4; index++)
        {
            try
            {
                string value = Encoding.UTF8.GetString(Convert.FromBase64String(encodedFields[index]));
                if (!String.IsNullOrWhiteSpace(value)) decoded.Add(value);
            }
            catch { return false; }
        }
        if (decoded.Count < 3) return false;
        PasteQueue.Clear();
        PasteQueue.AddRange(decoded);
        pasteQueueIndex = 0;
        pasteActive = true;
        SetClipboardText(PasteQueue[0]);
        return true;
    }

    private static bool TryReadAnnouncementPayload(out string clipboardText)
    {
        clipboardText = null;
        try
        {
            if (Clipboard.ContainsText(TextDataFormat.Html))
            {
                string html = Clipboard.GetText(TextDataFormat.Html);
                int start = html.IndexOf(AnnouncementPayloadPrefix, StringComparison.Ordinal);
                if (start >= 0)
                {
                    int end = start;
                    while (end < html.Length && !Char.IsWhiteSpace(html[end]) && html[end] != '<' && html[end] != '>') end++;
                    clipboardText = html.Substring(start, end - start);
                }
            }
            if (String.IsNullOrEmpty(clipboardText) && Clipboard.ContainsText(TextDataFormat.UnicodeText))
            {
                string plain = Clipboard.GetText(TextDataFormat.UnicodeText);
                if (!String.IsNullOrEmpty(plain) && plain.StartsWith(AnnouncementPayloadPrefix, StringComparison.Ordinal)) clipboardText = plain;
            }
        }
        catch { return false; }
        return !String.IsNullOrEmpty(clipboardText) && clipboardText.StartsWith(AnnouncementPayloadPrefix, StringComparison.Ordinal);
    }

    private static IntPtr PasteHookCallback(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var data = (KeyboardHookData)Marshal.PtrToStructure(lParam, typeof(KeyboardHookData));
            bool injected = (data.flags & LlkhfInjected) != 0;
            bool keyDown = wParam == (IntPtr)WmKeyDown || wParam == (IntPtr)WmSysKeyDown;
            bool keyUp = wParam == (IntPtr)WmKeyUp || wParam == (IntPtr)WmSysKeyUp;
            if (!injected && data.vkCode == VkV)
            {
                if (keyDown && (GetAsyncKeyState(VkControl) & 0x8000) != 0)
                {
                    TryLoadAnnouncementQueue();
                    if (pasteActive)
                    {
                        if (!pasteHandledVDown)
                        {
                            pasteHandledVDown = true;
                            PasteNextAnnouncementValue();
                        }
                        return (IntPtr)1;
                    }
                }
                else if (keyUp && pasteHandledVDown)
                {
                    pasteHandledVDown = false;
                    return (IntPtr)1;
                }
            }
        }
        return CallNextHookEx(pasteHookId, code, wParam, lParam);
    }

    private static void PasteNextAnnouncementValue()
    {
        if (!pasteActive || pasteQueueIndex < 0 || pasteQueueIndex >= PasteQueue.Count) return;
        if (!SetClipboardText(PasteQueue[pasteQueueIndex]))
        {
            pasteActive = false;
            PasteQueue.Clear();
            return;
        }
        keybd_event((byte)VkControl, 0, 0, UIntPtr.Zero);
        keybd_event((byte)VkV, 0, 0, UIntPtr.Zero);
        keybd_event((byte)VkV, 0, KeyeventfKeyup, UIntPtr.Zero);
        keybd_event((byte)VkControl, 0, KeyeventfKeyup, UIntPtr.Zero);
        pasteQueueIndex++;
        if (pasteQueueIndex >= PasteQueue.Count)
        {
            pasteActive = false;
            PasteQueue.Clear();
            pasteQueueIndex = 0;
        }
    }

    private static bool SetClipboardText(string value)
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try { Clipboard.SetText(value ?? String.Empty, TextDataFormat.UnicodeText); return true; }
            catch { Thread.Sleep(25); }
        }
        return false;
    }

    public static bool TryCaptureCompletion(string outputPath)
    {
        IntPtr handle = GetForegroundWindow();
        if (handle == IntPtr.Zero) return false;

        uint processId;
        GetWindowThreadProcessId(handle, out processId);
        string processName = String.Empty;
        try { processName = Process.GetProcessById((int)processId).ProcessName; } catch { return false; }
        var titleBuffer = new StringBuilder(256);
        GetWindowText(handle, titleBuffer, titleBuffer.Capacity);
        string identity = (processName + " " + titleBuffer.ToString()).ToLowerInvariant();
        if (!identity.Contains("fivem") && !identity.Contains("gtaprocess") && !identity.Contains("grand theft auto")) return false;

        RECT rect;
        if (!GetWindowRect(handle, out rect)) return false;
        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;
        if (width < 1280 || height < 720) return false;

        int scanLeft = (int)(width * 0.20);
        int scanTop = (int)(height * 0.34);
        int scanWidth = Math.Max(1, (int)(width * 0.59));
        int scanHeight = Math.Max(1, (int)(height * 0.34));
        using (var scan = new Bitmap(scanWidth, scanHeight, PixelFormat.Format24bppRgb))
        {
            using (var graphics = Graphics.FromImage(scan))
            {
                graphics.CopyFromScreen(rect.Left + scanLeft, rect.Top + scanTop, 0, 0, new Size(scanWidth, scanHeight), CopyPixelOperation.SourceCopy);
            }
            if (!LooksLikeCompletionRegion(scan, 0, scan.Width, 0, scan.Height)) return false;
        }

        using (var capture = new Bitmap(width, height, PixelFormat.Format24bppRgb))
        {
            using (var graphics = Graphics.FromImage(capture))
                graphics.CopyFromScreen(rect.Left, rect.Top, 0, 0, new Size(width, height), CopyPixelOperation.SourceCopy);
            SaveCompressedProof(capture, outputPath);
        }
        return File.Exists(outputPath);
    }

    public static bool AnalyzeImage(string imagePath)
    {
        using (var image = new Bitmap(imagePath)) return LooksLikeCompletionCard(image);
    }

    private static bool LooksLikeCompletionCard(Bitmap image)
    {
        int left = (int)(image.Width * 0.20);
        int right = (int)(image.Width * 0.79);
        int top = (int)(image.Height * 0.34);
        int bottom = (int)(image.Height * 0.68);
        return LooksLikeCompletionRegion(image, left, right, top, bottom);
    }

    private static bool LooksLikeCompletionRegion(Bitmap image, int left, int right, int top, int bottom)
    {
        int step = Math.Max(3, image.Width / 640);
        long sampled = 0;
        long lime = 0;
        long white = 0;
        long limeHeader = 0;
        long limeFooter = 0;

        for (int y = top; y < bottom; y += step)
        {
            for (int x = left; x < right; x += step)
            {
                Color color = image.GetPixel(x, y);
                sampled++;
                bool isLime = color.G > 145 && color.G > color.R * 1.05 && color.G > color.B * 1.45;
                bool isWhite = color.R > 188 && color.G > 188 && color.B > 178 && Math.Abs(color.R - color.G) < 38;
                if (isLime)
                {
                    lime++;
                    double relativeY = (double)(y - top) / Math.Max(1, bottom - top);
                    if (relativeY < 0.38) limeHeader++;
                    if (relativeY > 0.58) limeFooter++;
                }
                if (isWhite) white++;
            }
        }

        if (sampled == 0) return false;
        double limeRatio = (double)lime / sampled;
        double whiteRatio = (double)white / sampled;
        return limeRatio > 0.008 && whiteRatio > 0.028 && limeHeader > 12 && limeFooter > 12;
    }

    private static void SaveCompressedProof(Bitmap source, string outputPath)
    {
        int maxWidth = 2560;
        int maxHeight = 1440;
        double scale = Math.Min(1.0, Math.Min((double)maxWidth / source.Width, (double)maxHeight / source.Height));
        int width = Math.Max(1, (int)Math.Round(source.Width * scale));
        int height = Math.Max(1, (int)Math.Round(source.Height * scale));
        using (var resized = new Bitmap(width, height, PixelFormat.Format24bppRgb))
        {
            using (var graphics = Graphics.FromImage(resized))
            {
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.CompositingQuality = CompositingQuality.HighQuality;
                graphics.DrawImage(source, new Rectangle(0, 0, width, height));
            }
            ImageCodecInfo codec = null;
            foreach (var candidate in ImageCodecInfo.GetImageEncoders())
                if (candidate.FormatID == ImageFormat.Jpeg.Guid) codec = candidate;
            long[] qualities = { 84L, 76L, 68L, 58L, 48L };
            foreach (long quality in qualities)
            {
                using (var parameters = new EncoderParameters(1))
                {
                    parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
                    resized.Save(outputPath, codec, parameters);
                }
                if (new FileInfo(outputPath).Length <= 1750000) return;
            }
        }
    }

    private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardHookData
    {
        public int vkCode;
        public int scanCode;
        public uint flags;
        public int time;
        public IntPtr extraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc callback, IntPtr module, uint threadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr GetModuleHandle(string moduleName);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int virtualKey);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
}
'@

try {
    Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies @('System.Drawing', 'System.Windows.Forms') -ErrorAction Stop
} catch {
    if ($_.Exception.Message -notmatch 'already exists') { throw }
}

if ($AnalyzeImage) {
    if ([FastRaceCapture]::AnalyzeImage($AnalyzeImage)) { Write-Output 'completion-card'; exit 0 }
    Write-Output 'not-detected'
    exit 2
}

function Ensure-DataDirectory {
    if (-not (Test-Path -LiteralPath $script:DataDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $script:DataDirectory -Force | Out-Null
    }
}

function Protect-Token([string]$Token) {
    $plain = [Text.Encoding]::UTF8.GetBytes($Token)
    $protected = [Security.Cryptography.ProtectedData]::Protect($plain, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
}

function Unprotect-Token([string]$ProtectedToken) {
    if ([string]::IsNullOrWhiteSpace($ProtectedToken)) { return '' }
    try {
        $protected = [Convert]::FromBase64String($ProtectedToken)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($plain)
    } catch { return '' }
}

function New-DeviceToken {
    $bytes = New-Object byte[] 48
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return 'fast_ra_' + [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Read-AppConfig {
    Ensure-DataDirectory
    if (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf) {
        try { return ([IO.File]::ReadAllText($script:ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch {}
    }
    $token = New-DeviceToken
    $config = [pscustomobject]@{ protectedToken = Protect-Token $token; monitoring = $true }
    Write-AppConfig $config
    return $config
}

function Write-AppConfig($Config) {
    Ensure-DataDirectory
    $json = $Config | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object Text.UTF8Encoding $false))
}

function Invoke-AssistantJson([string]$Method, [string]$Path, [string]$Token, $Body = $null) {
    $headers = @{ Authorization = "Bearer $Token"; 'X-FAST-App-Version' = $script:AppVersion }
    $arguments = @{ Uri = "$($script:ApiOrigin)$Path"; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 20 }
    if ($null -ne $Body) {
        $arguments.ContentType = 'application/json; charset=utf-8'
        $arguments.Body = ($Body | ConvertTo-Json -Compress)
    }
    try {
        $response = Invoke-WebRequest @arguments
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Body = ($response.Content | ConvertFrom-Json) }
    } catch {
        $status = 0
        $raw = ''
        if ($_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            try {
                $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                $raw = $reader.ReadToEnd()
                $reader.Dispose()
            } catch {}
        }
        $body = try { $raw | ConvertFrom-Json } catch { [pscustomobject]@{ error = 'network_error' } }
        return [pscustomobject]@{ Status = $status; Body = $body }
    }
}

function Invoke-ResultUpload([string]$ImagePath, [string]$Token, [bool]$WasReviewed, [string]$SelectedRaceKey, [int]$SelectedPosition, [string]$SelectedTime) {
    $client = New-Object Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(50)
    $client.DefaultRequestHeaders.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Token)
    $client.DefaultRequestHeaders.Add('X-FAST-App-Version', $script:AppVersion)
    $multipart = New-Object Net.Http.MultipartFormDataContent
    try {
        $imageContent = New-Object Net.Http.ByteArrayContent(,[IO.File]::ReadAllBytes($ImagePath))
        $imageContent.Headers.ContentType = New-Object Net.Http.Headers.MediaTypeHeaderValue('image/jpeg')
        $multipart.Add($imageContent, 'screenshot', 'comprovante.jpg')
        if ($WasReviewed) {
            $multipart.Add((New-Object Net.Http.StringContent('true')), 'reviewed')
            $multipart.Add((New-Object Net.Http.StringContent($SelectedRaceKey)), 'raceKey')
            $multipart.Add((New-Object Net.Http.StringContent([string]$SelectedPosition)), 'position')
            $multipart.Add((New-Object Net.Http.StringContent($SelectedTime)), 'time')
        }
        $response = $client.PostAsync("$($script:ApiOrigin)/api/race-assistant/results", $multipart).Result
        return [pscustomobject]@{ status = [int]$response.StatusCode; body = $response.Content.ReadAsStringAsync().Result }
    } finally {
        $multipart.Dispose()
        $client.Dispose()
    }
}

function Write-WorkerResult([string]$Path, $Value) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10 -Compress), (New-Object Text.UTF8Encoding $false))
}

function Get-Sha256([string]$Path) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $hasher.Dispose() }
}

if ($UploadFile) {
    try {
        $configuration = Read-AppConfig
        $deviceToken = Unprotect-Token ([string]$configuration.protectedToken)
        $uploadResult = Invoke-ResultUpload $UploadFile $deviceToken ([bool]$Reviewed) $RaceKey $Position $RaceTime
        Write-WorkerResult $ResultFile $uploadResult
        exit 0
    } catch {
        Write-WorkerResult $ResultFile ([pscustomobject]@{ status = 0; body = '{"error":"upload_failed"}' })
        exit 1
    }
}

if ($CheckUpdate) {
    try {
        Ensure-DataDirectory
        $manifest = (Invoke-WebRequest -Uri $script:ManifestUrl -UseBasicParsing -TimeoutSec 20).Content | ConvertFrom-Json
        if ([version]$manifest.version -gt [version]$script:AppVersion) {
            $temporaryUpdate = Join-Path $script:DataDirectory 'update-download.zip'
            (New-Object Net.WebClient).DownloadFile([string]$manifest.url, $temporaryUpdate)
            $actualHash = Get-Sha256 $temporaryUpdate
            if ($actualHash -ne ([string]$manifest.sha256).ToLowerInvariant()) { throw 'Hash de atualização inválido.' }
            Move-Item -LiteralPath $temporaryUpdate -Destination $script:PendingUpdatePath -Force
            Write-WorkerResult $UpdateResultFile ([pscustomobject]@{ ready = $true; version = [string]$manifest.version })
        } else {
            Write-WorkerResult $UpdateResultFile ([pscustomobject]@{ ready = $false; version = $script:AppVersion })
        }
        exit 0
    } catch {
        Write-WorkerResult $UpdateResultFile ([pscustomobject]@{ ready = $false; error = 'update_check_failed' })
        exit 1
    }
}

if ($ValidateOnly) { exit 0 }

$configuration = Read-AppConfig
$script:DeviceToken = Unprotect-Token ([string]$configuration.protectedToken)
if ([string]::IsNullOrWhiteSpace($script:DeviceToken)) {
    $script:DeviceToken = New-DeviceToken
    $configuration.protectedToken = Protect-Token $script:DeviceToken
    Write-AppConfig $configuration
}

$script:Monitoring = if ($null -eq $configuration.monitoring) { $true } else { [bool]$configuration.monitoring }
$script:Paired = $false
$script:MemberName = ''
$script:PairingCode = ''
$script:CandidateFrames = 0
$script:Busy = $false
$script:CooldownUntil = [DateTime]::MinValue
$script:LastSessionCheck = [DateTime]::MinValue
$script:LastUpdateCheck = [DateTime]::MinValue
$script:UploadResultPath = ''
$script:CurrentProofPath = ''
$script:UpdateResultPath = ''
$script:ReviewRaces = @()

$createdNew = $false
$mutex = New-Object Threading.Mutex($true, 'Local\FAST_Race_Assistant_V1', [ref]$createdNew)
if (-not $createdNew) { exit 0 }

function New-FastLabel([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height, [float]$Size = 9, [Drawing.FontStyle]$Style = [Drawing.FontStyle]::Regular) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.SetBounds($X, $Y, $Width, $Height)
    $label.Font = New-Object Drawing.Font('Segoe UI', $Size, $Style)
    $label.ForeColor = [Drawing.ColorTranslator]::FromHtml('#f6f6f7')
    $label.BackColor = [Drawing.Color]::Transparent
    return $label
}

function New-FastButton([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height, [bool]$Primary = $false) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.SetBounds($X, $Y, $Width, $Height)
    $button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = [Drawing.ColorTranslator]::FromHtml($(if ($Primary) { '#8c2f26' } else { '#34343b' }))
    $button.BackColor = [Drawing.ColorTranslator]::FromHtml($(if ($Primary) { '#8c2f26' } else { '#151519' }))
    $button.ForeColor = [Drawing.Color]::White
    $button.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    return $button
}

function Format-PairingCode([string]$Code) {
    $clean = ($Code -replace '[^A-Z0-9]', '').ToUpperInvariant()
    if ($clean.Length -gt 4) { return $clean.Substring(0, 4) + '-' + $clean.Substring(4) }
    return $clean
}

function Set-AppStatus([string]$Title, [string]$Detail, [string]$Color = '#9b9ba4') {
    $statusTitle.Text = $Title
    $statusDetail.Text = $Detail
    $statusTitle.ForeColor = [Drawing.ColorTranslator]::FromHtml($Color)
    $tray.Text = ('FAST Race Assistant: ' + $Title)
    if ($tray.Text.Length -gt 63) { $tray.Text = $tray.Text.Substring(0, 63) }
}

function Show-AppWindow {
    $form.Show()
    $form.WindowState = [Windows.Forms.FormWindowState]::Normal
    $form.Activate()
}

function Refresh-Session([bool]$Notify = $false) {
    $result = Invoke-AssistantJson 'GET' '/api/race-assistant/session' $script:DeviceToken
    $script:LastSessionCheck = Get-Date
    if ($result.Status -eq 200 -and $result.Body.paired) {
        $wasPaired = $script:Paired
        $script:Paired = $true
        $script:MemberName = [string]$result.Body.member.name
        $memberValue.Text = $script:MemberName
        $pairingValue.Text = 'Discord vinculado'
        $pairingValue.ForeColor = [Drawing.ColorTranslator]::FromHtml('#f6f6f7')
        $pairButton.Text = 'Vinculado'
        $pairButton.Enabled = $false
        if ($script:Monitoring) { Set-AppStatus 'Monitorando o FiveM' 'Aguardando um cartão de corrida concluída.' '#f6f6f7' }
        if (-not $wasPaired -and $Notify) { $tray.ShowBalloonTip(3500, 'Discord vinculado', "Sessão ativa para $($script:MemberName).", [Windows.Forms.ToolTipIcon]::Info) }
        return
    }
    $script:Paired = $false
    $memberValue.Text = 'Nenhum membro vinculado'
    if ($result.Status -eq 202 -and $result.Body.code) {
        $script:PairingCode = Format-PairingCode ([string]$result.Body.code)
        $pairingValue.Text = $script:PairingCode
        $pairButton.Text = 'Abrir portal'
        $pairButton.Enabled = $true
        Set-AppStatus 'Aguardando vínculo' 'Informe o código no Dashboard, em Corridas e Auxiliar.'
    } else {
        $pairingValue.Text = 'Gere um código para começar'
        $pairButton.Text = 'Gerar código'
        $pairButton.Enabled = $true
        Set-AppStatus 'Configuração necessária' 'Vincule seu Discord para enviar recordes.'
    }
}

function Start-Pairing {
    if ($script:PairingCode) {
        Start-Process "$($script:ApiOrigin)/admin" | Out-Null
        [Windows.Forms.Clipboard]::SetText($script:PairingCode)
        $tray.ShowBalloonTip(3000, 'Código copiado', 'Abra Corridas, Auxiliar e cole o código.', [Windows.Forms.ToolTipIcon]::Info)
        return
    }
    $pairButton.Enabled = $false
    $pairButton.Text = 'Gerando...'
    $body = @{ deviceName = $env:COMPUTERNAME; appVersion = $script:AppVersion }
    $result = Invoke-AssistantJson 'POST' '/api/race-assistant/pairings' $script:DeviceToken $body
    if ($result.Status -eq 201) {
        $script:PairingCode = Format-PairingCode ([string]$result.Body.code)
        $pairingValue.Text = $script:PairingCode
        $pairButton.Text = 'Abrir portal'
        $pairButton.Enabled = $true
        [Windows.Forms.Clipboard]::SetText($script:PairingCode)
        Set-AppStatus 'Aguardando vínculo' 'O código foi copiado. Confirme no portal.'
    } else {
        $pairButton.Text = 'Tentar novamente'
        $pairButton.Enabled = $true
        Set-AppStatus 'Não foi possível conectar' 'Confira sua internet e tente novamente.' '#b8433a'
    }
}

function Begin-Upload([string]$ProofPath, [bool]$WasReviewed = $false, [string]$SelectedRace = '', [int]$SelectedPosition = 0, [string]$SelectedTime = '') {
    if ($script:Busy) { return }
    $script:Busy = $true
    $script:CurrentProofPath = $ProofPath
    $script:UploadResultPath = Join-Path $script:DataDirectory ("upload-result-" + [Guid]::NewGuid().ToString('N') + '.json')
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ' + (Quote-ProcessArgument $PSCommandPath) + ' -UploadFile ' + (Quote-ProcessArgument $ProofPath) + ' -ResultFile ' + (Quote-ProcessArgument $script:UploadResultPath)
    if ($WasReviewed) {
        $argumentLine += ' -Reviewed -RaceKey ' + (Quote-ProcessArgument $SelectedRace) + ' -Position ' + [string]$SelectedPosition + ' -RaceTime ' + (Quote-ProcessArgument $SelectedTime)
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -WindowStyle Hidden | Out-Null
    Set-AppStatus 'Analisando resultado' 'Validando corrida, posição e tempo total.' '#f6f6f7'
}

function Remove-CurrentProof {
    if ($script:CurrentProofPath -and (Test-Path -LiteralPath $script:CurrentProofPath)) {
        Remove-Item -LiteralPath $script:CurrentProofPath -Force -ErrorAction SilentlyContinue
    }
    $script:CurrentProofPath = ''
}

function Quote-ProcessArgument([string]$Value) {
    return '"' + ([string]$Value).Replace('"', '\"') + '"'
}

function Show-ReviewDialog($Payload) {
    $script:ReviewRaces = @($Payload.races)
    $review = New-Object Windows.Forms.Form
    $review.Text = 'Confirmar resultado'
    $review.ClientSize = New-Object Drawing.Size(720, 590)
    $review.BackColor = [Drawing.ColorTranslator]::FromHtml('#0b0b0d')
    $review.ForeColor = [Drawing.Color]::White
    $review.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $review.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $review.MaximizeBox = $false
    $review.MinimizeBox = $false
    $review.TopMost = $true

    $review.Controls.Add((New-FastLabel 'REVISÃO NECESSÁRIA' 24 18 300 20 8 ([Drawing.FontStyle]::Bold)))
    $reviewTitle = New-FastLabel 'Confirme os dados da corrida' 24 42 620 34 18 ([Drawing.FontStyle]::Bold)
    $review.Controls.Add($reviewTitle)
    $reviewHint = New-FastLabel 'A leitura teve baixa confiança. Corrija se necessário antes de enviar.' 24 78 650 36 9
    $reviewHint.ForeColor = [Drawing.ColorTranslator]::FromHtml('#9b9ba4')
    $review.Controls.Add($reviewHint)

    $picture = New-Object Windows.Forms.PictureBox
    $picture.SetBounds(24, 122, 672, 300)
    $picture.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
    $picture.BackColor = [Drawing.ColorTranslator]::FromHtml('#050506')
    try {
        $bytes = [IO.File]::ReadAllBytes($script:CurrentProofPath)
        $stream = New-Object IO.MemoryStream(,$bytes)
        $picture.Image = [Drawing.Image]::FromStream($stream)
    } catch {}
    $review.Controls.Add($picture)

    $raceLabel = New-FastLabel 'Corrida' 24 440 310 20 8 ([Drawing.FontStyle]::Bold)
    $positionLabel = New-FastLabel 'Colocação' 354 440 120 20 8 ([Drawing.FontStyle]::Bold)
    $timeLabel = New-FastLabel 'Tempo total' 484 440 212 20 8 ([Drawing.FontStyle]::Bold)
    $review.Controls.AddRange(@($raceLabel, $positionLabel, $timeLabel))
    $raceSelect = New-Object Windows.Forms.ComboBox
    $raceSelect.SetBounds(24, 462, 310, 34)
    $raceSelect.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $raceSelect.BackColor = [Drawing.ColorTranslator]::FromHtml('#18181b')
    $raceSelect.ForeColor = [Drawing.Color]::White
    foreach ($race in $script:ReviewRaces) { [void]$raceSelect.Items.Add([pscustomobject]@{ Key = [string]$race.key; Name = [string]$race.name }) }
    $raceSelect.DisplayMember = 'Name'
    if ($raceSelect.Items.Count -gt 0) { $raceSelect.SelectedIndex = 0 }
    $candidateKey = [string]$Payload.candidate.raceKey
    for ($index = 0; $index -lt $raceSelect.Items.Count; $index++) { if ($raceSelect.Items[$index].Key -eq $candidateKey) { $raceSelect.SelectedIndex = $index } }
    $review.Controls.Add($raceSelect)

    $positionInput = New-Object Windows.Forms.NumericUpDown
    $positionInput.SetBounds(354, 462, 110, 34)
    $positionInput.Minimum = 1
    $positionInput.Maximum = 999
    if ([int]$Payload.candidate.position -gt 0) { $positionInput.Value = [int]$Payload.candidate.position }
    $review.Controls.Add($positionInput)
    $timeInput = New-Object Windows.Forms.TextBox
    $timeInput.SetBounds(484, 462, 212, 34)
    $timeInput.Text = [string]$Payload.candidate.time
    $timeInput.BackColor = [Drawing.ColorTranslator]::FromHtml('#18181b')
    $timeInput.ForeColor = [Drawing.Color]::White
    $review.Controls.Add($timeInput)

    $cancel = New-FastButton 'Descartar' 464 526 106 38 $false
    $send = New-FastButton 'Confirmar e enviar' 580 526 116 38 $true
    $cancel.Add_Click({ $review.DialogResult = [Windows.Forms.DialogResult]::Cancel; $review.Close() })
    $send.Add_Click({
        if ($raceSelect.SelectedItem -and $timeInput.Text -match '^\d{1,3}:[0-5]\d\.\d{3}$') {
            $review.Tag = [pscustomobject]@{ RaceKey = $raceSelect.SelectedItem.Key; Position = [int]$positionInput.Value; Time = $timeInput.Text }
            $review.DialogResult = [Windows.Forms.DialogResult]::OK
            $review.Close()
        } else {
            [Windows.Forms.MessageBox]::Show('Selecione a corrida e informe o tempo no formato 07:54.326.', $script:AppName, 'OK', 'Warning') | Out-Null
        }
    })
    $review.Controls.AddRange(@($cancel, $send))
    $dialogResult = $review.ShowDialog()
    if ($picture.Image) { $picture.Image.Dispose() }
    if ($stream) { $stream.Dispose() }
    if ($dialogResult -eq [Windows.Forms.DialogResult]::OK) {
        $selection = $review.Tag
        $script:Busy = $false
        Begin-Upload $script:CurrentProofPath $true $selection.RaceKey $selection.Position $selection.Time
    } else {
        Remove-CurrentProof
        Set-AppStatus 'Resultado descartado' 'O monitor continua aguardando a próxima corrida.'
    }
    $review.Dispose()
}

function Process-UploadResult {
    if (-not $script:Busy -or -not $script:UploadResultPath -or -not (Test-Path -LiteralPath $script:UploadResultPath)) { return }
    try {
        $wrapper = [IO.File]::ReadAllText($script:UploadResultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $payload = try { [string]$wrapper.body | ConvertFrom-Json } catch { [pscustomobject]@{ error = 'invalid_response' } }
        Remove-Item -LiteralPath $script:UploadResultPath -Force -ErrorAction SilentlyContinue
        $script:UploadResultPath = ''
        $script:Busy = $false
        if ([int]$wrapper.status -eq 201 -and $payload.newRecord) {
            $tray.ShowBalloonTip(4500, 'Novo recorde enviado', "$($payload.candidate.raceName): $($payload.candidate.time)", [Windows.Forms.ToolTipIcon]::Info)
            Set-AppStatus 'Novo recorde registrado' "$($payload.candidate.raceName), tempo $($payload.candidate.time)." '#f6f6f7'
            Remove-CurrentProof
        } elseif ([int]$wrapper.status -eq 409 -and $payload.error -eq 'not_new_record') {
            Set-AppStatus 'Tempo já registrado' 'O resultado não superou seu recorde pessoal.'
            Remove-CurrentProof
        } elseif ($payload.requiresReview) {
            $tray.ShowBalloonTip(5000, 'Confirme o resultado', 'A leitura teve baixa confiança e precisa da sua revisão.', [Windows.Forms.ToolTipIcon]::Warning)
            Set-AppStatus 'Confirmação necessária' 'Revise a corrida, a colocação e o tempo.' '#b8433a'
            Show-ReviewDialog $payload
        } else {
            Set-AppStatus 'Falha no envio' 'O comprovante não foi enviado. Tente novamente na próxima corrida.' '#b8433a'
            $tray.ShowBalloonTip(4000, 'Falha no envio', 'Confira sua conexão e o vínculo com o site.', [Windows.Forms.ToolTipIcon]::Error)
            Remove-CurrentProof
        }
    } catch {
        $script:Busy = $false
        Set-AppStatus 'Falha no envio' 'Não foi possível interpretar a resposta do site.' '#b8433a'
        Remove-CurrentProof
    }
}

function Begin-UpdateCheck {
    if ($script:UpdateResultPath) { return }
    $script:LastUpdateCheck = Get-Date
    $script:UpdateResultPath = Join-Path $script:DataDirectory ("update-result-" + [Guid]::NewGuid().ToString('N') + '.json')
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + (Quote-ProcessArgument $PSCommandPath) + ' -CheckUpdate -UpdateResultFile ' + (Quote-ProcessArgument $script:UpdateResultPath)
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -WindowStyle Hidden | Out-Null
}

function Process-UpdateResult {
    if (-not $script:UpdateResultPath -or -not (Test-Path -LiteralPath $script:UpdateResultPath)) { return }
    try {
        $result = [IO.File]::ReadAllText($script:UpdateResultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($result.ready) {
            $updateValue.Text = "Versão $($result.version) pronta para a próxima inicialização"
            $tray.ShowBalloonTip(4500, 'Atualização pronta', 'A nova versão será instalada automaticamente na próxima inicialização.', [Windows.Forms.ToolTipIcon]::Info)
        } else { $updateValue.Text = "Versão $($script:AppVersion) atualizada" }
    } catch {}
    Remove-Item -LiteralPath $script:UpdateResultPath -Force -ErrorAction SilentlyContinue
    $script:UpdateResultPath = ''
}

[FastRaceCapture]::EnableDpiAwareness()
[Windows.Forms.Application]::EnableVisualStyles()
$script:PasteHookOwned = [FastRaceCapture]::InstallAnnouncementPasteHook()
$form = New-Object Windows.Forms.Form
$form.Text = $script:AppName
$form.ClientSize = New-Object Drawing.Size(680, 490)
$form.BackColor = [Drawing.ColorTranslator]::FromHtml('#050506')
$form.ForeColor = [Drawing.Color]::White
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.Icon = if (Test-Path -LiteralPath $IconPath) { try { [Drawing.Icon]::ExtractAssociatedIcon($IconPath) } catch { $null } } else { $null }

$brand = New-FastLabel 'FAST DIVISION' 28 22 220 24 9 ([Drawing.FontStyle]::Bold)
$brand.ForeColor = [Drawing.ColorTranslator]::FromHtml('#b8433a')
$title = New-FastLabel 'Race Assistant' 28 50 420 46 27 ([Drawing.FontStyle]::Bold)
$subtitleCopy = if ($script:PasteHookOwned) { 'Recordes do FiveM e colagem sequencial Ctrl+V' } else { 'Recordes do FiveM, com o auxiliar Ctrl+V legado ativo' }
$subtitle = New-FastLabel $subtitleCopy 30 98 560 28 10
$subtitle.ForeColor = [Drawing.ColorTranslator]::FromHtml('#9b9ba4')
$form.Controls.AddRange(@($brand, $title, $subtitle))

$panel = New-Object Windows.Forms.Panel
$panel.SetBounds(28, 142, 624, 248)
$panel.BackColor = [Drawing.ColorTranslator]::FromHtml('#0b0b0d')
$panel.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($panel)

$panel.Controls.Add((New-FastLabel 'STATUS' 18 15 180 18 8 ([Drawing.FontStyle]::Bold)))
$statusTitle = New-FastLabel 'Iniciando' 18 38 570 28 14 ([Drawing.FontStyle]::Bold)
$statusDetail = New-FastLabel 'Validando sua sessão.' 18 69 570 38 9
$statusDetail.ForeColor = [Drawing.ColorTranslator]::FromHtml('#9b9ba4')
$panel.Controls.AddRange(@($statusTitle, $statusDetail))

$separator = New-Object Windows.Forms.Panel
$separator.SetBounds(18, 112, 586, 1)
$separator.BackColor = [Drawing.ColorTranslator]::FromHtml('#27272a')
$panel.Controls.Add($separator)
$panel.Controls.Add((New-FastLabel 'MEMBRO' 18 127 160 18 8 ([Drawing.FontStyle]::Bold)))
$memberValue = New-FastLabel 'Nenhum membro vinculado' 18 150 280 26 10 ([Drawing.FontStyle]::Bold)
$panel.Controls.Add($memberValue)
$panel.Controls.Add((New-FastLabel 'CÓDIGO DE VÍNCULO' 320 127 210 18 8 ([Drawing.FontStyle]::Bold)))
$pairingValue = New-FastLabel 'Gere um código para começar' 320 150 270 26 10 ([Drawing.FontStyle]::Bold)
$pairingValue.ForeColor = [Drawing.ColorTranslator]::FromHtml('#9b9ba4')
$panel.Controls.Add($pairingValue)
$pairButton = New-FastButton 'Gerar código' 320 190 132 36 $true
$monitorButton = New-FastButton $(if ($script:Monitoring) { 'Pausar monitor' } else { 'Ativar monitor' }) 462 190 142 36 $false
$panel.Controls.AddRange(@($pairButton, $monitorButton))

$updateLabel = New-FastLabel 'ATUALIZAÇÕES' 28 407 180 18 8 ([Drawing.FontStyle]::Bold)
$updateValue = New-FastLabel "Versão $($script:AppVersion), verificação automática" 28 430 420 24 9
$updateValue.ForeColor = [Drawing.ColorTranslator]::FromHtml('#9b9ba4')
$author = New-FastLabel 'Produzido por Fael Verstappen' 430 430 222 24 9 ([Drawing.FontStyle]::Bold)
$author.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$form.Controls.AddRange(@($updateLabel, $updateValue, $author))

$tray = New-Object Windows.Forms.NotifyIcon
if (Test-Path -LiteralPath $IconPath) {
    try {
        $iconBitmap = New-Object Drawing.Bitmap($IconPath)
        $tray.Icon = [Drawing.Icon]::FromHandle($iconBitmap.GetHicon())
    } catch { $tray.Icon = [Drawing.SystemIcons]::Information }
} else { $tray.Icon = [Drawing.SystemIcons]::Information }
$tray.Text = $script:AppName
$tray.Visible = $true
$menu = New-Object Windows.Forms.ContextMenuStrip
$openItem = $menu.Items.Add('Abrir FAST Race Assistant')
$pauseItem = $menu.Items.Add($(if ($script:Monitoring) { 'Pausar monitoramento' } else { 'Ativar monitoramento' }))
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$exitItem = $menu.Items.Add('Encerrar')
$tray.ContextMenuStrip = $menu

$pairButton.Add_Click({ Start-Pairing })
$monitorButton.Add_Click({
    $script:Monitoring = -not $script:Monitoring
    $configuration.monitoring = $script:Monitoring
    Write-AppConfig $configuration
    $monitorButton.Text = if ($script:Monitoring) { 'Pausar monitor' } else { 'Ativar monitor' }
    $pauseItem.Text = if ($script:Monitoring) { 'Pausar monitoramento' } else { 'Ativar monitoramento' }
    if ($script:Monitoring -and $script:Paired) { Set-AppStatus 'Monitorando o FiveM' 'Aguardando um cartão de corrida concluída.' '#f6f6f7' }
    else { Set-AppStatus 'Monitor pausado' 'Nenhuma captura será realizada enquanto estiver pausado.' }
})
$pauseItem.Add_Click({ $monitorButton.PerformClick() })
$openItem.Add_Click({ Show-AppWindow })
$tray.Add_DoubleClick({ Show-AppWindow })
$exitItem.Add_Click({ $tray.Visible = $false; [Windows.Forms.Application]::Exit() })
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($eventArgs.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing) {
        $eventArgs.Cancel = $true
        $form.Hide()
        $tray.ShowBalloonTip(2500, 'FAST Race Assistant ativo', 'O monitor continua em segundo plano.', [Windows.Forms.ToolTipIcon]::Info)
    }
})

if ($SmokeTest) {
    [FastRaceCapture]::ShutdownAnnouncementPasteHook()
    $tray.Visible = $false
    $tray.Dispose()
    $form.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    exit 0
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if ($script:PasteHookOwned) {
        $queuedFields = [FastRaceCapture]::PollAnnouncementQueue()
        if ($queuedFields -gt 0) {
            $tray.ShowBalloonTip(3000, 'Sequência Ctrl+V pronta', "$queuedFields campos preparados para colar no jogo.", [Windows.Forms.ToolTipIcon]::Info)
        }
    }
    Process-UploadResult
    Process-UpdateResult
    if (((Get-Date) - $script:LastSessionCheck).TotalSeconds -ge 20) { Refresh-Session $true }
    if (((Get-Date) - $script:LastUpdateCheck).TotalHours -ge 6) { Begin-UpdateCheck }
    if (-not $script:Monitoring -or -not $script:Paired -or $script:Busy -or (Get-Date) -lt $script:CooldownUntil) { return }
    $candidatePath = Join-Path $script:DataDirectory 'captura-pendente.jpg'
    if ([FastRaceCapture]::TryCaptureCompletion($candidatePath)) { $script:CandidateFrames++ } else { $script:CandidateFrames = 0 }
    if ($script:CandidateFrames -ge 2) {
        $script:CandidateFrames = 0
        $script:CooldownUntil = (Get-Date).AddSeconds(18)
        $proofPath = Join-Path $script:DataDirectory ("comprovante-" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.jpg')
        Move-Item -LiteralPath $candidatePath -Destination $proofPath -Force
        Begin-Upload $proofPath
    }
})

Refresh-Session $false
$script:HideInitialWindow = $script:Paired
$form.Add_Shown({ if ($script:HideInitialWindow) { $form.Hide(); $script:HideInitialWindow = $false } })
Begin-UpdateCheck
$timer.Start()
$tray.ShowBalloonTip(3200, 'FAST Race Assistant ativo', 'Monitor de corridas e colagem sequencial disponíveis em segundo plano.', [Windows.Forms.ToolTipIcon]::Info)
try { [Windows.Forms.Application]::Run($form) }
finally {
    [FastRaceCapture]::ShutdownAnnouncementPasteHook()
    $timer.Stop()
    $timer.Dispose()
    $tray.Visible = $false
    $tray.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
