@echo off
call "%~dp0run.cmd" gif %*
set converter_exit=%errorlevel%
if not defined MEDIA_NO_PAUSE pause
exit /b %converter_exit%
