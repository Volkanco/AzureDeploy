param
(
[Parameter(Mandatory=$false)] [bool] $collectqueryperf=$false,
[Parameter(Mandatory=$false)] [bool] $collecttableinv=$false,
[Parameter(Mandatory=$true)] [string] $configfolder 
)


#Write-Output "RB Initial   : $([System.gc]::gettotalmemory('forcefullcollection') /1MB) MB" 

#region Variables definition
# Common  variables  accross solution 

$StartTime = [dateTime]::Now

#will use exact time for all inventory 
$timestamp=$StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:00.000Z")


#Update customer Id to your Operational Insights workspace ID
$customerID = Get-AutomationVariable -Name 'AzureHANAMonitor_WS_ID'
Write-output "target workspace id :$customerID"
#For shared key use either the primary or seconday Connected Sources client authentication key   
$sharedKey = Get-AutomationVariable -Name 'AzureHANAMonitor_WS_KEY'


$rbworkername=$env:COMPUTERNAME
# Automation Account and Resource group for automation

#$AAAccount = Get-AutomationVariable -Name 'AzureHANAMonitor-AzureAutomationAccount-MS-Mgmt'

#$AAResourceGroup = Get-AutomationVariable -Name 'AzureHANAMonitor-AzureAutomationResourceGroup-MS-Mgmt'

# OMS log analytics custom log name
$logname='SAPHana'
$Starttimer=get-date

# Hana Client Dll

$sapdll="Sap.Data.Hana.v4.5.dll" 

#endregion

#region Define Required Functions

# Create the function to create the authorization signature
Function Build-OMSSignature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
{
	$xHeaders = "x-ms-date:" + $date
	$stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
	$bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
	$keyBytes = [Convert]::FromBase64String($sharedKey)
	$sha256 = New-Object System.Security.Cryptography.HMACSHA256
	$sha256.Key = $keyBytes
	$calculatedHash = $sha256.ComputeHash($bytesToHash)
	$encodedHash = [Convert]::ToBase64String($calculatedHash)
	$authorization = 'SharedKey {0}:{1}' -f $customerId,$encodedHash
	return $authorization
}
# Create the function to create and post the request
Function Post-OMSData($customerId, $sharedKey, $body, $logType)
{


	#usage     $post=$null; $post=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
	$method = "POST"
	$contentType = "application/json"
	$resource = "/api/logs"
	$rfc1123date = [DateTime]::UtcNow.ToString("r")
	$contentLength = $body.Length
	$signature = Build-OMSSignature `
	-customerId $customerId `
	-sharedKey $sharedKey `
	-date $rfc1123date `
	-contentLength $contentLength `
	-fileName $fileName `
	-method $method `
	-contentType $contentType `
	-resource $resource
	
    [string]$uriadr = "https://{0}.ods.opinsights.azure.com{1}?api-version=2016-04-01" -f [string]$customerId,[string]$resource 
    $uri1=[System.Uri]$uriadr

	$OMSheaders = @{
		"Authorization" = $signature;
		"Log-Type" = $logType;
		"x-ms-date" = $rfc1123date;
		"time-generated-field" = $TimeStampField;
	}

	Try{
		$response = Invoke-WebRequest -Uri $uri1 -Method POST  -ContentType $contentType -Headers $OMSheaders -Body $body -UseBasicParsing
	}catch [Net.WebException] 
	{
		$ex=$_.Exception
		If ($_.Exception.Response.StatusCode.value__) {
			$exrespcode = ($_.Exception.Response.StatusCode.value__ ).ToString().Trim();
			#Write-Output $crap;
		}
		If  ($_.Exception.Message) {
			$exMessage = ($_.Exception.Message).ToString().Trim();
			#Write-Output $crapMessage;
		}
		$errmsg= "$exrespcode : $exMessage"
	}

	if ($errmsg){return $errmsg }
	Else{	return $response.StatusCode }
	#write-output $response.StatusCode
	Write-error $error[0]
}

#endregion

#region  load Hana hdbclient and config file
#$sapdll="C:\Program Files\sap\hdbclient\ado.net\v4.5\Sap.Data.Hana.v4.5.dll"  #add this as param 
$dllcol=@()
$dllcol+=Get-ChildItem -Path $env:ProgramFiles  -Filter $sapdll -Recurse -ErrorAction SilentlyContinue -Force

If([string]::IsNullOrEmpty($dllcol[0])) # Hana Client dll not found , will do a wider search
{
$folderlist=@()
$folderlist+="C:\Program Files"
$folderlist+="D:\Program Files"
$folderlist+="E:\Program Files"
$folderlist+=$configfolder 

	
	Foreach($Folder in $folderlist)
	{
		$dllcol+=Get-ChildItem -Path $Folder   -Filter $sapdll -Recurse -ErrorAction SilentlyContinue -Force
	}

}

If([string]::IsNullOrEmpty($dllcol[0]))
{
	Write-Error " Hana client Dll not found , Please install x64 HDBClient for Windows on the Hybrid Rb Worker :$rbworkername"
	Exit

}ELSE
{

#Add-type -Path $sapdll
	[reflection.assembly]::LoadWithPartialName( "Sap.Data.Hana" )|out-null
	[System.Reflection.Assembly]::LoadFrom($dllcol[0])|out-null
}


$configfile=$configfolder+"\hanaconfig.xml"

[xml]$hanaconfig=Get-Content $configfile

If([string]::IsNullOrEmpty($hanaconfig))
{
	Write-Error " Hana config xml not found under $configfolder!Please duplicate config template and name it as hanaconfig.xml under $configfolder"
	Exit
}else
{

$Timestampfield = "SYS_TIMESTAMP"  #check this as this needs to be in UTC 
$ex=$null
#$freq=15

	$start=get-date
	$nextstart=$start.AddMinutes($freq)

	Foreach($ins in $hanaconfig.HanaConnections.Rule)
	{
		$colstart=get-date
		$Omsupload=@()
		$OmsPerfupload=@()
		$OmsInvupload=@()
		$OmsStateupload=@()
		$saphost=$ins.'hanaserver'
		$sapport=$ins.'port'
		$user=Get-AutomationVariable -Name "AzureHanaMonitorUser_$($ins.UserAsset)"
		$password= Get-AutomationVariable -Name "AzureHanaMonitorPwd_$($ins.UserAsset)"

		$constring="Server={0}:{1};Database={2};UserID={3};Password={4}" -f $ins.HanaServer,$ins.Port,$ins.Database,$user,$password
		$conn=$null
		$conn = new-object Sap.Data.Hana.HanaConnection($constring);
		$ex=$null

		Try
		{
			$conn.open()
		}
		Catch
		{
			$Ex=$_.Exception.MEssage
		}
		
		IF($ex)
		{
			write-warning $ex
			$omsStateupload+= @(New-Object PSObject -Property @{
				HOST=$saphost
                PORT=$sapport
				CollectorType="State"
				Category="Connectivity"
				SubCategory="Host"
				Connection="Failed"
				ErrorMessage=$ex
			}
			)
		}
		
		IF ($conn.State -eq 'open')
		{	    
			
            Write-Output "Succesfully connected to $($ins.HanaServer):$($ins.Port)"
            $Omsstateupload+=, @(New-Object PSObject -Property @{
				HOST=$saphost
                 PORT=$sapport
				CollectorType="State"
				Category="Connectivity"
				SubCategory="Host"
				Connection="Successful"
				
				}
			)

			#define all queries in a variable and loop them, this can be exported to an external file part of the config 
			
			$hanaQueries=@()
			$hanaQueries+=New-Object PSObject -Property @{
				SqlQuery='SELECT * FROM SYS.M_HOST_INFORMATION'
				QueryType=''
				VersionRestriction=''
				SelectedFileds=''
				Description='HOST_INFORMATION'
				ColType='Inventory'
			}
			
			#region Collect instance data and databases 
			$query='SELECT * FROM SYS.M_HOST_INFORMATION'
					$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
			$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
			}
			      

			
			$Results=$null
			$Results=@(); 

			#Host Inventory 
			Write-Output ' CollectorType="Inventory" , Category="HostInfo"'

			$cu=New-Object PSObject -Property @{
				HOST=$saphost
				CollectorType="Inventory"
				Category="HostInfo"
			}

			$rowcount=1
			foreach($row in $ds.Tables[0].rows)
			{
				if ($row.key -notin ('net_nameserver_bindings','build_githash','ssfs_masterkey_changed','crypto_fips_version','crypto_provider','ssfs_masterkey_systempki_changed','crypto_provider_version'))
				{
					$cu|Add-Member -MemberType NoteProperty -Name $row.key  -Value $row.VALUE
					$Rowcount++
					If ($rowcount -gt 48   ){Break}

				}

			}


			$OmsInvupload+=@($cu)

			$sapinstance=$cu.sid+'-'+$cu.sapsystem
			$sapversion=$cu.build_version  #use build versionto decide which query to run

			$cu=$null

			$query="SELECT * from  SYS.M_SYSTEM_OVERVIEW"
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
			$cmd.fill($ds)

			$Resultsinv=$null
			$Resultsinv=@(); 
			$Resultsstate=$null
			$Resultsstate=@(); 

			Write-Output 'CollectorType="Status" -   Category="Host"'
			$resultsinv+= New-Object PSObject -Property @{
				HOST=$row.HOST
				Instance=$sapinstance
				CollectorType="Inventory"
				Category="Host"
				SubCategory="Startup"
				SECTION="SYSTEM"
				'Instance ID'=($ds.Tables[0].rows|where{$_.Name  -eq 'Instance ID'}).Value
				'Instance Number'=($ds.Tables[0].rows|where{$_.Name  -eq 'Instance Number'}).Value
				'Distributed'=($ds.Tables[0].rows|where{$_.Name  -eq 'Distributed'}).Value
				'Version'=($ds.Tables[0].rows|where{$_.Name  -eq 'Version'}).Value
				'MinStartTime'=($ds.Tables[0].rows|where{$_.Name  -eq 'Min Start Time'}).Value
				'MaxStartTime'=($ds.Tables[0].rows|where{$_.Name  -eq 'Max Start Time'}).Value
			}

			$resultsstate+= New-Object PSObject -Property @{
				HOST=$row.HOST
				Instance=$sapinstance
				CollectorType="State"
				Category="Host"
				SubCategory="Startup"
				SECTION="SYSTEM"
				'Instance ID'=($ds.Tables[0].rows|where{$_.Name  -eq 'Instance ID'}).Value
				'Instance Number'=($ds.Tables[0].rows|where{$_.Name  -eq 'Instance Number'}).Value
				'All Started'=($ds.Tables[0].rows|where{$_.Name  -eq 'All Started'}).Status
				'Memory'=($ds.Tables[0].rows|where{$_.Name  -eq 'Memory'}).Status
				'CPU'=($ds.Tables[0].rows|where{$_.Name  -eq 'CPU'}).Status
				'DISKDATA'=($ds.Tables[0].rows|where{$_.Name  -eq 'DATA'}).Status
				'DISKLOG'=($ds.Tables[0].rows|where{$_.Name  -eq 'Log'}).Status
				'DISKTRACE'=($ds.Tables[0].rows|where{$_.Name  -eq 'Trace'}).Status
			}

			$Omsinvupload+=,$Resultsinv
			$Omsstateupload+=,$Resultsstate


			$query='Select * from SYS_Databases.M_Services'
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
			}
			      

			$Results=$null
			$Resultsinv=@(); 
			$Resultsstate=@(); 

			Write-Output ' CollectorType="Inventory" ,  Category="DatabaseState"'

			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv+= New-Object PSObject -Property @{
					HOST=$row.Host
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="Database"
					Database=$row.DATABASE_NAME
					SERVICE_NAME=$row.SERVICE_NAME
					PROCESS_ID=$row.PROCESS_ID
					DETAIL=$row.Detail
					SQL_PORT=$row.SQL_PORT
					COORDINATOR_TYPE=$row.COORDINATOR_TYPE
			
				}
				$resultsstate+= New-Object PSObject -Property @{
					CollectorType="State"
					Category="Database"
					Database=$row.DATABASE_NAME
					SERVICE_NAME=$row.SERVICE_NAME
					PROCESS_ID=$row.PROCESS_ID
					ACTIVE_STATUS=$row.ACTIVE_STATUS 
				}
			}

			$Omsinvupload+=,$Resultsinv
			$Omsstateupload+=,$Resultsstate

