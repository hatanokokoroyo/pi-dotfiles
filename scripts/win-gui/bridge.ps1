#requires -Version 5.1
<#
  pi win-gui bridge  (ASCII-only source on purpose: parsable by both Windows
  PowerShell 5.1 and pwsh 7 without BOM/encoding pitfalls)

  Protocol: newline-delimited JSON on stdio.
    stdin  : one request per line  {"id":1,"op":"windows","args":{...}}
    stdout : one response per line {"id":1,"ok":true,"result":{...}}
             or {"id":1,"ok":false,"error":"..."}

  Spawned and driven by pi-dotfiles/extensions/wsl-win-gui.ts.
  Keep this process resident: a cold `powershell.exe -File` call costs
  450-900 ms, while a resident round trip costs ~20 ms.

  Coordinate space: physical pixels of the virtual desktop (per-monitor-v2 DPI
  aware). All rects/points in requests and responses use that space unless a
  parameter is explicitly documented as relative.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
try { [Console]::InputEncoding = $utf8 } catch { }
try { [Console]::OutputEncoding = $utf8 } catch { }

# ---------------------------------------------------------------- native + UIA

$script:KernelSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace PiWinGui {

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X; public int Y; }

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  [StructLayout(LayoutKind.Sequential)]
  public struct MONITORINFOEX {
    public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
  }

  public class MonitorInfoData {
    public int Index; public int Left; public int Top; public int Width; public int Height;
    public int WorkLeft; public int WorkTop; public int WorkWidth; public int WorkHeight;
    public uint DpiX; public uint DpiY; public double Scale; public bool Primary; public string Device;
  }

  public class WindowInfoData {
    public long Hwnd; public int Pid; public string Process; public string Class; public string Title;
    public int Left; public int Top; public int Width; public int Height;          // DwmGetWindowAttribute frame (visible)
    public int RawLeft; public int RawTop; public int RawWidth; public int RawHeight; // GetWindowRect (incl. shadow margin)
    public bool Visible; public bool Minimized; public bool Foreground; public int Z;
  }

  public static class Native {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT rect, int size);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, EnumMonitorProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFOEX info);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool BlockInput(bool block);

    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr data);
    public delegate bool EnumMonitorProc(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data);

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT {
      [FieldOffset(0)] public uint type;
      [FieldOffset(8)] public MOUSEINPUT mi;
      [FieldOffset(8)] public KEYBDINPUT ki;
      [FieldOffset(8)] public HARDWAREINPUT hi;
    }

    public const uint INPUT_MOUSE = 0;
    public const uint INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;
    public const uint KEYEVENTF_SCANCODE = 0x0008;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    public const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;
    public const uint MOUSEEVENTF_HWHEEL = 0x1000;

    public static bool SetAwareness() {
      // -4 = PER_MONITOR_AWARE_V2, -3 = PER_MONITOR_AWARE, -2 = SYSTEM_AWARE
      try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return true; } catch { }
      try { if (SetProcessDpiAwarenessContext(new IntPtr(-3))) return true; } catch { }
      try { if (SetProcessDpiAwareness(2) == 0) return true; } catch { }
      try { if (SetProcessDPIAware()) return true; } catch { }
      return false;
    }

    public static List<MonitorInfoData> GetMonitors() {
      List<MonitorInfoData> list = new List<MonitorInfoData>();
      EnumMonitorProc callback = delegate(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data) {
        MonitorInfoData info = new MonitorInfoData();
        info.Index = list.Count;
        info.Left = rect.Left; info.Top = rect.Top;
        info.Width = rect.Right - rect.Left; info.Height = rect.Bottom - rect.Top;
        MONITORINFOEX mi = new MONITORINFOEX();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
        if (GetMonitorInfo(monitor, ref mi)) {
          info.WorkLeft = mi.rcWork.Left; info.WorkTop = mi.rcWork.Top;
          info.WorkWidth = mi.rcWork.Right - mi.rcWork.Left;
          info.WorkHeight = mi.rcWork.Bottom - mi.rcWork.Top;
          info.Primary = (mi.dwFlags & 1) == 1;
          info.Device = mi.szDevice;
        }
        uint dx = 0, dy = 0;
        bool hasDpi = false;
        try { if (GetDpiForMonitor(monitor, 0, out dx, out dy) == 0) hasDpi = true; } catch { }
        if (!hasDpi) { dx = 96; dy = 96; }
        info.DpiX = dx; info.DpiY = dy;
        info.Scale = Math.Round(dx / 96.0, 2);
        list.Add(info);
        return true;
      };
      EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
      return list;
    }

    public static int MonitorIndexFor(List<MonitorInfoData> monitors, int x, int y) {
      for (int i = 0; i < monitors.Count; i++) {
        MonitorInfoData m = monitors[i];
        if (x >= m.Left && x < m.Left + m.Width && y >= m.Top && y < m.Top + m.Height) return i;
      }
      return -1;
    }

    public static List<long> EnumTopLevelWindows() {
      List<long> list = new List<long>();
      EnumWindowsProc callback = delegate(IntPtr hwnd, IntPtr data) {
        list.Add(hwnd.ToInt64());
        return true;
      };
      EnumWindows(callback, IntPtr.Zero);
      return list;
    }

    public static WindowInfoData DescribeWindow(long handle) {
      IntPtr hwnd = new IntPtr(handle);
      WindowInfoData info = new WindowInfoData();
      info.Hwnd = handle;
      uint pid = 0;
      GetWindowThreadProcessId(hwnd, out pid);
      info.Pid = (int)pid;
      StringBuilder title = new StringBuilder(1024);
      GetWindowTextW(hwnd, title, title.Capacity);
      info.Title = title.ToString();
      StringBuilder cls = new StringBuilder(512);
      GetClassNameW(hwnd, cls, cls.Capacity);
      info.Class = cls.ToString();
      RECT raw;
      if (GetWindowRect(hwnd, out raw)) {
        info.RawLeft = raw.Left; info.RawTop = raw.Top;
        info.RawWidth = raw.Right - raw.Left; info.RawHeight = raw.Bottom - raw.Top;
        info.Left = raw.Left; info.Top = raw.Top;
        info.Width = raw.Right - raw.Left; info.Height = raw.Bottom - raw.Top;
      }
      RECT frame;
      try {
        if (DwmGetWindowAttribute(hwnd, 9, out frame, Marshal.SizeOf(typeof(RECT))) == 0) {
          if (frame.Right - frame.Left > 0 && frame.Bottom - frame.Top > 0) {
            info.Left = frame.Left; info.Top = frame.Top;
            info.Width = frame.Right - frame.Left; info.Height = frame.Bottom - frame.Top;
          }
        }
      } catch { }
      info.Visible = IsWindowVisible(hwnd);
      info.Minimized = IsIconic(hwnd);
      info.Foreground = GetForegroundWindow() == hwnd;
      return info;
    }

    public static bool ForceForeground(long handle) {
      IntPtr hwnd = new IntPtr(handle);
      if (!IsWindow(hwnd)) return false;
      if (IsIconic(hwnd)) ShowWindow(hwnd, 9); // SW_RESTORE
      ShowWindow(hwnd, 5);                     // SW_SHOW
      uint pid = 0;
      uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
      uint myThread = GetCurrentThreadId();
      bool attached = false;
      try { attached = AttachThreadInput(myThread, fgThread, true); } catch { }
      BringWindowToTop(hwnd);
      SetForegroundWindow(hwnd);
      SetActiveWindow(hwnd);
      if (attached) { try { AttachThreadInput(myThread, fgThread, false); } catch { } }
      Thread.Sleep(60);
      return GetForegroundWindow() == hwnd;
    }

    public static bool SendUnicode(string text) {
      if (text == null || text.Length == 0) return true;
      List<INPUT> list = new List<INPUT>();
      foreach (char ch in text) {
        INPUT down = new INPUT();
        down.type = INPUT_KEYBOARD;
        down.ki.wVk = 0;
        down.ki.wScan = ch;
        down.ki.dwFlags = KEYEVENTF_UNICODE;
        list.Add(down);
        INPUT up = new INPUT();
        up.type = INPUT_KEYBOARD;
        up.ki.wVk = 0;
        up.ki.wScan = ch;
        up.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        list.Add(up);
      }
      INPUT[] arr = list.ToArray();
      uint sent = SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
      return sent == arr.Length;
    }

    public static bool SendVk(ushort vk, bool extended, bool keyUp) {
      INPUT input = new INPUT();
      input.type = INPUT_KEYBOARD;
      input.ki.wVk = vk;
      uint flags = 0;
      if (extended) flags |= KEYEVENTF_EXTENDEDKEY;
      if (keyUp) flags |= KEYEVENTF_KEYUP;
      input.ki.dwFlags = flags;
      INPUT[] arr = new INPUT[] { input };
      return SendInput(1, arr, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool MouseButton(int button, bool down) {
      INPUT input = new INPUT();
      input.type = INPUT_MOUSE;
      uint flag = MOUSEEVENTF_LEFTDOWN;
      if (button == 2) flag = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
      else if (button == 3) flag = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
      else flag = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
      input.mi.dwFlags = flag;
      INPUT[] arr = new INPUT[] { input };
      return SendInput(1, arr, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool Wheel(int delta, bool horizontal) {
      INPUT input = new INPUT();
      input.type = INPUT_MOUSE;
      input.mi.mouseData = (uint)delta;
      input.mi.dwFlags = horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
      INPUT[] arr = new INPUT[] { input };
      return SendInput(1, arr, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool MoveCursorSmooth(int fromX, int fromY, int toX, int toY, int steps) {
      if (steps < 1) steps = 1;
      for (int i = 1; i <= steps; i++) {
        int x = fromX + (toX - fromX) * i / steps;
        int y = fromY + (toY - fromY) * i / steps;
        SetCursorPos(x, y);
        Thread.Sleep(12);
      }
      return true;
    }
  }
}
'@

try {
  if (-not ('PiWinGui.Native' -as [type])) {
    Add-Type -TypeDefinition $script:KernelSource -Language CSharp | Out-Null
  }
} catch {
  [Console]::Out.WriteLine('{"ok":false,"error":"add-type-failed: ' + ($_.Exception.Message -replace '["\\\r\n]', ' ') + '"}')
  exit 1
}

[void][PiWinGui.Native]::SetAwareness()

Add-Type -AssemblyName UIAutomationClient | Out-Null
Add-Type -AssemblyName UIAutomationTypes | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
Add-Type -AssemblyName System.Windows.Forms | Out-Null

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

$script:ProcNameCache = @{}
$script:ElementMap = @{}   # uid -> AutomationElement
$script:ElementHwnd = @{}  # uid -> window handle (Int64)
$script:UidSeed = @{}

# ------------------------------------------------------------------- utilities

function Get-ProcName([int]$procId) {
  if ($script:ProcNameCache.ContainsKey($procId)) { return $script:ProcNameCache[$procId] }
  $name = ''
  try { $name = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { $name = '' }
  $script:ProcNameCache[$procId] = $name
  return $name
}

function Get-Monitors {
  return [PiWinGui.Native]::GetMonitors()
}

function ConvertTo-RectObject($left, $top, $width, $height) {
  # UIA reports -Infinity/NaN for some offscreen or virtualized elements.
  $l = $left; $t = $top; $w = $width; $h = $height
  if ($null -eq $l -or [double]::IsNaN([double]$l) -or [double]::IsInfinity([double]$l)) { $l = 0 }
  if ($null -eq $t -or [double]::IsNaN([double]$t) -or [double]::IsInfinity([double]$t)) { $t = 0 }
  if ($null -eq $w -or [double]::IsNaN([double]$w) -or [double]::IsInfinity([double]$w)) { $w = 0 }
  if ($null -eq $h -or [double]::IsNaN([double]$h) -or [double]::IsInfinity([double]$h)) { $h = 0 }
  return [ordered]@{ x = [int]$l; y = [int]$t; w = [int]$w; h = [int]$h }
}

function ConvertTo-SafeInt([double]$Value, [int]$Fallback = 0) {
  if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return $Fallback }
  if ($Value -gt 2147483647) { return 2147483647 }
  if ($Value -lt -2147483648) { return -2147483648 }
  return [int]$Value
}

function Get-WindowsData {
  param([switch]$IncludeHidden, [string]$TitlePattern, [string]$ProcessPattern)

  $monitors = Get-Monitors
  $handles = [PiWinGui.Native]::EnumTopLevelWindows()
  $result = New-Object System.Collections.ArrayList
  $z = 0
  foreach ($handle in $handles) {
    $info = [PiWinGui.Native]::DescribeWindow($handle)
    if (-not $info.Visible) { continue }
    if (-not $IncludeHidden -and [string]::IsNullOrWhiteSpace($info.Title)) { continue }
    if ($info.Width -le 1 -or $info.Height -le 1) { continue }
    if ($TitlePattern) {
      if (-not ($info.Title -match $TitlePattern)) { continue }
    }
    $info.Process = Get-ProcName $info.Pid
    if ($ProcessPattern) {
      if (-not ($info.Process -match $ProcessPattern)) { continue }
    }
    $centers = [PiWinGui.Native]::MonitorIndexFor($monitors, $info.Left + [int]($info.Width / 2), $info.Top + [int]($info.Height / 2))
    $entry = [ordered]@{
      hwnd         = [string]$info.Hwnd
      pid          = $info.Pid
      process      = $info.Process
      title        = $info.Title
      class        = $info.Class
      rect         = ConvertTo-RectObject $info.Left $info.Top $info.Width $info.Height
      windowRect   = ConvertTo-RectObject $info.RawLeft $info.RawTop $info.RawWidth $info.RawHeight
      monitor      = $centers
      minimized    = $info.Minimized
      foreground   = $info.Foreground
      z            = $z
    }
    [void]$result.Add($entry)
    $z++
  }
  return $result
}

function Resolve-WindowElement {
  param($WindowSpec)

  if ($null -eq $WindowSpec) { return $null }
  $filter = @{}
  if ($WindowSpec -is [string] -or $WindowSpec -is [ValueType]) {
    $handle = 0L
    if ([Int64]::TryParse([string]$WindowSpec, [ref]$handle)) {
      if ($handle -ne 0 -and [PiWinGui.Native]::IsWindow([IntPtr]$handle)) {
        return @{ hwnd = $handle; element = $AE::FromHandle([IntPtr]$handle) }
      }
    }
    $filter['title'] = [string]$WindowSpec
  } else {
    foreach ($k in $WindowSpec.PSObject.Properties.Name) { $filter[$k] = $WindowSpec.$k }
  }

  $handle = 0L
  if ($filter.ContainsKey('hwnd') -and [Int64]::TryParse([string]$filter['hwnd'], [ref]$handle)) {
    if ([PiWinGui.Native]::IsWindow([IntPtr]$handle)) {
      return @{ hwnd = $handle; element = $AE::FromHandle([IntPtr]$handle) }
    }
  }

  $titlePattern = $null
  if ($filter.ContainsKey('title') -and $filter['title']) { $titlePattern = [string]$filter['title'] }
  $procPattern = $null
  if ($filter.ContainsKey('process') -and $filter['process']) { $procPattern = [string]$filter['process'] }
  $wantedPid = 0
  if ($filter.ContainsKey('pid') -and $filter['pid']) { $wantedPid = [int]$filter['pid'] }

  $hits = @()
  foreach ($handle in [PiWinGui.Native]::EnumTopLevelWindows()) {
    $info = [PiWinGui.Native]::DescribeWindow($handle)
    if (-not $info.Visible) { continue }
    if ([string]::IsNullOrWhiteSpace($info.Title)) { continue }
    if ($titlePattern -and -not ($info.Title -match $titlePattern)) { continue }
    if ($procPattern -and -not ((Get-ProcName $info.Pid) -match $procPattern)) { continue }
    if ($wantedPid -ne 0 -and $info.Pid -ne $wantedPid) { continue }
    $hits += , @{ hwnd = $info.Hwnd; info = $info }
  }
  if ($hits.Count -eq 0) { return $null }
  # prefer foreground, else top of z-order (EnumWindows order)
  $chosen = $hits[0]
  foreach ($m in $hits) { if ($m.info.Foreground) { $chosen = $m; break } }
  return @{ hwnd = $chosen.hwnd; element = $AE::FromHandle([IntPtr]$chosen.hwnd) }
}

function Get-Uid {
  param($Element)
  $raw = $null
  try {
    $ids = $Element.GetRuntimeId()
    if ($ids -and $ids.Length -gt 0) { $raw = ($ids -join '.') }
  } catch { $raw = $null }
  if (-not $raw) {
    try {
      $r = $Element.Current.BoundingRectangle
      $raw = 'fb|' + $Element.Current.ControlType.ProgrammaticName + '|' + $Element.Current.Name + '|' + [int]$r.X + ',' + [int]$r.Y + ',' + [int]$r.Width + ',' + [int]$r.Height
    } catch { $raw = 'fb|' + (Get-Random -Minimum 100000 -Maximum 999999) }
  }
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt 5; $i++) { [void]$sb.Append($bytes[$i].ToString('x2')) }
  return 'u' + $sb.ToString()
}

function Get-ElementPatterns {
  param($Element)
  $names = New-Object System.Collections.Generic.List[string]
  $pairs = @(
    @{ name = 'invoke'; pattern = [System.Windows.Automation.InvokePattern]::Pattern },
    @{ name = 'value'; pattern = [System.Windows.Automation.ValuePattern]::Pattern },
    @{ name = 'text'; pattern = [System.Windows.Automation.TextPattern]::Pattern },
    @{ name = 'toggle'; pattern = [System.Windows.Automation.TogglePattern]::Pattern },
    @{ name = 'select'; pattern = [System.Windows.Automation.SelectionItemPattern]::Pattern },
    @{ name = 'expand'; pattern = [System.Windows.Automation.ExpandCollapsePattern]::Pattern },
    @{ name = 'scroll'; pattern = [System.Windows.Automation.ScrollPattern]::Pattern }
  )
  foreach ($p in $pairs) {
    $obj = $null
    try {
      if ($Element.TryGetCurrentPattern($p.pattern, [ref]$obj)) { [void]$names.Add($p.name) }
    } catch { }
  }
  return $names.ToArray()
}

function Get-SnapshotNodes {
  param(
    $WindowElement,
    [int]$MaxNodes = 300,
    [int]$MaxDepth = 24,
    [string]$NamePattern,
    [string]$RolePattern,
    [switch]$IncludeOffscreen,
    [switch]$WithPatterns,
    [Int64]$OwnerHwnd = 0
  )

  # Bulk FindAll + CacheRequest: one cross-process call fills every property we
  # filter on. Measured on a 320-element Chrome window: 91 ms FindAll + 84 ms
  # per-property reads becomes 95 ms + 1 ms. RuntimeId is NOT requested (it would
  # cost ~0.3 ms/element); uids are derived from cached properties instead and
  # map to the live element so click/invoke still run real UIA patterns.
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  $cacheRequest = New-Object System.Windows.Automation.CacheRequest
  foreach ($prop in @(
      $AE::NameProperty, $AE::BoundingRectangleProperty, $AE::ControlTypeProperty,
      $AE::IsOffscreenProperty, $AE::IsEnabledProperty, $AE::AutomationIdProperty,
      $AE::ClassNameProperty)) {
    $cacheRequest.Add($prop)
  }
  $cacheRequest.TreeFilter = [System.Windows.Automation.Automation]::ControlViewCondition

  $all = $null
  $cacheRequest.Push()
  try {
    $all = $WindowElement.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  } finally {
    $cacheRequest.Pop()
  }
  $findMs = $sw.ElapsedMilliseconds

  $nodes = New-Object System.Collections.ArrayList
  $truncated = $false
  $skipped = 0
  $count = $all.Count
  $seenUid = @{}

  for ($i = 0; $i -lt $count; $i++) {
    $el = $all[$i]
    $cached = $null
    try { $cached = $el.Cached } catch { continue }
    if ($null -eq $cached) { continue }

    $role = ''
    try { $role = $cached.ControlType.ProgrammaticName -replace '^ControlType\.', '' } catch { }
    $name = $cached.Name
    $rect = $cached.BoundingRectangle
    $offscreen = $cached.IsOffscreen

    if ($NamePattern -and -not ($name -match $NamePattern)) { $skipped++; continue }
    if ($RolePattern -and -not ($role -match $RolePattern)) { $skipped++; continue }
    if (-not $IncludeOffscreen -and ($offscreen -or $rect.Width -le 0 -or $rect.Height -le 0)) { $skipped++; continue }

    $w = ConvertTo-SafeInt $rect.Width
    $h = ConvertTo-SafeInt $rect.Height
    $x = ConvertTo-SafeInt $rect.X
    $y = ConvertTo-SafeInt $rect.Y

    # uid from cached properties: stable within one snapshot, and identical
    # role+name+rect duplicates intentionally collapse onto one uid.
    $fingerprint = $role + '|' + $name + '|' + $x + ',' + $y + ',' + $w + ',' + $h + '|' + $cached.AutomationId
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($fingerprint))
    $uidBuilder = New-Object System.Text.StringBuilder
    for ($b = 0; $b -lt 5; $b++) { [void]$uidBuilder.Append($hashBytes[$b].ToString('x2')) }
    $uid = 'u' + $uidBuilder.ToString()

    if ($seenUid.ContainsKey($uid)) { $skipped++; continue }
    $seenUid[$uid] = $true

    if ($nodes.Count -ge $MaxNodes) { $truncated = $true; break }

    $script:ElementMap[$uid] = $el
    if ($OwnerHwnd -ne 0) { $script:ElementHwnd[$uid] = $OwnerHwnd }

    $displayName = $name
    if ($displayName -and $displayName.Length -gt 120) { $displayName = $displayName.Substring(0, 120) + '...' }
    $node = [ordered]@{
      uid  = $uid
      role = $role
      name = if ($displayName) { $displayName } else { '' }
      rect = ConvertTo-RectObject $x $y $w $h
    }
    if ($cached.IsEnabled -eq $false) { $node.enabled = $false }
    if ($offscreen) { $node.offscreen = $true }
    if ($WithPatterns) {
      $patterns = Get-ElementPatterns $el
      if ($patterns.Count -gt 0) { $node.patterns = $patterns }
    }
    [void]$nodes.Add($node)
  }

  return @{ nodes = $nodes; visited = $count; skipped = $skipped; truncated = $truncated; findMs = $findMs; totalMs = $sw.ElapsedMilliseconds }
}

function Resolve-ElementByUid {
  param([string]$Uid)
  if (-not $Uid) { return $null }
  if (-not $script:ElementMap.ContainsKey($Uid)) { return $null }
  return $script:ElementMap[$Uid]
}

function Get-CursorInfo {
  $p = New-Object PiWinGui.POINT
  [void][PiWinGui.Native]::GetCursorPos([ref]$p)
  $handle = [PiWinGui.Native]::WindowFromPoint($p)
  $root = [PiWinGui.Native]::GetAncestor($handle, 2)
  $title = ''
  if ($root -ne [IntPtr]::Zero) {
    $info = [PiWinGui.Native]::DescribeWindow($root.ToInt64())
    $title = $info.Title
  }
  return [ordered]@{
    x = $p.X; y = $p.Y; hwnd = [string]$root.ToInt64(); title = $title
  }
}

function Get-ImageBlankness {
  param([System.Drawing.Bitmap]$Bitmap)
  $rect = New-Object System.Drawing.Rectangle 0, 0, $Bitmap.Width, $Bitmap.Height
  $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  try {
    $stride = $data.Stride
    $bytes = New-Object byte[] ($stride * $Bitmap.Height)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $seen = New-Object System.Collections.Generic.HashSet[int]
    $stepY = [Math]::Max(1, [int]($Bitmap.Height / 48))
    $stepX = [Math]::Max(1, [int]($Bitmap.Width / 48))
    for ($y = 0; $y -lt $Bitmap.Height; $y += $stepY) {
      $row = $y * $stride
      for ($x = 0; $x -lt $Bitmap.Width; $x += $stepX) {
        $i = $row + $x * 4
        if ($i + 3 -lt $bytes.Length) {
          $color = $bytes[$i] + ($bytes[$i + 1] -shl 8) + ($bytes[$i + 2] -shl 16)
          [void]$seen.Add($color)
          if ($seen.Count -gt 6) { return $false }
        }
      }
    }
    return ($seen.Count -le 2)
  } finally {
    $Bitmap.UnlockBits($data)
  }
}

function Save-BitmapImage {
  param(
    [System.Drawing.Bitmap]$Bitmap,
    [string]$Path,
    [string]$Format = 'png',
    [int]$Quality = 82
  )

  $dir = [System.IO.Path]::GetDirectoryName($Path)
  if ($dir -and -not [System.IO.Directory]::Exists($dir)) {
    [void][System.IO.Directory]::CreateDirectory($dir)
  }
  $ext = [System.IO.Path]::GetExtension($Path)
  if ([string]::IsNullOrWhiteSpace($ext)) {
    if ($Format -eq 'jpeg' -or $Format -eq 'jpg') { $Path = $Path + '.jpg' } else { $Path = $Path + '.png' }
  }
  if ($Format -eq 'jpeg' -or $Format -eq 'jpg') {
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    $params = New-Object System.Drawing.Imaging.EncoderParameters 1
    $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([int]$Quality)
    $Bitmap.Save($Path, $codec, $params)
  } else {
    $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  }
  return $Path
}

# ------------------------------------------------------------------------ ops

# Paste text through the clipboard, then restore the previous clipboard content.
# Measured: SendInput KEYEVENTF_UNICODE is unreliable in some controls (new
# Notepad turns "abc def" into "abc fff" by repeating a neighbouring character,
# repro'd at chunk sizes 1/32 and with per-char 40 ms gaps, while a WinForms
# TextBox is fine). Clipboard paste is exact in both, and faster for long text.
function Invoke-ClipboardPaste {
  param([string]$Text, [switch]$KeepClipboard)
  $previous = $null
  if (-not $KeepClipboard) {
    try { $previous = Get-Clipboard -Raw -ErrorAction Stop } catch { $previous = $null }
  }
  Set-Clipboard -Value $Text
  Start-Sleep -Milliseconds 110
  [void][PiWinGui.Native]::SendVk(0x11, $false, $false)
  [void][PiWinGui.Native]::SendVk(0x56, $false, $false)
  Start-Sleep -Milliseconds 20
  [void][PiWinGui.Native]::SendVk(0x56, $false, $true)
  [void][PiWinGui.Native]::SendVk(0x11, $false, $true)
  Start-Sleep -Milliseconds 90
  if (-not $KeepClipboard -and $null -ne $previous -and $previous -ne '') {
    try { Set-Clipboard -Value $previous } catch { }
  }
  return $true
}

function Send-UnicodeChunked {
  param([string]$Text, [int]$ChunkSize = 32)
  if ([string]::IsNullOrEmpty($Text)) { return $true }
  if ($ChunkSize -lt 8) { $ChunkSize = 8 }
  for ($offset = 0; $offset -lt $Text.Length; $offset += $ChunkSize) {
    $take = [Math]::Min($ChunkSize, $Text.Length - $offset)
    $slice = $Text.Substring($offset, $take)
    $ok = [PiWinGui.Native]::SendUnicode($slice)
    if (-not $ok) { return $false }
    Start-Sleep -Milliseconds 25
  }
  return $true
}

function Read-ElementText {
  param($Element, [int]$Limit = 4000)
  $value = $null
  $text = $null
  $obj = $null
  try {
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$obj)) {
      $value = $obj.Current.Value
    }
  } catch { }
  try {
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$obj)) {
      $text = $obj.DocumentRange.GetText(-1)
    }
  } catch { }
  $combined = $null
  if ($value) { $combined = $value } elseif ($text) { $combined = $text }
  if ($combined -and $Limit -gt 0 -and $combined.Length -gt $Limit) {
    $combined = $combined.Substring(0, $Limit) + '...[truncated]'
  }
  return @{ value = $value; text = $text; combined = $combined }
}

