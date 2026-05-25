param(
    [string]$OutputDir,
    [string]$Timestamp
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir "email_config.json"

$config = Get-Content $configPath | ConvertFrom-Json

Write-Host "Sender: $($config.sender)"
Write-Host "Recipient: $($config.recipient)"

$apkFile = Get-ChildItem -Path $OutputDir -Filter "qnote-arm64-v8a*$Timestamp.apk" | Select-Object -First 1

if (-not $apkFile) {
    Write-Host "[ERROR] arm64-v8a APK not found"
    exit 1
}

$sizeMB = [math]::Round($apkFile.Length / 1MB, 2)
Write-Host "APK: $($apkFile.Name) ($sizeMB MB)"

try {
    $att = New-Object System.Net.Mail.Attachment($apkFile.FullName)
    $msg = New-Object System.Net.Mail.MailMessage
    $msg.From = $config.sender
    $msg.To.Add($config.recipient)
    $msg.Subject = "QNote APK (arm64) - $Timestamp"
    $msg.Body = "APK build completed.`n`nFile: $($apkFile.Name)`nSize: $sizeMB MB`n`nThis is arm64-v8a version for modern phones."
    
    $msg.Attachments.Add($att)
    
    $smtp = New-Object System.Net.Mail.SmtpClient($config.smtp_server, $config.smtp_port)
    $smtp.EnableSsl = $true
    $smtp.Timeout = 180000
    $smtp.Credentials = New-Object System.Net.NetworkCredential($config.sender, $config.password)
    
    Write-Host "Sending..."
    $smtp.Send($msg)
    Write-Host "Email sent successfully!"
    
    $att.Dispose()
    $smtp.Dispose()
}
catch {
    Write-Host "[ERROR] Failed to send email"
    Write-Host "Error: $($_.Exception.Message)"
    if ($_.Exception.InnerException) {
        Write-Host "Inner: $($_.Exception.InnerException.Message)"
    }
    exit 1
}