#get USer DB list 
			$UserDBs=@($resultsinv|where{[String]::IsNullOrEmpty($_.Database) -ne $true -and $_.SQL_PORT -ne 0 -and $_.Database -ne 'SYSTEMDB'}|select DATABASE,SQL_Port)

			$UserDBs

#endregion


#region inventory collection

			$query='SELECT * FROM SYS.M_DATABASE'
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
			}
			 
			$Resultsinv=$null
			$Resultsinv=@(); 


			Write-Output ' CollectorType="Inventory" ,  Category="DatabaseInfo"'

			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv+= New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="Database"
					SYSTEM_ID=$row.SYSTEM_ID
					Database=$row.DATABASE_NAME
					START_TIME=$row.START_TIME
					VERSION=$row.VERSION
					USAGE=$row.USAGE

				}
			}

			$Omsinvupload+=,$Resultsinv

			$query="SELECT * FROM SYS.M_SERVICES"
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
			}
			 
			$Resultsinv=$null
			$Resultsinv=@(); 

			Write-Output 'CollectorType="Inventory" -   Category="Services"'

			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv+= New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="Services"
					PORT=$row.PORT
					SERVICE_NAME=$row.SERVICE_NAME
					PROCESS_ID=$row.PROCESS_ID
					DETAIL=$row.DETAIL
					ACTIVE_STATUS=$row.ACTIVE_STATUS
					SQL_PORT=$row.SQL_PORT
					COORDINATOR_TYPE=$row.COORDINATOR_TYPE
				}

				$OmsStateupload+= New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="State"
					Category="Services"
					PORT=$row.PORT
					SERVICE_NAME=$row.SERVICE_NAME
					PROCESS_ID=$row.PROCESS_ID
					ACTIVE_STATUS=$row.ACTIVE_STATUS
					
				}
			}

			$Omsinvupload+=,$Resultsinv



			$query="SELECT * from SYS.M_HOST_RESOURCE_UTILIZATION"
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
                
			
			} 

			$Resultsperf=$null
			$Resultsperf=@(); 

#this is used to calculate UTC time conversion in data collection 
			$utcdiff=NEW-TIMESPAN –Start $ds[0].Tables[0].rows[0].UTC_TIMESTAMP  –End $ds[0].Tables[0].rows[0].SYS_TIMESTAMP 


			Write-Output '  CollectorType="Performance" - Category="Host" - Subcategory="OverallUsage" '

			$Resultsperf=$null
			$Resultsperf=@(); 
			foreach ($row in $ds.Tables[0].rows)
			{
				

				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="FREE_PHYSICAL_MEMORY"
					PerfInstance=$row.HOST
					PerfValue=$row.FREE_PHYSICAL_MEMORY/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
					
				}

				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="USED_PHYSICAL_MEMORY"
					PerfInstance=$row.HOST
					PerfValue=$row.USED_PHYSICAL_MEMORY/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}
				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="FREE_SWAP_SPACE"
					PerfInstance=$row.HOST
					PerfValue=$row.FREE_SWAP_SPACE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}

				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="USED_SWAP_SPACE"
					PerfInstance=$row.HOST
					PerfValue=$row.USED_SWAP_SPACE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}
				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="ALLOCATION_LIMIT"
					PerfInstance=$row.HOST
					PerfValue=$row.ALLOCATION_LIMIT/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}

				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="INSTANCE_TOTAL_MEMORY_USED_SIZE"
					PerfInstance=$row.HOST
					PerfValue=$row.INSTANCE_TOTAL_MEMORY_USED_SIZE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}
				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="INSTANCE_TOTAL_MEMORY_PEAK_USED_SIZE"
					PerfInstance=$row.HOST
					PerfValue=$row.INSTANCE_TOTAL_MEMORY_PEAK_USED_SIZE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}

				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="INSTANCE_TOTAL_MEMORY_ALLOCATED_SIZE"
					PerfInstance=$row.HOST
					PerfValue=$row.INSTANCE_TOTAL_MEMORY_ALLOCATED_SIZE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}

				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="INSTANCE_CODE_SIZE"
					PerfInstance=$row.HOST
					PerfValue=$row.INSTANCE_CODE_SIZE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}
				
				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="INSTANCE_SHARED_MEMORY_ALLOCATED_SIZE"
					PerfInstance=$row.HOST
					PerfValue=$row.INSTANCE_SHARED_MEMORY_ALLOCATED_SIZE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}
				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="TOTAL_CPU_USER_TIME"
					PerfInstance=$row.HOST
					PerfValue=$row.TOTAL_CPU_USER_TIME
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}
				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="TOTAL_CPU_SYSTEM_TIME"
					PerfInstance=$row.HOST
					PerfValue=$row.TOTAL_CPU_SYSTEM_TIME
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}
				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="TOTAL_CPU_WIO_TIME"
					PerfInstance=$row.HOST
					PerfValue=$row.TOTAL_CPU_WIO_TIME
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}
				$Resultsperf+=New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="TOTAL_CPU_IDLE_TIME"
					PerfInstance=$row.HOST
					PerfValue=$row.TOTAL_CPU_IDLE_TIME
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				}



			}


			$Omsperfupload+=,$Resultsperf


