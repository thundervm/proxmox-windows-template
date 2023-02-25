# Delete cloudbase-init User

net user cloudbase-init /delete

# Attribute service to local system

sc.exe config cloudbase-init obj= .\LocalSystem

# Modify executon path of Service

$newtext = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\cloudbase-init' -Name 'ImagePath' | Select-Object -ExpandProperty ImagePath | %{$_.replace(" cloudbase-init ", " NT-AUTHORITY\SYSTEM ")}
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\cloudbase-init' -Name 'ImagePath' -Value $newtext

# Remove a microsoft store language package that causes generelazing issues

Get-AppxPackage | Where-Object {$_.name -Like "*Language*"} | Remove-AppxPackage
