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
   [string][ValidateScript({ -not (Test-Path -LiteralPath $_) })]$DestinationFilePath,
   [Parameter(Mandatory=$false,
			  ValueFromPipeline=$false,
			  HelpMessage="Buffer size in bytes.")]
   [int32]$BufferSize=512*2*2*2, # 4096: the default windows cluster size.
   [Parameter(Mandatory=$false,
			  ValueFromPipeline=$false,
			  HelpMessage="Amount of tries.")]
   [int16]$MaxRetries=0
)

Write-Host "Starting copy of $SourceFilePath..." -ForegroundColor "Green";

# Making buffer
$Buffer = New-Object -TypeName System.Byte[] -ArgumentList $BufferSize;
$FailCounter = 0;

# Making container for storing missread offsets.
$UnreadableBlocks = @();
function New-Block() { 
	param ([int64] $OffSet, [int32] $Size)
	  
	$block = new-object PSObject

	Add-Member -InputObject $block -MemberType NoteProperty -Name "OffSet" -Value $OffSet;
	Add-Member -InputObject $block -MemberType NoteProperty -Name "Size" -Value $Size;
	  
	return $block;
}


# Fetching source and destination files.
$SourceFile = Get-Item -LiteralPath $SourceFilePath;
$DestinationFile = New-Object System.IO.FileInfo ($DestinationFilePath);

if (-not (Test-Path -LiteralPath ($DestinationParentFilePath = Split-Path -Path $DestinationFilePath -Parent) -PathType Container)) {
	New-Item -ItemType Directory -Path $DestinationParentFilePath | Out-Null;
}

$SourceStream = $SourceFile.OpenRead();
$DestinationStream = $DestinationFile.OpenWrite();

# Copying starts here
while ($SourceStream.Position -lt $SourceStream.Length) {
	try {
		
		$ReadLength = $SourceStream.Read($Buffer, 0, $Buffer.length);
		# If the read operation is successful, the current position of the stream is advanced by the number of bytes read. If an exception occurs, the current position of the stream is unchanged. (http://msdn.microsoft.com/en-us/library/system.io.filestream.read.aspx)
		
	} catch [System.IO.IOException] {
		
		$ShouldHaveReadSize = [math]::Min([int64] $BufferSize, ($SourceStream.Length - $SourceStream.Position));
		
		if (++$FailCounter -le $MaxRetries) { # Retry to read block 
		
			Write-Host $FailCounter"th retry to read "$ShouldHaveReadSize" bytes starting at "$($SourceStream.Position)" bytes." -ForegroundColor "DarkYellow";
			Write-Debug "Debugging read retry...";
			
			continue;
		
		} else { # Failed read of block.
		
			$FailCounter = 0; # reset fail counter;
			
			Write-Host "Can not read"$ShouldHaveReadSize" bytes starting at "$($SourceStream.Position)" bytes: "$($_.Exception.message) -ForegroundColor "DarkRed";
			Write-Debug "Debugging read failure...";
		
			$DestinationStream.Write((New-Object System.Byte[] ($BufferSize)), 0, $ShouldHaveReadSize);
		
			$UnreadableBlocks += New-Block -OffSet $SourceStream.Position -Size $ShouldHaveReadSize;

			$SourceStream.Position = $SourceStream.Position + $ShouldHaveReadSize;
		
			continue;
		
		}
		
	} catch {
	
		Write-Warning "Unhandled error at $($SourceStream.position) bit: $($_.Exception.message)";
		Write-Debug "Unhandled error. You should debug."; 
		
		throw $_;
	
	}

	# Read block successful
	if ($FailCounter -gt 0) { # There were prior read failures
		$FailCounter= 0; # reset fail counter;
		Write-Host "Successfully read"$ReadLength" bytes starting at "$($SourceStream.Position - $ReadLength)" bytes." -ForegroundColor "DarkGreen";
	}
	
	
	$DestinationStream.Write($Buffer, 0, $ReadLength);
    # Write-Progress -Activity "Hashing File" -Status $file -percentComplete ($total/$fd.length * 100)
}

$SourceStream.Dispose();
$DestinationStream.Dispose();

if ($UnreadableBlocks) {
	
	# Define local variables
	$UnreadableBytes = ($UnreadableBlocks | Measure-Object -Sum -Property Size).Sum;
	$DestinationPathWithBadBlocks = $DestinationFile.DirectoryName + '\' + $DestinationFile.BaseName + '_' + $UnreadableBytes + 'badbytes';
	
	Write-Host "$UnreadableBytes bytes are bad." -ForegroundColor "Magenta";
		
	# Rename the file so one knows there is bad data.
	$DestinationFile.MoveTo($DestinationPathWithBadBlocks + $DestinationFile.Extension);
	
	# Export bad blocks.
	Export-Clixml -Path ($DestinationPathWithBadBlocks + '.xml') -InputObject $UnreadableBlocks;
}

# Set creation and modification times
$DestinationFile.CreationTimeUtc = $SourceFile.CreationTimeUtc;
$DestinationFile.LastWriteTimeUtc = $SourceFile.LastWriteTimeUtc;
$DestinationFile.IsReadOnly = $SourceFile.IsReadOnly;

Write-Host "Finished copying $SourceFilePath!" -ForegroundColor "Green";

