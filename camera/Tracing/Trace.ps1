#requires -Version 4.0
<#
//*********************************************************
//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the Microsoft Public License.
// THIS CODE IS PROVIDED AS IS WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
//*********************************************************
#>
<#
 .SYNOPSIS
 Captures ETW traces.

 .PARAMETER Output
 Output path. A temporary folder is created by default.

 .PARAMETER Help
 Shows the detailed help information.

 .PARAMETER List
 Displays the list of available scenarios.

 .PARAMETER Detailed
 Shows additional information about the scenarios available.

 .EXAMPLE
 .\Trace.ps1 -List
 Shows information about the supported scenarios.

 .EXAMPLE
 .\Trace.ps1 -List -Detailed
 Shows information about the supported scenarios, including providers used.

 .EXAMPLE
 .\Trace.ps1 -Start
 Start tracing without stopping
#>

[CmdletBinding(DefaultParameterSetName = "Common")]
param(
    [Parameter(ParameterSetName = "Common", ValueFromPipeline = $true)]
    [Alias("o")]
    [String]
    $Output,

    [Parameter(ParameterSetName = "Common", ValueFromPipeline = $true)]
    [Switch]
    [Alias("start")]
    $StartBootTrace,

    [Parameter(ParameterSetName = "StopBootTrace", ValueFromPipeline = $true)]
    [ValidateNotNullOrEmpty()]
    [Alias("stop")]
    [String]
    $StopBootTrace,
    [Parameter(ParameterSetName = "Help")]
    [Alias("h", "?")]
    [Switch]
    $Help,

    [Parameter(ParameterSetName = "List")]
    [Switch]
    $Detailed
)

#--------------------------------------------------------------------
# Variables
#--------------------------------------------------------------------

# Scenario to be used, when the "Default" scenario is chosen.
$Scenario = New-Object System.Collections.ArrayList
$Scenario.Add("Multimedia") > $null

$Modules = @(

    # Needed to access caller variables ($Verbose, $Debug, and etc.) from the included modules.
    "$PSScriptRoot\lib\Get-CallerPreference.psm1"

    # Helper functions.
    "$PSScriptRoot\lib\Types.psm1"
    "$PSScriptRoot\lib\Utils.psm1"
)

# Contains information about the local and target environments.
$EnvironmentInfo = $null

# Collection of scenarios to be executed.
$ScenariosData = @{}

# List of tracing script paths.
$StartScripts          = New-Object System.Collections.ArrayList
$StopScripts           = New-Object System.Collections.ArrayList
$PostProcessingScripts = New-Object System.Collections.ArrayList

# List of outstanding background jobs.
$BackgroundJobs        = New-Object System.Collections.ArrayList

#--------------------------------------------------------------------
# Functions
#--------------------------------------------------------------------

<#
 .SYNOPSIS
 Script entry point.
