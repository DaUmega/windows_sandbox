@echo off
net user Administrator lab /active:yes
net user tester pass /add
net localgroup "Remote Desktop Users" tester /add
wmic useraccount where "name='tester'" set PasswordExpires=false
netsh advfirewall firewall add rule name="Lab ICMPv4-In" protocol=icmpv4:8,any dir=in action=allow
powershell -NoProfile -ExecutionPolicy Bypass -File C:\OEM\harden-defender.ps1
