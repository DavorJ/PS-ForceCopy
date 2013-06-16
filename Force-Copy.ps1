## .SYNOPSIS
#########################
## This script copies a file, ignoring device I/O errors that abort the reading of files in most applications.
##
## .DESCRIPTION
#########################
## This script will copy the specified file even if it contains unreadable blocks caused by device I/O errors and such. The block that it can not read will be replaced with zeros. The size of the block is determined by the buffer. So, to optimize it for speed, use a large buffer. T optimize fo accuracy, use small buffer, smallest being the cluter size of the partition where your sourcefile resides.
##
## .OUTPUTS
#########################
## Errorcode 0: Copy operation finished without errors.
## Errorcode 1: Copy operation finished with unreadable blocks.
## Errorcode 2: Destination file exists, but -Overwrite not specified.
## Errorcode 3: Destination file exists but has no bad blocks (i.e. no badblocks.xml file found)
## 
## .INPUTS
#########################
## ...
##
## .PARAMETER SourceFilePath
## Path to the source file.
##  
## .PARAMETER DestinationFilePath
## Path to the destination file.
## 
## .PARAMETER Buffer
## I makes absolutely no sense to set this less than the cluser size of the partition. Setting it lower than cluster size might force rereading a bad sector in a cluster multiple times. Better is to adjust the retry option. Also, System.IO.FileStream buffers input and output for better performance. (http://msdn.microsoft.com/en-us/library/system.io.filestream.aspx).
##
## .EXAMPLE
## .\Force-Copy.ps1 -SourceFilePath "file_path_on_bad_disk" -DestinationFilePath "destinaton_path" -MaxRetries 6
## 
## This will copy file_path_on_bad_disk to destinaton_path with maximum of 6 retries on each cluster of 4096 bytes encountered. Usually 6 retries is enough to succeed, unless the sector is really completely unreadable. 
##
## .EXAMPLE
## dir '*.jpg' -recurse | foreach {.\Force-Copy.ps1 -SourceFilePath $_.FullName -DestinationFilePath ("C:\Saved"+(Split-Path $_.FullName -NoQualifier)) -Maxretries 2}
##
## This command will copy all jpg's beginning with "Total" and copy them to "C:\Saved\relative_path" preserving their relative path.
#########################

[CmdletBinding()]
param( 
   [Parameter(Mandatory=$true,
			  ValueFromPipeline=$true,
			  HelpMessage="Source file path.")]
   [string][ValidateScript({Test-Path -LiteralPath $_ -Type Leaf})]$SourceFilePath,
   [Parameter(Mandatory=$true,
			  ValueFromPipeline=$true,
			  HelpMessage="Destination file path.")]
   [string][ValidateScript({Test-Path -LiteralPath $_ -IsValid})]$DestinationFilePath,
   [Parameter(Mandatory=$false,
			  ValueFromPipeline=$false,
			  HelpMessage="Buffer size in bytes.")]
   [int32]$BufferSize=512*2*2*2, # 4096: the default windows cluster size.
   [Parameter(Mandatory=$false,
			  ValueFromPipeline=$false,
			  HelpMessage="Amount of tries.")]
   [int16]$MaxRetries=0,
   [Parameter(Mandatory=$false,
			  ValueFromPipeline=$false,
			  HelpMessage="Overwrite destination file?")]
   [switch]$Overwrite=$false,
   [Parameter(Mandatory=$false,
			  ValueFromPipeline=$true,
			  HelpMessage="Specify position from which to read block.")]
   [int64]$Position=0, # must be 0, current limitation
   [Parameter(Mandatory=$false,
			  ValueFromPipeline=$true,
			  HelpMessage="Specify end position for reading.")]
   [int64]$PositionEnd=-1, # must be -1, current limitation
   [Parameter(Mandatory=$false,
			  ValueFromPipeline=$false,
			  HelpMessage="Ignore the existing badblocks.xml file?")]
   [switch]$IgnoreBadBlocksFile=$false,   # not implemented
   [Parameter(Mandatory=$false,
			  ValueFromPipeline=$false,
			  HelpMessage="Will the source file be deleted in case no bad blocks are encountered?")]
   [switch]$DeleteSourceOnSuccess=$false
)

Set-StrictMode -Version 2;

# Simple assert function from http://poshcode.org/1942
function Assert {
# Example
# set-content C:\test2\Documents\test2 "hi"
# C:\PS>assert { get-item C:\test2\Documents\test2 } "File wasn't created by Set-Content!"
#
[CmdletBinding()]
param( 
   [Parameter(Position=0,ParameterSetName="Script",Mandatory=$true)]
   [ScriptBlock]$condition
,
   [Parameter(Position=0,ParameterSetName="Bool",Mandatory=$true)]
   [bool]$success
,
   [Parameter(Position=1,Mandatory=$true)]
   [string]$message
)

   $message = "ASSERT FAILED: $message"
  
   if($PSCmdlet.ParameterSetName -eq "Script") {
      try {
         $ErrorActionPreference = "STOP"
         $success = &$condition
      } catch {
         $success = $false
         $message = "$message`nEXCEPTION THROWN: $($_.Exception.GetType().FullName)"         
      }
   }
   if(!$success) {
      throw $message
   }
}

