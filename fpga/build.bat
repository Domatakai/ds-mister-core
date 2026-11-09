@echo off
setlocal
rem ---------------------------------------------------------------------------
rem NDS MiSTer Test - Windows build (Quartus Prime Lite 17.0)
rem
rem Runs the full compile flow (analysis, fitting, ASM, timing) and produces
rem output_files\NDS.rbf. Quartus is expected at the default Lite install
rem location; pass a different bin64 directory as the first argument if needed:
rem
rem   build.bat                               -> C:\intelFPGA_lite\17.0\quartus\bin64
rem   build.bat "D:\other\quartus\bin64"      -> custom location
rem ---------------------------------------------------------------------------
cd /d "%~dp0"

set "QUARTUS_BIN=%~1"
if "%QUARTUS_BIN%"=="" set "QUARTUS_BIN=C:\intelFPGA_lite\17.0\quartus\bin64"

if not exist "%QUARTUS_BIN%\quartus_sh.exe" (
  echo ERROR: quartus_sh.exe not found at "%QUARTUS_BIN%".
  echo Pass your Quartus bin64 directory as the first argument, e.g.:
  echo   build.bat "C:\intelFPGA_lite\17.0\quartus\bin64"
  exit /b 1
)

echo Using: "%QUARTUS_BIN%\quartus_sh.exe"
rem Print the pinned build stamp so a release build shows its date. The
rem flow takes it from sys\build_id.txt; without one it uses today's date.
set "BUILD_STAMP="
if exist "sys\build_id.txt" for /f "tokens=1" %%S in ('findstr /r "^[0-9][0-9][0-9][0-9][0-9][0-9]$" sys\build_id.txt') do set "BUILD_STAMP=%%S"
if defined BUILD_STAMP (
  echo Build stamp: %BUILD_STAMP%  from sys\build_id.txt
) else (
  echo Build stamp: none pinned - the flow uses today's date.
)
echo.
echo Compiling NDS - first full compile takes roughly 10-20 minutes...
echo.

"%QUARTUS_BIN%\quartus_sh.exe" --flow compile NDS
if errorlevel 1 (
  echo.
  echo COMPILE FAILED. Check the messages above; the most common causes are
  echo a missing file listed in files.qip or a Quartus version other than 17.0.x.
  exit /b 1
)

if not exist "output_files\NDS.rbf" (
  echo Compile finished but output_files\NDS.rbf was not generated.
  echo Check the fitter messages for what failed.
  exit /b 1
)

echo.
echo SUCCESS: output_files\NDS.rbf is ready.
if defined BUILD_STAMP (
  echo Build stamp: %BUILD_STAMP%  from sys\build_id.txt
) else (
  echo Build stamp: none pinned - the build used today's date.
)
echo.
choice /c YN /n /m "Record output_files\NDS.rbf.stamp for this build? [Y/N] "
if errorlevel 2 goto :deploy
python "tools\bump_build_id.py" --record
if errorlevel 9009 echo python was not found - record it later with tools\bump_build_id.py --record
:deploy
echo.
echo Deploy to the DE10-Nano SD card ^(adjust the drive letter^):
echo   copy output_files\NDS.rbf  E:\games\NDS\NDS.rbf
echo.
echo Optional BIOS files go to E:\BIOS\ (bios7.bin + bios9.bin).
exit /b 0