# UIA text lags behind the real document (measured: 96 of 300 chars at +500 ms,
# complete at +2 s). Poll until the length we expect shows up instead of
# sleeping a fixed time.
function Wait-ElementTextLength {
  param($Element, [int]$Expected, [int]$TimeoutMs = 2500)
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  $last = -1
  while ((Get-Date) -lt $deadline) {
    $probe = Read-ElementText -Element $Element -Limit 0
    $current = 0
    if ($probe.combined) { $current = $probe.combined.Length }
    if ($current -gt $last) { $last = $current }
    if ($current -ge $Expected) { return $current }
    Start-Sleep -Milliseconds 120
  }
  return $last
}

function Invoke-Op {
  param([string]$Op, $Params)

  switch ($Op) {

    'hello' {
      $monitors = Get-Monitors
      $virtual = [ordered]@{
        x = [PiWinGui.Native]::GetSystemMetrics(76)
        y = [PiWinGui.Native]::GetSystemMetrics(77)
        w = [PiWinGui.Native]::GetSystemMetrics(78)
        h = [PiWinGui.Native]::GetSystemMetrics(79)
      }
      return [ordered]@{
        ok            = $true
        psVersion     = $PSVersionTable.PSVersion.ToString()
        psEdition     = $PSVersionTable.PSEdition
        processId     = $PID
        dpiAware      = 'per-monitor-v2'
        virtualScreen = $virtual
        monitorCount  = $monitors.Count
        monitors      = @($monitors | ForEach-Object {
            [ordered]@{
              index = $_.Index; x = $_.Left; y = $_.Top; w = $_.Width; h = $_.Height
              dpiX = $_.DpiX; dpiY = $_.DpiY; scale = $_.Scale; primary = $_.Primary; device = $_.Device
              workArea = [ordered]@{ x = $_.WorkLeft; y = $_.WorkTop; w = $_.WorkWidth; h = $_.WorkHeight }
            }
          })
      }
    }

    'monitors' {
      $monitors = Get-Monitors
      return [ordered]@{
        virtualScreen = [ordered]@{
          x = [PiWinGui.Native]::GetSystemMetrics(76); y = [PiWinGui.Native]::GetSystemMetrics(77)
          w = [PiWinGui.Native]::GetSystemMetrics(78); h = [PiWinGui.Native]::GetSystemMetrics(79)
        }
        monitors = @($monitors | ForEach-Object {
            [ordered]@{
              index = $_.Index; x = $_.Left; y = $_.Top; w = $_.Width; h = $_.Height
              dpiX = $_.DpiX; dpiY = $_.DpiY; scale = $_.Scale; primary = $_.Primary; device = $_.Device
              workArea = [ordered]@{ x = $_.WorkLeft; y = $_.WorkTop; w = $_.WorkWidth; h = $_.WorkHeight }
            }
          })
        cursor = Get-CursorInfo
      }
    }

    'windows' {
      $windows = Get-WindowsData -IncludeHidden:([bool]$Params.all) -TitlePattern $Params.title -ProcessPattern $Params.process
      return [ordered]@{ count = $windows.Count; windows = @($windows) }
    }

    'focus' {
      $target = Resolve-WindowElement $Params.window
      if (-not $target) { throw 'window-not-found' }
      $ok = [PiWinGui.Native]::ForceForeground($target.hwnd)
      $info = [PiWinGui.Native]::DescribeWindow($target.hwnd)
      return [ordered]@{
        ok         = $ok
        hwnd       = [string]$target.hwnd
        title      = $info.Title
        foreground = [PiWinGui.Native]::GetForegroundWindow().ToInt64().ToString()
      }
    }

    'snapshot' {
      $target = Resolve-WindowElement $Params.window
      if (-not $target) { throw 'window-not-found' }
      $snap = Get-SnapshotNodes -WindowElement $target.element `
        -MaxNodes ([int]($Params.maxNodes | ForEach-Object { if ($_) { $_ } else { 300 } })) `
        -MaxDepth ([int]($Params.maxDepth | ForEach-Object { if ($_) { $_ } else { 24 } })) `
        -NamePattern $Params.name -RolePattern $Params.role `
        -IncludeOffscreen:([bool]$Params.includeOffscreen) -WithPatterns:([bool]$Params.patterns) `
        -OwnerHwnd ([Int64]$target.hwnd)
      $info = [PiWinGui.Native]::DescribeWindow($target.hwnd)
      return [ordered]@{
        hwnd      = [string]$target.hwnd
        title     = $info.Title
        rect      = ConvertTo-RectObject $info.Left $info.Top $info.Width $info.Height
        visited   = $snap.visited
        skipped   = $snap.skipped
        truncated = $snap.truncated
        timings   = [ordered]@{ find = $snap.findMs; total = $snap.totalMs }
        nodes     = @($snap.nodes)
      }
    }

    'element' {
      $el = Resolve-ElementByUid ([string]$Params.uid)
      if (-not $el) { throw 'uid-not-found' }
      $current = $el.Current
      $rect = $current.BoundingRectangle
      return [ordered]@{
        uid      = [string]$Params.uid
        role     = ($current.ControlType.ProgrammaticName -replace '^ControlType\.', '')
        name     = $current.Name
        rect     = ConvertTo-RectObject $rect.X $rect.Y $rect.Width $rect.Height
        enabled  = $current.IsEnabled
        offscreen = $current.IsOffscreen
        patterns = Get-ElementPatterns $el
      }
    }

    'read' {
      $value = $null
      $text = $null
      $source = ''
      $el = $null
      if ($Params.uid) {
        $el = Resolve-ElementByUid ([string]$Params.uid)
        if (-not $el) { throw 'uid-not-found' }
        $source = 'uid'
      } else {
        $target = Resolve-WindowElement $Params.window
        if (-not $target) { throw 'window-not-found' }
        $source = 'window'
        $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Edit)
        $el = $target.element.FindFirst($TS::Descendants, $cond)
        if (-not $el) {
          $condDoc = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Document)
          $el = $target.element.FindFirst($TS::Descendants, $condDoc)
        }
        if (-not $el) { $el = $target.element }
      }
      $obj = $null
      try {
        if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$obj)) {
          $value = $obj.Current.Value
        }
      } catch { }
      try {
        if ($el.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$obj)) {
          $text = $obj.DocumentRange.GetText(-1)
        }
      } catch { }
      $limit = 4000
      if ($Params.limit) { $limit = [int]$Params.limit }
      if ($value -and $value.Length -gt $limit) { $value = $value.Substring(0, $limit) + '...[truncated]' }
      if ($text -and $text.Length -gt $limit) { $text = $text.Substring(0, $limit) + '...[truncated]' }
      $rect = $el.Current.BoundingRectangle
      return [ordered]@{
        source = $source
        value  = $value
        text   = $text
        rect   = ConvertTo-RectObject $rect.X $rect.Y $rect.Width $rect.Height
      }
    }

    'setValue' {
      $el = Resolve-ElementByUid ([string]$Params.uid)
      if (-not $el) { throw 'uid-not-found' }
      $obj = $null
      if (-not $el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$obj)) { throw 'no-value-pattern' }
      $obj.SetValue([string]$Params.text)
      return [ordered]@{ ok = $true; value = $obj.Current.Value }
    }

    'click' {
      $notches = 1
      if ($Params.count) { $notches = [int]$Params.count }
      $button = 1
      if ($Params.button) {
        switch ([string]$Params.button) {
          'left' { $button = 1 }
          'right' { $button = 2 }
          'middle' { $button = 3 }
          default { $button = [int]$Params.button }
        }
      }

      $x = 0; $y = 0
      $targetHwnd = $null
      if ($Params.uid) {
        $el = Resolve-ElementByUid ([string]$Params.uid)
        if (-not $el) { throw 'uid-not-found' }
        $rect = $el.Current.BoundingRectangle
        $x = [int]($rect.X + $rect.Width / 2)
        $y = [int]($rect.Y + $rect.Height / 2)
        if ($script:ElementHwnd.ContainsKey([string]$Params.uid)) { $targetHwnd = $script:ElementHwnd[[string]$Params.uid] }
        if ($Params.method -eq 'uia-invoke') {
          $obj = $null
          if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$obj)) {
            $obj.Invoke()
            return [ordered]@{ ok = $true; method = 'uia-invoke'; x = $x; y = $y }
          }
          throw 'no-invoke-pattern'
        }
      } elseif ($null -ne $Params.x -and $null -ne $Params.y) {
        $x = [int]$Params.x
        $y = [int]$Params.y
      } elseif ($Params.window) {
        $target = Resolve-WindowElement $Params.window
        if (-not $target) { throw 'window-not-found' }
        $info = [PiWinGui.Native]::DescribeWindow($target.hwnd)
        $rx = [int]$Params.rx
        $ry = [int]$Params.ry
        $x = $info.Left + $rx
        $y = $info.Top + $ry
        $targetHwnd = $target.hwnd
      } else {
        throw 'need uid, x/y or window+rx/ry'
      }

      if ($Params.dx) { $x += [int]$Params.dx }
      if ($Params.dy) { $y += [int]$Params.dy }

      if ($targetHwnd -and $Params.noFocus -ne $true) {
        [void][PiWinGui.Native]::ForceForeground([Int64]$targetHwnd)
      }
      if ($Params.expectForeground -eq $true -and $targetHwnd) {
        if ([PiWinGui.Native]::GetForegroundWindow().ToInt64() -ne [Int64]$targetHwnd) {
          throw ('foreground-mismatch: expected ' + $targetHwnd + ' got ' + [PiWinGui.Native]::GetForegroundWindow().ToInt64())
        }
      }

      [void][PiWinGui.Native]::SetCursorPos($x, $y)
      Start-Sleep -Milliseconds 30
      for ($i = 0; $i -lt $notches; $i++) {
        [void][PiWinGui.Native]::MouseButton($button, $true)
        Start-Sleep -Milliseconds 25
        [void][PiWinGui.Native]::MouseButton($button, $false)
        if ($i -lt $notches - 1) { Start-Sleep -Milliseconds 60 }
      }
      Start-Sleep -Milliseconds 80
      return [ordered]@{
        ok     = $true
        method = 'mouse'
        x      = $x
        y      = $y
        button = $button
        count  = $notches
        cursor = Get-CursorInfo
      }
    }

    'type' {
      # 'paste' is the default: exact for CJK/emoji in every control tested,
      # while SendInput UNICODE corrupts some of them (see Invoke-ClipboardPaste).
      $method = 'paste'
      if ($Params.method) { $method = [string]$Params.method }
      $text = [string]$Params.text
      $targetHwnd = $null
      if ($Params.window) {
        $target = Resolve-WindowElement $Params.window
        if (-not $target) { throw 'window-not-found' }
        $targetHwnd = $target.hwnd
        if ($Params.noFocus -ne $true) { [void][PiWinGui.Native]::ForceForeground([Int64]$targetHwnd) }
      }
      if ($Params.uid) {
        $el = Resolve-ElementByUid ([string]$Params.uid)
        if (-not $el) { throw 'uid-not-found' }
        if ($method -eq 'value') {
          $obj = $null
          if (-not $el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$obj)) { throw 'no-value-pattern' }
          $obj.SetValue($text)
          return [ordered]@{ ok = $true; method = 'value'; value = $obj.Current.Value }
        }
        $rect = $el.Current.BoundingRectangle
        try { $el.SetFocus() } catch { }
        [void][PiWinGui.Native]::SetCursorPos([int]($rect.X + $rect.Width / 2), [int]($rect.Y + $rect.Height / 2))
        Start-Sleep -Milliseconds 30
        [void][PiWinGui.Native]::MouseButton(1, $true)
        Start-Sleep -Milliseconds 20
        [void][PiWinGui.Native]::MouseButton(1, $false)
        Start-Sleep -Milliseconds 60
      }
      if ($Params.replace -eq $true) {
        [void][PiWinGui.Native]::SendVk(0x11, $false, $false)   # CTRL
        [void][PiWinGui.Native]::SendVk(0x41, $false, $false)   # A
        [void][PiWinGui.Native]::SendVk(0x41, $false, $true)
        [void][PiWinGui.Native]::SendVk(0x11, $false, $true)
        Start-Sleep -Milliseconds 40
      }
      if ($method -eq 'paste') {
        [void](Invoke-ClipboardPaste -Text $text -KeepClipboard:([bool]$Params.keepClipboard))
      } else {
        $chunk = 32
        if ($Params.chunkSize) { $chunk = [int]$Params.chunkSize }
        [void](Send-UnicodeChunked -Text $text -ChunkSize $chunk)
      }
      if ($Params.enter -eq $true) {
        Start-Sleep -Milliseconds 40
        [void][PiWinGui.Native]::SendVk(0x0D, $false, $false)
        Start-Sleep -Milliseconds 20
        [void][PiWinGui.Native]::SendVk(0x0D, $false, $true)
      }
      Start-Sleep -Milliseconds 120
      $result = [ordered]@{ ok = $true; method = $method; length = $text.Length }
      if ($Params.uid -and $Params.verify -ne $false) {
        $el = Resolve-ElementByUid ([string]$Params.uid)
        if ($el) {
          $expected = $text.Length
          if ($Params.replace -eq $true) { $observed = Wait-ElementTextLength -Element $el -Expected $expected } else { $observed = (Read-ElementText -Element $el -Limit 0).combined }
          if ($observed -ne $null -and $observed -is [int]) {
            $result.observedLength = $observed
            if ($observed -lt $expected) { $result.warning = 'ui-text-shorter-than-sent: UIA text lags; re-read with read after a short delay or verify via clipboard' }
          }
        }
      }
      return $result
    }

    'key' {
      $combo = [string]$Params.keys
      if ($Params.window) {
        $target = Resolve-WindowElement $Params.window
        if (-not $target) { throw 'window-not-found' }
        [void][PiWinGui.Native]::ForceForeground([Int64]$target.hwnd)
      }
      $vkMap = @{
        'CTRL' = 0x11; 'CONTROL' = 0x11; 'SHIFT' = 0x10; 'ALT' = 0x12; 'WIN' = 0x5B
        'ENTER' = 0x0D; 'RETURN' = 0x0D; 'TAB' = 0x09; 'ESC' = 0x1B; 'ESCAPE' = 0x1B
        'SPACE' = 0x20; 'BACKSPACE' = 0x08; 'BKSP' = 0x08; 'DELETE' = 0x2E; 'DEL' = 0x2E
        'INSERT' = 0x2D; 'INS' = 0x2D; 'HOME' = 0x24; 'END' = 0x23
        'PAGEUP' = 0x21; 'PGUP' = 0x21; 'PAGEDOWN' = 0x22; 'PGDN' = 0x22
        'UP' = 0x26; 'DOWN' = 0x28; 'LEFT' = 0x25; 'RIGHT' = 0x27
        'PRINTSCREEN' = 0x2C; 'CAPSLOCK' = 0x14
      }
      for ($i = 1; $i -le 24; $i++) { $vkMap['F' + $i] = 0x6F + $i }

      $parts = $combo -split '\+'
      $vks = New-Object System.Collections.Generic.List[int]
      foreach ($raw in $parts) {
        $token = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($token)) { continue }
        $upper = $token.ToUpperInvariant()
        if ($vkMap.ContainsKey($upper)) { [void]$vks.Add($vkMap[$upper]); continue }
        if ($upper.Length -eq 1) {
          $code = [int][char]$upper
          if ($code -ge 65 -and $code -le 90) { [void]$vks.Add($code); continue }
          if ($code -ge 48 -and $code -le 57) { [void]$vks.Add($code); continue }
        }
        throw ('unknown-key: ' + $token)
      }
      if ($vks.Count -eq 0) { throw 'no-keys' }

      $repeat = 1
      if ($Params.repeat) { $repeat = [int]$Params.repeat }
      for ($r = 0; $r -lt $repeat; $r++) {
        for ($i = 0; $i -lt $vks.Count; $i++) {
          $ext = ($vks[$i] -eq 0x2E -or $vks[$i] -eq 0x25 -or $vks[$i] -eq 0x26 -or $vks[$i] -eq 0x27 -or $vks[$i] -eq 0x24 -or $vks[$i] -eq 0x23 -or $vks[$i] -eq 0x21 -or $vks[$i] -eq 0x22)
          [void][PiWinGui.Native]::SendVk([uint16]$vks[$i], $ext, $false)
          Start-Sleep -Milliseconds 15
        }
        for ($i = $vks.Count - 1; $i -ge 0; $i--) {
          $ext = ($vks[$i] -eq 0x2E -or $vks[$i] -eq 0x25 -or $vks[$i] -eq 0x26 -or $vks[$i] -eq 0x27 -or $vks[$i] -eq 0x24 -or $vks[$i] -eq 0x23 -or $vks[$i] -eq 0x21 -or $vks[$i] -eq 0x22)
          [void][PiWinGui.Native]::SendVk([uint16]$vks[$i], $ext, $true)
          Start-Sleep -Milliseconds 15
        }
        Start-Sleep -Milliseconds 60
      }
      return [ordered]@{ ok = $true; keys = $combo; repeat = $repeat }
    }

    'drag' {
      $x1 = [int]$Params.x1; $y1 = [int]$Params.y1; $x2 = [int]$Params.x2; $y2 = [int]$Params.y2
      $steps = 18
      if ($Params.steps) { $steps = [int]$Params.steps }
      [void][PiWinGui.Native]::SetCursorPos($x1, $y1)
      Start-Sleep -Milliseconds 80
      [void][PiWinGui.Native]::MouseButton(1, $true)
      Start-Sleep -Milliseconds 60
      [void][PiWinGui.Native]::MoveCursorSmooth($x1, $y1, $x2, $y2, $steps)
      Start-Sleep -Milliseconds 80
      [void][PiWinGui.Native]::MouseButton(1, $false)
      Start-Sleep -Milliseconds 120
      return [ordered]@{ ok = $true; from = @($x1, $y1); to = @($x2, $y2) }
    }

    'scroll' {
      if ($null -ne $Params.x -and $null -ne $Params.y) {
        [void][PiWinGui.Native]::SetCursorPos([int]$Params.x, [int]$Params.y)
        Start-Sleep -Milliseconds 60
      }
      $notches = 3
      if ($Params.notches) { $notches = [int]$Params.notches }
      $direction = 'down'
      if ($Params.direction) { $direction = [string]$Params.direction }
      $delta = 120 * $notches
      if ($direction -eq 'up' -or $direction -eq 'left') { $delta = - $delta }
      $horizontal = ($direction -eq 'left' -or $direction -eq 'right')
      [void][PiWinGui.Native]::Wheel($delta, $horizontal)
      Start-Sleep -Milliseconds 120
      return [ordered]@{ ok = $true; direction = $direction; notches = $notches }
    }

    'clipboard' {
      if ($Params.set) {
        Set-Clipboard -Value ([string]$Params.set)
        Start-Sleep -Milliseconds 60
      }
      $value = ''
      try { $value = Get-Clipboard -Raw -ErrorAction Stop } catch { $value = '' }
      return [ordered]@{ ok = $true; text = $value }
    }

    'screenshot' {
      $monitors = Get-Monitors
      $targetKind = 'window'
      if ($Params.target) { $targetKind = [string]$Params.target }

      $captureRect = $null
      $windowInfo = $null
      $method = 'screen'
      $printWindowTarget = [IntPtr]::Zero

      if ($targetKind -eq 'window') {
        $target = Resolve-WindowElement $Params.window
        if (-not $target) { throw 'window-not-found' }
        $windowInfo = [PiWinGui.Native]::DescribeWindow($target.hwnd)
        if ($windowInfo.Minimized -and $Params.restore -eq $true) {
          [void][PiWinGui.Native]::ForceForeground($target.hwnd)
          Start-Sleep -Milliseconds 250
          $windowInfo = [PiWinGui.Native]::DescribeWindow($target.hwnd)
        }
        if ($Params.captureShadow -eq $true) {
          $captureRect = @{ x = $windowInfo.RawLeft; y = $windowInfo.RawTop; w = $windowInfo.RawWidth; h = $windowInfo.RawHeight }
        } else {
          $captureRect = @{ x = $windowInfo.RawLeft; y = $windowInfo.RawTop; w = $windowInfo.RawWidth; h = $windowInfo.RawHeight }
        }
        $printWindowTarget = [IntPtr]$target.hwnd
        $method = 'printwindow'
      } elseif ($targetKind -eq 'monitor') {
        $idx = 0
        if ($null -ne $Params.monitor) { $idx = [int]$Params.monitor }
        if ($idx -lt 0 -or $idx -ge $monitors.Count) { throw ('monitor-out-of-range: ' + $idx) }
        $m = $monitors[$idx]
        $captureRect = @{ x = $m.Left; y = $m.Top; w = $m.Width; h = $m.Height }
      } elseif ($targetKind -eq 'region') {
        $r = $Params.region
        if (-not $r) { throw 'region-required' }
        $captureRect = @{ x = [int]$r.x; y = [int]$r.y; w = [int]$r.w; h = [int]$r.h }
      } elseif ($targetKind -eq 'full') {
        $captureRect = @{
          x = [PiWinGui.Native]::GetSystemMetrics(76); y = [PiWinGui.Native]::GetSystemMetrics(77)
          w = [PiWinGui.Native]::GetSystemMetrics(78); h = [PiWinGui.Native]::GetSystemMetrics(79)
        }
      } else {
        throw ('unknown-target: ' + $targetKind)
      }

      if ($captureRect.w -le 0 -or $captureRect.h -le 0) { throw 'empty-capture-rect' }

      # Source rect = the whole thing we render/copy from.
      # Final rect = source rect further limited by crop (global physical pixels).
      # PrintWindow always renders the entire window at source-rect size, so a
      # crop must be applied to the rendered bitmap, not to the capture size.
      $sourceRect = @{ x = $captureRect.x; y = $captureRect.y; w = $captureRect.w; h = $captureRect.h }
      $finalRect = @{ x = $sourceRect.x; y = $sourceRect.y; w = $sourceRect.w; h = $sourceRect.h }
      if ($Params.crop) {
        $c = $Params.crop
        $x1 = [Math]::Max($sourceRect.x, [int]$c.x)
        $y1 = [Math]::Max($sourceRect.y, [int]$c.y)
        $x2 = [Math]::Min($sourceRect.x + $sourceRect.w, [int]$c.x + [int]$c.w)
        $y2 = [Math]::Min($sourceRect.y + $sourceRect.h, [int]$c.y + [int]$c.h)
        if ($x2 -le $x1 -or $y2 -le $y1) { throw 'crop-outside-capture-rect' }
        $finalRect = @{ x = $x1; y = $y1; w = $x2 - $x1; h = $y2 - $y1 }
      }

      $bitmap = New-Object System.Drawing.Bitmap $sourceRect.w, $sourceRect.h
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      $blank = $false
      $setForeground = $false

      if ($printWindowTarget -ne [IntPtr]::Zero -and $Params.forceScreen -ne $true) {
        $hdc = $graphics.GetHdc()
        $ok = $false
        try { $ok = [PiWinGui.Native]::PrintWindow($printWindowTarget, $hdc, 2) } finally { $graphics.ReleaseHdc($hdc) }
        if (-not $ok) {
          $graphics.CopyFromScreen($sourceRect.x, $sourceRect.y, 0, 0, (New-Object System.Drawing.Size $sourceRect.w, $sourceRect.h))
          $method = 'screen'
        }
      } else {
        $graphics.CopyFromScreen($sourceRect.x, $sourceRect.y, 0, 0, (New-Object System.Drawing.Size $sourceRect.w, $sourceRect.h))
        $method = 'screen'
      }
      $graphics.Dispose()

      $blank = Get-ImageBlankness -Bitmap $bitmap
      if ($blank -and $printWindowTarget -ne [IntPtr]::Zero -and $Params.fallbackScreen -ne $false) {
        # PrintWindow returned a blank frame (composited / GPU surfaces): retry by
        # raising the window and screen-copying its rect.
        [void][PiWinGui.Native]::ForceForeground([Int64]$printWindowTarget.ToInt64())
        Start-Sleep -Milliseconds 220
        $bitmap.Dispose()
        $bitmap = New-Object System.Drawing.Bitmap $sourceRect.w, $sourceRect.h
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($sourceRect.x, $sourceRect.y, 0, 0, (New-Object System.Drawing.Size $sourceRect.w, $sourceRect.h))
        $graphics.Dispose()
        $method = 'screen-after-blank-printwindow'
        $setForeground = $true
        $blank = Get-ImageBlankness -Bitmap $bitmap
      }

      if ($finalRect.w -ne $sourceRect.w -or $finalRect.h -ne $sourceRect.h) {
        $cropOffsetX = $finalRect.x - $sourceRect.x
        $cropOffsetY = $finalRect.y - $sourceRect.y
        $cropped = New-Object System.Drawing.Bitmap $finalRect.w, $finalRect.h
        $cropGraphics = [System.Drawing.Graphics]::FromImage($cropped)
        $cropGraphics.DrawImage(
          $bitmap,
          (New-Object System.Drawing.Rectangle 0, 0, $finalRect.w, $finalRect.h),
          (New-Object System.Drawing.Rectangle $cropOffsetX, $cropOffsetY, $finalRect.w, $finalRect.h),
          [System.Drawing.GraphicsUnit]::Pixel)
        $cropGraphics.Dispose()
        $bitmap.Dispose()
        $bitmap = $cropped
      }
      $captureRect = $finalRect

      $origW = $bitmap.Width
      $origH = $bitmap.Height
      $maxDim = 1600
      if ($null -ne $Params.maxDim) { $maxDim = [int]$Params.maxDim }
      $scale = 1.0
      if ($maxDim -gt 0 -and ($origW -gt $maxDim -or $origH -gt $maxDim)) {
        $scale = $maxDim / [double][Math]::Max($origW, $origH)
      }

      $outBitmap = $bitmap
      $newW = [int][Math]::Round($origW * $scale)
      $newH = [int][Math]::Round($origH * $scale)
      if ($scale -ne 1.0 -and $newW -gt 0 -and $newH -gt 0) {
        $outBitmap = New-Object System.Drawing.Bitmap $newW, $newH
        $g2 = [System.Drawing.Graphics]::FromImage($outBitmap)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g2.DrawImage($bitmap, (New-Object System.Drawing.Rectangle 0, 0, $newW, $newH))
        $g2.Dispose()
      }

      $path = [string]$Params.out
      if ([string]::IsNullOrWhiteSpace($path)) { throw 'out-required' }
      $saved = Save-BitmapImage -Bitmap $outBitmap -Path $path -Format ([string]$Params.format) -Quality ([int]($Params.quality | ForEach-Object { if ($_) { $_ } else { 82 } }))
      $outBitmap.Dispose()
      $bitmap.Dispose()

      $monitorIndex = [PiWinGui.Native]::MonitorIndexFor($monitors, $captureRect.x + [int]($captureRect.w / 2), $captureRect.y + [int]($captureRect.h / 2))
      $result = [ordered]@{
        ok          = $true
        path        = $saved
        method      = $method
        blank       = $blank
        raisedWindow = $setForeground
        width       = $newW
        height      = $newH
        sourceWidth = $origW
        sourceHeight = $origH
        scale       = [Math]::Round($scale, 4)
        captureRect = ConvertTo-RectObject $captureRect.x $captureRect.y $captureRect.w $captureRect.h
        origin      = [ordered]@{ x = $captureRect.x; y = $captureRect.y }
        monitor     = $monitorIndex
        hint        = 'screen coordinate = origin + (image pixel / scale)'
      }
      if ($windowInfo) {
        $result.window = [ordered]@{
          hwnd     = [string]$windowInfo.Hwnd
          title    = $windowInfo.Title
          rect     = ConvertTo-RectObject $windowInfo.Left $windowInfo.Top $windowInfo.Width $windowInfo.Height
          minimized = $windowInfo.Minimized
        }
      }
      if ($scale -lt 0.55) {
        $result.warning = 'downscaled a lot; text may be unreadable - capture window/region or raise maxDim'
      }
      return $result
    }

    'wait' {
      $target = Resolve-WindowElement $Params.window
      if (-not $target) { throw 'window-not-found' }
      $timeout = 5000
      if ($Params.timeout) { $timeout = [int]$Params.timeout }
      $poll = 300
      $deadline = (Get-Date).AddMilliseconds($timeout)
      while ((Get-Date) -lt $deadline) {
        $snap = Get-SnapshotNodes -WindowElement $target.element -MaxNodes 400 -MaxDepth 24 -NamePattern $Params.name -RolePattern $Params.role -WithPatterns -OwnerHwnd ([Int64]$target.hwnd)
        if ($snap.nodes.Count -gt 0) {
          return [ordered]@{ ok = $true; waited = $true; nodes = @($snap.nodes) }
        }
        Start-Sleep -Milliseconds $poll
      }
      return [ordered]@{ ok = $true; waited = $false; nodes = @() }
    }

    'shutdown' {
      return [ordered]@{ ok = $true; bye = $true }
    }

    default {
      throw ('unknown-op: ' + $Op)
    }
  }
}

# ------------------------------------------------------------------- main loop

$readyPayload = [ordered]@{
  ok      = $true
  event   = 'ready'
  pid     = $PID
  ps      = $PSVersionTable.PSVersion.ToString()
  edition = $PSVersionTable.PSEdition
}
[Console]::Out.WriteLine(($readyPayload | ConvertTo-Json -Compress -Depth 6))
[Console]::Out.Flush()

while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  $line = $line.Trim()
  if ($line -eq '') { continue }

  $request = $null
  try { $request = $line | ConvertFrom-Json } catch {
    [Console]::Out.WriteLine('{"ok":false,"error":"bad-json"}')
    [Console]::Out.Flush()
    continue
  }

  $rid = $null
  if ($request.PSObject.Properties.Name -contains 'id') { $rid = $request.id }
  $op = [string]$request.op
  $argsObj = $null
  if ($request.PSObject.Properties.Name -contains 'args') { $argsObj = $request.args }

  $stop = $false
  try {
    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-Op -Op $op -Params $argsObj
    $stopWatch.Stop()
    if ($result -is [System.Collections.IDictionary]) {
      $result['elapsedMs'] = [int]$stopWatch.ElapsedMilliseconds
    }
    $payload = [ordered]@{ id = $rid; op = $op; ok = $true; result = $result }
    $json = $payload | ConvertTo-Json -Compress -Depth 20
    if ($op -eq 'shutdown') { $stop = $true }
  } catch {
    $message = $_.Exception.Message
    $message = $message -replace '[\r\n]+', ' '
    $payload = [ordered]@{ id = $rid; op = $op; ok = $false; error = $message }
    $json = $payload | ConvertTo-Json -Compress -Depth 6
  }

  [Console]::Out.WriteLine($json)
  [Console]::Out.Flush()

  if ($script:ElementMap.Count -gt 6000) {
    $script:ElementMap = @{}
    $script:ElementHwnd = @{}
  }
  if ($script:ProcNameCache.Count -gt 800) { $script:ProcNameCache = @{} }

  if ($stop) { break }
}
