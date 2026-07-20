#requires -RunAsAdministrator
$Drive = $env:SystemDrive   # the OS drive, e.g. C:

# 1. Turn on BitLocker: TPM protector, XTS-AES 256, used-space-only.
#    -SkipHardwareTest is the important part (see below).
Enable-BitLocker -MountPoint $Drive `
    -EncryptionMethod XtsAes256 `
    -UsedSpaceOnly `
    -TpmProtector `
    -SkipHardwareTest | Out-Null

# 2. Add a recovery password. THIS is the key that gets escrowed to AD,
#    not the TPM protector.
Add-BitLockerKeyProtector -MountPoint $Drive -RecoveryPasswordProtector | Out-Null

# 3. Back up that recovery password to on-prem AD DS.
$RecoveryId = ((Get-BitLockerVolume -MountPoint $Drive).KeyProtector |
    Where-Object KeyProtectorType -eq 'RecoveryPassword')[0].KeyProtectorId
manage-bde.exe -protectors -adbackup $Drive -id $RecoveryId

# 4. Wait for encryption to complete.
do {
    Start-Sleep -Seconds 5
    $v = Get-BitLockerVolume -MountPoint $Drive
    Write-Host ("{0} {1}% {2}" -f $Drive, $v.EncryptionPercentage, $v.VolumeStatus)
} until ($v.VolumeStatus -eq 'FullyEncrypted')