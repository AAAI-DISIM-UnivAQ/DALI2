@echo off
setlocal enabledelayedexpansion

REM DALI2 Launcher for Windows
echo.
echo ========================================
echo   DALI2 Multi-Agent System
echo ========================================
echo.

REM Check if Docker is available
docker --version >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Docker not found. Please install Docker Desktop.
    echo         https://docs.docker.com/desktop/install/windows/
    pause
    exit /b 1
)

echo Modes:
echo   1. Single instance (all agents on one node)
echo   2. Distributed (multi-node federation)
echo.
set /p "MODE=Choose mode [1]: "
if "!MODE!"=="" set "MODE=1"

if "!MODE!"=="2" (
    echo.
    echo Starting distributed mode (2 nodes^)...
    echo   Node 1 (sensors^): http://localhost:8081
    echo   Node 2 (responders^): http://localhost:8082
    echo.
    docker compose -f docker-compose.distributed.yml up --build
    goto :end
)

REM --- Single instance mode ---
echo.
echo Available example agent files:
echo.
for %%f in (examples\*.pl) do (
    echo   - %%f
)
echo.

if not "%~1"=="" (
    set "AGENT_FILE=%~1"
) else (
    set /p "AGENT_FILE=Agent file [examples/agriculture.pl]: "
    if "!AGENT_FILE!"=="" set "AGENT_FILE=examples/agriculture.pl"
)
echo Using: !AGENT_FILE!
echo.

REM --- OpenAI API key (optional) ---
if not "%OPENAI_API_KEY%"=="" (
    echo OpenAI API key: already set in environment
) else (
    echo OpenAI API key is optional. Leave empty to skip AI features.
    set /p "OPENAI_API_KEY=OpenAI API key [none]: "
    if "!OPENAI_API_KEY!"=="" (
        echo AI Oracle: disabled
    ) else (
        echo AI Oracle: enabled
    )
)
echo.

REM --- Build and start ---
echo Building and starting DALI2...
echo Web UI: http://localhost:8080
echo Press Ctrl+C to stop.
echo.

docker compose up --build

:end
endlocal
