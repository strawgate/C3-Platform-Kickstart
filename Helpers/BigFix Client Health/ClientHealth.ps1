param (
    [string] $Masthead = "http://bigfix:52311/masthead/masthead.afxm",
    [string] $Installer = "http://software.bigfix.com/download/bes/95/BigFix-BES-Client-9.5.2.56.exe"
)

$RegistrySoftwareRoot = if ($ENV:PROCESSOR_ARCHITECTURE -eq "AMD64") { "HKLM:\Software\WOW6432Node" } else { "HKLM:\Software" }
$ProgramFilesRoot = if ($ENV:PROCESSOR_ARCHITECTURE -eq "AMD64") { ${env:ProgramFiles(x86)} } else { ${env:ProgramFiles} }

function Check-RegistryKeys {
    param (
        [string[]] $Keys
    )

    foreach ($Key in $Keys) {
        if (!(test-path $Key)) {
            throw "$Key does not exist"
        }
    }
}

function Check-RegistryValues {
    param (
        [string[][]] $KeyValuePairs
    )

    foreach ($Pair in $KeyValuePairs) {
        $Key = $Pair[0]
        $Value = $Pair[1]
        try {
            (Get-ItemProperty -Path $Key)."$Value" | out-null
        } catch {
            throw "$Value not in $Key"
        }
    }
}

function Check-Directories {
    param (
        [string[]] $Directories
    )
    foreach ($Directory in $Directories) {
        if (!(resolve-path $Directory)) {
            throw "$Directory does not exist"
        }
    }
}

function Check-Files {
    param (
        [string[]] $Files
    )
    foreach ($File in $Files) {
        if (!(resolve-path $File)) {
            throw "$File does not exist"
        }
    }
}

function Check-Services {
    param (
        [string[]] $Services,
        [switch] $Repair
    )

    foreach ($Service in $Services) {
        $Service = get-service $Service -ErrorAction SilentlyContinue

        if (!($Service)) { throw "$Service does not exist" }

        if ($Repair) {
            if ($Service.Status -ne "Running") {
                $Service | Start-Service
                Start-Sleep -Seconds 30
            }

            if ($Service.StartType -ne "Automatic") {
                $Service | set-service -StartupType Automatic
            }
        }
    }
}

Function Invoke-Repair {
    param (
        [string[][]]$Actions,
        $Cache
    )
    foreach ($ActionPair in $Actions) {
        $Exe = $ActionPair[0]
        $Cmdline = $ActionPair[1]
        start-process -FilePath $Exe -ArgumentList $Cmdline -WorkingDirectory $Cache -wait
    }

}

Function Invoke-Downloads {
    param (
        $Downloads,
        $Cache
    )
    new-item $Cache -ItemType directory -ErrorAction SilentlyContinue

    foreach ($Download in $Downloads.GetEnumerator()) {
        $wc = new-object System.Net.WebClient

        $Destination = "$Cache\$($Download.Name)"

        remove-item $Destination -ErrorAction SilentlyContinue
    
        $wc.DownloadFile($Download.Value, $Destination)

        $wc.Dispose()
    }
}

function write-log {
    param (
        $Text,
        [ValidateSet(“Verbose”,”Error”,”Summary”)] 
        $Type = "Verbose"
    )
    if ($Type -like "Verbose") { $ID = 1337; $EntryType = "Information" }
    if ($Type -like "Error")   { $ID = 1338; $EntryType = "Error" }
    if ($Type -like "Summary") { $ID = 1340; $EntryType = "SuccessAudit" }

    New-EventLog -LogName "BigFix Client Health" -Source "Client Health" -ErrorAction SilentlyContinue
    Limit-EventLog -LogName "BigFix Client Health" -Retention 28 -ErrorAction SilentlyContinue
    
    write-host $Text
    write-eventlog -logname "BigFix Client Health" -source "Client Health" -eventID $ID -EntryType $EntryType -message "$Text"
}

try {
    $Services = @(
        "BESClient"
    )

    Check-Services $Services -Repair

    $RegistryKeys = @(
        @(
            "$RegistrySoftwareRoot\BigFix",
            "$RegistrySoftwareRoot\BigFix\EnterpriseClient"
        )
    )

    $RegistryValues = @(
        @("$RegistrySoftwareRoot\BigFix\EnterpriseClient", "EnterpriseClientFolder"),
        @("$RegistrySoftwareRoot\BigFix\EnterpriseClient\GlobalOptions", "ComputerId")
    )

    Check-RegistryKeys $RegistryKeys
    Check-RegistryValues $RegistryValues

    $InstallDir = (Get-ItemProperty -Path "$RegistrySoftwareRoot\BigFix\EnterpriseClient").EnterpriseClientFolder

    $Directories = @(
        "$InstallDir",
        "$InstallDir\__BESData",
        "$InstallDir\__BESData\__Global",
        "$InstallDir\__BESData\__Global\Logs",
        "$InstallDir\__BESData\actionsite"
    )

    $Files = @(
        "$InstallDir\besclient.exe",
        "$InstallDir\__BESData\actionsite\ActionSite.afxm"
    )

    #If it's after 6am do a log check too
    if ((get-date).hour -gt 6) {$Files += "$InstallDir\__BESData\__Global\Logs\$((Get-Date).tostring("yyyyMMdd")).log"}
    
    Check-Directories $Directories
    Check-Files $Files

    write-log "Client Health Check Passed" -Type Summary

} catch {

    write-log -Text $_.Exception.Message -ID "1340"
    
    $Downloads = @{
        "Cleaner.exe" = "https://www.ibm.com/developerworks/community/wikis/form/anonymous/api/wiki/90553c0b-42eb-4df0-9556-d3c2e0ac4c52/page/90bfd4e5-98b9-4a9b-a6cb-812f1f8d5702/attachment/63b54d70-2290-4044-8b67-6eb0a4d66cfc/media/BESRemove9.5.0.311.exe";
        "Client.exe" = $Installer;
        "masthead.afxm" = $MastHead;
    }

    $Repair = @(
        @("net.exe", "stop besclient"),
        @("Robocopy.exe", "/E ""$InstallDir\__BESData"" ""$($env:windir)\BigFix\Backup\$(get-date -format "yyyyMMdd-HHmmss")"""),
        @("Cleaner.exe", "/silent /client /force"),
        @("Client.exe", "/s /v/qn")
    )

    Invoke-Downloads -Downloads $Downloads -Cache "$($env:windir)\BigFix\Cache"

    Invoke-Repair -Actions $Repair -Cache "$($env:windir)\BigFix\Cache"

    write-log "Client Repair Completed" -Type Error
}