@echo off
setlocal
chcp 65001 >nul
set PYTHONUTF8=1
set PYTHONDONTWRITEBYTECODE=1
if exist "%~dp0runtime\python\python.exe" goto portable
where python >nul 2>&1
if not errorlevel 1 goto system_python
where py >nul 2>&1
if not errorlevel 1 goto launcher
echo Python runtime was not found. Extract the complete package first.
exit /b 1
:portable
"%~dp0runtime\python\python.exe" -B -X utf8 "%~dp0media.py" %*
exit /b %errorlevel%
:system_python
python -B -X utf8 "%~dp0media.py" %*
exit /b %errorlevel%
:launcher
py -3 -B -X utf8 "%~dp0media.py" %*
exit /b %errorlevel%
