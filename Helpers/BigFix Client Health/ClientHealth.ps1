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

    write-log "BigFix Client Executable Health Check Passed"
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
        if ((get-date).hour -le 1) {
            write-log "No log for today but it's too close to Midnight to fail."
        } else {
            throw "No BigFix Log for today"
        }
    }

    if (!(test-path "$InstallDir\besclient.exe")) {throw "BigFix executable missing"}

    write-log "BigFix Client Log Health Check Passed"
}

Function Check-ClientRegistry {
    if(!(Get-InstallDir)) { throw "Unable to locate BigFix in the Windows Registry" }

    write-log "BigFix Client Registry Health Check Passed"
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
    write-log "Backing up __BESData"

    $InstallDir = Get-InstallDir
    if(!($InstallDir)) {write-log "Nothing to backup"; return}

    $BackupDir = "$InstallDir\__BESData" -replace("BES Client","__BESData.bak")

    move-item "$InstallDir\__BESData" "$($env:windir)\BigFix\__BESData-$(get-date -format "yyyyMMdd-HHmmss").bak"
}

Function Clean-BigFix {
    write-log "Cleaning off BigFix"
    
    start-process "$($env:windir)\BigFix\Installer Cache\BES-Clean.exe" -ArgumentList "/silent /client /force" -wait
}

Function Clean-BigFix {
    write-log "Cleaning off BigFix"
    
    start-process "$($env:windir)\BigFix\Installer Cache\BES-Clean.exe" -ArgumentList "/silent /client /force" -wait
}

Function Cache-Downloads {

    new-item "$($env:windir)\BigFix\Installer Cache" -ItemType directory -ErrorAction SilentlyContinue
    $wc = new-object System.Net.WebClient

    #Cleaner
    write-log "Downloading Cleaner"

    $Source = "https://www.ibm.com/developerworks/community/wikis/form/anonymous/api/wiki/90553c0b-42eb-4df0-9556-d3c2e0ac4c52/page/90bfd4e5-98b9-4a9b-a6cb-812f1f8d5702/attachment/63b54d70-2290-4044-8b67-6eb0a4d66cfc/media/BESRemove9.5.0.311.exe"
    $Destination = "$($env:windir)\BigFix\Installer Cache\BES-Clean.exe"
    remove-item "$Destination" -ErrorAction SilentlyContinue
    
    $wc.DownloadFile($source, $destination)

    # Setup
    write-log "Downloading BigFix Setup" 
    
    $Source = $Installer
    $Destination = "$($env:windir)\BigFix\Installer Cache\BES-Setup.exe"
    
    remove-item "$Destination" -ErrorAction SilentlyContinue
    $wc.DownloadFile($source, $destination)
    if (!(test-path "$Destination")) { throw "Error Downloading Installer" }

    #Masthead
    write-log "Downloading MastHead"
    
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
    param ( $Text )

    
    new-eventlog -source BFInstall -logname Application -ErrorAction SilentlyContinue

    write-host $Text
    write-eventlog -logname Application -source BFInstall -eventID 1337 -entrytype Information -message "$Text"
}

try {
    Check-Service
    Get-InstallDir
    Check-ClientRegistry
    Check-ClientExe -InstallDir (Get-InstallDir)
    Check-ClientLogs -InstallDir (Get-InstallDir)
} catch {
    write-log $_.Exception.Message
    
    Cache-Downloads

    write-log "Stopping BESClient Service"
    Stop-service -Name BESClient -ErrorAction SilentlyContinue -Force

    start-sleep -Seconds 5
    
    Backup-BESData
    
    Clean-BigFix
    
    Install-BigFix

    write-log "Done with Healthcheck"
}
