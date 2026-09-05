#requires -Version 5.1

param(
    [switch]$ValidateOnly,
    [switch]$CheckUpdate,
    [string]$UpdateResultFile = '',
    [switch]$SmokeTest,
    [string]$IconPath = (Join-Path $PSScriptRoot 'fast-emblem.png')
)

$ErrorActionPreference = 'Stop'
$script:AppName = 'FAST - Auxiliar Ctrl+V'
$script:AppVersion = '1.1.0'
$script:DataDirectory = Join-Path $env:LOCALAPPDATA 'FAST\RaceAssistant\data'
if ($SmokeTest) { $script:DataDirectory = Join-Path $env:TEMP 'FAST-CtrlV-SmokeTest' }
$script:PendingUpdatePath = Join-Path $script:DataDirectory 'pending-update.zip'
$script:ManifestUrl = 'https://github.com/aledsst-ai/fast-race-assistant/releases/latest/download/fast-race-assistant-latest.json'

try {
    $versionConfig = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'version.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string]$versionConfig.version -match '^\d+\.\d+\.\d+$') {
        $script:AppVersion = [string]$versionConfig.version
    }
} catch {}

function Ensure-DataDirectory {
    if (-not (Test-Path -LiteralPath $script:DataDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $script:DataDirectory -Force | Out-Null
    }
}

function Write-UpdateResult([string]$Path, $Value) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 4 -Compress),
        (New-Object Text.UTF8Encoding $false)
    )
}

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

