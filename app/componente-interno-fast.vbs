Option Explicit

Dim shell, fileSystem, installDirectory, helperScript, dataDirectory, pendingUpdate, updateDirectory, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

installDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
helperScript = fileSystem.BuildPath(installDirectory, "fast-race-assistant.ps1")
dataDirectory = fileSystem.BuildPath(installDirectory, "data")
pendingUpdate = fileSystem.BuildPath(dataDirectory, "pending-update.zip")
updateDirectory = fileSystem.BuildPath(dataDirectory, "update")
shell.CurrentDirectory = installDirectory

If fileSystem.FileExists(pendingUpdate) Then
    command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " & Chr(34) _
        & "$pending = '" & Replace(pendingUpdate, "'", "''") & "'; " _
        & "$update = '" & Replace(updateDirectory, "'", "''") & "'; " _
        & "$install = '" & Replace(installDirectory, "'", "''") & "'; " _
        & "if (Test-Path -LiteralPath $update) { Remove-Item -LiteralPath $update -Recurse -Force }; " _
        & "Expand-Archive -LiteralPath $pending -DestinationPath $update -Force; " _
        & "Get-ChildItem -LiteralPath $update -File | Copy-Item -Destination $install -Force; " _
        & "Remove-Item -LiteralPath $pending -Force; Remove-Item -LiteralPath $update -Recurse -Force" & Chr(34)
    shell.Run command, 0, True
End If

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " _
    & Chr(34) & helperScript & Chr(34)

shell.Run command, 0, False

Set fileSystem = Nothing
Set shell = Nothing
