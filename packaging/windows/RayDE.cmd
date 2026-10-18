@echo off
rem Starts RayDE on ash: a project given on the command line, else one chosen in a dialog.
rem RAYDE_ASH names ash.exe; without it, ash on PATH is used.
setlocal
set "HERE=%~dp0"
if "%RAYDE_ASH%"=="" set "RAYDE_ASH=ash"
if exist "%HERE%rayscript-host.exe" set "RAYSCRIPT_HOST=%HERE%rayscript-host.exe"
if "%~1"=="" (
  for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.OpenFileDialog; $d.Title = 'Open a project'; $d.Filter = 'RayDE projects (*.hxml;*.rayext)|*.hxml;*.rayext'; if ($d.ShowDialog() -eq 'OK') { $d.FileName }"`) do set "PROJECT=%%P"
  if "%PROJECT%"=="" exit /b 0
  "%RAYDE_ASH%" --preset application "%HERE%rayde.hl" "%PROJECT%"
) else (
  "%RAYDE_ASH%" --preset application "%HERE%rayde.hl" %*
)
