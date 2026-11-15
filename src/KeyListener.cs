using System;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Security.Principal;
using System.Threading;
using System.Xml;

internal static class XiaoAiKey {
    static readonly string Root = AppDomain.CurrentDomain.BaseDirectory;
    static readonly string StateRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XiaoAiKey");
    static readonly string Sid = WindowsIdentity.GetCurrent().User.Value;
    static readonly object Gate = new object();
    static readonly Stopwatch Clock = Stopwatch.StartNew();
    static long lastPress = -1000;
    static string executable, launchArguments, workingDirectory;

    static void Log(string text) {
        lock (Gate) {
            Directory.CreateDirectory(StateRoot);
            string path = Path.Combine(StateRoot, "listener.log");
            if (File.Exists(path) && new FileInfo(path).Length > 65536) File.WriteAllText(path, "");
            File.AppendAllText(path, DateTime.Now.ToString("s") + " " + text + Environment.NewLine);
        }
    }

    [STAThread] static int Main(string[] args) {
        try {
            string mode = args.Length == 0 ? "--run" : args[0];
            string eventName = "Local\\XiaoAiKey.Stop." + Sid;
            if (mode == "--stop") {
                try { using (var e = EventWaitHandle.OpenExisting(eventName)) e.Set(); }
                catch (WaitHandleCannotBeOpenedException) { }
                return 0;
            }
            if (mode != "--run" && mode != "--launch") return 2;
            if (new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) {
                Log("ERROR: listener must run without administrator privileges; terminal was not launched.");
                return 3;
            }
            var xml = new XmlDocument();
            xml.XmlResolver = null;
            Directory.CreateDirectory(StateRoot);
            string settings = Path.Combine(Root, "settings.xml");
            xml.Load(settings);
            executable = Environment.ExpandEnvironmentVariables(xml.SelectSingleNode("/XiaoAiKey/ExecutablePath").InnerText);
            launchArguments = Environment.ExpandEnvironmentVariables(xml.SelectSingleNode("/XiaoAiKey/Arguments").InnerText);
            workingDirectory = Environment.ExpandEnvironmentVariables(xml.SelectSingleNode("/XiaoAiKey/WorkingDirectory").InnerText);
            if (!File.Exists(executable) || !Directory.Exists(workingDirectory))
                throw new FileNotFoundException("Check ExecutablePath and WorkingDirectory in settings.xml.");
            Log("CONFIG PID=" + Process.GetCurrentProcess().Id + " file=" + settings + " executable=" + executable + " arguments=" + launchArguments);
            if (mode == "--launch") { LaunchTerminal(); return 0; }
            bool fresh;
            using (var mutex = new Mutex(true, "Local\\XiaoAiKey.Listener." + Sid, out fresh)) {
                if (!fresh) return 0;
                using (var stop = new EventWaitHandle(false, EventResetMode.ManualReset, eventName))
                using (var watcher = new ManagementEventWatcher(new ManagementScope(@"\\.\root\WMI"), new WqlEventQuery("SELECT * FROM HID_EVENT20"))) {
                    watcher.EventArrived += OnEvent;
                    try {
                        watcher.Start();
                        Log("READY: standard-user listener; " + mode);
                        stop.WaitOne();
                    } finally { watcher.Stop(); Log("STOPPED"); }
                }
            }
            return 0;
        } catch (Exception ex) { try { Log("ERROR: " + ex.Message); } catch { } return 1; }
    }

    static void OnEvent(object sender, EventArrivedEventArgs args) {
        try {
            byte[] data;
            using (var ev = args.NewEvent) { data = ev["EventDetail"] as byte[]; }
            if (data == null || data.Length < 3 || data[0] != 1 || data[1] != 0x23 || data[2] != 1) return;
            if (!File.Exists(Path.Combine(StateRoot, "ready.txt"))) { Log("Key ignored: controller not attached yet."); return; }
            lock (Gate) {
                if (Clock.ElapsedMilliseconds - lastPress < 600) return;
                lastPress = Clock.ElapsedMilliseconds;
            }
            LaunchTerminal();
        } catch (Exception ex) { Log("Event error: " + ex.Message); }
    }

    static void LaunchTerminal() {
            Process.Start(new ProcessStartInfo {
                FileName = executable,
                Arguments = launchArguments,
                WorkingDirectory = workingDirectory,
                UseShellExecute = true
            });
            Log("Launch requested (standard-user token): " + executable + " " + launchArguments);
    }
}
