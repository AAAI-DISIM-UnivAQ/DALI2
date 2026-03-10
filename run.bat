@echo off
setlocal

REM DALI2 Launcher for Windows
REM Usage: run.bat [agent_file]
REM Example: run.bat examples\agriculture.pl

set AGENT_FILE=%1
if "%AGENT_FILE%"=="" set AGENT_FILE=examples\agriculture.pl

echo === DALI2 Multi-Agent System ===
echo Agent file: %AGENT_FILE%
echo.

REM Check if Docker is available
docker --version >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Docker not found. Trying local SWI-Prolog...
    swipl -l src\server.pl -g main -t halt -- 8080 %AGENT_FILE%
    exit /b
)

echo Building and starting with Docker...
docker compose up --build

endlocal
