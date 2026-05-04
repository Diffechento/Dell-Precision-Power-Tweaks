@echo off
set XML=%TEMP%\ts_logon_task.xml
(
echo ^<?xml version="1.0" encoding="UTF-16"?^>
echo ^<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"^>
echo ^<RegistrationInfo^>^<Author^>DESKTOP-QRNJRHF\user^</Author^>^</RegistrationInfo^>
echo ^<Principals^>^<Principal id="Author"^>
echo ^<UserId^>S-1-5-21-1559987391-582093766-1207331604-1001^</UserId^>
echo ^<LogonType^>InteractiveToken^</LogonType^>
echo ^<RunLevel^>HighestAvailable^</RunLevel^>
echo ^</Principal^>^</Principals^>
echo ^<Settings^>
echo ^<DisallowStartIfOnBatteries^>false^</DisallowStartIfOnBatteries^>
echo ^<StopIfGoingOnBatteries^>false^</StopIfGoingOnBatteries^>
echo ^<MultipleInstancesPolicy^>IgnoreNew^</MultipleInstancesPolicy^>
echo ^<IdleSettings^>^<Duration^>PT10M^</Duration^>^<WaitTimeout^>PT1H^</WaitTimeout^>^<StopOnIdleEnd^>true^</StopOnIdleEnd^>^<RestartOnIdle^>false^</RestartOnIdle^>^</IdleSettings^>
echo ^</Settings^>
echo ^<Triggers^>^<LogonTrigger^>^<StartBoundary^>2026-05-04T18:10:00^</StartBoundary^>^</LogonTrigger^>^</Triggers^>
echo ^<Actions Context="Author"^>^<Exec^>
echo ^<Command^>powershell.exe^</Command^>
echo ^<Arguments^>-WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\user\Downloads\ThrottleStop_9.7.3\start_ts_minimized.ps1"^</Arguments^>
echo ^</Exec^>^</Actions^>
echo ^</Task^>
) > "%XML%"

schtasks /delete /tn "ThrottleStop" /f >nul 2>&1
schtasks /create /tn "ThrottleStop" /xml "%XML%" /f
del "%XML%"

echo.
schtasks /query /tn "ThrottleStop" /fo LIST | findstr "TaskName\|Status\|Task To Run"
echo.
echo Done.
pause