#CollectorType="Inventory" or "Performance"


			$query="SELECT * FROM SYS.M_BACKUP_CATALOG where SYS_START_TIME    > add_seconds(now(),-$($freq*60))"
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 
			$Resultsinv=$null
			$Resultsinv=@(); 


			Write-Output ' CollectorType="Inventory" ,  Category="BAckupCatalog"'
			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv+= New-Object PSObject -Property @{
					Hostname=$saphost
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="BackupCatalog"
					Database=$defaultdb                   
					ENTRY_ID=$row.ENTRY_ID
					ENTRY_TYPE_NAME=$row.ENTRY_TYPE_NAME
					BACKUP_ID=$row.BACKUP_ID
					SYS_START_TIME=$row.SYS_START_TIME
					UTC_START_TIME=$row.UTC_START_TIME
					SYS_END_TIME=$row.SYS_END_TIME
					UTC_END_TIME=$row.UTC_END_TIME
					STATE_NAME=$row.STATE_NAME
					COMMENT=$row.COMMENT
					MESSAGE=$row.MESSAGE
					SYSTEM_ID=$row.SYSTEM_ID
					ENCRYPTION_ROOT_KEY_HASH=$row.ENCRYPTION_ROOT_KEY_HASH 
					SOURCE_DATABASE_NAME=$row.SOURCE_DATABASE_NAME


				}
			}

			$Omsinvupload+=,$Resultsinv



			$query='SELECT * FROM SYS.M_BACKUP_SIZE_ESTIMATIONS'
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsinv=$null
			$Resultsinv=@(); 


			Write-Output ' CollectorType="Inventory" ,  Category="Backup"'

			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv+= New-Object PSObject -Property @{
					HOST=$saphost
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="Backup"
					Database=$defaultdb
					PORT=$row.PORT
					SERVICE_NAME=$row.SERVICE_NAME 
					ENTRY_TYPE_NAME=$row.ENTRY_TYPE_NAME
					ESTIMATED_SIZE=$row.ESTIMATED_SIZE/1024/1024


				}
			}

			$Omsinvupload+=,$Resultsinv




			$query='SELECT * FROM SYS.M_DATA_VOLUMES'
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsinv=$null
			$Resultsinv=@(); 


			Write-Output ' CollectorType="Inventory" ,  Category="Volumes"'
			foreach ($row in $ds.Tables[0].rows)
			{
				$Resultsinv+= New-Object PSObject -Property @{
					HOST=$row.HOST.tolower() 
					Instance=$sapinstance                  
					CollectorType="Inventory"
					Category="Volumes"
					PORT=$row.PORT
					PARTITION_ID=$row.PARTITION_ID
					VOLUME_ID=$row.VOLUME_ID
					FILE_NAME=$row.FILE_NAME
					FILE_ID=$row.FILE_ID
					STATE=$row.STATE
					SIZE=$row.SIZE
					MAX_SIZE=$row.MAX_SIZE

				}
			}

			$Omsinvupload+=,$Resultsinv



			$query='SELECT * FROM SYS.M_DISKS'
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsinv=$null
			$Resultsinv=@(); 


			Write-Output 'CollectorType="Inventory" -   Category="Disk"'
			foreach ($row in $ds.Tables[0].rows)
			{
				
				$Resultsinv+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="Disks"
					DISK_ID=$row.DISK_ID
					DEVICE_ID=$row.DEVICE_ID
					PATH=$row.PATH
					SUBPATH=$row.SUBPATH
					FILESYSTEM_TYPE=$row.FILESYSTEM_TYPE
					USAGE_TYPE=$row.USAGE_TYPE
					TOTAL_SIZE=$row.TOTAL_SIZE/1024/1024/1024
					USED_SIZE=$row.USED_SIZE/1024/1024/1024

				}
			}

			$Omsinvupload+=,$Resultsinv


			$query='SELECT * FROM SYS.M_DISK_USAGE'
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			$Resultsperf=@(); 


			Write-Output 'CollectorType="Performance" -   Category="DiskUsage"'
			foreach ($row in $ds.Tables[0].rows)
			{
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="Disk"
					PerfCounter="USED_SIZE"
					PerfInstance=$defaultdb
					USAGE_TYPE=$row.USAGE_TYPE 
					PerfValue=$row.USED_SIZE
				}
			}

			$Omsperfupload+=,$Resultsperf



			$query="SELECT * FROM SYS.M_LICENSE"
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsinv=$null
			$Resultsinv=@(); 


			Write-Output 'CollectorType="Inventory" -   Category="License"'
			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv+= New-Object PSObject -Property @{
					HOST=$saphost
					CollectorType="Inventory"
					Category="License"
					HARDWARE_KEY=$row.HARDWARE_KEY
					SYSTEM_ID=$row.SYSTEM_ID
					INSTALL_NO=$row.INSTALL_NO
					SYSTEM_NO=$row.SYSTEM_NO
					PRODUCT_NAME=$row.PRODUCT_NAME
					PRODUCT_LIMIT=$row.PRODUCT_LIMIT
					PRODUCT_USAGE=$row.PRODUCT_USAGE
					START_DATE=$row.START_DATE
					EXPIRATION_DATE=$row.EXPIRATION_DATE
					LAST_SUCCESSFUL_CHECK=$row.LAST_SUCCESSFUL_CHECK
					PERMANENT=$row.PERMANENT
					VALID=$row.VALID
					ENFORCED=$row.ENFORCED
					LOCKED_DOWN=$row.LOCKED_DOWN
					IS_DATABASE_LOCAL=$row.IS_DATABASE_LOCAL
					MEASUREMENT_XML=$row.MEASUREMENT_XML

				}
			}

			$Omsinvupload+=,$Resultsinv





if($collecttableinv -and (get-date).Minute -lt 15)
{
			$query='Select Host,Port,Loaded,TABLE_NAME,RECORD_COUNT,RAW_RECORD_COUNT_IN_DELTA,MEMORY_SIZE_IN_TOTAL,MEMORY_SIZE_IN_MAIN,MEMORY_SIZE_IN_DELTA 
from M_CS_TABLES'

			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsinv=$null
			$Resultsinv=@(); 

### check if needed returns 111835 tables

			Write-Output 'CollectorType="Inventory" -   Category="Tables"'

			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv+= New-Object PSObject -Property @{
					HOST=$row.HOST.ToLower()
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="Tables"
					Database=$defaultdb
					PORT=$row.PORT
					LOADED=$row.LOADED
					TABLE_NAME=$row.TABLE_NAME
					RECORD_COUNT=$row.RECORD_COUNT
					RAW_RECORD_COUNT_IN_DELTA=$row.RAW_RECORD_COUNT_IN_DELTA
					MEMORY_SIZE_IN_TOTAL_MB=$row.MEMORY_SIZE_IN_TOTAL/1024/1024
					MEMORY_SIZE_IN_MAIN_MB=$row.MEMORY_SIZE_IN_MAIN/1024/1024
					MEMORY_SIZE_IN_DELTA_MB=$row.MEMORY_SIZE_IN_DELTA/1024/1024
				}
			}

			$Omsinvupload+=,$Resultsinv

}

			$Resultsinv=$null
			$Resultsinv=@(); 

			Write-Output 'CollectorType="Inventory" -   Category="Alerts"'

			$Query='Select * from _SYS_STATISTICS.Statistics_Current_Alerts'
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 


			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv+= New-Object PSObject -Property @{
					HOST=$row.ALERT_HOST
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="Alerts"
					Database=$defaultdb
					ALERT_ID=$row.ALERT_ID
					INDEX=$row.INDEX
					ALERT_HOST=$row.ALERT_HOST
					ALERT_PORT=$row.ALERT_PORT
					SNAPSHOT_ID=$row.SNAPSHOT_ID
					ALERT_DESCRIPTION=$row.ALERT_DESCRIPTION
					ALERT_DETAILS=$row.ALERT_DETAILS
					ALERT_NAME=$row.ALERT_NAME
					ALERT_RATING=$row.ALERT_RATING
					ALERT_TIMESTAMP=$row.ALERT_TIMESTAMP
					ALERT_USERACTION=$row.ALERT_USERACTION
					SCHEDULE=$row.SCHEDULE
				}
			}

			$Omsinvupload+=,$Resultsinv


#endregion




#region PErformance collection
# Service CPU 


			$query='Select * from SYS.M_Service_statistics'
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 
			$Resultsperf=$null
			$Resultsperf=@(); 

			Write-Output '  CollectorType="Performance" - Category="Host" - Subcategory="OverallUsage" '
			IF($ds.Tables[0].rows)
			{
				foreach ($row in $ds.Tables[0].rows)
				{
					
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="PROCESS_MEMORY_GB"
						PerfValue=$row.PROCESS_MEMORY_GB/1024/1024/1024
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="ACTIVE_REQUEST_COUNT"
						PerfValue=$row.ACTIVE_REQUEST_COUNT
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="TOTAL_CPU"
						PerfValue=$row.TOTAL_CPU
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="PROCESS_CPU_TIME"
						PerfValue=$row.PROCESS_CPU_TIME
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="PHYSICAL_MEMORY_GB"
						PerfValue=$row.PHYSICAL_MEMORY_GB/1024/1024/1024
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="OPEN_FILE_COUNT"
						PerfValue=$row.OPEN_FILE_COUNT
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="PROCESS_PHYSICAL_MEMORY_GB"
						PerfValue=$row.PROCESS_PHYSICAL_MEMORY_GB/1024/1024/1024
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="TOTAL_CPU_TIME"
						PerfValue=$row.TOTAL_CPU_TIME
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="ACTIVE_THREAD_COUNT"
						PerfValue=$row.ACTIVE_THREAD_COUNT
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="FINISHED_NON_INTERNAL_REQUEST_COUNT"
						PerfValue=$row.FINISHED_NON_INTERNAL_REQUEST_COUNT
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="PROCESS_CPU"
						PerfValue=$row.PROCESS_CPU
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="ALL_FINISHED_REQUEST_COUNT"
						PerfValue=$row.ALL_FINISHED_REQUEST_COUNT
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="REQUESTS_PER_SEC"
						PerfValue=$row.REQUESTS_PER_SEC
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="AVAILABLE_MEMORY_GB"
						PerfValue=$row.AVAILABLE_MEMORY_GB/1024/1024/1024
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="THREAD_COUNT"
						PerfValue=$row.THREAD_COUNT
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="TOTAL_MEMORY_GB"
						PerfValue=$row.TOTAL_MEMORY_GB/1024/1024/1024
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="RESPONSE_TIME"
						PerfValue=$row.RESPONSE_TIME
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="PENDING_REQUEST_COUNT"
						PerfValue=$row.PENDING_REQUEST_COUNT
					}
				}

			}

			$Omsperfupload+=,$Resultsperf

#Updated CPU statictics collection 


			$query="SELECT SAMPLE_TIME,HOST,
