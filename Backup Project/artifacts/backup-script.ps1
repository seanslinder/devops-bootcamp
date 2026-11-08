param(
    [Parameter(Mandatory=$true, HelpMessage="Enter path to Source folder to backup")]
    [string]$SourcePath,
    
    [Parameter(Mandatory=$true, HelpMessage="Enter path for saving a backup")]
    [string]$BackupsFolder
)

# If parameters are not set
if (-not $SourcePath) {
    $SourcePath = "C:\Users\Ботир\Backup-Project\Source"
}
if (-not $BackupsFolder) {
    $BackupsFolder = "C:\Users\Ботир\Backup-Project\backups"
}

# Testing SourcePath and BackupsFolder
if (-not (Test-Path $SourcePath)) {
    Write-Host "Source folder at $SourcePath doesn't exist"
    exit 1
}
if (-not (Test-Path $BackupsFolder)) {
    Write-Host "Backups folder not found. Creating..."
    New-Item -Path $BackupsFolder -ItemType Directory -Force | Out-Null
    Write-Host "Backups folder created at: $BackupsFolder"
}

# Create a log file
$logFile = Join-Path $BackupsFolder "log_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
function Write-Log {
    param(
        [string]$message,
        [string]$level
    )
    $prefix = "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] [$level]"
    $logEntry = "$prefix $message"
    Add-Content -Path $logFile -Value $logEntry -Encoding UTF8
    switch ($level) {
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
        "ERROR"   {
            Write-Host $logEntry -ForegroundColor Red
            Write-Host "$prefix BACKUP WAS UNSUCCESSFUL" -ForegroundColor Red
            Add-Content -Path $logFile -Value "$prefix BACKUP WAS UNSUCCESSFUL" -Encoding UTF8
        }
        "WARNING" { Write-Host $logEntry -ForegroundColor Yellow }
        default   { Write-Host $logEntry -ForegroundColor White }
    }
}

# Starting backup
Write-Log -message "STARTING BACKUP" -level "INFO"
Write-Log -message "Date: $(Get-Date -Format 'dd.MM.yyyy')" -level "INFO"
Write-Log -message "Time: $(Get-Date -Format 'HH:mm:ss')" -level "INFO"
Write-Log -message "Computer: $env:COMPUTERNAME" -level "INFO"
Write-Log -message "User: $env:USERNAME" -level "INFO"

# Counting files to copy
try {
    $fileCount = (Get-ChildItem -Path $SourcePath -Recurse -File).Count
    Write-Log -message "Found files to copy: $fileCount" -level "INFO"
} catch {
    Write-Log -message "Error while counting files in Source folder: $_" -level "WARNING"
    $fileCount = 0
}

# Create a backup folder
$backupPath = Join-Path $BackupsFolder "backup_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss")"
try {
    New-Item -Path $backupPath -ItemType Directory | Out-Null
    Write-Log -message "Created backup folder at: $backupPath" -level "INFO"
}
catch {
    Write-Log -message "Error while creating backup folder at: $backupPath" -level "ERROR"
    exit 1
}

# Copying
try {
    Copy-Item -Path $SourcePath -Destination $backupPath -Recurse -Force
    Write-Log -message "Source contents copied to: $backupPath" -level "INFO"
}
catch {
    Write-Log -message "Error while copying Source contents to: $backupPath" -level "ERROR"
    Remove-Item -Path $backupPath -Recurse -Force -ErrorAction SilentlyContinue
    Read-Host "Press Enter to exit"
    exit 1
}

# Compressing
$zipPath = "$backupPath.zip"
try {
    Compress-Archive -Path $backupPath -DestinationPath $zipPath
    if (Test-Path $zipPath) {
        $size = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
        Write-Log -message "Source files compressed at: $zipPath. Size: $size MB" -level "INFO"
    }
}
catch {
    Write-Log -message "Error while compressing: $backupPath" -level "ERROR"
    Read-Host "Press Enter to exit"
    exit 1
}

# Cleanup temporary folder
try {
    Remove-Item -Path $backupPath -Recurse -Force
    Write-Log -message "Temporary folder cleaned up: $backupPath" -level "INFO"
}
catch {
    Write-Log -message "Error while cleaning up: $backupPath" -level "WARNING"
}

# Successfully finishing backup
Write-Log -message "BACKUP SUCCESSFUL" -level "INFO"