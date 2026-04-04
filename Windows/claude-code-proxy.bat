@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "OPENCLAW_HOME=%USERPROFILE%\.openclaw"
set "OPENCLAW_CONFIG=%OPENCLAW_HOME%\openclaw.json"
set "INSTALL_DIR=%OPENCLAW_HOME%\workspace\scripts"
set "INSTALL_CORE_DIR=%INSTALL_DIR%\Core"
set "INSTALLED_SCRIPT=%INSTALL_DIR%\claude-code-proxy.bat"
set "INSTALLED_PROXY_JS=%INSTALL_CORE_DIR%\claude-code-proxy.js"
set "TASK_NAME=ClaudeCodeProxy"

if defined PROXY_PORT (
    set "DEFAULT_PORT=%PROXY_PORT%"
) else (
    set "DEFAULT_PORT=8787"
)

set "MODE=%~1"
set "PORT=%~2"

if not defined MODE set "MODE=install"
if not defined PORT set "PORT=%DEFAULT_PORT%"

for /f "delims=0123456789" %%A in ("%MODE%") do set "NON_NUMERIC=%%A"
if not defined NON_NUMERIC (
    set "PORT=%MODE%"
    set "MODE=install"
)
set "NON_NUMERIC="

if /I "%MODE%"=="help" goto :usage
if /I "%MODE%"=="--help" goto :usage
if /I "%MODE%"=="-h" goto :usage
if /I "%MODE%"=="install" goto :install
if /I "%MODE%"=="serve" goto :serve

echo Unknown mode: %MODE%
echo.
goto :usage

:usage
echo Usage:
echo   claude-code-proxy.bat
echo   claude-code-proxy.bat install [port]
echo   claude-code-proxy.bat serve [port]
echo.
echo Modes:
echo   install  Install the proxy, patch openclaw.json, register a startup task, and start it.
echo   serve    Run the proxy in the foreground. This is the mode used by the scheduled task.
pause
exit /b 1

:require_command
where "%~1" >nul 2>nul
if errorlevel 1 (
    echo Required command not found: %~1
    exit /b 1
)
exit /b 0

:verify_claude
claude --version >nul 2>nul
if errorlevel 1 (
    echo Claude Code CLI is installed but not usable. Run "claude" to finish setup.
    exit /b 1
)
exit /b 0

:resolve_proxy_js
set "RESOLVED_PROXY_JS="
if exist "%SCRIPT_DIR%\Core\claude-code-proxy.js" set "RESOLVED_PROXY_JS=%SCRIPT_DIR%\Core\claude-code-proxy.js"
if not defined RESOLVED_PROXY_JS if exist "%SCRIPT_DIR%\..\Core\claude-code-proxy.js" set "RESOLVED_PROXY_JS=%SCRIPT_DIR%\..\Core\claude-code-proxy.js"
if defined RESOLVED_PROXY_JS exit /b 0
echo Shared proxy entrypoint not found next to the script or in ..\Core
exit /b 1

:backup_openclaw_config
if not exist "%OPENCLAW_CONFIG%" exit /b 0
for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "BACKUP_TIMESTAMP=%%I"
copy "%OPENCLAW_CONFIG%" "%OPENCLAW_CONFIG%.backup.%BACKUP_TIMESTAMP%" >nul
if errorlevel 1 (
    echo Failed to back up %OPENCLAW_CONFIG%
    exit /b 1
)
echo Backed up %OPENCLAW_CONFIG%
exit /b 0

:install_files
call :resolve_proxy_js || exit /b 1
mkdir "%INSTALL_DIR%" >nul 2>nul
mkdir "%INSTALL_CORE_DIR%" >nul 2>nul
copy "%~f0" "%INSTALLED_SCRIPT%" >nul
if errorlevel 1 (
    echo Failed to install script at %INSTALLED_SCRIPT%
    exit /b 1
)
copy "%RESOLVED_PROXY_JS%" "%INSTALLED_PROXY_JS%" >nul
if errorlevel 1 (
    echo Failed to install proxy JS at %INSTALLED_PROXY_JS%
    exit /b 1
)
echo Installed script at %INSTALLED_SCRIPT%
echo Installed proxy JS at %INSTALLED_PROXY_JS%
exit /b 0

