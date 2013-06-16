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
			  ValueFromPipeline=$true,
			  HelpMessage="Path to the allready copied file with bad blocks.")]
   [string][ValidateScript({(Test-Path -LiteralPath $_)})]$PartialFilePath,
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
   [int64]$Position=0,
   [Parameter(Mandatory=$false,
			  ValueFromPipeline=$true,
			  HelpMessage="Specify end position for reading.")]
   [int64]$PositionEnd=-1
)

# Set-StrictMode -Version 2;

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
	Write-Host "Destination file $DestinationFilePath allready exists and -Overwrite not specified. Exiting script..." -ForegroundColor "Red";
	exit 1;
}

# Fetching source file
$SourceFile = Get-Item -LiteralPath $SourceFilePath;
Assert {$Position -lt $SourceFile.length} "Specified position out of source file bounds.";

# Fetching destination file.
if (-not (Test-Path -LiteralPath ($DestinationParentFilePath = Split-Path -Path $DestinationFilePath -Parent) -PathType Container)) { # Make destination parent folder in case it doesn't exist.
	New-Item -ItemType Directory -Path $DestinationParentFilePath | Out-Null;
}
$DestinationFile = New-Object System.IO.FileInfo ($DestinationFilePath); # Does not (!) physicaly make a file.
if ($Overwrite -and (Test-Path -LiteralPath $DestinationFilePath)) {Assert {$SourceFile.Length -eq $DestinationFile.Length} "Source and destination file have not the same size!"} # Make sure the Source and Destination files have the same length prior to overwrite!

# Fetching partial file.
if ($PartialFilePath) {$PartialFile = Get-Item -LiteralPath $PartialFilePath; Assert {$SourceFile.Length -eq $PartialFile.Length} "Source and partial file have not the same size!";}

# Fetching badblocks.xml from $PartialFile
if ($PartialFilePath) {
	if (Test-Path ($PartialFile.DirectoryName + '\' + $PartialFile.BaseName + '.badblocks.xml')) {
		$PartialFileBadBlocks = Import-Clixml -Path ($PartialFile.DirectoryName + '\' + $PartialFile.BaseName + '.badblocks.xml');
		Write-Host "Badblocks.xml successfully imported." -ForegroundColor "Green";
		Assert {($PartialFileBadBlocks | Measure-Object -Average -Property Size).Average -eq $BufferSize } "Block sizes do not match between source and partial file. Can not continue." # This is currently an implementation shortcomming.
	} else {
		Write-Host "Partial file specified, but no badblocks.xml exists: partial file will be copied and nothing will be read from source file." -ForegroundColor "Yellow";
	}
}

# Making buffer
$Buffer = New-Object -TypeName System.Byte[] -ArgumentList $BufferSize;

# Making container for storing missread offsets.
$UnreadableBlocks = @();

# Making filestreams
$SourceStream = $SourceFile.OpenRead();
$DestinationStream = $DestinationFile.OpenWrite();
if ($PartialFilePath) {$PartialStream = $PartialFile.OpenRead();}

if ($PositionEnd -le -1) {$PositionEnd = $SourceStream.Length}

# Copying starts here
Write-Host "Starting copying of $SourceFilePath..." -ForegroundColor "Green";

[bool] $ReadSuccessful = $false;

while ($Position -lt $PositionEnd) {

	if ($PartialFilePath -and
		-not ($PositionMarkedAsBad = $PartialFileBadBlocks | % {if (($_.Offset -le $Position) -and ($Position -lt ($_.Offset + $_.Size))) {$true;}})) {
			
			if (($DestinationStream.Position -eq 0) -or $LastReadFromSource) {Write-Host "Started reading from partial file at offset $Position." -ForegroundColor "DarkGreen";}
			$LastReadFromSource = $false;
			
			# Read a block from partial file
			$ReadLength = Force-Read -Stream $PartialStream -Position $Position -Buffer ([ref] $Buffer) -Successful ([ref] $ReadSuccessful) -MaxRetries 0;
			
			assert $ReadSuccessful "Could not read byte $Position from partial file.";
			
	} else {
	
			if (($DestinationStream.Position -eq 0) -or -not $LastReadFromSource) {Write-Host "Started reading from source file at offset $Position." -ForegroundColor "DarkRed";}
			$LastReadFromSource = $true;

			# Force read a block from source
			$ReadLength = Force-Read -Stream $SourceStream -Position $Position -Buffer ([ref] $Buffer) -Successful ([ref] $ReadSuccessful) -MaxRetries $MaxRetries;		
	
	}
	
	if (-not $ReadSuccessful) {
		$UnreadableBlocks += New-Block -OffSet $Position -Size $ReadLength;
	}
	
	# Write to destination file.
	$DestinationStream.Position = $Position;
	$DestinationStream.Write($Buffer, 0, $ReadLength);
    # Write-Progress -Activity "Hashing File" -Status $file -percentComplete ($total/$fd.length * 100)
	
	$Position += $ReadLength; # adjust position
}

$SourceStream.Dispose();
$DestinationStream.Dispose();
if ($PartialFilePath) {$PartialStream.Dispose();}

if ($UnreadableBlocks) {
	
	# Define local variables
	$UnreadableBytes = ($UnreadableBlocks | Measure-Object -Sum -Property Size).Sum;
	$DestinationPathWithBadBlocks = $DestinationFile.DirectoryName + '\' + $DestinationFile.BaseName + '_' + $UnreadableBytes + 'badbytes';
	
	Write-Host "$UnreadableBytes bytes are bad." -ForegroundColor "Magenta";
		
	# Rename the file so one knows there is bad data.
	while ((Test-Path -LiteralPath ($TmpPath = $DestinationPathWithBadBlocks + ($suffix = if($i++) {"_$i"}) + $DestinationFile.Extension))) {}
	$DestinationFile.MoveTo($DestinationPathWithBadBlocks + $suffix + $DestinationFile.Extension);
	
	# Export bad blocks.
	Export-Clixml -Path ($DestinationPathWithBadBlocks + $suffix + '.badblocks.xml') -InputObject $UnreadableBlocks;
}

# Set creation and modification times
$DestinationFile.CreationTimeUtc = $SourceFile.CreationTimeUtc;
$DestinationFile.LastWriteTimeUtc = $SourceFile.LastWriteTimeUtc;
$DestinationFile.IsReadOnly = $SourceFile.IsReadOnly;

Write-Host "Finished copying $SourceFilePath!" -ForegroundColor "Green";

