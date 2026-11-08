# Backup Project

PowerShell script for automated folder backup with compression, logging, and error handling.

---

## Usage

### Command-Line Parameters (Recommended)

```powershell
.\backup_script.ps1 -SourcePath "C:\MyFolder" -BackupsFolder "D:\Backups"
```

| Parameter | Description |
|-----------|-------------|
| `-SourcePath` | Folder to back up |
| `-BackupsFolder` | Where to save the backup |

### Using Defaults

Run without parameters to use hardcoded paths from the script:
```powershell
.\backup_script.ps1
```

### How It Works
- **Parameters provided** → use them
- **No parameters** → use default paths

### Backup Output
```
{BackupsFolder}\backup_YYYY-MM-DD_HH-MM-SS.zip
{BackupsFolder}\log_YYYY-MM-DD_HH-MM-SS.log
```

### Exit Codes
- `0` = Success
- `1` = Error

### Examples
```powershell
# With parameters
.\backup_script.ps1 -SourcePath "C:\Projects" -BackupsFolder "E:\Archive"

# With defaults (edit paths in script first)
.\backup_script.ps1
```

---

## Artifacts

### Backup script

Here's the original script written in powershell
[Backup script](artifacts/backup-script.ps1)

### Backup logs

Log files showing backup history with timestamps and status messages.
![Backup logs](artifacts/logs-screenshot.png)

### Scheduled task

Optionally, you can use Windows Task Scheduler to automate backup process. Here's an example of Windows Task Scheduler configured for automatic daily backups.
![Scheduled task](artifacts/schedule.png)
