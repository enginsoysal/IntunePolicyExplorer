// A windowed PowerShell host makes the synthetic WPF preview available to desktop UI tools.
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;

class OfflinePreviewHost
{
    [STAThread]
    static void Main(string[] args)
    {
        if (args.Length != 1) throw new ArgumentException("Expected absolute path to Start-OfflinePreview.ps1");
        using (var runspace = RunspaceFactory.CreateRunspace())
        {
            runspace.ApartmentState = ApartmentState.STA;
            runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
            runspace.Open();
            using (var ps = PowerShell.Create())
            {
                ps.Runspace = runspace;
                ps.AddCommand(args[0]).AddParameter("Width", 850).AddParameter("Height", 600);
                ps.Invoke();
                if (ps.HadErrors)
                    File.WriteAllText(Path.Combine(Path.GetDirectoryName(args[0]), "results", "host-error.txt"), String.Join(Environment.NewLine, ps.Streams.Error));
            }
        }
    }
}
