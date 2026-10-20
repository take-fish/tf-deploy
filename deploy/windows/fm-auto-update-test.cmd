@echo off
REM FishMatrix test auto-update (Windows Task Scheduler, every 2 min)
"D:\develop\Git\bin\bash.exe" -lc "bash /d/code/cloud-take-fish/tf-deploy/scripts/auto-update-test.sh" >> "D:\develop\fm-auto-update-test.log" 2>&1