if ($CheckUpdate) {
    try {
        Ensure-DataDirectory
        $manifest = (Invoke-WebRequest -Uri $script:ManifestUrl -UseBasicParsing -TimeoutSec 20).Content | ConvertFrom-Json
        if ([version]$manifest.version -gt [version]$script:AppVersion) {
            $downloadPath = Join-Path $script:DataDirectory 'update-download.zip'
            (New-Object Net.WebClient).DownloadFile([string]$manifest.url, $downloadPath)
            $actualHash = Get-Sha256 $downloadPath
            if ($actualHash -ne ([string]$manifest.sha256).ToLowerInvariant()) {
                throw 'Hash de atualizacao invalido.'
            }
            Move-Item -LiteralPath $downloadPath -Destination $script:PendingUpdatePath -Force
            Write-UpdateResult $UpdateResultFile ([pscustomobject]@{ ready = $true; version = [string]$manifest.version })
        } else {
            Write-UpdateResult $UpdateResultFile ([pscustomobject]@{ ready = $false; version = $script:AppVersion })
        }
        exit 0
    } catch {
        Write-UpdateResult $UpdateResultFile ([pscustomobject]@{ ready = $false; error = 'update_check_failed' })
        exit 1
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$source = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class FastClipboardHelper
{
    private const string PayloadPrefix = "FAST_ANNOUNCEMENT_QUEUE_V1|";
    private const int WhKeyboardLl = 13;
    private const int WmKeyDown = 0x0100;
    private const int WmKeyUp = 0x0101;
    private const int WmSysKeyDown = 0x0104;
    private const int WmSysKeyUp = 0x0105;
    private const int VkControl = 0x11;
    private const int VkV = 0x56;
    private const uint LlkhfInjected = 0x10;
    private const uint KeyeventfKeyup = 0x0002;

    private static readonly string[] FieldNames = { "titulo", "mensagem", "duracao", "imagem" };
    private static readonly List<string> Queue = new List<string>();
    private static LowLevelKeyboardProc _hookProc;
    private static IntPtr _hookId = IntPtr.Zero;
    private static NotifyIcon _tray;
    private static Icon _trayIcon;
    private static IntPtr _trayIconHandle = IntPtr.Zero;
    private static ApplicationContext _context;
    private static Mutex _mutex;
    private static int _queueIndex;
    private static bool _active;
    private static bool _handledVDown;

    [STAThread]
    public static void Run(string iconPath, string version)
    {
        bool createdNew;
        _mutex = new Mutex(true, "Local\\FAST_Announcement_Paste_Helper_V1", out createdNew);
        if (!createdNew) return;

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        _context = new ApplicationContext();

        var menu = new ContextMenuStrip();
        var statusItem = new ToolStripMenuItem("Aguardando sequencia") { Enabled = false };
        var versionItem = new ToolStripMenuItem("Versao " + version) { Enabled = false };
        var authorItem = new ToolStripMenuItem("Produzido por Fael Verstappen") { Enabled = false };
        var cancelItem = new ToolStripMenuItem("Cancelar sequencia");
        var exitItem = new ToolStripMenuItem("Encerrar auxiliar");
        cancelItem.Click += delegate { CancelSequence(true); statusItem.Text = "Aguardando sequencia"; };
        exitItem.Click += delegate { _context.ExitThread(); };
        menu.Items.Add(statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(cancelItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(versionItem);
        menu.Items.Add(authorItem);
        menu.Items.Add(exitItem);

        _trayIcon = LoadTrayIcon(iconPath);
        _tray = new NotifyIcon {
            Icon = _trayIcon ?? SystemIcons.Information,
            Text = "FAST - Auxiliar Ctrl+V",
            ContextMenuStrip = menu,
            Visible = true
        };
        _tray.DoubleClick += delegate { ShowCurrentStatus(); };

        var timer = new System.Windows.Forms.Timer { Interval = 75 };
        timer.Tick += delegate {
            if (TryLoadQueueFromClipboard() || _active) statusItem.Text = QueueStatusText();
        };
        timer.Start();

        _hookProc = HookCallback;
        _hookId = SetWindowsHookEx(WhKeyboardLl, _hookProc, GetModuleHandle(null), 0);
        if (_hookId == IntPtr.Zero) {
            timer.Dispose();
            _tray.Visible = false;
            _tray.Dispose();
            DisposeTrayIcon();
            throw new InvalidOperationException("Nao foi possivel iniciar o monitor de Ctrl+V.");
        }

        _tray.ShowBalloonTip(
            3000,
            "Auxiliar FAST ativo",
            "Aguardando uma sequencia preparada pelo Gerador de Anuncios.",
            ToolTipIcon.Info
        );

        try {
            Application.Run(_context);
        } finally {
            timer.Stop();
            timer.Dispose();
            if (_hookId != IntPtr.Zero) UnhookWindowsHookEx(_hookId);
            _tray.Visible = false;
            _tray.Dispose();
            DisposeTrayIcon();
            _mutex.ReleaseMutex();
            _mutex.Dispose();
        }
    }

    private static Icon LoadTrayIcon(string iconPath)
    {
        if (String.IsNullOrWhiteSpace(iconPath) || !File.Exists(iconPath)) return null;
        try {
            using (var source = new Bitmap(iconPath))
            using (var canvas = new Bitmap(32, 32, PixelFormat.Format32bppArgb))
            using (var graphics = Graphics.FromImage(canvas)) {
                graphics.Clear(Color.Transparent);
                graphics.CompositingQuality = CompositingQuality.HighQuality;
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                graphics.SmoothingMode = SmoothingMode.HighQuality;
                graphics.DrawImage(source, new Rectangle(0, 0, 32, 32));
                _trayIconHandle = canvas.GetHicon();
            }
            return Icon.FromHandle(_trayIconHandle);
        } catch {
            DisposeTrayIcon();
            return null;
        }
    }

    private static void DisposeTrayIcon()
    {
        if (_trayIcon != null) {
            _trayIcon.Dispose();
            _trayIcon = null;
        }
        if (_trayIconHandle != IntPtr.Zero) {
            DestroyIcon(_trayIconHandle);
            _trayIconHandle = IntPtr.Zero;
        }
    }

    private static bool TryLoadQueueFromClipboard()
    {
        string clipboardText;
        if (!TryReadPayloadFromClipboard(out clipboardText)) return false;
        string[] encodedFields = clipboardText.Substring(PayloadPrefix.Length).Split('|');
        if (encodedFields.Length < 3) return false;

        var decodedFields = new List<string>();
        for (int i = 0; i < encodedFields.Length && i < FieldNames.Length; i++) {
            try {
                string decoded = Encoding.UTF8.GetString(Convert.FromBase64String(encodedFields[i]));
                if (!String.IsNullOrWhiteSpace(decoded)) decodedFields.Add(decoded);
            } catch {
                CancelSequence(false);
                return false;
            }
        }
        if (decodedFields.Count < 3) return false;

        Queue.Clear();
        Queue.AddRange(decodedFields);
        _queueIndex = 0;
        _active = true;
        SetClipboardText(Queue[0]);
        UpdateTrayText();
        _tray.ShowBalloonTip(
            3000,
            "Sequencia pronta",
            Queue.Count + " campos preparados. Use Ctrl+V em cada campo do jogo.",
            ToolTipIcon.Info
        );
        return true;
    }

    private static bool TryReadPayloadFromClipboard(out string clipboardText)
    {
        clipboardText = null;
        try {
            if (Clipboard.ContainsText(TextDataFormat.Html)) {
                string html = Clipboard.GetText(TextDataFormat.Html);
                int start = html.IndexOf(PayloadPrefix, StringComparison.Ordinal);
                if (start >= 0) {
                    int end = start;
                    while (end < html.Length && !Char.IsWhiteSpace(html[end]) && html[end] != '<' && html[end] != '>') end++;
                    clipboardText = html.Substring(start, end - start);
                }
            }
            if (String.IsNullOrEmpty(clipboardText) && Clipboard.ContainsText(TextDataFormat.UnicodeText)) {
                string plain = Clipboard.GetText(TextDataFormat.UnicodeText);
                if (!String.IsNullOrEmpty(plain) && plain.StartsWith(PayloadPrefix, StringComparison.Ordinal)) clipboardText = plain;
            }
        } catch {
            return false;
        }
        return !String.IsNullOrEmpty(clipboardText) && clipboardText.StartsWith(PayloadPrefix, StringComparison.Ordinal);
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0) {
            var data = (KbdLlHookStruct)Marshal.PtrToStructure(lParam, typeof(KbdLlHookStruct));
            bool injected = (data.flags & LlkhfInjected) != 0;
            bool keyDown = wParam == (IntPtr)WmKeyDown || wParam == (IntPtr)WmSysKeyDown;
            bool keyUp = wParam == (IntPtr)WmKeyUp || wParam == (IntPtr)WmSysKeyUp;

            if (!injected && data.vkCode == VkV) {
                if (keyDown && IsControlDown()) {
                    TryLoadQueueFromClipboard();
                    if (_active) {
                        if (!_handledVDown) {
                            _handledVDown = true;
                            PasteNextValue();
                        }
                        return (IntPtr)1;
                    }
                } else if (keyUp && _handledVDown) {
                    _handledVDown = false;
                    return (IntPtr)1;
                }
            }
        }
        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    private static void PasteNextValue()
    {
        if (!_active || _queueIndex < 0 || _queueIndex >= Queue.Count) return;
        if (!SetClipboardText(Queue[_queueIndex])) {
            CancelSequence(false);
            _tray.ShowBalloonTip(3000, "Falha ao colar", "Prepare a sequencia novamente.", ToolTipIcon.Error);
            return;
        }

        SendPasteShortcut();
        _queueIndex++;
        if (_queueIndex >= Queue.Count) {
            _active = false;
            _tray.Text = "FAST - Sequencia concluida";
            _tray.ShowBalloonTip(2500, "Anuncio preenchido", "Todos os campos foram colados.", ToolTipIcon.Info);
        } else {
            UpdateTrayText();
        }
    }

    private static bool SetClipboardText(string value)
    {
        for (int attempt = 0; attempt < 5; attempt++) {
            try {
                Clipboard.SetText(value ?? String.Empty, TextDataFormat.UnicodeText);
                return true;
            } catch {
                Thread.Sleep(25);
            }
        }
        return false;
    }

    private static void SendPasteShortcut()
    {
        keybd_event((byte)VkControl, 0, 0, UIntPtr.Zero);
        keybd_event((byte)VkV, 0, 0, UIntPtr.Zero);
        keybd_event((byte)VkV, 0, KeyeventfKeyup, UIntPtr.Zero);
        keybd_event((byte)VkControl, 0, KeyeventfKeyup, UIntPtr.Zero);
    }

    private static bool IsControlDown()
    {
        return (GetAsyncKeyState(VkControl) & 0x8000) != 0;
    }

    private static void CancelSequence(bool notify)
    {
        Queue.Clear();
        _queueIndex = 0;
        _active = false;
        _handledVDown = false;
        if (_tray != null) {
            _tray.Text = "FAST - Auxiliar Ctrl+V";
            if (notify) _tray.ShowBalloonTip(2200, "Sequencia cancelada", "O Ctrl+V voltou ao funcionamento normal.", ToolTipIcon.Info);
        }
    }

    private static void ShowCurrentStatus()
    {
        string message = _active
            ? QueueStatusText() + ". Pressione Ctrl+V no campo correspondente."
            : "Aguardando uma sequencia preparada pelo Gerador de Anuncios.";
        _tray.ShowBalloonTip(2800, "FAST - Colagem sequencial", message, ToolTipIcon.Info);
    }

    private static string QueueStatusText()
    {
        if (!_active || Queue.Count == 0) return "Aguardando sequencia";
        int index = Math.Min(_queueIndex, Queue.Count - 1);
        string field = index < FieldNames.Length ? FieldNames[index] : "proximo campo";
        return "Proximo: " + field + " (" + (_queueIndex + 1) + "/" + Queue.Count + ")";
    }

    private static void UpdateTrayText()
    {
        string status = "FAST - " + QueueStatusText();
        _tray.Text = status.Length > 63 ? status.Substring(0, 63) : status;
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KbdLlHookStruct
    {
        public int vkCode;
        public int scanCode;
        public uint flags;
        public int time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc callback, IntPtr module, uint threadId);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string moduleName);
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int virtualKey);
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr icon);
}
'@

try {
    Add-Type -TypeDefinition $source -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop
    if ($ValidateOnly -or $SmokeTest) { exit 0 }

    Ensure-DataDirectory
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -CheckUpdate'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    [FastClipboardHelper]::Run($IconPath, $script:AppVersion)
} catch {
    [Windows.Forms.MessageBox]::Show(
        "Nao foi possivel iniciar o auxiliar.\r\n\r\n$($_.Exception.Message)",
        $script:AppName,
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}