LPAD(ROUND(CPU_PCT), 7) CPU_PCT,
LPAD(TO_DECIMAL(USED_MEM_GB, 10, 2), 11) USED_MEM_GB,
LPAD(ROUND(USED_MEM_PCT), 7) MEM_PCT,
LPAD(TO_DECIMAL(NETWORK_IN_MB, 10, 2), 13) NETWORK_IN_MB,
LPAD(TO_DECIMAL(NETWORK_OUT_MB, 10, 2), 14) NETWORK_OUT_MB,
LPAD(TO_DECIMAL(SWAP_IN_MB, 10, 2), 10) SWAP_IN_MB,
LPAD(TO_DECIMAL(SWAP_OUT_MB, 10, 2), 11) SWAP_OUT_MB
FROM
( SELECT
	SAMPLE_TIME,
	CASE WHEN AGGREGATE_BY = 'NONE' OR INSTR(AGGREGATE_BY, 'HOST') != 0 THEN HOST ELSE MAP(BI_HOST, '%', 'any', BI_HOST) END HOST,
	AVG(CPU_PCT) CPU_PCT,
	SUM(USED_MEM_GB) USED_MEM_GB,
	MAP(SUM(TOTAL_MEM_GB), 0, 0, SUM(USED_MEM_GB) / SUM(TOTAL_MEM_GB) * 100) USED_MEM_PCT,
	SUM(USED_DISK_GB) USED_DISK_GB,
	MAP(SUM(TOTAL_DISK_GB), 0, 0, SUM(USED_DISK_GB) / SUM(TOTAL_DISK_GB) * 100) USED_DISK_PCT,
	SUM(NETWORK_IN_MB) NETWORK_IN_MB,
	SUM(NETWORK_OUT_MB) NETWORK_OUT_MB,
	SUM(SWAP_IN_MB) SWAP_IN_MB,
	SUM(SWAP_OUT_MB) SWAP_OUT_MB
FROM
( SELECT
	CASE 
		WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
		CASE 
			WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
			TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 
			'YYYY/MM/DD HH24:MI:SS'), L.TIME) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
			ELSE TO_VARCHAR(L.TIME, BI.TIME_AGGREGATE_BY)
		END
		ELSE 'any' 
	END SAMPLE_TIME,
	L.HOST,
	AVG(L.CPU) CPU_PCT,
	AVG(L.MEMORY_USED) / 1024 / 1024 / 1024 USED_MEM_GB,
	AVG(L.MEMORY_SIZE) / 1024 / 1024 / 1024 TOTAL_MEM_GB,
	AVG(L.DISK_USED) / 1024 / 1024 / 1024 USED_DISK_GB,
	AVG(L.DISK_SIZE) / 1024 / 1024 / 1024 TOTAL_DISK_GB,
	AVG(L.NETWORK_IN) / 1024 / 1024 NETWORK_IN_MB,
	AVG(L.NETWORK_OUT) / 1024 / 1024 NETWORK_OUT_MB,
	AVG(L.SWAP_IN) / 1024 / 1024 SWAP_IN_MB,
	AVG(L.SWAP_OUT) / 1024 / 1024 SWAP_OUT_MB,
	BI.HOST BI_HOST,
	BI.AGGREGATE_BY
	FROM
	( SELECT
		BEGIN_TIME,
		END_TIME,
		HOST,
		AGGREGATE_BY,
		MAP(TIME_AGGREGATE_BY,
		'NONE',        'YYYY/MM/DD HH24:MI:SS',
		'HOUR',        'YYYY/MM/DD HH24',
		'DAY',         'YYYY/MM/DD (DY)',
		'HOUR_OF_DAY', 'HH24',
		TIME_AGGREGATE_BY ) TIME_AGGREGATE_BY
	FROM
	( SELECT                      /* Modification section */
		/*TO_TIMESTAMP('2014/05/08 09:48:00', 'YYYY/MM/DD HH24:MI:SS') BEGIN_TIME,  */
		add_seconds(now(),-$($freq*60)) BEGIN_TIME,
		TO_TIMESTAMP('9999/05/06 09:00:00', 'YYYY/MM/DD HH24:MI:SS') END_TIME,
		'%' HOST,
		'TIME,HOST' AGGREGATE_BY,      
		'TS60' TIME_AGGREGATE_BY   
		FROM
		DUMMY
	)
	) BI,
	M_LOAD_HISTORY_HOST L
	WHERE
	L.HOST LIKE BI.HOST AND
	L.TIME BETWEEN BI.BEGIN_TIME AND BI.END_TIME
	GROUP BY
	CASE 
		WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
		CASE 
			WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
			TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 
			'YYYY/MM/DD HH24:MI:SS'), L.TIME) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
			ELSE TO_VARCHAR(L.TIME, BI.TIME_AGGREGATE_BY)
		END
		ELSE 'any' 
	END,
	L.HOST,
	BI.HOST,
	BI.AGGREGATE_BY
)
GROUP BY
	SAMPLE_TIME,
	CASE WHEN AGGREGATE_BY = 'NONE' OR INSTR(AGGREGATE_BY, 'HOST') != 0 THEN HOST ELSE MAP(BI_HOST, '%', 'any', BI_HOST) END
) ORDER BY    SAMPLE_TIME DESC "

			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			$Resultsperf=@(); 

			IF($ds.Tables[0].rows)
			{
				foreach ($row in $ds.Tables[0].rows)
				{

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="CPU_PCT"
						PerfValue=$row.CPU_PCT
					}

				}
			}

			$Omsperfupload+=,$Resultsperf


			$query="Select SAMPLE_TIME ,
