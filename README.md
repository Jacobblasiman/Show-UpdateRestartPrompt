# Show-UpdateRestartPrompt

Shows a restart prompt when Windows Update is waiting on a restart to finish installing updates. If no update restart is pending, the script exits without showing anything.

It tries the built-in engaged-restart dialog first (`MusNotificationUx.exe`). Current Windows 11 builds usually do not raise that dialog on demand. When it does not appear, the script shows a Windows 11-style card with **Restart now**, **Schedule restart**, and **Close**.

The card appears at the bottom-right of the screen. **Schedule restart** opens the native picker and leaves a closeable guide in that corner. The guide explains the picker: turn on **Schedule a time**, choose **Pick a day** and **Pick a time**, then confirm. The PC has to be powered on, awake, and online at that time. The restart cannot be scheduled during downtime. Close dismisses the guide.

Pending file renames and RunOnce entries are ignored. Those are set by routine Edge and OneDrive cleanup and are not an update restart.

## Usage

Run in the signed-in user's session with 64-bit Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Show-UpdateRestartPrompt.ps1
```

Preview the card without a pending restart. Restart now does not reboot in this mode:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Show-UpdateRestartPrompt.ps1 -Preview
```

For Intune, run the script with the logged-on user's credentials and in 64-bit PowerShell. **Close** only dismisses the current run. The prompt shows again on the next run while Windows Update still requires a restart.

A restart happens only when the user clicks **Restart now**.