#>
function Main {
    [CmdletBinding()]
    [OutputType([String])]
    param()

    begin {
        Import-Module -Name $Modules -Force -NoClobber:$false -DisableNameChecking -ErrorAction Stop -Function * -Alias * -Cmdlet * -Variable *

        Get-CallerPreference -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState
    }

    process {
        if ($Help) {
            Get-Help $MyInvocation.PSCommandPath -Detailed
            return
        }

        . $PSScriptRoot\lib\TraceFn.ps1

        # Convert the input arguments to the proper strongly-typed values.
        $script:OperationModeType  = Read-TraceOperationMode      "NoPostProcessing"
        $script:TargetType         = Read-TraceTargetType         $null
        $script:ToolsetType        = Read-TraceToolsetType        "WPR"
        $script:PostProcessingType = Read-TracePostProcessingType "None"

        $IsStopBootTrace = $false
        if([String]::IsNullOrEmpty($StopBootTrace) -eq $false)
        {
            $IsStopBootTrace = $true
        }

        #
        # Make sure the script is running elevated.
        #

        if (!(Test-DeviceConnected) -and !(Test-InAdminRole)) {
            Write-Error "Please, run the current script from the elevated command prompt"
            return
        }
        #
        # Main loop.
        #

        $tracingStarted = $false

        try {
            if($IsStopBootTrace)
            {
                Write-Host "Gathering system information..."
                Get-EnvironmentInformation

                $script:StopScripts = @(Get-ChildItem -Path $path -Filter *_stop.cmd | select -ExpandProperty FullName)

                # Put scripts on device, if needed.
                Write-Host "Preparing target system..."
                Prepare-Target

                if ($TargetType -ne [Tracing.TargetType]::Local) {
                    PutFile-Target -Local "$($EnvironmentInfo.TraceScriptsPathLocal)\*" -Target $EnvironmentInfo.TraceScriptsPathTarget -TargetType $TargetType

                    # Modify locations of the start/stop scripts, as they are on a remote device now.
                    # NOTE: Don't do anything with the post-processing scripts, because they are run locally.
                    $script:StartScripts = $script:StartScripts | % { "$($EnvironmentInfo.TraceScriptsPathTarget)\$((Get-Item $_).Name)" }
                    $script:StopScripts  = $script:StopScripts  | % { "$($EnvironmentInfo.TraceScriptsPathTarget)\$((Get-Item $_).Name)" }
                }

                Write-Host "Stopping tracing and merging results..."
                Stop-Tracing -DownloadFiles
                $tracingStarted = $false

                Write-Host "Saving target system details..."
                Save-TargetDetailsOnStop

                # Decide if the post-processing is needed.
                if (($OperationModeType -ne [Tracing.OperationMode]::NoPostProcessing) -and ($PostProcessingType -ne [Tracing.PostProcessingType]::None)) {
                    Write-Host "Post-processing..."

                    if (Test-DomainNetworkAvailable) {
                        Start-PostProcessing
                    } else {
                        Write-Host "Post-processing skipped, domain resources not available" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "Post-processing skipped per user request" -ForegroundColor Yellow
                }

                Write-Host "Waiting for the background jobs to complete..."
                Wait-ForBackgroundJobs

                Write-Host "Output: $($EnvironmentInfo.TracePathLocal)"
    
            }
            else
            {
                Write-Host "Looking for the logging scenarios..."
                #$script:ScenariosData = Get-Scenario $Scenario

                Write-Host "Gathering system information..."
                Get-EnvironmentInformation

                Write-Host "Preparing local system..."
                Prepare-Local

                # If the user wants us to generate scripts, but not to run them.
                Write-Host "Preparing target system..."
                Prepare-Target

                Write-Host "Saving target system details..."
                Save-TargetDetailsOnStart

                Write-Host "Creating tracing scripts..."
                Create-Scripts -bootTrace:$StartBootTrace

                Write-Host "Starting tracing..."
                $tracingStarted = $true
                Start-Tracing

                if ($StartBootTrace)
                {
                    # retain tracing between reboot
                    Write-Host "Waiting for the background jobs to complete..."
                    Wait-ForBackgroundJobs

                    Write-Host "To stop active trace"
                    Write-Host "    Trace.ps1 -stopbootTrace $($EnvironmentInfo.TracePathLocal)" 
                    return $EnvironmentInfo.TracePathLocal
                }
                else
                {
                    # Wait for user input, or for background tasks to finish.
                    Wait-ForStop

                    Write-Host "Stopping tracing and merging results..."
                    Stop-Tracing -DownloadFiles
                    $tracingStarted = $false

                    Write-Host "Saving target system details..."
                    Save-TargetDetailsOnStop

                    Write-Host "Waiting for the background jobs to complete..."
                    Wait-ForBackgroundJobs

                    Write-Host "Output: $($EnvironmentInfo.TracePathLocal)"

                    Compress-Archive -Path $($EnvironmentInfo.TracePathLocal) -DestinationPath $($EnvironmentInfo.TracePathLocal)
                }
            }
        } catch {
            Write-Error "Unexpected error: $_"
        } finally {
            # Open the output, and archive directory.
            if (Test-Path $EnvironmentInfo.TracePathLocal) {
                Start-Process ($EnvironmentInfo.TracePathLocal) > $null
            }

            if ($tracingStarted -and (-not $StartBootTrace)) {
                # No need to download files in case we were interrupted.
                Stop-Tracing -DownloadFiles:$false
            }
        }
        Write-Host "Done"
    }
}

<#
 .SYNOPSIS
 Populates the $EnvironmentInfo object.
#>
function Get-EnvironmentInformation {
    [CmdletBinding()]
    [OutputType([void])]
    param()

    begin {
        Get-CallerPreference -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState
    }

    process {
        Write-Verbose "[Get-EnvironmentInformation] Collecting environment information"

        $systemArchitecture = Get-LocalSystemArchitecture

        # Figure out if xperf can be found in the PATH.
        cmd /c where /Q xperf.exe > $null
        if ($LASTEXITCODE -eq 0) {
            $localXPerf = cmd /c where xperf.exe
        } else {
            $localXPerf = "C:\Windows\System32\XPerf.exe"
        }

        $script:EnvironmentInfo = New-Object Tracing.EnvironmentInfo
        $EnvironmentInfo.ScriptRootPath          = $PSScriptRoot
        $EnvironmentInfo.TargetTemp              = if ($TargetType -eq [Tracing.TargetType]::TShell) { "C:\Data\Test\Tracing" } elseif ($TargetType -eq [Tracing.TargetType]::XBox) { "D:\Tmp\Tracing" } else { $env:TEMP }
        $EnvironmentInfo.SymLocalPath            = "$($env:SystemDrive)\Symbols.pri"
        $EnvironmentInfo.TraceEtlBase            = "Trace_$($env:USERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        $EnvironmentInfo.TracePathTarget         = "$($EnvironmentInfo.TargetTemp)\$($EnvironmentInfo.TraceEtlBase)"
        $EnvironmentInfo.TracePathLocal          = if ([String]::IsNullOrEmpty($Output)) { "$($env:TEMP)\$($EnvironmentInfo.TraceEtlBase)" } else { $Output }
        $EnvironmentInfo.TraceScriptsPathLocal   = "$($EnvironmentInfo.TracePathLocal)\Scripts"
        $EnvironmentInfo.TraceScriptsPathTarget  = "$($EnvironmentInfo.TracePathTarget)\Scripts"
        

        Write-Verbose "[Get-EnvironmentInformation] Data:"
        Write-Verbose "  ScriptRootPath          : $($EnvironmentInfo.ScriptRootPath)"
        Write-Verbose "  TargetTemp              : $($EnvironmentInfo.TargetTemp)"
        Write-Verbose "  SymLocalPath            : $($EnvironmentInfo.SymLocalPath)"
        Write-Verbose "  TraceEtlBase            : $($EnvironmentInfo.TraceEtlBase)"
        Write-Verbose "  TracePathTarget         : $($EnvironmentInfo.TracePathTarget)"
        Write-Verbose "  TracePathLocal          : $($EnvironmentInfo.TracePathLocal)"
        Write-Verbose "  TraceScriptsPathLocal   : $($EnvironmentInfo.TraceScriptsPathLocal)"
        Write-Verbose "  TraceScriptsPathTarget  : $($EnvironmentInfo.TraceScriptsPathTarget)"

        Write-Verbose "[Get-EnvironmentInformation] Done"
    }
}

<#
 .SYNOPSIS
 Stores system information in the output folder.
#>
function Save-TargetDetailsOnStart {
    [CmdletBinding()]
    [OutputType([void])]
    param()

    begin {
        Get-CallerPreference -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState

        [void]$BackgroundJobs.Clear()
    }

    process {

        try{
            $buildInfo = Get-BuildInfo -TargetType $TargetType
            $buildInfoFilePath = "$($EnvironmentInfo.TracePathLocal)\BuildInfo.log"

            # build 
            $buildInfoStr = New-Object System.Text.StringBuilder
            [void]$buildInfoStr.AppendLine("Version=$($buildInfo.Version),Arch=$($buildInfo.Flavor),Branch=$($buildInfo.Branch)")
            $buildInfoStr.ToString() | Set-Content $buildInfoFilePath -Encoding Ascii

        } catch {
                Write-Verbose "[Save-TargetDetailsOnStart] Error while getting buildInfo: $_"
        }

        if ($TargetType -eq [Tracing.TargetType]::Local) {
            
            Write-Verbose "[Save-TargetDetailsOnStart] Collecting machine information and crash reports"

            #
            # Collect information about the machine.
            #
            Gather-DxDiag
            Gather-SetupAPILog
            Gather-PnpUtil

            # Save buildInfo
        }
    }
}

<#
 .SYNOPSIS
 Stores system information in the output folder.
#>
function Save-TargetDetailsOnStop {
    [CmdletBinding()]
    [OutputType([void])]
    param()

    begin {
        Get-CallerPreference -Cmdlet $PSCmdlet -SessionState $ExecutionContext.SessionState
    }

    process {
        if ($TargetType -ne [Tracing.TargetType]::Local) {
            Write-Verbose "[Save-TargetDetailsOnStop] Skipping for the remote device"
        } else {
            Write-Verbose "[Save-TargetDetailsOnStop] Collecting machine information and crash reports"

            Gather-WinHelloInfo
            Gather-WinBioEvtx

            Write-Verbose "[Save-TargetDetailsOnStop] Done"
       }
    }
}

#--------------------------------------------------------------------
# Commands
#--------------------------------------------------------------------

# Set the default error action to 'Stop'.
$ErrorActionPreference = "Stop"
$WarningPreference     = "Continue"

Main
