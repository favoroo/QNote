param(
    [string]$ApkPath,
    [string]$Timestamp
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir "email_config.json"

$config = Get-Content $configPath | ConvertFrom-Json

if ($config.password -eq "请填入QQ邮箱授权码") {
    Write-Host "[WARNING] Please fill in the QQ email authorization code in email_config.json"
    exit 1
}

Write-Host "Sender: $($config.sender)"
Write-Host "Recipient: $($config.recipient)"
Write-Host "SMTP: $($config.smtp_server):$($config.smtp_port)"
Write-Host "APK: $ApkPath"
Write-Host "APK Size: $([math]::Round((Get-Item $ApkPath).Length / 1MB, 2)) MB"

try {
    $att = New-Object System.Net.Mail.Attachment($ApkPath)
    $msg = New-Object System.Net.Mail.MailMessage
    $msg.From = $config.sender
    $msg.To.Add($config.recipient)
    $msg.Subject = "QNote APK - $Timestamp"
    $msg.Body = "APK build completed.`n`nFile: $ApkPath`nSize: $([math]::Round((Get-Item $ApkPath).Length / 1MB, 2)) MB"
    $msg.Attachments.Add($att)
    
    $smtp = New-Object System.Net.Mail.SmtpClient($config.smtp_server, $config.smtp_port)
    $smtp.EnableSsl = $true
    $smtp.Timeout = 120000
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
