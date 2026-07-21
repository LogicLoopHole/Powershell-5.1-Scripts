$v = gwmi -Namespace root\cimv2\Security\MicrosoftVolumeEncryption Win32_EncryptableVolume -Filter "DriveLetter='C:'"
$v.Encrypt(0,1).ReturnValue
$v.GetEncryptionMethod().EncryptionMethod
