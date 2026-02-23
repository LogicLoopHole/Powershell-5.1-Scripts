# Join-Domain.ps1
# Runs at FirstLogon via AutoLogon - Joins computer to domain with user-prompted credentials
#Requires -RunAsAdministrator

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

# ============================================================================
# CONFIGURATION - Modify these values for your environment
# ============================================================================
$DomainName = "Example.Domain"                                    # Your domain FQDN
$DomainController = "DC01.Example.Domain"                   # Optional: specific DC (FQDN required since Aug 2024)
$OUPath = "CN=Computers,DC=Example,DC=Domain" # Target OU for computer object
$LogPath = "C:\OSDCloud\Logs"

# ============================================================================
$ScriptName = "Join-Domain"
$LogFile = "$LogPath\$ScriptName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# Ensure log directory exists
New-Item -Path $LogPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $LogMessage
    switch ($Level) {
        "ERROR"   { Write-Host $Message -ForegroundColor Red }
        "WARNING" { Write-Host $Message -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $Message -ForegroundColor Green }
        default   { Write-Host $Message -ForegroundColor Cyan }
    }
}

function Remove-AutoLogon {
    Write-Log "Removing AutoLogon configuration..."
    try {
        $WinLogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        Remove-ItemProperty -Path $WinLogonPath -Name "AutoAdminLogon" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $WinLogonPath -Name "DefaultUserName" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $WinLogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $WinLogonPath -Name "DefaultDomainName" -ErrorAction SilentlyContinue
        Write-Log "AutoLogon configuration removed"
    }
    catch {
        Write-Log "Failed to remove AutoLogon: $_" "WARNING"
    }
}

function Remove-TempLocalAdmin {
    param([string]$Username = "osdadmin")
    Write-Log "Removing temporary local admin account '$Username'..."
    try {
        $User = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
        if ($User) {
            Remove-LocalUser -Name $Username -ErrorAction Stop
            Write-Log "Temporary admin account '$Username' removed" "SUCCESS"
        }
        else {
            Write-Log "Temporary admin account '$Username' not found (may already be removed)"
        }
    }
    catch {
        Write-Log "Failed to remove temporary admin: $_" "WARNING"
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Domain Join Process" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "Domain join process started"
Write-Log "Domain: $DomainName"
Write-Log "Target OU: $OUPath"

try {
    # Check if already domain joined
    $CurrentDomain = (Get-CimInstance Win32_ComputerSystem).Domain
    if ($CurrentDomain -eq $DomainName) {
        Write-Log "Computer is already joined to $DomainName" "SUCCESS"
        # Clean up and exit
        Remove-AutoLogon
        Remove-TempLocalAdmin
        [System.Windows.Forms.MessageBox]::Show(
            "Computer is already joined to $DomainName`n`nClick OK to restart.",
            "Already Domain Joined",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        Restart-Computer -Force
        exit 0
    }

    # Read saved hostname (for logging/verification)
    $HostnameFile = "C:\OSDCloud\Hostname.txt"
    if (Test-Path $HostnameFile) {
        $SavedHostname = (Get-Content $HostnameFile).Trim()
        $CurrentHostname = $env:COMPUTERNAME
        Write-Log "Saved hostname: $SavedHostname"
        Write-Log "Current hostname: $CurrentHostname"
        if ($SavedHostname -ne $CurrentHostname) {
            Write-Log "Hostname mismatch - unattend.xml may not have applied correctly" "WARNING"
        }
    }

    # Prompt for domain credentials
    Write-Log "Prompting user for domain credentials..."
    $CredentialPrompt = "Enter credentials to join '$DomainName`n`nUse format: DOMAIN\username or username@domain.com"
    $Credential = $null
    $MaxAttempts = 3
    $Attempt = 0
    while ($null -eq $Credential -and $Attempt -lt $MaxAttempts) {
        $Attempt++
        Write-Log "Credential prompt attempt $Attempt of $MaxAttempts"
        try {
            $Credential = Get-Credential -Message $CredentialPrompt -ErrorAction Stop
            if ($null -eq $Credential) {
                Write-Log "User cancelled credential prompt" "WARNING"
                $Retry = [System.Windows.Forms.MessageBox]::Show(
                    "Domain join credentials are required`n`nDo you want to try again?",
                    "Credentials Required",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                if ($Retry -eq [System.Windows.Forms.DialogResult]::No) {
                    Write-Log "User chose not to retry - exiting without domain join" "WARNING"
                    exit 1
                }
                $Credential = $null
            }
        }
        catch {
            Write-Log "Error during credential prompt: $_" "ERROR"
            $Credential = $null
        }
    }

    if ($null -eq $Credential) {
        Write-Log "Failed to obtain credentials after $MaxAttempts attempts" "ERROR"
        [System.Windows.Forms.MessageBox]::Show(
            "Could not obtain domain credentials`n`nThe computer will NOT be joined to the domain.`nYou will need to join manually.",
            "Domain Join Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 1
    }

    # Attempt domain join
    Write-Log "Attempting to join domain '$DomainName'..."
    Write-Log "Using OU: $OUPath"
    $JoinParams = @{
        DomainName = $DomainName
        Credential = $Credential
        OUPath     = $OUPath
        Force      = $true
        ErrorAction = "Stop"
    }

    # Add domain controller if specified
    if (-not [string]::IsNullOrEmpty($DomainController)) {
        $JoinParams.Add("Server", $DomainController)
        Write-Log "Using domain controller: $DomainController"
    }

    try {
        Add-Computer @JoinParams
        Write-Log "Successfully joined domain '$DomainName'" "SUCCESS"
        # Clean up
        Remove-AutoLogon
        Remove-TempLocalAdmin
        [System.Windows.Forms.MessageBox]::Show(
            "Successfully joined domain: $DomainName`n`nThe computer will now restart.",
            "Domain Join Successful",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        Write-Log "Restarting computer..."
        Restart-Computer -Force
    }
    catch {
        $ErrorMessage = $_.Exception.Message
        Write-Log "Domain join failed: $ErrorMessage" "ERROR"
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to join domain: $DomainName`n`nError: $ErrorMessage`n`nPlease join the domain manually.",
            "Domain Join Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 1
    }
}
catch {
    Write-Log "Unexpected error: $_" "ERROR"
    exit 1
}

pause