# Forces read on Stream and returns total number of bytes read into buffer.
function Force-Read() {
param( 
	[Parameter(Mandatory=$true)]
	[System.IO.FileStream]$Stream,
	[Parameter(Mandatory=$true)]
	[int64]$Position,
	[Parameter(Mandatory=$true)]
	[ref]$Buffer,
	[Parameter(Mandatory=$true)]
	[ref]$Successful,
	[Parameter(Mandatory=$false)]
	[int16]$MaxRetries=0
)

	$Stream.Position = $Position;
	$FailCounter = 0;
	$Successful.Value = $false;

	while (-not $Successful.Value) {
	
		try {
			
			$ReadLength = $Stream.Read($Buffer.Value, 0, $Buffer.Value.Length);
			# If the read operation is successful, the current position of the stream is advanced by the number of bytes read. If an exception occurs, the current position of the stream is unchanged. (http://msdn.microsoft.com/en-us/library/system.io.filestream.read.aspx)
			
		} catch [System.IO.IOException] {
			
			$ShouldHaveReadSize = [math]::Min([int64] $Buffer.Value.Length, ($Stream.Length - $Stream.Position));
			
			if (++$FailCounter -le $MaxRetries) { # Retry to read block 
			
				Write-Host $FailCounter"th retry to read "$ShouldHaveReadSize" bytes starting at "$($Stream.Position)" bytes." -ForegroundColor "DarkYellow";
				Write-Debug "Debugging read retry...";
				
				continue;
			
			} else { # Failed read of block.

				Write-Host "Can not read"$ShouldHaveReadSize" bytes starting at "$($Stream.Position)" bytes: "$($_.Exception.message) -ForegroundColor "DarkRed";
				Write-Debug "Debugging read failure...";
				
				# Should be here ONLY on UNsuccessful read!
				# $Successful is $false by default;
				$Buffer.Value = New-Object System.Byte[] ($Buffer.Value.Length);
				return $ShouldHaveReadSize;
			
			}
			
		} catch {
		
			Write-Warning "Unhandled error at $($Stream.position) bit: $($_.Exception.message)";
			Write-Debug "Unhandled error. You should debug."; 
			
			throw $_;
		
		}
		
		if ($FailCounter -gt 0) { # There were prior read failures
			Write-Host "Successfully read"$ReadLength" bytes starting at "$($SourceStream.Position - $ReadLength)" bytes." -ForegroundColor "DarkGreen";
		}
		
		# Should be here ONLY on successful read!
		$Successful.Value = $true;
		# Buffer is allready set during successful read.
		return $ReadLength;

	}

	throw "Should not be here...";
}

# Returns a custom object for storing bad block data.
function New-Block() { 
	param ([int64] $OffSet, [int32] $Size)
	  
	$block = new-object PSObject

	Add-Member -InputObject $block -MemberType NoteProperty -Name "OffSet" -Value $OffSet;
	Add-Member -InputObject $block -MemberType NoteProperty -Name "Size" -Value $Size;
	  
	return $block;
}

# Snity checks
if ((Test-Path -LiteralPath $DestinationFilePath) -and -not $Overwrite) {
	Write-Host "Destination file $DestinationFilePath allready exists and -Overwrite not specified. Exiting." -ForegroundColor "Red";
	exit 2;
}
Assert {$Position -eq 0 -and $PositionEnd -eq -1} "Current limitation: Position and POsitionEnd should be 0 and -1 respectively.";

# Setting global variables
$DestinationFileBadBlocksPath = $DestinationFilePath + '.badblocks.xml';
$DestinationFileBadBlocks = @();

# Fetching SOURCE file
$SourceFile = Get-Item -LiteralPath $SourceFilePath;
Assert {$Position -lt $SourceFile.length} "Specified position out of source file bounds.";

# Fetching DESTINATION file.
if (-not (Test-Path -LiteralPath ($DestinationParentFilePath = Split-Path -Path $DestinationFilePath -Parent) -PathType Container)) { # Make destination parent folder in case it doesn't exist.
	New-Item -ItemType Directory -Path $DestinationParentFilePath | Out-Null;
}
$DestinationFile = New-Object System.IO.FileInfo ($DestinationFilePath); # Does not (!) physicaly make a file.
$NewDestinationFile = -not $DestinationFile.Exists;

