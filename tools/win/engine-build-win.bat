@echo off
REM Configure + build the rn-impeller engine with MSVC.
REM
REM Lives in C:\Devel\rni-win-scripts, NOT inside the staged tree: the staging
REM rsync runs with --delete, so a driver script placed inside it is deleted by
REM the very sync that put it there.
setlocal
set STAGE=C:\Devel\rni-win
set BUILD=C:\Devel\rni-win-build

call "C:\Devel\VSBuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 ( echo FAIL_VCVARS & exit /b 1 )

set CMAKE=C:\Devel\VSBuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe
set NINJA=C:\Devel\VSBuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe

REM ⛔ A python3.exe SHIM MUST PHYSICALLY EXIST.
REM The first python3 on PATH is the Microsoft Store stub, which prints "Python
REM was not found" and returns 9009. The real interpreter ships python.exe but
REM NOT python3.exe, so prepending its directory does not help either.
set PYDIR=C:\Users\dev\AppData\Local\Programs\Python\Python312
set SHIM=C:\Devel\rni-win-scripts\shim
if not exist "%SHIM%" mkdir "%SHIM%"
if not exist "%SHIM%\python3.exe" copy /y "%PYDIR%\python.exe" "%SHIM%\python3.exe" >nul
set PATH=%SHIM%;%PYDIR%;%PATH%

if "%1"=="clean" rmdir /s /q "%BUILD%" 2>nul

echo === configure ===
"%CMAKE%" -S "%STAGE%\engine" -B "%BUILD%" -G Ninja ^
  -DCMAKE_MAKE_PROGRAM="%NINJA%" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DHERMES_SRC=C:/Devel/hermes-win ^
  -DHERMES_BUILD=C:/Devel/hermes-win-build ^
  -DCMAKE_INSTALL_PREFIX="%BUILD%\stage"
if errorlevel 1 ( echo CONFIGURE_FAIL & exit /b 1 )
echo CONFIGURE_OK

echo === build ===
REM -k 0 keeps going after the first failure so ONE run enumerates the whole
REM error set instead of one error per cross-OS round trip.
"%CMAKE%" --build "%BUILD%" --target rn-impeller -- -k 0
echo BUILD_EXIT=%errorlevel%
endlocal