HOST,
LPAD(PORT, 5) PORT,
LPAD(ROUND(PING_MS), 7) PING_MS,
LPAD(ROUND(CPU_PCT), 3) CPU,
LPAD(ROUND(SYS_CPU_PCT), 3) SYS, 
LPAD(ROUND(USED_MEM_GB), 7) USED_GB,
LPAD(TO_DECIMAL(SWAP_IN_MB, 10, 2), 7) SWAP_MB,
LPAD(ROUND(CONNECTIONS), 5) CONNS,
LPAD(ROUND(TRANSACTIONS), 5) TRANS,
LPAD(ROUND(BLOCKED_TRANSACTIONS), 6) BTRANS,
LPAD(ROUND(EXECUTIONS_PER_S), 7) EXE_PS,
LPAD(TO_DECIMAL(ACTIVE_THREADS, 10, 2), 7) ACT_THR,
LPAD(TO_DECIMAL(WAITING_THREADS, 10, 2), 8) WAIT_THR,
LPAD(TO_DECIMAL(ACTIVE_SQL_EXECUTORS, 10, 2), 7) ACT_SQL,
LPAD(TO_DECIMAL(WAITING_SQL_EXECUTORS, 10, 2), 8) WAIT_SQL,
LPAD(TO_DECIMAL(PENDING_SESSIONS, 10, 2), 9) PEND_SESS,
LPAD(ROUND(VERSIONS), 9) VERSIONS,
LPAD(ROUND(TRANS_ID_RANGE), 9) UPD_RANGE,
LPAD(ROUND(COMMIT_ID_RANGE), 9) COM_RANGE,
LPAD(ROUND(MERGES), 6) MERGES,
LPAD(ROUND(UNLOADS), 7) UNLOADS
FROM
( SELECT
	SAMPLE_TIME,
	CASE WHEN AGGREGATE_BY = 'NONE' OR INSTR(AGGREGATE_BY, 'HOST') != 0 THEN HOST          ELSE MAP(BI_HOST, '%', 'any', BI_HOST) END HOST,
	CASE WHEN AGGREGATE_BY = 'NONE' OR INSTR(AGGREGATE_BY, 'PORT') != 0 THEN TO_VARCHAR(PORT) ELSE MAP(BI_PORT, '%', 'any', BI_PORT) END PORT,
	AVG(PING_MS) PING_MS,
	AVG(CPU_PCT) CPU_PCT,
	AVG(SYS_CPU_PCT) SYS_CPU_PCT,
	SUM(USED_MEM_GB) USED_MEM_GB,
	SUM(SWAP_IN_MB) SWAP_IN_MB,
	SUM(CONNECTIONS) CONNECTIONS,
	SUM(TRANSACTIONS) TRANSACTIONS,
	SUM(BLOCKED_TRANSACTIONS) BLOCKED_TRANSACTIONS,
	SUM(EXECUTIONS) / SUM(INTERVAL_S) EXECUTIONS_PER_S,
	MAX(COMMIT_ID_RANGE) COMMIT_ID_RANGE,
	MAX(TRANS_ID_RANGE) TRANS_ID_RANGE,
	SUM(VERSIONS) VERSIONS,
	SUM(PENDING_SESSIONS) PENDING_SESSIONS,
	SUM(RECORD_LOCK_COUNT) RECORD_LOCK_COUNT,
	SUM(ACTIVE_THREADS) ACTIVE_THREADS,
	SUM(ACTIVE_SQL_EXECUTORS) ACTIVE_SQL_EXECUTORS,
	SUM(WAITING_THREADS) WAITING_THREADS,
	SUM(WAITING_SQL_EXECUTORS) WAITING_SQL_EXECUTORS,
	SUM(MERGES) MERGES,
	SUM(UNLOADS) UNLOADS
FROM
( SELECT
	CASE 
		WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
		CASE 
			WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
			TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 
			'YYYY/MM/DD HH24:MI:SS'), L.TIME) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
			ELSE TO_VARCHAR(L.TIME, BI.TIME_AGGREGATE_BY)
		END
		ELSE 'any' 
	END SAMPLE_TIME,
	L.HOST,
	TO_VARCHAR(L.PORT) PORT,
	AVG(L.PING_TIME) PING_MS,
	AVG(L.CPU) CPU_PCT,
	AVG(L.SYSTEM_CPU) SYS_CPU_PCT,
	AVG(L.MEMORY_USED) / 1024 / 1024 / 1024 USED_MEM_GB,
	AVG(L.SWAP_IN) / 1024 / 1024 SWAP_IN_MB,
	AVG(L.CONNECTION_COUNT) CONNECTIONS,
	AVG(L.TRANSACTION_COUNT) TRANSACTIONS,
	AVG(L.BLOCKED_TRANSACTION_COUNT) BLOCKED_TRANSACTIONS,
	SUM(L.STATEMENT_COUNT) EXECUTIONS,
	AVG(L.COMMIT_ID_RANGE) COMMIT_ID_RANGE,
	AVG(L.TRANSACTION_ID_RANGE) TRANS_ID_RANGE,
	AVG(L.MVCC_VERSION_COUNT) VERSIONS,
	AVG(L.PENDING_SESSION_COUNT) PENDING_SESSIONS,
	AVG(L.RECORD_LOCK_COUNT) RECORD_LOCK_COUNT,
	AVG(L.ACTIVE_THREAD_COUNT) ACTIVE_THREADS,
	AVG(L.ACTIVE_SQL_EXECUTOR_COUNT) ACTIVE_SQL_EXECUTORS,
	AVG(L.WAITING_THREAD_COUNT) WAITING_THREADS,
	AVG(L.WAITING_SQL_EXECUTOR_COUNT) WAITING_SQL_EXECUTORS,
	SUM(L.CS_MERGE_COUNT) MERGES,
	SUM(L.CS_UNLOAD_COUNT) UNLOADS,
	SUM(INTERVAL_S) INTERVAL_S,
	BI.HOST BI_HOST,
	BI.PORT BI_PORT,
	BI.AGGREGATE_BY
	FROM
	( SELECT
		BEGIN_TIME,
		END_TIME,
		HOST,
		PORT,
		EXCLUDE_STANDBY,
		AGGREGATE_BY,
		MAP(TIME_AGGREGATE_BY,
		'NONE',        'YYYY/MM/DD HH24:MI:SS',
		'HOUR',        'YYYY/MM/DD HH24',
		'DAY',         'YYYY/MM/DD (DY)',
		'HOUR_OF_DAY', 'HH24',
		TIME_AGGREGATE_BY ) TIME_AGGREGATE_BY
	FROM
	( SELECT                      /* Modification section */
		/*TO_TIMESTAMP('2014/05/08 09:48:00', 'YYYY/MM/DD HH24:MI:SS') BEGIN_TIME,  */
		add_seconds(now(),-900) BEGIN_TIME, 
		TO_TIMESTAMP('9999/05/06 09:00:00', 'YYYY/MM/DD HH24:MI:SS') END_TIME,
		'%' HOST,
		'%' PORT,
		'X' EXCLUDE_STANDBY,
		'TIME, HOST, PORT' AGGREGATE_BY,               /* TIME, HOST, PORT and comma separated combinations, NONE for no aggregation */
		'TS60' TIME_AGGREGATE_BY     /* HOUR, DAY, HOUR_OF_DAY or database time pattern, TS<seconds> for time slice, NONE for no aggregation */
		FROM
		DUMMY
	)
	) BI INNER JOIN
	( SELECT
		L.*,
		NANO100_BETWEEN(LEAD(TIME, 1) OVER (PARTITION BY HOST, PORT ORDER BY TIME DESC), TIME) / 10000000 INTERVAL_S
	FROM
		M_LOAD_HISTORY_SERVICE L
	) L ON
		L.HOST LIKE BI.HOST AND
		TO_VARCHAR(L.PORT) LIKE BI.PORT AND
		L.TIME BETWEEN BI.BEGIN_TIME AND BI.END_TIME LEFT OUTER JOIN
	M_SERVICES S ON
		S.HOST = L.HOST AND
		S.SERVICE_NAME = 'indexserver'
	WHERE
	( BI.EXCLUDE_STANDBY = ' ' OR S.COORDINATOR_TYPE IS NULL OR S.COORDINATOR_TYPE != 'STANDBY' )      
	GROUP BY
	CASE 
		WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
		CASE 
			WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
			TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 
			'YYYY/MM/DD HH24:MI:SS'), L.TIME) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
			ELSE TO_VARCHAR(L.TIME, BI.TIME_AGGREGATE_BY)
		END
		ELSE 'any' 
	END,
	L.HOST,
	L.PORT,
	BI.HOST,
	BI.PORT,
	BI.AGGREGATE_BY,
	BI.TIME_AGGREGATE_BY
)
GROUP BY
	SAMPLE_TIME,
	CASE WHEN AGGREGATE_BY = 'NONE' OR INSTR(AGGREGATE_BY, 'HOST') != 0 THEN HOST          ELSE MAP(BI_HOST, '%', 'any', BI_HOST) END,
	CASE WHEN AGGREGATE_BY = 'NONE' OR INSTR(AGGREGATE_BY, 'PORT') != 0 THEN TO_VARCHAR(PORT) ELSE MAP(BI_PORT, '%', 'any', BI_PORT) END
)
ORDER BY
SAMPLE_TIME DESC
WITH HINT (NO_JOIN_REMOVAL)"
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			$Resultsperf=@(); 


			IF($ds.Tables[0].rows)
			{
				foreach ($row in $ds.Tables[0].rows)
				{

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="CPU_PCT"
						PerfValue=$row.CPU
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="SYSCPU_PCT"
						PerfValue=$row.SYS
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="Connections"
						PerfValue=$row.CONNS
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="Transactions"
						PerfValue=$row.TRANS
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="Requestspersec"
						PerfValue=$row.EXE_PS
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="ActiveThreads"
						PerfValue=$row.ACT_THR
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="WaitingThreads"
						PerfValue=$row.WAIT_THR
					}

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="ActiveSQLExecutorTHR"
						PerfValue=$row.ACT_SQL
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="PendingSessions"
						PerfValue=$row.PEND_SESS
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="Merges"
						PerfValue=$row.MERGES
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="Unloads"
						PerfValue=$row.UNLOADS
					}



				}
			}

			$Omsperfupload+=,$Resultsperf


			Write-Output '  CollectorType="Performance" - Category="Memory" - Subcategory="OverallUsage" '

			$query="SELECT * FROM SYS.M_MEMORY Where PORT=30003" ###HArdcoded change this
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			$Resultsperf=@(); 

			IF ($ds.tables[0].rows)
			{
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="SYSTEM_MEMORY_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="SYSTEM_MEMORY_FREE_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="PROCESS_MEMORY_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="PROCESS_RESIDENT_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="PROCESS_CODE_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="PROCESS_STACK_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="PROCESS_ALLOCATION_LIMIT"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="GLOBAL_ALLOCATION_LIMIT"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="EFFECTIVE_PROCESS_ALLOCATION_LIMIT"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="HEAP_MEMORY_ALLOCATED_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="HEAP_MEMORY_USED_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="HEAP_MEMORY_FREE_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="HEAP_MEMORY_ROOT_ALLOCATED_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="HEAP_MEMORY_ROOT_FREE_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="SHARED_MEMORY_ALLOCATED_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="SHARED_MEMORY_USED_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="SHARED_MEMORY_FREE_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="TOTAL_MEMORY_SIZE_IN_USE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="COMPACTORS_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="COMPACTORS_FREEABLE_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				}

			}

			$Omsperfupload+=,$Resultsperf


			$query="SELECT * FROM SYS.M_SERVICE_MEMORY"
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage

                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			$Resultsperf=@(); 

			Write-Output '  CollectorType="Performance" - Category="Service" - Subcategory="MemoryUsage" '
			foreach ($row in $ds.Tables[0].rows)
			{
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="COMPACTORS_ALLOCATED_SIZE"
					PerfValue=$row.COMPACTORS_ALLOCATED_SIZE/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="HEAP_MEMORY_ALLOCATED_SIZE"
					PerfValue=$row.HEAP_MEMORY_ALLOCATED_SIZE/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="HEAP_MEMORY_USED_SIZE"
					PerfValue=$row.HEAP_MEMORY_USED_SIZE/1024/1024/1024
				}

				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="LOGICAL_MEMORY_SIZE"
					PerfValue=$row.LOGICAL_MEMORY_SIZE/1024/1024/1024
				}

				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="TOTAL_MEMORY_USED_SIZE"
					PerfValue=$row.TOTAL_MEMORY_USED_SIZE/1024/1024/1024
				}

				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="ALLOCATION_LIMIT"
					PerfValue=$row.ALLOCATION_LIMIT/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="STACK_SIZE"
					PerfValue=$row.STACK_SIZE/1024/1024/1024
				}


				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="PHYSICAL_MEMORY_SIZE"
					PerfValue=$row.PHYSICAL_MEMORY_SIZE/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="SHARED_MEMORY_USED_SIZE"
					PerfValue=$row.SHARED_MEMORY_USED_SIZE/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="CODE_SIZE"
					PerfValue=$row.CODE_SIZE/1024/1024/1024
				}

				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="EFFECTIVE_ALLOCATION_LIMIT"
					PerfValue=$row.EFFECTIVE_ALLOCATION_LIMIT/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="SHARED_MEMORY_ALLOCATED_SIZE"
					PerfValue=$row.SHARED_MEMORY_ALLOCATED_SIZE/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="COMPACTORS_FREEABLE_SIZE"
					PerfValue=$row.COMPACTORS_FREEABLE_SIZE/1024/1024/1024
				}
			}
			$Omsperfupload+=,$Resultsperf

#int ext connection count does not exit check version


			$query="SELECT  HOST , PORT , to_varchar(time, 'YYYY-MM-DD HH24:MI') as TIME, ROUND(AVG(CPU),0)as PROCESS_CPU , ROUND(AVG(SYSTEM_CPU),0) as SYSTEM_CPU , 
