@echo off
title The House - Dashboard
cd /d "%~dp0"

echo.
echo   ========================================
echo       The House - Dashboard
echo       Tom, Jerry ^& Big Mamma
echo   ========================================
echo.

:: Check Python (use py launcher which is always available)
where py >nul 2>&1
if %errorlevel% neq 0 (
    echo   ERROR: Python not found.
    echo   Install from https://www.python.org/downloads/
    echo.
    pause
    exit /b 1
)

:: Auto-install Flask if missing
py -c "import flask" >nul 2>&1
if %errorlevel% neq 0 (
    echo   Installing Flask...
    py -m pip install flask >nul 2>&1
    if %errorlevel% neq 0 (
        echo   ERROR: Could not install Flask.
        echo   Try running: py -m pip install flask
        echo.
        pause
        exit /b 1
    )
    echo   Flask installed.
    echo.
)

:: Open browser after a short delay
start "" cmd /c "timeout /t 2 /nobreak >nul & start http://localhost:5005"

:: Start the server (blocks until Ctrl+C)
echo   Starting dashboard at http://localhost:5005
echo   Close this window to stop.
echo.
py "%~dp0ui.py"

pause
