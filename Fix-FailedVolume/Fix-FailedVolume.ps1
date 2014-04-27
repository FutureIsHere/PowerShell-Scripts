<#
.SYNOPSIS
  The script check status of a mirror disk(s) using diskpart
.DESCRIPTION
	Windows 7 does not generate any events when built-in software RAID disk is failed. This script is a work-around, which could help to notify the user id it's happened.
   Check status of all mirror disks attached to the local host. If the status is Failed, it generates an event in the System log.
   The script uses "diskpart" utility.
.PARAMETER <paramName>
   no input parameters are required
.EXAMPLE
   <An example of using the script>
#>
#1. Get all RAID volumes ("list volume")
Function Run-Diskpart {
	param (
		[Parameter(Position=0,Mandatory=$true) ]
		$DiskpartCommand		#command which will be executed via diskpart (i.e. "list volumes")
	)
    $DP_UNKNOWN_COMMAND_MESSAGE = "Microsoft DiskPart version"
	try {
		$CommandOutput = ($DiskpartCommand | diskpart)
		#if Disppart version line more than 1 times - unknown command
		$RegexpResult = $CommandOutput -match $DP_UNKNOWN_COMMAND_MESSAGE
        if ($RegexpResult.Length -gt 1) {
            Throw ("ERROR!!! Unknown command:""" + $DiskpartCommand +"""!")
        } else {
            return $CommandOutput
        }
	} catch {
        Throw $_
	}
}
Function Parse-DiskpartList {
	param (
		[parameter(Position=0,Mandatory=$true)]
		[array]$DiskpartOutput
	)
	#remove empty lines
	$tmpArray = @()
	foreach ($line in $DiskpartOutput) {
		$line = $line.TrimStart()
		if ($line.length -ne 0) {
			$tmpArray+=$line
		}
	}
	$DiskpartOutput = $tmpArray

	#find the line with dashes (i.e. "----- ---- --- "
	$indexTitleSeparatorLine = $null
	$indexCurrentLine = 0
	foreach ($line in $DiskpartOutput) {
		if ($line -match "---") {
			$indexTitleSeparatorLine = $indexCurrentLine
			break
		}
		$indexCurrentLine++ 
	}
	if ($indexTitleSeparatorLine -eq $null) {
		throw ("ERROR!!! Incorect format of diskpart output (no separation line (----))")
	}
	
	#get the last data line index (the line before "DISKPART>" line)
	$indexLastDataLine = $null
	for ($i = $indexTitleSeparatorLine; $i -lt $DiskpartOutput.Length; $i++) {
		if ($DiskpartOutput[$i] -match "DISKPART>") {
			$indexLastDataLine = $i - 1 	#the line above
			break
		}
	}
	if ($indexLastDataLine -eq $null) {
		throw ("ERROR!!! Incorect format of diskpart output (no ending line)")
	}

	#calculate columns's width (i.e. "-----" - 5)
	$arrColumnWidth = @()
	$arrColumns = $DiskpartOutput[$indexTitleSeparatorLine].Split()
	foreach($Column in $arrColumns) {
		if ($Column.Length -ne 0) {
			#include only not empty column titles
			$arrColumnWidth+=$Column.Length
		}
	}
	
	#get columns's title
	$ColumnTitleLine = $DiskpartOutput[$indexTitleSeparatorLine-1]	#we assume, that the title line is above the separation line
	$arrColumnTitle = @()
	$indexCurrentColumnTitle = 0		#position of the first character of column's title in the title line
	for ($i = 0; $i -lt $arrColumnWidth.Length; $i++) {
		if ($i -ne ($arrColumnWidth.Length -1)) {
			$ColumnTitle = $ColumnTitleLine.Substring($indexCurrentColumnTitle,$arrColumnWidth[$i])
			$indexCurrentColumnTitle = $indexCurrentColumnTitle + 2 		#at least 2 whitespaces separates columns
			$indexCurrentColumnTitle = $indexCurrentColumnTitle + $arrColumnWidth[$i]		#move the position index to the next column
		} else {
			#get the last element
			$ColumnTitle = $ColumnTitleLine.Substring($indexCurrentColumnTitle)
		}
		$ColumnTitle = $ColumnTitle.Trim()
		$arrColumnTitle += $ColumnTitle
	}
	
	#parse the data
	#the data will be stored in an array of objects
	$arrDiskpartListData = @()
	for ($i = $indexTitleSeparatorLine + 1; $i -le $indexLastDataLine; $i++) {
		#create an object which contains the data
		$objData = New-Object psobject
		foreach ($Column in $arrColumnTitle) {
			$objData | Add-Member -Name "$Column" -MemberType NoteProperty -Value $null
		}
		$indexCurrentColumn = 0
		$indexCurrentColumnData = 0		#position of the first character of data column
		$DataLine = $DiskpartOutput[$i]
		foreach ($Column in $arrColumnTitle) {
			if ($indexCurrentColumn -lt ($arrColumnTitle.Length - 1)) {
				$Data = $DataLine.Substring($indexCurrentColumnData,$arrColumnWidth[$indexCurrentColumn])
				$indexCurrentColumnData=$indexCurrentColumnData + 2 	#at least 2 whitespaces separates columns
				$indexCurrentColumnData=$indexCurrentColumnData + $arrColumnWidth[$indexCurrentColumn]
				$indexCurrentColumn++			
			} else {
				$Data = $DataLine.Substring($indexCurrentColumnData)
			}
			$Data = $Data.Trim()
			$objData.$Column = $Data
		}
		$arrDiskpartListData+= $objData
	}
	return $arrDiskpartListData
}
cls
#1. Get all RAID volumes ("list volume")
try {   
    $DP_output = Run-Diskpart "list volume"
    $AllVolumes = $null
	$AllVolumes = Parse-DiskpartList $DP_output
} catch {
    $CaughtException = $_
	Write-Host $CaughtException
}

#2. Generate an error event if one of volumes is NOT healthy
$EVENT_SOURCE = "DiskDiagnostic"
if ([System.Diagnostics.EventLog]::SourceExists($EVENT_SOURCE)-eq $false) {		#create the event source if it does not exist
	New-EventLog -LogName "System" -Source $EVENT_SOURCE
}
$NumberOfUnhealthyVolumes = 0
foreach ($Volume in $AllVolumes) {
	if (($Volume."Status" -notmatch "Healthy") -and ($Volume."Type" -notmatch "Removable")){
		$NumberOfUnhealthyVolumes++
		if ($Volume."Status" -match "Rebuild") {
			$EventErrorMessage = ("Volume """ + $Volume."Volume ###" + """, Letter """ + $Volume."Ltr" + """, Type """ + $Volume."Type" + """ is rebuilding!" )
			Write-EventLog -EventId 5565 -LogName "System" -Source $EVENT_SOURCE -EntryType Warning -Message $EventErrorMessage -Category 0
		} else {
			$EventErrorMessage = ("Volume """ + $Volume."Volume ###" + """, Letter """ + $Volume."Ltr" + """, Type """ + $Volume."Type" + """ is NOT healthy!`nThe current status:""" + $Volume."Status" + """!" )
			Write-EventLog -EventId 5566 -LogName "System" -Source $EVENT_SOURCE -EntryType Error -Message $EventErrorMessage -Category 0
		}
	}
}
if ($NumberOfUnhealthyVolumes -eq 0) {
	$EventErrorMessage = ("The volumes verifitation script has completed. All volumes are healthy!" )
	Write-EventLog -EventId 5570 -LogName "System" -Source $EVENT_SOURCE -EntryType Information -Message $EventErrorMessage -Category 0
	return 0
} else {
	#try to recover the failed volumes
	foreach ($Volume in $AllVolumes) {
		if ($Volume."Status" -match "Failed Rd") {
			$VolumeNumber = (($Volume."Volume ###").Split())[1]
			$DP_Command = @(("select volume " + $VolumeNumber),'recover')
			$DP_output = Run-Diskpart $DP_Command
			if ($DP_output -match "The RECOVER command completed successfully") {
				$EventErrorMessage = ("The RECOVER command for volume """ + $Volume."Volume ###" + """, Letter """ + $Volume."Ltr" + """, Type """ + $Volume."Type" + """  has been started successfully!" )
				Write-EventLog -EventId 5567 -LogName "System" -Source $EVENT_SOURCE -EntryType Information -Message $EventErrorMessage -Category 0
			} else {
				$EventErrorMessage = ("The RECOVER command for volume """ + $Volume."Volume ###" + """, Letter """ + $Volume."Ltr" + """, Type """ + $Volume."Type" + """  has failed!`nStatus:""" +  $DP_output + """")
				Write-EventLog -EventId 5568 -LogName "System" -Source $EVENT_SOURCE -EntryType Error -Message $EventErrorMessage -Category 0
			}
		}
	}
	#check the status of disks and volumes
	#If there are disks with "Error" status - generate an error event
	$DP_Output = Run-Diskpart "list disk"
	$AllDisks = $null
	$AllDisks = Parse-DiskpartList $DP_Output
	foreach ($Disk in $AllDisks) {
		if ($Disk."Status" -match "Error") {
			$EventErrorMessage = ("ERROR!!! """ + $Disk."Disk ###" + """, Size: """ + $Disk."Size" + """ has Error status!")
			Write-EventLog -EventId 5569 -LogName "System" -Source $EVENT_SOURCE -EntryType Error -Message $EventErrorMessage -Category 0
		}
	}
    $DP_output = Run-Diskpart "list volume"
    $AllVolumes = $null
	$AllVolumes = Parse-DiskpartList $DP_output
	$NumberOfRebuildingVolumes = 0
	foreach ($Volume in $AllVolumes) {
		if ($Volume."Status" -match "Rebuild") {
			$NumberOfRebuildingVolumes++
		}
	}
	if ($NumberOfRebuildingVolumes -eq $NumberOfUnhealthyVolumes) {
		$EventErrorMessage = ("All unhealthy volumes (" + $NumberOfUnhealthyVolumes + ") are rebuilding!")
		Write-EventLog -EventId 5571 -LogName "System" -Source $EVENT_SOURCE -EntryType Information -Message $EventErrorMessage -Category 0
	} else {
		$EventErrorMessage = ("ERROR!!! Some of unhealthy volumes (" + $NumberOfUnhealthyVolumes + ") are NOT rebuilding!")
		Write-EventLog -EventId 5572 -LogName "System" -Source $EVENT_SOURCE -EntryType Error -Message $EventErrorMessage -Category 0
		return 0
	}
	do {
		sleep -Seconds 600			#delay between checks
	    $DP_output = Run-Diskpart "list volume"
    	$AllVolumes = $null
		$AllVolumes = Parse-DiskpartList $DP_output
		$NumberOfRebuildingVolumes = 0
		foreach ($Volume in $AllVolumes) {
			if ($Volume."Status" -match "Rebuild") {
				$NumberOfRebuildingVolumes++
				$EventErrorMessage = ("Volume """ + $Volume."Volume ###" + """, Letter """ + $Volume."Ltr" + """, Type """ + $Volume."Type" + """ is rebuilding!" )
				Write-EventLog -EventId 5565 -LogName "System" -Source $EVENT_SOURCE -EntryType Warning -Message $EventErrorMessage -Category 0
			} else {
				if ($Volume."Status" -notmatch "Healthy") {
					$EventErrorMessage = ("Volume """ + $Volume."Volume ###" + """, Letter """ + $Volume."Ltr" + """, Type """ + $Volume."Type" + """ is not healthy or rebuilding!`nCurrent status:""" + $Volume."Status" + """!" )
					Write-EventLog -EventId 5573 -LogName "System" -Source $EVENT_SOURCE -EntryType Warning -Message $EventErrorMessage -Category 0
					return 0
				}
			}
		}
	} while ($NumberOfRebuildingVolumes -gt 0)
	$EventErrorMessage = ("Rebuilding of volumes have been completed successfully!" )
	Write-EventLog -EventId 5575 -LogName "System" -Source $EVENT_SOURCE -EntryType Information -Message $EventErrorMessage -Category 0
	
}
$AllVolumesHealthy = $false