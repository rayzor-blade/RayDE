# Puts a RayDE shortcut, with its icon, on the Start menu and optionally the desktop.
#   powershell -File install-shortcut.ps1 [-Folder <where RayDE.exe is>] [-Desktop]
param(
  [string]$Folder = $PSScriptRoot,
  [switch]$Desktop
)
$icon = Join-Path $Folder "rayde.ico"
$launcher = Join-Path $Folder "RayDE.exe"
if (-not (Test-Path $icon)) { throw "rayde.ico is not in $Folder" }
if (-not (Test-Path $launcher)) { throw "RayDE.exe is not in $Folder" }
$shell = New-Object -ComObject WScript.Shell
function New-Shortcut($path) {
  $link = $shell.CreateShortcut($path)
  $link.TargetPath = $launcher
  $link.WorkingDirectory = $Folder
  $link.IconLocation = $icon
  $link.WindowStyle = 7
  $link.Description = "RayDE, the Haxe Integrated Development Environment"
  $link.Save()
}
New-Shortcut (Join-Path ([Environment]::GetFolderPath("Programs")) "RayDE.lnk")
if ($Desktop) { New-Shortcut (Join-Path ([Environment]::GetFolderPath("Desktop")) "RayDE.lnk") }
