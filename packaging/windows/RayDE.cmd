@echo off
rem Starts RayDE on Welcome, or a workspace supplied on the command line.
rem RAYDE_ASH names ash.exe; without it, ash on PATH is used.
setlocal
set "HERE=%~dp0"
set "RAYDE_EXTENSIONS=%HERE%extensions"
if "%RAYDE_ASH%"=="" set "RAYDE_ASH=ash"
if exist "%HERE%rayscript-host.exe" set "RAYSCRIPT_HOST=%HERE%rayscript-host.exe"
"%RAYDE_ASH%" --preset application "%HERE%rayde.hl" %*
