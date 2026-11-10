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
rem   build.bat --no-test              -> skip the self-tests
rem   build.bat --record --verify      -> record and check without
rem                                       prompting
rem   build.bat --strict              -> fail when the record predates
rem                                       the pin
rem   build.bat --max-age 7           -> fail when the record is older
rem                                       than 7 days
rem The documents are checked on every build, --no-test included.
rem The summary below the deploy steps prints the record's stamp, its
rem SHA-256 and how long ago it was written.
rem ---------------------------------------------------------------------------
cd /d "%~dp0"

set "QUARTUS_BIN="
set "SKIP_TEST="
set "RECORD_FLAG="
set "VERIFY_FLAG="
set "STRICT_FLAG="
set "MAX_AGE="
:args
if "%~1"=="" goto :argsdone
if /i "%~1"=="--no-test" (set "SKIP_TEST=1" & shift & goto :args)
if /i "%~1"=="--record" (set "RECORD_FLAG=1" & shift & goto :args)
if /i "%~1"=="--verify" (set "VERIFY_FLAG=1" & shift & goto :args)
if /i "%~1"=="--strict" (set "STRICT_FLAG=1" & shift & goto :args)
if /i "%~1"=="--max-age" goto :maxage
set "QUARTUS_BIN=%~1"
shift
goto :args
:maxage
if "%~2"=="" (
  echo ERROR: --max-age needs a number of days, e.g. --max-age 7
  exit /b 1
)
rem A value that is all digits leaves no token for /f to split off.
for /f "delims=0123456789" %%A in ("%~2") do (
  echo ERROR: --max-age wants a whole number of days, got "%~2"
  exit /b 1
)
set "MAX_AGE=%~2"
shift
shift
goto :args
:argsdone
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
if defined SKIP_TEST echo Skipping the self-tests on request.
if defined SKIP_TEST goto :testdone
echo Checking the build-stamp tool...
python "tools\test_bump_build_id.py"
if errorlevel 9009 goto :notest
if errorlevel 1 goto :testfailed
goto :testdone
:notest
echo python was not found - skipping the self-tests.
goto :testdone
:testfailed
echo.
echo ERROR: the build-stamp self-test failed; fix it before building.
exit /b 1
:docfailed
echo.
echo ERROR: the documents failed tools\check_docs.py;
echo fix them before building.
exit /b 1
:testdone
rem The documents are checked on every build, --no-test included: a
rem wrapped heading or a wide line is cheap to fix now and costly to
rem find after the flow has run.
echo Checking the documents...
python "tools\check_docs.py"
if errorlevel 9009 goto :nodocs
if errorlevel 1 goto :docfailed
goto :compile
:nodocs
echo python was not found - the documents were not checked.
:compile
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
if defined RECORD_FLAG goto :dorecord
choice /c YN /n /m "Record output_files\NDS.rbf.stamp for this build? [Y/N] "
if errorlevel 2 goto :checkstamp
:dorecord
python "tools\bump_build_id.py" --record
if errorlevel 9009 echo python was not found - record it later with tools\bump_build_id.py --record
:checkstamp
if exist "output_files\NDS.rbf.stamp" goto :verifystamp
if defined VERIFY_FLAG goto :norecord
echo No record for this bitstream - nothing to check.
goto :deploy
:norecord
echo ERROR: --verify asked for a record and there is none for this
echo bitstream - build with --record, or answer Y at the prompt.
exit /b 1
:verifystamp
set "VERIFY_ARGS=--verify"
if defined STRICT_FLAG set "VERIFY_ARGS=%VERIFY_ARGS% --strict"
if defined MAX_AGE set "VERIFY_ARGS=%VERIFY_ARGS% --max-age %MAX_AGE%"
python "tools\bump_build_id.py" %VERIFY_ARGS%
if errorlevel 9009 goto :deploy
if errorlevel 1 goto :stalestamp
goto :deploy
:stalestamp
echo.
echo ERROR: the recorded stamp does not match this bitstream or the pin.
echo Rebuild, or record the current bitstream with --record.
exit /b 1
:deploy
echo.
echo Deploy to the DE10-Nano SD card ^(adjust the drive letter^):
echo   copy output_files\NDS.rbf  E:\games\NDS\NDS.rbf
echo.
echo Optional BIOS files go to E:\BIOS\ (bios7.bin + bios9.bin).
echo.
if not exist "output_files\NDS.rbf.stamp" goto :finished
echo Record for output_files\NDS.rbf:
findstr /b /c:"build stamp:" /c:"sha256:" "output_files\NDS.rbf.stamp"
python "tools\bump_build_id.py" --age
if errorlevel 9009 findstr /b /c:"recorded:" "output_files\NDS.rbf.stamp"
:finished
exit /b 0