# Special handling for DESTINATION file in case OVERWRITE is used! Only bad block are read from source!
if ($Overwrite -and (Test-Path -LiteralPath $DestinationFilePath)) {
	
	# Make sure the Source and Destination files have the same length prior to overwrite!
	Assert {$SourceFile.Length -eq $DestinationFile.Length} "Source and destination file have not the same size!"  
	
	# Search for badblocks.xml - if it doesn't exist then the file is probably OK, so don't do anything!
	if (-not (Test-Path -LiteralPath $DestinationFileBadBlocksPath)) {
	
		Write-Host "Destination file $DestinationFilePath has no bad blocks. It is unwise to continue... Exiting." -ForegroundColor "Red";
		exit 3;

	} else { # There is a $DestinationFileBadBlocksPath
		
		$DestinationFileBadBlocks = Import-Clixml $DestinationFileBadBlocksPath;
		Write-Host "Badblocks.xml successfully imported. Destination file has $(($DestinationFileBadBlocks | Measure-Object -Sum -Property Size).Sum) bad bytes." -ForegroundColor "Yellow";
		
		# Make sure destination file has bad blocks.
		if ($DestinationFileBadBlocksPath.Length -eq 0) {
			Write-Host "Destination file $DestinationFilePath has no bad blocks according to badblocks.xml. Should not overwrite... Exiting." -ForegroundColor "Red";
			exit 3;
		}	
	
		Assert {($DestinationFileBadBlocks | Measure-Object -Average -Property Size).Average -eq $BufferSize } "Block sizes do not match between source and destination file. Can not continue." # This is currently an implementation shortcomming.
			
	}
}

# Making buffer
$Buffer = New-Object -TypeName System.Byte[] -ArgumentList $BufferSize;

# Making container for storing missread offsets.
$UnreadableBlocks = @();

# Making filestreams
$SourceStream = $SourceFile.OpenRead();
$DestinationStream = $DestinationFile.OpenWrite();

if ($PositionEnd -le -1) {$PositionEnd = $SourceStream.Length}

# Copying starts here
Write-Host "Starting copying of $SourceFilePath..." -ForegroundColor "Green";

[bool] $ReadSuccessful = $false;

while ($Position -lt $PositionEnd) {

	if ($NewDestinationFile -or 
	   ($PositionMarkedAsBad = $DestinationFileBadBlocks | % {if (($_.Offset -le $Position) -and ($Position -lt ($_.Offset + $_.Size))) {$true;}})) {
			
			if (($Position -eq 0) -or -not $LastReadFromSource) {Write-Host "Started reading from source file at offset $Position." -ForegroundColor "DarkRed";}
			$LastReadFromSource = $true;

			# Force read a block from source
			$ReadLength = Force-Read -Stream $SourceStream -Position $Position -Buffer ([ref] $Buffer) -Successful ([ref] $ReadSuccessful) -MaxRetries $MaxRetries;		

			if (-not $ReadSuccessful) {
				$UnreadableBlocks += New-Block -OffSet $Position -Size $ReadLength;
			}
				
			# Write to destination file.
			$DestinationStream.Position = $Position;
			$DestinationStream.Write($Buffer, 0, $ReadLength);
			
	} else {
	
			if ($Position -eq 0 -or $LastReadFromSource) {Write-Host "Skipping from offset $Position." -ForegroundColor "DarkGreen";}
			$LastReadFromSource = $false;
			
			# Skipping block.
			$ReadLength = $BufferSize;
		
	}
	
	$Position += $ReadLength; # adjust position
	
	# Write-Progress -Activity "Hashing File" -Status $file -percentComplete ($total/$fd.length * 100)
}

$SourceStream.Dispose();
$DestinationStream.Dispose();

if ($UnreadableBlocks) {
	
	# Write summaryamount of bad blocks.
	Write-Host "$(($UnreadableBlocks | Measure-Object -Sum -Property Size).Sum) bytes are bad." -ForegroundColor "Magenta";
	
	# Export badblocks.xml file.
	Export-Clixml -Path ($DestinationFileBadBlocksPath) -InputObject $UnreadableBlocks;

} elseif (Test-Path -LiteralPath $DestinationFileBadBlocksPath) { # No unreadable blocks and badblocks.xml exists.
	
	Remove-Item -LiteralPath $DestinationFileBadBlocks;
}

# Set creation and modification times
$DestinationFile.CreationTimeUtc = $SourceFile.CreationTimeUtc;
$DestinationFile.LastWriteTimeUtc = $SourceFile.LastWriteTimeUtc;
$DestinationFile.IsReadOnly = $SourceFile.IsReadOnly;

Write-Host "Finished copying $SourceFilePath!" -ForegroundColor "Green";

# Return specific code.
if ($UnreadableBlocks) {
	exit 1;
} else {
	exit 0;
}
