$ErrorActionPreference = "Stop"
$resourcesDir = "$ENV:SystemDrive\UnattendResources"
$configIniPath = "$resourcesDir\config.ini"

function Set-PersistDrivers {
    Param(
    [parameter(Mandatory=$true)]
    [string]$Path,
    [switch]$Persist=$true
    )
    if (!(Test-Path $Path)){
        return $false
    }
    try {
        $xml = [xml](Get-Content $Path)
    }catch{
        Write-Error "Failed to load $Path"
        return $false
    }
    if (!$xml.unattend.settings){
        return $false
    }
    foreach ($i in $xml.unattend.settings) {
        if ($i.pass -eq "generalize"){
            $index = [array]::IndexOf($xml.unattend.settings, $i)
            if ($xml.unattend.settings[$index].component -and $xml.unattend.settings[$index].component.PersistAllDeviceInstalls -ne $Persist.ToString()){
                $xml.unattend.settings[$index].component.PersistAllDeviceInstalls = $Persist.ToString()
            }
        }
    }
    $xml.Save($Path)
}

function Clean-UpdateResources {
    $HOST.UI.RawUI.WindowTitle = "Running update resources cleanup"
    # We're done, disable AutoLogon
	
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name Unattend*
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoLogonCount

    # Cleanup
    Remove-Item -Recurse -Force $resourcesDir
    Remove-Item -Force "$ENV:SystemDrive\Unattend.xml"

}

function Clean-WindowsUpdates {
    Param(
        $PurgeUpdates
    )
    $HOST.UI.RawUI.WindowTitle = "Running Dism cleanup..."
    if (([System.Environment]::OSVersion.Version.Major -gt 6) -or ([System.Environment]::OSVersion.Version.Minor -ge 2))
    {
        if (!$PurgeUpdates) {
            Dism.exe /Online /Cleanup-Image /StartComponentCleanup
        } else {
            Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
        }
        if ($LASTEXITCODE)
        {
            throw "Dism.exe clean failed"
        }
    }
}

function Run-Defragment {
    $HOST.UI.RawUI.WindowTitle = "Running Defrag..."
    #Defragmenting all drives at normal priority
    defrag.exe /C /H /V
    if ($LASTEXITCODE)
    {
        throw "Defrag.exe failed"
    }
}

function Release-IP {
    $HOST.UI.RawUI.WindowTitle = "Releasing IP..."
    ipconfig.exe /release
    if ($LASTEXITCODE)
    {
        throw "IPconfig release failed"
    }
}

function Install-WindowsUpdates {
    Import-Module "$resourcesDir\WindowsUpdates\WindowsUpdates"
    $BaseOSKernelVersion = [System.Environment]::OSVersion.Version
    $OSKernelVersion = ($BaseOSKernelVersion.Major.ToString() + "." + $BaseOSKernelVersion.Minor.ToString())
    $KBIdsBlacklist = @{
        "6.1" = @("KB2808679", "KB2894844", "KB3019978");
        "6.2" = @("KB3013538", "KB3042058")
        "6.3" = @("KB3013538", "KB3042058")
    }
    $excludedUpdates = $KBIdsBlacklist[$OSKernelVersion]

    $updates = Get-WindowsUpdate -Verbose -ExcludeKBId $KBIdsBlacklist
    $maximumUpdates = 20
    if (!$updates.Count) {
        $updates = [array]$updates
    }
    if ($updates) {
        $availableUpdatesNumber = $updates.Count
        Write-Host "Found $availableUpdatesNumber updates. Installing..."
        Install-WindowsUpdate -Updates $updates[0..$maximumUpdates]
        Restart-Computer -Force
    }
}



try
{
    Import-Module "$resourcesDir\ini.psm1"
    $installUpdates = Get-IniFileValue -Path $configIniPath -Section "DEFAULT" -Key "InstallUpdates" -Default $false -AsBoolean
    $persistDrivers = Get-IniFileValue -Path $configIniPath -Section "DEFAULT" -Key "PersistDriverInstall" -Default $true -AsBoolean
	
	# There are cases in which the fallowing line might need to be executed. If the network is for some resons setted to Public winRM can't be configured.

	#Set-NetConnectionProfile -InterfaceIndex (Get-NetConnectionProfile).InterfaceIndex -NetworkCategory Private
	
	# Seting up winRM
    Set-ExecutionPolicy Bypass -Force
	Enable-PSRemoting -Force -Confirm
    & "$resourcesDir\SetupWinRMAccess.ps1"
	
    if ($installUpdates) {
        Install-WindowsUpdates
		Clean-WindowsUpdates -PurgeUpdates $purgeUpdates
    }

    #Run-Defragment
	
    Clean-UpdateResources

	$Host.UI.RawUI.WindowTitle = "Running Sysprep..."        
    $unattendXMLUrl = "https://raw.githubusercontent.com/stefan-caraiman/windows-openstack-imaging-tools/master/Unattend64.xml"
	$unattendXMLPath = "$ENV:Temp\Unattend.xml"
	(new-object System.Net.WebClient).DownloadFile($unattendXMLUrl, $unattendXMLPath)
	
	Release-IP
	
	& "$ENV:SystemRoot\System32\Sysprep\Sysprep.exe" `/generalize `/oobe `/shutdown `/unattend:"$unattendXMLPath"
}
catch
{
    $host.ui.WriteErrorLine($_.Exception.ToString())
    $x = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    throw
}