MAX(MEMORY_USED) as MEMORY_USED , MAX(MEMORY_ALLOCATION_LIMIT) as MEMORY_ALLOCATION_LIMIT , SUM(HANDLE_COUNT) as HANDLE_COUNT , 
ROUND(AVG(PING_TIME),0) as PING_TIME, MAX(SWAP_IN) as SWAP_IN ,SUM(CONNECTION_COUNT) as CONNECTION_COUNT, SUM(TRANSACTION_COUNT)  as TRANSACTION_COUNT,  SUM(BLOCKED_TRANSACTION_COUNT) as BLOCKED_TRANSACTION_COUNT , SUM(STATEMENT_COUNT) as STATEMENT_COUNT
from SYS.M_LOAD_HISTORY_SERVICE 
WHERE TIME > add_seconds(now(),-$($freq*60))
Group by  HOST , PORT,to_varchar(time, 'YYYY-MM-DD HH24:MI')"

#double check and remove seconday CPU
			$sqcondcpu="SELECT  Time,sum(CPU) from SYS.M_LOAD_HISTORY_SERVICE 
WHERE TIME > add_seconds(now(),-$($freq*60))
group by Host,Time
order by Time desc"
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			$Resultsperf=@(); 

			Write-Output '  CollectorType="Performance" - Category="COU,MEmory" - Subcategory="Usage" '
			foreach ($row in $ds.Tables[0].rows)
			{
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="EXTERNAL_CONNECTION_COUNT"
					PerfValue=$row.EXTERNAL_CONNECTION_COUNT
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="EXTERNAL_TRANSACTION_COUNT"
					PerfValue=$row.EXTERNAL_TRANSACTION_COUNT
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="STATEMENT_COUNT"
					PerfValue=$row.STATEMENT_COUNT
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="TRANSACTION_COUNT"
					PerfValue=$row.TRANSACTION_COUNT
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="SYSTEM_CPU"
					PerfValue=$row.SYSTEM_CPU
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="MEMORY_USED"
					PerfValue=$row.MEMORY_USED/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
                    Category='LoadHistory'
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="PROCESS_CPU"
					PerfValue=$row.PROCESS_CPU
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="IDLE_CONNECTION_COUNT"
					PerfValue=$row.IDLE_CONNECTION_COUNT
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="MEMORY_ALLOCATION_LIMIT"
					PerfValue=$row.MEMORY_ALLOCATION_LIMIT/1024/1024/1024
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="HANDLE_COUNT"
					PerfValue=$row.HANDLE_COUNT
				}

				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="INTERNAL_TRANSACTION_COUNT"
					PerfValue=$row.INTERNAL_TRANSACTION_COUNT
				}

				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="BLOCKED_TRANSACTION_COUNT"
					PerfValue=$row.BLOCKED_TRANSACTION_COUNT
				}

				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="USER_TRANSACTION_COUNT"
					PerfValue=$row.USER_TRANSACTION_COUNT
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="CONNECTION_COUNT"
					PerfValue=$row.CONNECTION_COUNT
				}


				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="SWAP_IN"
					PerfValue=$row.SWAP_IN
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="PING_TIME"
					PerfValue=$row.PING_TIME
				}
				$Resultsperf+= New-Object PSObject -Property @{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$defaultdb
					SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="INTERNAL_CONNECTION_COUNT"
					PerfValue=$row.INTERNAL_CONNECTION_COUNT
				}
			}
			$Omsperfupload+=,$Resultsperf


			$query="SELECT  HOST,to_varchar(time, 'YYYY-MM-DD HH24:MI') as TIME, ROUND(AVG(CPU),0)as CPU_Total ,
ROUND(AVG(Network_IN)/1024/1024,2)as Network_IN_MB,ROUND(AVG(Network_OUT)/1024/1024,2) as Network_OUT_MB,
MAX(MEMORY_RESIDENT)/1024/1024/1024 as ResidentGB,MAX(MEMORY_TOTAL_RESIDENT/1024/1024/1024 )as TotalResidentGB
,MAX(MEMORY_USED/1024/1024/1024) as UsedMemoryGB
,MAX(MEMORY_RESIDENT-MEMORY_TOTAL_RESIDENT)/1024/1024/1024 as Database_ResidentGB
,MAX(MEMORY_ALLOCATION_LIMIT)/1024/1024/1024 as AllocationLimitGB
from SYS.M_LOAD_HISTORY_HOST
WHERE TIME > add_seconds(now(),-$($freq*60))
Group by  HOST ,to_varchar(time, 'YYYY-MM-DD HH24:MI')"
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                    write-warning  $ex 
			}
			 
			$Resultsperf=$null
			$Resultsperf=@(); 

			IF ($ds.Tables[0].rows)
			{

				Write-Output '  CollectorType="Performance" - Category="Host" - Subcategory="Overall" '

				foreach ($row in $ds.Tables[0].rows)
				{
					

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="USEDMEMORYGB"
						PerfValue=$row.USEDMEMORYGB
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="ALLOCATIONLIMITGB"
						PerfValue=$row.ALLOCATIONLIMITGB
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="RESIDENTGB"
						PerfValue=$row.RESIDENTGB
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="TOTALRESIDENTGB"
						PerfValue=$row.TOTALRESIDENTGB
					}


					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="DATABASE_RESIDENTGB"
						PerfValue=$row.DATABASE_RESIDENTGB
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="NETWORK_OUT_MB"
						PerfValue=$row.NETWORK_OUT_MB
					}

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="CPU_TOTAL"
						PerfValue=$row.CPU_TOTAL
					}

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						SYS_TIMESTAMP=([datetime]$row.TIME).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="NETWORK_IN_MB"
						PerfValue=$row.NETWORK_IN_MB
					}
				}
				$Omsperfupload+=,$Resultsperf

			}


			$query='Select Schema_name,round(sum(Memory_size_in_total)/1024/1024) as "ColunmTablesMBUSed" from M_CS_TABLES group by Schema_name'
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}

			 

			$Resultsperf=$null
			$Resultsperf=@(); 


			IF ($ds.Tables[0].rows)
			{
				Write-Output '  CollectorType="Performance" - Category="TaBle" - Subcategory="OverallUsage" '
				foreach($row in $ds.Tables[0].rows)
				{
					$Resultsperf+=  New-Object PSObject -Property @{
						HOST=$SAPHOST
						Instance=$sapinstance
						CollectorType="Performance"
						PerfObject="Tables"
						PerfCounter="ColunmTablesMBUSed"
						PerfInstance=$row.SCHEMA_NAME
						PerfValue=$row.ColunmTablesMBUSed
					}


				}

			}
			$Omsperfupload+=,$Resultsperf


			$query='SELECT  host,component, sum(Used_memory_size) USed_MEmory_size from public.m_service_component_memory group by host, component'
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			$Resultsperf=@(); 


			IF ($ds.Tables[0].rows)
			{

				Write-Output '  CollectorType="Performance" - Category="Memory" - Subcategory="Usage" '
				foreach ($row in $ds.Tables[0].rows)
				{
					$Resultsperf+=  New-Object PSObject -Property @{
						HOST=$row.HOST
						Instance=$sapinstance
						CollectorType="Performance"
						PerfObject="Memory"
						PerfCounter="Component"
						PerfInstance=$row.COMPONENT
						PerfValue=$row.USED_MEMORY_SIZE/1024/1024

					}
				}

				$Omsperfupload+=,$Resultsperf
			}


			$query='Select t1.host,round(sum(t1.Total_memory_used_size/1024/1024/1024),1) as "UsedMemoryGB",round(sum(t1.physical_memory_size/1024/1024/1024),2) "DatabaseResident" ,SUM(T2.Peak) as PeakGB from m_service_memory  as T1 
Join 
(Select  Host, ROUND(SUM(M)/1024/1024/1024,2) Peak from (Select  host,SUM(CODE_SIZE+SHARED_MEMORY_ALLOCATED_SIZE) as M from sys.M_SERVICE_MEMORY group by host  
union 
select host, sum(INCLUSIVE_PEAK_ALLOCATION_SIZE) as M from M_HEAP_MEMORY_RESET WHERE depth = 0 group by host ) group by Host )as T2 on T1.Host=T2.Host
group by T1.host'
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 
			$Resultsperf=$null
			$Resultsperf=@(); 


			IF ($ds.Tables[0].rows)
			{

				Write-Output '  CollectorType="Performance" - Category="MEmory" - Subcategory="Usage" '
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$ds.tables[0].rows[0].HOST
					CollectorType="Performance"
					Instance=$sapinstance
					PerfObject="Memory"
					PerfCounter="UsedMemoryGB"
					PerfInstance=$ds.tables[0].rows[0].HOST
					PerfValue=$ds.tables[0].rows[0].UsedMemoryGB
					
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$ds.tables[0].rows[0].HOST
					CollectorType="Performance"
					Instance=$sapinstance
					PerfObject="Memory"
					PerfCounter="DatabaseResidentGB"
					PerfInstance=$ds.tables[0].rows[0].HOST
					PerfValue=$ds.tables[0].rows[0].DatabaseResident
					
				}
				$Resultsperf+= New-Object PSObject -Property @{
					HOST=$ds.tables[0].rows[0].HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="PeakUsedMemoryGB"
					PerfInstance=$ds.tables[0].rows[0].HOST
					PerfValue=$ds.tables[0].rows[0].PeakGB
					
				}
			}
			$Omsperfupload+=,$Resultsperf

# check takes long time to calculate

			$query='select  host,schema_name ,sum(DISTINCT_COUNT) RECORD_COUNT,
	sum(MEMORY_SIZE_IN_TOTAL) COMPRESSED_SIZE,	sum(UNCOMPRESSED_SIZE) UNCOMPRESSED_SIZE, (sum(UNCOMPRESSED_SIZE)/sum(MEMORY_SIZE_IN_TOTAL)) Compression_Ratio