:patch_openclaw_config
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$path = [Environment]::ExpandEnvironmentVariables('%OPENCLAW_CONFIG%');" ^
  "$port = '%PORT%';" ^
  "$json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json;" ^
  "if (-not $json.models) { $json | Add-Member -NotePropertyName models -NotePropertyValue ([pscustomobject]@{}) };" ^
  "if (-not $json.models.providers) { $json.models | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{}) };" ^
  "$proxyProvider = [pscustomobject]@{ baseUrl = ('http://localhost:' + $port); apiKey = 'proxy-no-key-needed'; api = 'anthropic-messages'; headers = [pscustomobject]@{}; models = @([pscustomobject]@{ id = 'claude-opus-4-5'; name = 'Claude Opus 4.5 (Proxy)'; api = 'anthropic-messages'; reasoning = $false; input = @('text'); cost = [pscustomobject]@{ input = 0; output = 0; cacheRead = 0; cacheWrite = 0 }; contextWindow = 200000; maxTokens = 8192 }, [pscustomobject]@{ id = 'claude-sonnet-4-5'; name = 'Claude Sonnet 4.5 (Proxy)'; api = 'anthropic-messages'; reasoning = $false; input = @('text'); cost = [pscustomobject]@{ input = 0; output = 0; cacheRead = 0; cacheWrite = 0 }; contextWindow = 200000; maxTokens = 8192 }) };" ^
  "$json.models.providers | Add-Member -NotePropertyName 'claude-code-proxy' -NotePropertyValue $proxyProvider -Force;" ^
  "if (-not $json.agents) { $json | Add-Member -NotePropertyName agents -NotePropertyValue ([pscustomobject]@{}) };" ^
  "if (-not $json.agents.defaults) { $json.agents | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{}) };" ^
  "if (-not $json.agents.defaults.models) { $json.agents.defaults | Add-Member -NotePropertyName models -NotePropertyValue ([pscustomobject]@{}) };" ^
  "$json.agents.defaults.models | Add-Member -NotePropertyName 'claude-code-proxy/claude-opus-4-5' -NotePropertyValue ([pscustomobject]@{ alias = 'opus' }) -Force;" ^
  "$json.agents.defaults.models | Add-Member -NotePropertyName 'claude-code-proxy/claude-sonnet-4-5' -NotePropertyValue ([pscustomobject]@{ alias = 'sonnet' }) -Force;" ^
  "$json | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding UTF8"
if errorlevel 1 (
    echo Failed to patch %OPENCLAW_CONFIG%
    exit /b 1
)
echo Patched %OPENCLAW_CONFIG%
exit /b 0

:install_startup_task
schtasks /Create /F /TN "%TASK_NAME%" /SC ONLOGON /TR "\"%INSTALLED_SCRIPT%\" serve %PORT%" >nul
if errorlevel 1 (
    echo Failed to register scheduled task %TASK_NAME%
    exit /b 1
)
echo Installed scheduled task %TASK_NAME%
exit /b 0

:start_task
schtasks /Run /TN "%TASK_NAME%" >nul
if errorlevel 1 (
    echo Could not start scheduled task automatically.
    echo Run manually: schtasks /Run /TN "%TASK_NAME%"
    exit /b 1
)
echo Started scheduled task %TASK_NAME%
exit /b 0

:restart_gateway
where openclaw >nul 2>nul
if errorlevel 1 (
    echo openclaw command not found. Please restart the gateway manually.
    exit /b 0
)
echo Restarting OpenClaw gateway...
openclaw gateway restart
if errorlevel 1 (
    echo Could not restart automatically. Run: openclaw gateway restart
)
exit /b 0

:print_summary
echo.
echo =============================================
echo Deployment complete
echo.
echo Installed provider: claude-code-proxy -^> http://localhost:%PORT%
echo Proxy script: %INSTALLED_SCRIPT%
echo Startup task: %TASK_NAME%
echo.
echo Suggested default model update:
echo   agents.defaults.model.primary = claude-code-proxy/claude-opus-4-5
echo   or
echo   agents.defaults.model.primary = claude-code-proxy/claude-sonnet-4-5
echo.
echo Useful commands:
echo   schtasks /Query /TN "%TASK_NAME%"
echo   schtasks /Run /TN "%TASK_NAME%"
echo   schtasks /Delete /TN "%TASK_NAME%" /F
echo   openclaw gateway restart
exit /b 0

:serve
call :resolve_proxy_js || exit /b 1
call :require_command claude || exit /b 1
call :require_command node || exit /b 1
call :verify_claude || exit /b 1
set "PORT=%PORT%"
echo Starting Claude Code Proxy on port %PORT%
echo Requests will be forwarded through the real Claude Code CLI
echo Press Ctrl+C to stop
echo.
node "%RESOLVED_PROXY_JS%"
exit /b %errorlevel%

:install
echo Claude Code Proxy Setup for OpenClaw
echo ====================================
echo.
echo This installs the proxy startup task on port %PORT%, patches openclaw.json, and starts the task.
echo.
if not exist "%OPENCLAW_CONFIG%" (
    echo OpenClaw config not found at %OPENCLAW_CONFIG%
    echo Run "openclaw wizard" first on the target machine.
    exit /b 1
)
call :require_command claude || exit /b 1
call :require_command node || exit /b 1
call :require_command powershell || exit /b 1
call :require_command schtasks || exit /b 1
call :verify_claude || exit /b 1
call :backup_openclaw_config || exit /b 1
call :install_files || exit /b 1
call :patch_openclaw_config || exit /b 1
call :install_startup_task || exit /b 1
call :start_task
call :restart_gateway
call :print_summary
pause
exit /b 0