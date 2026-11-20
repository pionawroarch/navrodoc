@echo off
chcp 65001 >nul
echo === navro. dokumentacja – budowanie programu .exe ===
where npm >nul 2>nul || (echo Brak Node.js. Zainstaluj LTS z https://nodejs.org i uruchom ponownie. & pause & exit /b 1)
call npm install || (pause & exit /b 1)
call npm run dist || (pause & exit /b 1)
echo.
echo Gotowe. Instalator i wersja przenosna sa w folderze "dist".
explorer dist
pause
