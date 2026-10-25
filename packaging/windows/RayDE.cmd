@echo off
rem Starts RayDE on Welcome, or a workspace supplied on the command line.
setlocal
set "HERE=%~dp0"
if "%RAYDE_EXTENSIONS%"=="" set "RAYDE_EXTENSIONS=%HERE%extensions"
"%HERE%RayDE.exe" %*