, 100*(sum(UNCOMPRESSED_SIZE)/sum(MEMORY_SIZE_IN_TOTAL)) Compression_PErcentage
	FROM SYS.M_CS_ALL_COLUMNS Group by host,Schema_name having sum(Uncompressed_size) >0 '

			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			$Resultsperf=@(); 


			IF ($ds.Tables[0].rows)
			{

				Write-Output '  CollectorType="Performance" - Category="Memory" - Subcategory="Compression" '
				foreach ($row in $ds.Tables[0].rows)
				{
					
					$Resultsperf+= New-Object PSObject -Property @{
						HOST=$row.Host
						Instance=$sapinstance
						CollectorType="Performance"
						Database=$defaultdb
						PerfObject="Compression"
						PerfCounter="RECORD_COUNT"
						PerfInstance=$row.Schema_NAme
						PerfValue=$row.RECORD_COUNT
						
					}
					$Resultsperf+= New-Object PSObject -Property @{
						HOST=$row.Host
						Instance=$sapinstance
						CollectorType="Performance"
						Database=$defaultdb
						PerfObject="Compression"
						PerfCounter="COMPRESSED_SIZE"
						PerfInstance=$row.Schema_NAme
						PerfValue=$row.COMPRESSED_SIZE/1024/1024
						
					}
					$Resultsperf+= New-Object PSObject -Property @{
						HOST=$row.Host
						Instance=$sapinstance
						Database=$defaultdb
						CollectorType="Performance"
						PerfObject="Compression"
						PerfCounter="UNCOMPRESSED_SIZE"
						PerfInstance=$row.Schema_NAme
						PerfValue=$row.UNCOMPRESSED_SIZE/1024/1024
						
					}
					$Resultsperf+= New-Object PSObject -Property @{
						HOST=$row.Host
						Instance=$sapinstance
						CollectorType="Performance"
						Database=$defaultdb
						PerfObject="Compression"
						PerfCounter="COMPRESSION_RATIO"
						PerfInstance=$row.Schema_NAme
						PerfValue=$row.COMPRESSION_RATIO
						
					}
					$Resultsperf+= New-Object PSObject -Property @{
						HOST=$row.Host
						Instance=$sapinstance
						CollectorType="Performance"
						Database=$defaultdb
						PerfObject="Compression"
						PerfCounter="COMPRESSION_PERCENTAGE"
						PerfInstance=$row.Schema_NAme
						PerfValue=$row.COMPRESSION_PERCENTAGE

					}
				}
				$Omsperfupload+=,$Resultsperf


			}







			<#

			Double check viw IO_perf or io_total or M_VOLUME_IO_DETAILED_STATs   
			time in micro seconds

			SELECT HOST, PORT, TYPE, round(MAX_IO_BUFFER_SIZE / 1024, 3) “Maximum buffer size in KB”,    TRIGGER_ASYNC_WRITE_COUNT, AVG_TRIGGER_ASYNC_WRITE_TIME as “Avg Write Time in  Microsecond” from “PUBLIC”.”M_VOLUME_IO_DETAILED_STATISTICS” where type = ‘LOG’   and VOLUME_ID in (select VOLUME_ID from PUBLIC.M_VOLUMES where SERVICE_NAME = ‘indexserver’ and  AVG_TRIGGER_ASYNC_WRITE_TIME > 0)

#>

			$query="SELECT * FROM SYS.M_volume_io_performance_statistics"
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			$Resultsperf=@(); 


			IF ($ds.Tables[0].rows)
			{

				Write-Output '  CollectorType="Performance" - Category="Volume" - Subcategory="IOStat" '
				foreach ($row in $ds.Tables[0].rows)
				{
					


					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="MIN_READ_SIZE"
						PerfValue=$row.MIN_READ_SIZE
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="FAILED_READS"
						PerfValue=$row.FAILED_READS
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="MIN_READ_TIME"
						PerfValue=$row.MIN_READ_TIME
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="AVG_WRITE_SIZE"
						PerfValue=$row.AVG_WRITE_SIZE
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="MAX_READ_TIME"
						PerfValue=$row.MAX_READ_TIME
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="SUM_WRITE_SIZE"
						PerfValue=$row.SUM_WRITE_SIZE
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="SUM_READ_SIZE"
						PerfValue=$row.SUM_READ_SIZE
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="LAST_WRITE_TIME"
						PerfValue=$row.LAST_WRITE_TIME
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="MIN_WRITE_TIME"
						PerfValue=$row.MIN_WRITE_TIME
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="FAILED_WRITES"
						PerfValue=$row.FAILED_WRITES
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="READ_COMPLETIONS"
						PerfValue=$row.READ_COMPLETIONS
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="SUM_WRITE_TIME"
						PerfValue=$row.SUM_WRITE_TIME
					}

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="MIN_WRITE_SIZE"
						PerfValue=$row.MIN_WRITE_SIZE
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="MAX_READ_SIZE"
						PerfValue=$row.MAX_READ_SIZE
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="AVG_READ_TIME"
						PerfValue=$row.AVG_READ_TIME
					}

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="WRITE_COMPLETIONS"
						PerfValue=$row.WRITE_COMPLETIONS
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="MAX_WRITE_SIZE"
						PerfValue=$row.MAX_WRITE_SIZE
					}

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="READ_REQUESTS"
						PerfValue=$row.READ_REQUESTS
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="LAST_WRITE_SIZE"
						PerfValue=$row.LAST_WRITE_SIZE
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="WRITE_REQUESTS"
						PerfValue=$row.WRITE_REQUESTS
					}

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="LAST_READ_SIZE"
						PerfValue=$row.LAST_READ_SIZE
					}


					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="SUM_READ_TIME"
						PerfValue=$row.SUM_READ_TIME
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="AVG_READ_SIZE"
						PerfValue=$row.AVG_READ_SIZE
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="LAST_READ_TIME"
						PerfValue=$row.LAST_READ_TIME
					}

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="MAX_WRITE_TIME"
						PerfValue=$row.MAX_WRITE_TIME
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						
						CollectorType="Performance"
						PerfObject="Volumes"
						PerfInstance=$row.Type+":"+$row.PATH
						PerfCounter="AVG_WRITE_TIME"
						PerfValue=$row.AVG_WRITE_TIME
					}
				}

				$Omsperfupload+=,$Resultsperf
			}


			$query='Select HOST,
