<#
.SYNOPSIS
  Turns on everything Windows Defender / Firewall offer out of the box,
  then enables RDP so Administrator:lab can connect in for testing.

.NOTES
  Tamper Protection CANNOT be toggled from PowerShell/registry by design
  (Microsoft blocked programmatic changes to it since ~1903) - if you want
  it on, flip it manually once in Windows Security > Virus & threat
  protection settings. Everything else below is scriptable.
#>

$ErrorActionPreference = "Continue"

# --- Microsoft Defender Antivirus: everything turned up -------------------
Set-MpPreference -DisableRealtimeMonitoring $false
Set-MpPreference -DisableIOAVProtection $false
Set-MpPreference -DisableBehaviorMonitoring $false
Set-MpPreference -DisableScriptScanning $false
Set-MpPreference -DisableArchiveScanning $false
Set-MpPreference -DisableRemovableDriveScanning $false
Set-MpPreference -DisableEmailScanning $false

Set-MpPreference -MAPSReporting Advanced
Set-MpPreference -SubmitSamplesConsent NeverSend
Set-MpPreference -CloudBlockLevel High
Set-MpPreference -CloudExtendedTimeout 50
Set-MpPreference -PUAProtection 1

# Controlled Folder Access (ransomware protection) + Network Protection
# (integers, not "Enabled" - the string form fails to bind on some Defender platform versions)
Set-MpPreference -EnableControlledFolderAccess 1
Set-MpPreference -EnableNetworkProtection 1

# Attack Surface Reduction - full recommended rule set, all set to Block
$AsrRules = @(
    "56a863a9-875e-4185-98a7-b882c64b5ce5", # Block abuse of exploited vulnerable signed drivers
    "7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c", # Block Adobe Reader from creating child processes
    "d4f940ab-401b-4efc-aadc-ad5f3c50688a", # Block all Office applications from creating child processes
    "9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2", # Block credential stealing from lsass.exe
    "be9ba2d9-53ea-4cdc-84e5-9b1eeee46550", # Block executable content from email client and webmail
    "01443614-cd74-433a-b99e-2ecdc07bfc25", # Block executable files from running unless prevalence/age/trusted list
    "5beb7efe-fd9a-4556-801d-275e5ffc04cc", # Block execution of potentially obfuscated scripts
    "d3e037e1-3eb8-44c8-a917-57927947596d", # Block JavaScript/VBScript from launching downloaded executable content
    "3b576869-a4ec-4529-8536-b80a7769e899", # Block Office applications from creating executable content
    "75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84", # Block Office applications from injecting code into other processes
    "26190899-1602-49e8-8b27-eb1d0a1ce869", # Block Office communication application from creating child processes
    "e6db77e5-3df2-4cf1-b95a-636979351e5b", # Block persistence through WMI event subscription
    "d1e49aac-8f56-4280-b9ba-993a6d77406c", # Block process creations from PSExec/WMI commands
    "b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4", # Block untrusted/unsigned processes running from USB
    "c1db55ab-c21a-4637-bb3f-a12568109d35"  # Use advanced protection against ransomware
)
Set-MpPreference -AttackSurfaceReductionRules_Ids $AsrRules -AttackSurfaceReductionRules_Actions 1

# Best-effort signature refresh - fails on fresh installs when the Defender
# service isn't fully up yet (0x800706be); Windows Update covers it after boot
try { Update-MpSignature -ErrorAction Stop }
catch { Write-Warning "Update-MpSignature failed, skipping: $($_.Exception.Message)" }

# --- Windows Firewall: on everywhere ---------------------------------------
Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True

# --- RDP: enabled so you can actually get in for testing -------------------
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# Marker so you can confirm provisioning completed on a fresh box
"Provisioned $(Get-Date -Format o)" | Out-File -FilePath C:\OEM\PROVISIONED.txt -Encoding utf8
