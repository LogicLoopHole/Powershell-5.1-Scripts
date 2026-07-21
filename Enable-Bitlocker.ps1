$v = gwmi -Namespace root\cimv2\Security\MicrosoftVolumeEncryption Win32_EncryptableVolume -Filter "DriveLetter='C:'"
$v.ProtectKeyWithTPM($null,$null).ReturnValue
$r=$v.ProtectKeyWithNumericalPassword($null,$null); $r.ReturnValue
$v.BackupRecoveryInformationToActiveDirectory($r.VolumeKeyProtectorID).ReturnValue
$v.Encrypt(0,1).ReturnValue
