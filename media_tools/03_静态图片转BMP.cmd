@echo off
call "%~dp0run.cmd" image %*
set converter_exit=%errorlevel%
if not defined MEDIA_NO_PAUSE pause
exit /b %converter_exit%