PORT,
CONNECTION_ID,
TRANSACTION_ID,
STATEMENT_ID,
DB_USER,
APP_USER,
START_TIME,
DURATION_MICROSEC,
OBJECT_NAME,
OPERATION,
RECORDS,
STATEMENT_STRING,
PARAMETERS,
ERROR_CODE,
ERROR_TEXT,
LOCK_WAIT_COUNT,
LOCK_WAIT_DURATION,
ALLOC_MEM_SIZE_ROWSTORE,
ALLOC_MEM_SIZE_COLSTORE,
MEMORY_SIZE,
REUSED_MEMORY_SIZE,
CPU_TIME FROM PUBLIC.M_EXPENSIVE_STATEMENTS WHERE ERROR_CODE >0  and START_TIME> add_seconds(now(),-$($freq*60))'

			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsinv=$null
			$Resultsinv=@(); 


			IF($ds.Tables[0])
			{

				Write-Output '  CollectorType="Performance" - Category="Statetment" - Subcategory="Expensive" '
				foreach ($row in $ds.Tables[0].rows)
				{
					$resultsinv+= New-Object PSObject -Property @{
						HOST=$row.Host
						Instance=$sapinstance
						CollectorType="Inventory"
						Category="ExpensiveStatements"
						Database=$defaultdb
						PORT=$row.Port
						CONNECTION_ID=$row.CONNECTION_ID
						TRANSACTION_ID=$row.TRANSACTION_ID
						STATEMENT_ID=$row.STATEMENT_ID
						DB_USER=$row.DB_USER
						APP_USER=$row.APP_USER
						SYS_TIMESTAMP=$row.START_TIME
						DURATION_MICROSEC=$row.DURATION_MICROSEC
						OBJECT_NAME=$row.OBJECT_NAME
						OPERATION=$row.OPERATION
						RECORDS=$row.RECORDS
						STATEMENT_STRING=$row.STATEMENT_STRING
						PARAMETERS=$row.PARAMETERS
						ERROR_CODE=$row.ERROR_CODE
						ERROR_TEXT=$row.ERROR_TEXT
						LOCK_WAIT_COUNT=$row.LOCK_WAIT_COUNT
						LOCK_WAIT_DURATION=$row.LOCK_WAIT_DURATION
						ALLOC_MEM_SIZE_ROWSTORE_MB=$row.ALLOC_MEM_SIZE_ROWSTORE/1024/1024
						ALLOC_MEM_SIZE_COLSTORE_MB=$row.ALLOC_MEM_SIZE_COLSTORE/1024/1024
						MEMORY_SIZE=$row.MEMORY_SIZE
						REUSED_MEMORY_SIZE=$row.REUSED_MEMORY_SIZE
						CPU_TIME=$row.CPU_TIME
					}
				}
				$Omsinvupload+=,$Resultsinv
			}


			IF($collectqueryperf)
			{

				Write-Output " Query Collection Enabled"
				$Resultsperf=$null
				$Resultsperf=@()

				$query="Select * from M_SQL_PLAN_CACHE  where AVG_EXECUTION_TIME > 0 AND LAST_EXECUTION_TIMESTAMP >  add_seconds(now(),-$($freq*60))"
# where LAST_EXECUTION_TIMESTAMP >  add_seconds(now(),-900)
				$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
				$ds = New-Object system.Data.DataSet ;
$ex=$null
				Try{
					$cmd.fill($ds)
				}
				Catch
				{
					$Ex=$_.Exception.MEssage
                    write-warning  $ex 
				}
				 

				$Resultsperf=$null
				$Resultsperf=@(); 

				foreach ($row in $ds.Tables[0].rows)
				{
					
					

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="TOTAL_TABLE_LOAD_TIME_DURING_PREPARATION"
						PerfValue=$row.TOTAL_TABLE_LOAD_TIME_DURING_PREPARATION/1000000 
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="AVG_TABLE_LOAD_TIME_DURING_PREPARATION"
						PerfValue=$row.AVG_TABLE_LOAD_TIME_DURING_PREPARATION/1000000 
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="LAST_EXECUTION_TIMESTAMP"
						PerfValue=$row.LAST_EXECUTION_TIMESTAMP
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="TOTAL_LOCK_WAIT_COUNT"
						PerfValue=$row.TOTAL_LOCK_WAIT_COUNT
					}


					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="TOTAL_PREPARATION_TIME"
						PerfValue=$row.TOTAL_PREPARATION_TIME/1000000 
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="AVG_EXECUTION_MEMORY_SIZE"
						PerfValue=$row.AVG_EXECUTION_MEMORY_SIZE
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="EXECUTION_COUNT"
						PerfValue=$row.EXECUTION_COUNT
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="REFERENCE_COUNT"
						PerfValue=$row.REFERENCE_COUNT
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Inventory"
						Category="Statement"
						STATEMENT_HASH=$row.STATEMENT_HASH
						STATEMENT_STRING=$row.STATEMENT_STRING
						USER_NAME=$row.USER_NAME
						IS_INTERNAL=$row.IS_INTERNAL
						SESSION_USER_NAME=$row.SESSION_USER_NAME
						IS_PINNED_PLAN=$row.IS_PINNED_PLAN
						IS_VALID=$row.IS_VALID
						VOLUME_ID=$row.VOLUME_ID
						IS_DISTRIBUTED_EXECUTION=$row.IS_DISTRIBUTED_EXECUTION
						PLAN_SHARING_TYPE=$row.PLAN_SHARING_TYPE

					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="TOTAL_LOCK_WAIT_DURATION"
						PerfValue=$row.TOTAL_LOCK_WAIT_DURATION/1000000 
					}


					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="EXECUTION_COUNT_BY_ROUTING"
						PerfValue=$row.EXECUTION_COUNT_BY_ROUTING
					}


					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="TOTAL_EXECUTION_MEMORY_SIZE"
						PerfValue=$row.TOTAL_EXECUTION_MEMORY_SIZE
					}

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="AVG_CURSOR_DURATION"
						PerfValue=$row.AVG_CURSOR_DURATION/1000000
					}

					
					
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="AVG_EXECUTION_FETCH_TIME"
						PerfValue=$row.AVG_EXECUTION_FETCH_TIME/1000000
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="TOTAL_EXECUTION_TIME"
						PerfValue=$row.TOTAL_EXECUTION_TIME/1000000
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="AVG_EXECUTION_CLOSE_TIME"
						PerfValue=$row.AVG_EXECUTION_CLOSE_TIME/1000000
					}

					
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="PREPARATION_COUNT"
						PerfValue=$row.PREPARATION_COUNT
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="AVG_EXECUTION_TIME"
						PerfValue=$row.AVG_EXECUTION_TIME/1000000
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="AVG_EXECUTION_OPEN_TIME"
						PerfValue=$row.AVG_EXECUTION_OPEN_TIME/1000000
					}

					

					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="TOTAL_CURSOR_DURATION"
						PerfValue=$row.TOTAL_CURSOR_DURATION/1000000
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="AVG_SERVICE_NETWORK_REQUEST_DURATION"
						PerfValue=$row.AVG_SERVICE_NETWORK_REQUEST_DURATION/1000000
					}
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="TOTAL_RESULT_RECORD_COUNT"
						PerfValue=$row.TOTAL_RESULT_RECORD_COUNT
					}

					
					
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="PLAN_MEMORY_SIZE"
						PerfValue=$row.PLAN_MEMORY_SIZE
					}


					
					
					$Resultsperf+= New-Object PSObject -Property @{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$defaultdb
						Schema_Name=$row.SCHEMA_NAME
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addhours($utcdiff.Hours)
						CollectorType="Performance"
						PerfObject="Query"
						PerfInstance=$row.STATEMENT_HASH
						PerfCounter="AVG_PREPARATION_TIME"
						PerfValue=$row.AVG_PREPARATION_TIME/1000000
					}
				}
				$Omsperfupload+=,$Resultsperf

			}





			$query="Select SUM(EXECUTION_COUNT) as EXECUTION_COUNT ,HOST from M_SQL_PLAN_CACHE  where  LAST_EXECUTION_TIMESTAMP >  add_seconds(now(),-900) group by HOST"
# where LAST_EXECUTION_TIMESTAMP >  add_seconds(now(),-900)
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)|out-null
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			$Resultsperf=@(); 

			IF($ds.Tables[0].rows)
			{
				foreach ($row in $ds.Tables[0].rows)
				{
					$Resultsperf+= New-Object PSObject -Property @{
						HOST=$row.HOST.ToLower()
						Instance=$sapinstance
						CollectorType="Performance"
						Database=$defaultdb
						PerfObject="Query"
						PerfInstance=$row.HOST
						PerfCounter="TOTAL_EXECUTION_COUNT"
						PerfValue=$row.EXECUTION_COUNT     

					}
				}
				$Omsperfupload+=,$Resultsperf
			}




			$query="Select SUM(EXECUTION_COUNT*AVG_EXECUTION_TIME) as TOTAL_EXECUTION_TIME ,HOST from M_SQL_PLAN_CACHE  where  LAST_EXECUTION_TIMESTAMP >  add_seconds(now(),-$($freq*60)) group by HOST"
# where LAST_EXECUTION_TIMESTAMP >  add_seconds(now(),-900)
			$cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds = New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)|out-null
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex 
			}
			 



			$Resultsperf=$null
			$Resultsperf=@(); 

			IF($ds[0].Tables.rows)
			{
				foreach ($row in $ds.Tables[0].rows)
				{
					$Resultsperf+= New-Object PSObject -Property @{
						HOST=$row.HOST.ToLower()
						Instance=$sapinstance
						CollectorType="Performance"
						Category="Query"
						Subcategory="TotalTime"
						Database=$defaultdb
						PerfObject="Query"
						PerfInstance=$row.HOST
						PerfCounter="TOTAL_EXECUTION_TIME"
						PerfValue=$row.TOTAL_EXECUTION_TIME /1000000    
						
					}
				}
				$Omsperfupload+=,$Resultsperf
			}


			$colend=get-date
#endregion


			$AzLAUploadsuccess=0
			$AzLAUploaderror=0
			
			$Omsperfupload+=@(New-Object PSObject -Property @{
				HOST=$saphost
				CollectorType="Performance"
				PerfObject="Colllector"
				PerfCounter="Duration_sec"
				PerfValue=($colend-$colstart).Totalseconds
				
			})
			$message="{0} inventory data, {1}  state data and {2} performance data will be uploaded to OMS Log Analytics " -f $Omsinvupload.count,$OmsStateupload.count,$OmsPerfupload.count
			write-output $message

			If($Omsinvupload)
			{

				$jsonlogs=$null
				$dataitem=$null
				

				foreach( $dataitem in $Omsinvupload)
				{


					$jsonlogs= ConvertTo-Json -InputObject $dataitem
					$post=$null; 
					$post=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
					if ($post -in (200..299))
					{
						$AzLAUploadsuccess++
					}Else
					{
						$AzLAUploaderror++
					}
				}
			}

			If($Omsstateupload)
			{

				$jsonlogs=$null
				$dataitem=$null
				
				foreach( $dataitem in $Omsstateupload)
				{


					$jsonlogs= ConvertTo-Json -InputObject $dataitem
					$post=$null; 
					$post=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
					if ($post -in (200..299))
					{
						$AzLAUploadsuccess++
					}Else
					{
						$AzLAUploaderror++
					}
				}
			}


			If($Omsperfupload)
			{

				$jsonlogs=$null
				$dataitem=$null
				

				foreach( $dataitem in $Omsperfupload)
				{


					$jsonlogs= ConvertTo-Json -InputObject $dataitem
					$post=$null; 
					$post=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
					if ($post -in (200..299))
					{
						$AzLAUploadsuccess++
					}Else
					{
						$AzLAUploaderror++
					}
				}
			}

			$conn.Close()

#endregion

		}Else
		{

			#send connectivity failure event
			
			$Omsstateupload=@()
		    write-warning "Uploading connection failed event"
				
				$Omsstateupload+= @(New-Object PSObject -Property @{
					HOST=$saphost
                     PORT=$sapport
					CollectorType="State"
					Category="Connectivity"
					SubCategory="Host"
					Connection="Failed"
					ErrorMessage=$ex
				})

				$jsonlogs=$null
				

				foreach( $dataitem in $Omsstateupload)
				{

                    $jsonlogs= ConvertTo-Json -InputObject $dataitem
					$post=$null; 
					$post=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
					if ($post -in (200..299))
					{
						$AzLAUploadsuccess++
					}Else
					{
						$AzLAUploaderror++
					}
				}

			

		}

		write-output "Log Analytics Data Upload Summary :"
		write-output "Successful Batch Count : $AzLAUploadsuccess"
		IF($AzLAUploaderror -ne 0)
		{
			write-warning "Failed batch Count: $AzLAUploaderror, Please make sure Log Analytics workspace ID and Key is correct in Azure automation asset"
		}ELSE
		{
			write-output "Failed batch Count: $AzLAUploaderror"
		}
		
		$Omsupload=$null
		$omsupload=@()
		$conn.Close()

	}


	$colend=Get-date
	write-output "Collected all data in  $(($colend-$colstart).Totalseconds)  seconds"
	write-output "Next collection will run @ $nextstart"

	$diffsec=[math]::Round(($nextstart-$(get-date)).Totalseconds,0)
}


