@echo off
REM Double-clickable wrapper around setup.ps1.
REM -ExecutionPolicy Bypass keeps this working on machines where script
REM execution is otherwise restricted, without changing the system policy.
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
