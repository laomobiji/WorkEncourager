' Work widget launcher - starts the WPF floating window silently (relative paths)
' NOTE: the trailing 0 in sh.Run already hides the console window,
'       so we do NOT use -WindowStyle Hidden (a common AV red flag).
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File """ & dir & "\work_widget.ps1""", 0, False
