param (
    [string] $Masthead,
    [string] $Installer = "http://software.bigfix.com/download/bes/95/BigFix-BES-Client-9.5.2.56.exe"
)

Function Check-ClientExe {
    param (
        $InstallDir
    )
    if (!(test-path $InstallDir)) {throw "BigFix Installation directory missing"}
    if (!(test-path "$InstallDir\besclient.exe")) {throw "BigFix executable missing"}
}

Function Check-ClientLogs {
    param (
        $InstallDir
    )
    if (!(test-path $InstallDir)) {throw "BigFix Installation directory missing"}
    if (!(test-path "$InstallDir\__BESData")) {throw "BigFix __BESData directory missing"}
    if (!(test-path "$InstallDir\__BESData\__Global")) {throw "BigFix __BESData\Global directory missing"}
    if (!(test-path "$InstallDir\__BESData\__Global\Logs")) {throw "BigFix __BESData\Global\Logs directory missing"}

    $Logs = get-childitem -path "$InstallDir\__BESData\__Global\Logs"
    if (!($Logs | where-object {$_.LastWriteTime.ToShortDateString() -eq (Get-Date).ToShortDateString()})) { 
        write-log "No BigFix Log for Today"
        if (!($Logs | where-object {$_.LastWriteTime.ToShortDateString() -eq (Get-Date).addDays(-1).ToShortDateString()})) {     
            throw "No BigFix Log for yesterday"
        }
    }

    if (!(test-path "$InstallDir\besclient.exe")) {throw "BigFix executable missing"}
}

Function Check-ClientRegistry {
    if(!(Get-InstallDir)) { throw "Unable to locate BigFix in the Windows Registry" }
}

Function Get-InstallDir {
    if ($ENV:PROCESSOR_ARCHITECTURE -eq "AMD64") {
        $Registry = test-path "HKLM:\SOFTWARE\WOW6432Node\BigFix"
        $InstallDir = (Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\BigFix\EnterpriseClient" -ErrorAction SilentlyContinue).EnterpriseClientFolder
    } else {
        $Registry = test-path "HKLM:\SOFTWARE\BigFix"
        $InstallDir = (Get-ItemProperty -Path "HKLM:\SOFTWARE\BigFix\EnterpriseClient" -ErrorAction SilentlyContinue).EnterpriseClientFolder
    }

    return $InstallDir
}

Function Check-Service {
    $Service = get-service besclient -ErrorAction SilentlyContinue

    if (!($Service)) { return $False }

    # Check Service State
    if ($Service.Status -ne "Running") {
        write-log "Starting Service"
        $Service | Start-Service
        $Service | set-service -StartupType Automatic
    }

    return $Service
}

Function Backup-BESData {
    write-log -Text "Backing up __BESData" -ID "1338"

    $InstallDir = Get-InstallDir
    if(!($InstallDir)) {write-log "Nothing to backup"; return}

    $BackupDir = "$InstallDir\__BESData" -replace("BES Client","__BESData.bak")

    move-item "$InstallDir\__BESData" "$($env:windir)\BigFix\__BESData-$(get-date -format "yyyyMMdd-HHmmss").bak"
}

Function Clean-BigFix {
    write-log -Text "Cleaning off BigFix" -ID "1338"
    
    start-process "$($env:windir)\BigFix\Installer Cache\BES-Clean.exe" -ArgumentList "/silent /client /force" -wait
}

Function Cache-Downloads {

    new-item "$($env:windir)\BigFix\Installer Cache" -ItemType directory -ErrorAction SilentlyContinue
    $wc = new-object System.Net.WebClient

    #Cleaner
    write-log -Text "Downloading Cleaner" -ID "1338"

    $Source = "https://www.ibm.com/developerworks/community/wikis/form/anonymous/api/wiki/90553c0b-42eb-4df0-9556-d3c2e0ac4c52/page/90bfd4e5-98b9-4a9b-a6cb-812f1f8d5702/attachment/63b54d70-2290-4044-8b67-6eb0a4d66cfc/media/BESRemove9.5.0.311.exe"
    $Destination = "$($env:windir)\BigFix\Installer Cache\BES-Clean.exe"
    remove-item "$Destination" -ErrorAction SilentlyContinue
    
    $wc.DownloadFile($source, $destination)

    # Setup
    write-log -Text "Downloading BigFix Setup"  -ID "1338"
    
    $Source = $Installer
    $Destination = "$($env:windir)\BigFix\Installer Cache\BES-Setup.exe"
    
    remove-item "$Destination" -ErrorAction SilentlyContinue
    $wc.DownloadFile($source, $destination)
    if (!(test-path "$Destination")) { throw "Error Downloading Installer" }

    #Masthead
    write-log "Downloading MastHead" -ID "1338"
    
    $Source = $Masthead
    $Destination = "$($env:windir)\BigFix\Installer Cache\masthead.afxm"
    
    remove-item "$Destination" -ErrorAction SilentlyContinue
    
    $wc.DownloadFile($source, $destination)
    if (!(test-path "$Destination")) { throw "Error Downloading Installer" }
}

Function Install-BigFix {

    write-log "Installing BigFix"

    start-process "$($env:windir)\BigFix\Installer Cache\BES-Setup.exe" -ArgumentList "/s /v/qn" -wait
}

function write-log {
    param (
        $Text,
        $ID = 1337
    )

    New-EventLog -LogName "BigFix Client Health" -Source "Client Health" -ErrorAction SilentlyContinue
    Limit-EventLog -LogName "BigFix Client Health" -Retention 28 -ErrorAction SilentlyContinue

    write-host $Text
    write-eventlog -logname "BigFix Client Health" -source "Client Health" -eventID $ID -entrytype Information -message "$Text"
}

try {
    Check-Service
    Get-InstallDir
    throw "test"
    Check-ClientRegistry
    Check-ClientExe -InstallDir (Get-InstallDir)
    Check-ClientLogs -InstallDir (Get-InstallDir)
    write-log "BigFix Client Health Check Passed"
} catch {
    write-log -Text $_.Exception.Message -ID "1340"
    
    Cache-Downloads

    write-log -Text "Stopping BESClient Service" -ID "1338"
    Stop-service -Name BESClient -ErrorAction SilentlyContinue -Force

    start-sleep -Seconds 5
    
    Backup-BESData
    
    Clean-BigFix
    
    Install-BigFix

    write-log -Text "Done with Client Repair" -ID "1339"
}
