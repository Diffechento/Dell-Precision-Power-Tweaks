@echo off
set USER=%USERDOMAIN%\%USERNAME%
set PS_CMD=powershell.exe
set PS_ARGS=-WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\user\Downloads\ThrottleStop_9.7.3\on_power_change.ps1"

:: Remove old tasks
schtasks /delete /tn "SwitchToAC" /f >nul 2>&1
schtasks /delete /tn "SwitchToBattery" /f >nul 2>&1
schtasks /delete /tn "PowerSourceChange" /f >nul 2>&1

:: Create single task on Event ID 105 (Power source change)
set XML=%TEMP%\task_power.xml
(
echo ^<?xml version="1.0" encoding="UTF-16"?^>
echo ^<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"^>
echo ^<Triggers^>^<EventTrigger^>^<Enabled^>true^</Enabled^>
echo ^<Subscription^>^&lt;QueryList^&gt;^&lt;Query Id="0" Path="System"^&gt;^&lt;Select Path="System"^&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=105]]^&lt;/Select^&gt;^&lt;/Query^&gt;^&lt;/QueryList^&gt;^</Subscription^>
echo ^</EventTrigger^>^</Triggers^>
echo ^<Principals^>^<Principal^>^<UserId^>%USER%^</UserId^>^<LogonType^>InteractiveToken^</LogonType^>^<RunLevel^>HighestAvailable^</RunLevel^>^</Principal^>^</Principals^>
echo ^<Settings^>^<MultipleInstancesPolicy^>Queue^</MultipleInstancesPolicy^>^<DisallowStartIfOnBatteries^>false^</DisallowStartIfOnBatteries^>^<StopIfGoingOnBatteries^>false^</StopIfGoingOnBatteries^>^<ExecutionTimeLimit^>PT2M^</ExecutionTimeLimit^>^</Settings^>
echo ^<Actions^>^<Exec^>^<Command^>%PS_CMD%^</Command^>^<Arguments^>%PS_ARGS%^</Arguments^>^</Exec^>^</Actions^>
echo ^</Task^>
) > "%XML%"

schtasks /create /tn "PowerSourceChange" /xml "%XML%" /f
del "%XML%"

echo.
schtasks /query /tn "PowerSourceChange" /fo LIST | findstr "TaskName\|Status"
echo.
echo Done. Plug/unplug charger to test. Check power_monitor.log for results.
pause
