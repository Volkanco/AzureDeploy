param
(
[Parameter(Mandatory=$false)] [bool] $collectqueryperf=$false,
[Parameter(Mandatory=$false)] [bool] $collecttableinv=$false,
[Parameter(Mandatory=$true)] [string] $configfolder="C:\HanaMonitor",
[Parameter(Mandatory=$true)] [int] $freq=15
)


#Write-Output "RB Initial   : $([System.gc]::gettotalmemory('forcefullcollection') /1MB) MB" 

#region login to Azure Arm and retrieve variables

$connectionName = "AzureRunAsConnection"
try
{
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

    "Logging in to Azure..."
    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
}
catch {
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}


$AAResourceGroup = Get-AutomationVariable -Name 'AzureSAPHanaMonitoring-AzureAutomationResourceGroup-MS-Mgmt'
$AAAccount = Get-AutomationVariable -Name 'AzureSAPHanaMonitoring-AzureAutomationAccount-MS-Mgmt'

$varText= "AAResourceGroup = $AAResourceGroup , AAAccount = $AAAccount"

#endregion

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
$hanadefaultpath="C:\Program Files\sap\hdbclient\ado.net\v4.5\$sapdll"
IF(Test-Path -Path  $hanadefaultpath)
{
   [System.Reflection.Assembly]::LoadFrom($hanadefaultpath) #|out-null
    Write-Output " Hana Client found in default location"

}Else{
    $dllcol=@()
    $dllcol+=Get-ChildItem -Path $env:ProgramFiles  -Filter $sapdll -Recurse -ErrorAction SilentlyContinue -Force

    If([string]::IsNullOrEmpty($dllcol[0])) # Hana Client dll not found , will do a wider search
    {
    $folderlist=@()
    $folderlist+="C:\Program Files"
    $folderlist+="D:\Program Files"
    $folderlist+="E:\Program Files"
    $folderlist+=$configfolder 
    Write-Output " Hana client not found in default location , searching for $sapdll "
        
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
       # [reflection.assembly]::LoadWithPartialName( "Sap.Data.Hana" )|out-null
        [System.Reflection.Assembly]::LoadFrom($dllcol[0])|out-null
    }


}



$configfile=$configfolder+"\hanaconfig.xml"

[xml]$hanaconfig=Get-Content $configfile

If([string]::IsNullOrEmpty($hanaconfig))
{
	Write-Error " Hana config xml not found under $configfolder!Please duplicate config template and name it as hanaconfig.xml under $configfolder"
	Exit
}else
{
    Write-Output " Config file found "
$Timestampfield = "SYS_TIMESTAMP"  #check this as this needs to be in UTC 
$ex=$null


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
        
        

		If($ins.UserAsset -match 'default')
		{
			$user=Get-AutomationVariable -Name "AzureHanaMonitorUser"
			$password= Get-AutomationVariable -Name "AzureHanaMonitorPwd"
		}else
		{
			$user=Get-AutomationVariable -Name $ins.UserAsset+"User"
			$password= Get-AutomationVariable -Name $ins.UserAsset+"Password"
		}

		$constring="Server={0}:{1};Database={2};UserID={3};Password={4}" -f $ins.HanaServer,$ins.Port,$ins.Database,$user,$password
		$conn=$null
		$conn = new-object Sap.Data.Hana.HanaConnection($constring);
		$hanadb=$null
        $hanadb=$ins.Database
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
				Database=$hanadb
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
				 Database=$hanadb
				CollectorType="State"
				Category="Connectivity"
				SubCategory="Host"
				Connection="Successful"
				
				})

			#define all queries in a variable and loop them, this can be exported to an external file part of the config 
			
			$hanaQueries=@()
			
			#get last run time 

			$rbvariablename=$null
			$rbvariablename="LastRun-$saphost-$hanadb"

			$ex=$null
			Try{
					$lasttimestamp=$null
				$lasttimestamp=Get-AzureRmAutomationVariable `
				-Name $rbvariablename `
				-ResourceGroupName $AAResourceGroup `
				-AutomationAccountName $AAAccount -EA 0
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
			}
			$query="SELECT CURRENT_TIMESTAMP ,add_seconds(CURRENT_TIMESTAMP,-900) as LastTime  FROM DUMMY"
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

			if($ex -ne $null -OR $lasttimestamp -eq $null )
			{
				write-warning "Last Run Time not found for $saphost-$hanadb : $ex"
				$lastruntime=$ds.Tables[0].rows[0].LastTime # we will use this to mark lasst data collection time in HANA
			}Else
			{
				$lastruntime=$lasttimestamp  # we will use this to mark lasst data collection time in HANA				
			}
				$currentruntime=$ds.Tables[0].rows[0].CURRENT_TIMESTAMP

				Write-Output "Last Collection time was $lastruntime and currenttime is  $currentruntime "
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

				$mdc=$null
			Write-Output ' CollectorType="Inventory" ,  Category="DatabaseState"'
            If($ex)
            {
                #not multi tenant
                $MDC=$false

            }Else
            {
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

            $MDC=$true
            }

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
#			$utcdiff=NEW-TIMESPAN –Start $ds[0].Tables[0].rows[0].UTC_TIMESTAMP  –End $ds[0].Tables[0].rows[0].SYS_TIMESTAMP 
			$query="SELECT 
			O.HOST,
			N.VALUE TIMEZONE_NAME,
			LPAD(O.VALUE, 17) TIMEZONE_OFFSET_S
			FROM
			( SELECT                      /* Modification section */
			'%' HOST
			FROM
			DUMMY
			) BI,
			( SELECT
			HOST,
			VALUE
			FROM
			M_HOST_INFORMATION
			WHERE
			KEY = 'timezone_offset'
			) O,
			( SELECT
			HOST,
			VALUE
			FROM
			M_HOST_INFORMATION
			WHERE
			KEY = 'timezone_name'
			) N
			WHERE
			O.HOST LIKE BI.HOST AND
			N.HOST = O.HOST
			ORDER BY
			O.HOST
			"

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
					
					$utcdiff=$ds.Tables[0].rows[0].TIMEZONE_OFFSET_S


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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
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


			    #volume throughput
				$query="select v.host, v.port, v.service_name, s.type,
				round(s.total_read_size / 1024 / 1024, 3) as `"ReadsMB`",
				round(s.total_read_size / case s.total_read_time when 0 then -1 else
			   s.total_read_time end, 3) as `"ReadMBpersec`",
				round(s.total_read_time / 1000 / 1000, 3) as `"ReadTimeSec`",
				trigger_read_ratio as `"Read Ratio`",
				round(s.total_write_size / 1024 / 1024, 3) as `"WritesMB`",
				round(s.total_write_size / case s.total_write_time when 0 then -1 else
			   s.total_write_time end, 3) as `"WriteMBpersec`",
				round(s.total_write_time / 1000 / 1000, 3) as `"WriteTimeSec`" ,
				trigger_write_ratio as `"Write Ratio`"
			   from `"PUBLIC`".`"M_VOLUME_IO_TOTAL_STATISTICS_RESET`" s, PUBLIC.M_VOLUMES v
			   where s.volume_id = v.volume_id
			   and type not in ( 'TRACE' )
			   order by type, service_name, s.volume_id; "
			   
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
									   SERVICE_NAME=$row.SERVICE_NAME
									   TYPE=$row.TYPE 
									   CollectorType="Performance"
									   PerfObject="Volumes"
									   PerfInstance=$row.Type
									   PerfCounter="Read_MB_Sec"
									   PerfValue=[double]$row.ReadMBpersec
								   }
								   $Resultsperf+= New-Object PSObject -Property @{
			   
									   HOST=$row.HOST
									   Instance=$sapinstance
									   Database=$defaultdb
									   SERVICE_NAME=$row.SERVICE_NAME
									   TYPE=$row.TYPE 
									   CollectorType="Performance"
									   PerfObject="Volumes"
									   PerfInstance=$row.Type
									   PerfCounter="Write_MB_Sec"
									   PerfValue=[double]$row.WriteMBpersec
								   }
			   
													 
							   }
			   
							   $Omsperfupload+=,$Resultsperf
						   }
			   #Save Point Duration
			   
			   $query="select start_time, volume_id,
				round(duration / 1000000) as `"DurationSec`",
				round(critical_phase_duration / 1000000) as `"CriticalSeconds`",
				round(total_size / 1024 / 1024) as `"SizeMB`",
				round(total_size / duration) as `"Appro. MB/sec`",
				round (flushed_rowstore_size / 1024 / 1024) as `"Row Store Part MB`"
			   from m_savepoints where start_time  > add_seconds(now(),-$($freq*60));"
			   
			   
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
									   TIMESTamp=$row.START_TIME
									   VOLUME_ID =$row.VOLUME_ID 
									   CollectorType="Performance"
									   PerfObject="SavePoint"
									   PerfInstance=$row.VOLUME_ID
									   PerfCounter="DurationSec"
									   PerfValue=[double]$row.DurationSec
								   }
								   $Resultsperf+= New-Object PSObject -Property @{
			   
									   HOST=$row.HOST
									   Instance=$sapinstance
									   Database=$defaultdb
									   TIMESTamp=$row.START_TIME
									   VOLUME_ID =$row.VOLUME_ID 
									   CollectorType="Performance"
									   PerfObject="SavePoint"
									   PerfInstance=$row.VOLUME_ID
									   PerfCounter="CriticalSeconds"
									   PerfValue=[double]$row.CriticalSeconds
								   }
								   $Resultsperf+= New-Object PSObject -Property @{
			   
									   HOST=$row.HOST
									   Instance=$sapinstance
									   Database=$defaultdb
									   TIMESTamp=$row.START_TIME
									   VOLUME_ID =$row.VOLUME_ID 
									   CollectorType="Performance"
									   PerfObject="SavePoint"
									   PerfInstance=$row.VOLUME_ID
									   PerfCounter="SizeMB"
									   PerfValue=[double]$row.SizeMB
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
						RECORDS=[long]$row.RECORDS
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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
						SYS_TIMESTAMP=([datetime]$row.LAST_PREPARATION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
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

			#######################################################################################
#added queries 

$query="SELECT HOST,
LPAD(PORT, 5) PORT,
SERVICE_NAME SERVICE,
LPAD(NUM, 5) NUM,
CONN_ID,
LPAD(THREAD_ID, 9) THREAD_ID,
THREAD_TYPE,
THREAD_STATE,
ACTIVE,
APP_USER,
DURATION_S,
CPU_TIME_S
FROM
( SELECT
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST')         != 0 THEN T.HOST               ELSE MAP(BI.HOST, '%', 'any', BI.HOST)                 END HOST,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'PORT')         != 0 THEN TO_VARCHAR(T.PORT)      ELSE MAP(BI.PORT, '%', 'any', BI.PORT)                 END PORT,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SERVICE')      != 0 THEN S.SERVICE_NAME       ELSE MAP(BI.SERVICE_NAME, '%', 'any', BI.SERVICE_NAME) END SERVICE_NAME,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'APP_USER')     != 0 THEN T.APP_USER           ELSE 'any'                                             END APP_USER,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'THREAD_TYPE')  != 0 THEN T.THREAD_TYPE        ELSE 'any'                                             END THREAD_TYPE,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'THREAD_STATE') != 0 THEN T.THREAD_STATE       ELSE 'any'                                             END THREAD_STATE,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'THREAD_ID')    != 0 THEN TO_VARCHAR(T.THREAD_ID) ELSE 'any'                                             END THREAD_ID,
  COUNT(*) NUM,
  MAP(MIN(T.CONN_ID), MAX(T.CONN_ID), LPAD(MAX(T.CONN_ID), 10), 'various') CONN_ID,
  MAP(MIN(T.ACTIVE), MAX(T.ACTIVE), MAX(T.ACTIVE), 'various') ACTIVE,
  LPAD(TO_DECIMAL(MAP(BI.AGGREGATION_TYPE, 'AVG', AVG(T.DURATION_MS), 'MAX', MAX(T.DURATION_MS), 'SUM', SUM(T.DURATION_MS)) / 1000, 10, 2), 10) DURATION_S,
  LPAD(TO_DECIMAL(MAP(BI.AGGREGATION_TYPE, 'AVG', AVG(T.CPU_TIME_US), 'MAX', MAX(T.CPU_TIME_US), 'SUM', SUM(T.CPU_TIME_US)) / 1000 / 1000, 10, 2), 10) CPU_TIME_S,
  BI.ORDER_BY
FROM
( SELECT                                      /* Modification section */
	'%' HOST,
	'%' PORT,
	'%' SERVICE_NAME,
	'X' ONLY_ACTIVE_THREADS,
	-1 CONN_ID,
	'SUM' AGGREGATION_TYPE,       /* MAX, AVG, SUM */
	'NONE' AGGREGATE_BY,          /* HOST, PORT, SERVICE, APP_USER, THREAD_TYPE, THREAD_STATE, THREAD_ID and comma separated combinations, NONE for no aggregation */
	'THREADS' ORDER_BY             /* THREAD_ID, CONNECTION, THREADS */
  FROM
	DUMMY
) BI,
  M_SERVICES S,
( SELECT
	HOST,
	PORT,
	CONNECTION_ID CONN_ID,
	THREAD_ID,
	THREAD_TYPE,
	THREAD_STATE,
	IS_ACTIVE ACTIVE,
	APPLICATION_USER_NAME APP_USER,
	DURATION DURATION_MS,
	CPU_TIME_SELF CPU_TIME_US
  FROM
	M_SERVICE_THREADS
) T
WHERE
  S.HOST LIKE BI.HOST AND
  TO_VARCHAR(S.PORT) LIKE BI.PORT AND
  S.SERVICE_NAME LIKE BI.SERVICE_NAME AND
  T.HOST = S.HOST AND
  T.PORT = S.PORT AND
  ( BI.ONLY_ACTIVE_THREADS = ' ' OR T.ACTIVE = 'TRUE' ) AND
  ( BI.CONN_ID = -1 OR T.CONN_ID = BI.CONN_ID )
GROUP BY
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST')         != 0 THEN T.HOST               ELSE MAP(BI.HOST, '%', 'any', BI.HOST)                 END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'PORT')         != 0 THEN TO_VARCHAR(T.PORT)      ELSE MAP(BI.PORT, '%', 'any', BI.PORT)                 END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SERVICE')      != 0 THEN S.SERVICE_NAME       ELSE MAP(BI.SERVICE_NAME, '%', 'any', BI.SERVICE_NAME) END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'APP_USER')     != 0 THEN T.APP_USER           ELSE 'any'                                             END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'THREAD_TYPE')  != 0 THEN T.THREAD_TYPE        ELSE 'any'                                             END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'THREAD_STATE') != 0 THEN T.THREAD_STATE       ELSE 'any'                                             END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'THREAD_ID')    != 0 THEN TO_VARCHAR(T.THREAD_ID) ELSE 'any'                                             END,
  BI.ORDER_BY,
  BI.AGGREGATION_TYPE
)
ORDER BY
MAP(ORDER_BY, 'THREAD_ID',   THREAD_ID, 'any', 'CONNECTION', CONN_ID, 'any'),
MAP(ORDER_BY, 'THREADS', NUM) DESC"
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
		   

		  $Resultsinv=$null
		  $Resultsinv=@(); 

		  IF($ds[0].Tables.rows)
		  {
			  foreach ($row in $ds.Tables[0].rows)
			  {
				  $Resultsinv+= New-Object PSObject -Property @{
					  HOST=$row.HOST.ToLower()
					  Instance=$sapinstance
					  CollectorType="Inventory"
					  Category="Thread"
					  Subcategory="Current"
					  Database=$defaultdb
					  PORT=$row.PORT
					  SERVICE=$row.SERVICE
					  NUM=$row.Num
					  CONN_ID=$row.CONN_ID
					  THREAD_ID=$row.THREAD_ID
					  THREAD_TYPE=$row.THREAD_TYPE
					   THREAD_STATE=$row.THREAD_STATE    
					   ACTIVE=$row.ACTIVE
					  APP_USER=$row.APP_USER 
					  DURATION_S=[double]$row.DURATION_S 
					  CPU_TIME_S=[double]$row.CPU_TIME_S
				  }
			  }
			  $Omsinvupload+=,$Resultsinv
		  }
# Tables - LArgest Inventory 
	  $query="SELECT OWNER,
TABLE_NAME,
S,                                        /* 'C' --> column store, 'R' --> row store */
LOADED L,                                 /* 'Y' --> fully loaded, 'P' --> partially loaded, 'N' --> not loaded */
HOST,
B T,                                      /* 'X' if table belongs to list of technical tables (SAP Note 2388483) */
U,                                        /* 'X' if unique index exists for table */
LPAD(ROW_NUM, 3) POS,
LPAD(COLS, 4) COLS,
LPAD(RECORDS, 12) RECORDS,
LPAD(TO_DECIMAL(TOTAL_DISK_MB / 1024, 10, 2), 7) DISK_GB,
LPAD(TO_DECIMAL(MAX_TOTAL_MEM_MB / 1024, 10, 2), 10) MAX_MEM_GB,
LPAD(TO_DECIMAL(TOTAL_MEM_MB / 1024, 10, 2), 10) CUR_MEM_GB,
LPAD(TO_DECIMAL(`"TO`TAL_MEM_%`", 9, 2), 5) `"MEM_%`",
LPAD(TO_DECIMAL(SUM(`"TOTAL_MEM_%`") OVER (ORDER BY ROW_NUM), 5, 2), 5) `"CUM_%`",
LPAD(PARTITIONS, 5) `"PART.`",
LPAD(TO_DECIMAL(TABLE_MEM_MB / 1024, 10, 2), 10) TAB_MEM_GB,
LPAD(INDEXES, 4) `"IND.`",
LPAD(TO_DECIMAL(INDEX_MEM_MB / 1024, 10, 2), 10) IND_MEM_GB,
LPAD(LOBS, 4) LOBS,
LPAD(TO_DECIMAL(LOB_MB / 1024, 10, 2), 6) LOB_GB
FROM
( SELECT
  OWNER,
  TABLE_NAME,
  HOST,
  B,
  CASE WHEN UNIQUE_INDEXES = 0 THEN ' ' ELSE 'X' END U,
  MAP(STORE, 'COLUMN', 'C', 'ROW', 'R') S,
  COLS,
  RECORDS,
  TABLE_MEM_MB + INDEX_MEM_RS_MB TOTAL_MEM_MB,
  IFNULL(MAX_MEM_MB, TABLE_MEM_MB + INDEX_MEM_RS_MB) MAX_TOTAL_MEM_MB,
  TABLE_MEM_MB - INDEX_MEM_CS_MB TABLE_MEM_MB,             /* Indexes are contained in CS table size */
  LOADED,
  TOTAL_DISK_MB,
  CASE 
	WHEN SUM(TABLE_MEM_MB + INDEX_MEM_RS_MB) OVER () * 100 = 0 THEN 0 
	ELSE (TABLE_MEM_MB +  INDEX_MEM_RS_MB) / SUM(TABLE_MEM_MB + INDEX_MEM_RS_MB) OVER () * 100 
  END `"TOTAL_MEM_%`",
  PARTITIONS,
  INDEXES,
  INDEX_MEM_RS_MB + INDEX_MEM_CS_MB INDEX_MEM_MB,
  LOBS,
  LOB_MB,
  ROW_NUMBER () OVER ( ORDER BY MAP ( ORDER_BY, 
	'TOTAL_DISK',  TOTAL_DISK_MB, 
	'CURRENT_MEM', TABLE_MEM_MB + INDEX_MEM_RS_MB, 
	'MAX_MEM',     IFNULL(MAX_MEM_MB, TABLE_MEM_MB + INDEX_MEM_RS_MB),
	'TABLE_MEM',   TABLE_MEM_MB - INDEX_MEM_CS_MB, 
	'INDEX_MEM',   INDEX_MEM_RS_MB + INDEX_MEM_CS_MB ) 
	DESC, OWNER,   TABLE_NAME ) ROW_NUM,
  RESULT_ROWS,
  ORDER_BY
FROM
( SELECT
	T.SCHEMA_NAME OWNER,
	T.TABLE_NAME,
	TS.HOST,
	CASE WHEN T.TABLE_NAME IN
	( 'BALHDR', 'BALHDRP', 'BALM', 'BALMP', 'BALDAT', 'BALC', 
	  'BAL_INDX', 'EDIDS', 'EDIDC', 'EDIDOC', 'EDI30C', 'EDI40', 'EDID4',
	  'IDOCREL', 'SRRELROLES', 'SWFGPROLEINST', 'SWP_HEADER', 'SWP_NODEWI', 'SWPNODE',
	  'SWPNODELOG', 'SWPSTEPLOG', 'SWW_CONT', 'SWW_CONTOB', 'SWW_WI2OBJ', 'SWWCNTP0',
	  'SWWCNTPADD', 'SWWEI', 'SWWLOGHIST', 'SWWLOGPARA', 'SWWWIDEADL', 'SWWWIHEAD', 
	  'SWWWIRET', 'SWZAI', 'SWZAIENTRY', 'SWZAIRET', 'SWWUSERWI',                  
	  'BDCP', 'BDCPS', 'BDCP2', 'DBTABLOG', 'DBTABPRT', 
	  'ARFCSSTATE', 'ARFCSDATA', 'ARFCRSTATE', 'TRFCQDATA',
	  'TRFCQIN', 'TRFCQOUT', 'TRFCQSTATE', 'SDBAH', 'SDBAD', 'DBMSGORA', 'DDLOG',
	  'APQD', 'TST01', 'TST03', 'TSPEVJOB', 'TXMILOGRAW', 'TSPEVDEV', 
	  'SNAP', 'SMO8FTCFG', 'SMO8FTSTP', 'SMO8_TMSG', 'SMO8_TMDAT', 
	  'SMO8_DLIST', 'SMW3_BDOC', 'SMW3_BDOC1', 'SMW3_BDOC2', 
	  'SMW3_BDOC4', 'SMW3_BDOC5', 'SMW3_BDOC6', 'SMW3_BDOC7', 'SMW3_BDOCQ', 'SMWT_TRC',
	  'TPRI_PAR', 'RSBMLOGPAR', 'RSBMLOGPAR_DTP', 'RSBMNODES', 'RSBMONMESS',
	  'RSBMONMESS_DTP', 'RSBMREQ_DTP', 'RSCRTDONE', 'RSDELDONE', 'RSHIEDONE',
	  'RSLDTDONE', 'RSMONFACT', 'RSMONICTAB', 'RSMONIPTAB', 'RSMONMESS', 'RSMONRQTAB', 'RSREQDONE',
	  'RSRULEDONE', 'RSSELDONE', 'RSTCPDONE', 'RSUICDONE',
	  'VBDATA', 'VBMOD', 'VBHDR', 'VBERROR', 'ENHLOG',
	  'VDCHGPTR', 'JBDCPHDR2', 'JBDCPPOS2', 'SWELOG', 'SWELTS', 'SWFREVTLOG',
	  'ARDB_STAT0', 'ARDB_STAT1', 'ARDB_STAT2', 'TAAN_DATA', 'TAAN_FLDS', 'TAAN_HEAD', 'QRFCTRACE', 'QRFCLOG',
	  'DDPRS', 'TBTCO', 'TBTCP', 'TBTCS', 'MDMFDBEVENT', 'MDMFDBID', 'MDMFDBPR',
	  'RSRWBSTORE', 'RSRWBINDEX', '/SAPAPO/LISMAP', '/SAPAPO/LISLOG', 
	  'CCMLOG', 'CCMLOGD', 'CCMSESSION', 'CCMOBJLST', 'CCMOBJKEYS',
	  'RSBATCHCTRL', 'RSBATCHCTRL_PAR', 'RSBATCHDATA', 'RSBATCHHEADER', 'RSBATCHPROT', 'RSBATCHSTACK',
	  'SXMSPMAST', 'SXMSPMAST2', 'SXMSPHIST', 
	  'SXMSPHIST2', 'SXMSPFRAWH', 'SXMSPFRAWD', 'SXMSCLUR', 'SXMSCLUR2', 'SXMSCLUP',
	  'SXMSCLUP2', 'SWFRXIHDR', 'SWFRXICNT', 'SWFRXIPRC', 
	  'XI_AF_MSG', 'XI_AF_MSG_AUDIT', 'BC_MSG', 'BC_MSG_AUDIT',
	  'SMW0REL', 'SRRELROLES', 'COIX_DATA40', 'T811E', 'T811ED', 
	  'T811ED2', 'RSDDSTATAGGR', 'RSDDSTATAGGRDEF', 'RSDDSTATCOND', 'RSDDSTATDTP',
	  'RSDDSTATDELE', 'RSDDSTATDM', 'RSDDSTATEVDATA', 'RSDDSTATHEADER',
	  'RSDDSTATINFO', 'RSDDSTATLOGGING', 'RSERRORHEAD', 'RSERRORLOG',
	  'DFKKDOUBTD_W', 'DFKKDOUBTD_RET_W', 'RSBERRORLOG', 'INDX',
	  'SOOD', 'SOOS', 'SOC3', 'SOFFCONT1', 'BCST_SR', 'BCST_CAM',
	  'SICFRECORDER', 'CRM_ICI_TRACES', 'RSPCINSTANCE', 'RSPCINSTANCET',
	  'GVD_BGPROCESS', 'GVD_BUFF_POOL_ST', 'GVD_LATCH_MISSES', 
	  'GVD_ENQUEUE_STAT', 'GVD_FILESTAT', 'GVD_INSTANCE',    
	  'GVD_PGASTAT', 'GVD_PGA_TARGET_A', 'GVD_PGA_TARGET_H',
	  'GVD_SERVERLIST', 'GVD_SESSION_EVT', 'GVD_SESSION_WAIT',
	  'GVD_SESSION', 'GVD_PROCESS', 'GVD_PX_SESSION',  
	  'GVD_WPTOTALINFO', 'GVD_ROWCACHE', 'GVD_SEGMENT_STAT',
	  'GVD_SESSTAT', 'GVD_SGACURRRESIZ', 'GVD_SGADYNFREE',  
	  'GVD_SGA', 'GVD_SGARESIZEOPS', 'GVD_SESS_IO',     
	  'GVD_SGASTAT', 'GVD_SGADYNCOMP', 'GVD_SEGSTAT',     
	  'GVD_SPPARAMETER', 'GVD_SHAR_P_ADV', 'GVD_SQLAREA',     
	  'GVD_SQL', 'GVD_SQLTEXT', 'GVD_SQL_WA_ACTIV',
	  'GVD_SQL_WA_HISTO', 'GVD_SQL_WORKAREA', 'GVD_SYSSTAT',     
	  'GVD_SYSTEM_EVENT', 'GVD_DATABASE', 'GVD_CURR_BLKSRV', 
	  'GVD_DATAGUARD_ST', 'GVD_DATAFILE', 'GVD_LOCKED_OBJEC',
	  'GVD_LOCK_ACTIVTY', 'GVD_DB_CACHE_ADV', 'GVD_LATCHHOLDER', 
	  'GVD_LATCHCHILDS', 'GVD_LATCH', 'GVD_LATCHNAME',   
	  'GVD_LATCH_PARENT', 'GVD_LIBRARYCACHE', 'GVD_LOCK',        
	  'GVD_MANGD_STANBY', 'GVD_OBJECT_DEPEN', 'GVD_PARAMETER',   
	  'GVD_LOGFILE', 'GVD_PARAMETER2', 'GVD_TEMPFILE',    
	  'GVD_UNDOSTAT', 'GVD_WAITSTAT', 'ORA_SNAPSHOT',
	  '/TXINTF/TRACE', 'RSECLOG', 'RSECUSERAUTH_CL', 'RSWR_DATA',
	  'RSECVAL_CL', 'RSECHIE_CL', 'RSECTXT_CL', 'RSECSESSION_CL',
	  'UPC_STATISTIC', 'UPC_STATISTIC2', 'UPC_STATISTIC3',
	  'RSTT_CALLSTACK', 'RSZWOBJ', 'RSIXWWW', 'RSZWBOOKMARK', 'RSZWVIEW', 
	  'RSZWITEM', 'RSR_CACHE_DATA_B', 'RSR_CACHE_DATA_C', 'RSR_CACHE_DBS_BL',
	  'RSR_CACHE_FFB', 'RSR_CACHE_QUERY', 'RSR_CACHE_STATS',
	  'RSR_CACHE_VARSHB', 'WRI`$_OPTSTAT_HISTGRM_HISTORY',
	  'WRI`$_OPTSTAT_HISTHEAD_HISTORY', 'WRI`$_OPTSTAT_IND_HISTORY',
	  'WRI`$_OPTSTAT_TAB_HISTORY', 'WRH`$_ACTIVE_SESSION_HISTORY',
	  'RSODSACTUPDTYPE', 'TRFC_I_SDATA', 'TRFC_I_UNIT', 'TRFC_I_DEST', 
	  'TRFC_I_UNIT_LOCK', 'TRFC_I_EXE_STATE', 'TRFC_I_ERR_STATE',
	  'DYNPSOURCE', 'DYNPLOAD', 'D010TAB', 'REPOSRC', 'REPOLOAD',
	  'RSOTLOGOHISTORY', 'SQLMD', '/SDF/ZQLMD', 'RSSTATMANREQMDEL',
	  'RSSTATMANREQMAP', 'RSICPROT', 'RSPCPROCESSLOG',
	  'DSVASRESULTSGEN', 'DSVASRESULTSSEL', 'DSVASRESULTSCHK', 
	  'DSVASRESULTSATTR', 'DSVASREPODOCS', 'DSVASSESSADMIN', 'DOKCLU',
	  'ORA_SQLC_HEAD', 'ORA_SQLC_DATA', 'CS_AUDIT_LOG_', 'RSBKSELECT',
	  'SWN_NOTIF', 'SWN_NOTIFTSTMP', 'SWN_SENDLOG', 'JOB_LOG',
	  'SWNCMONI', 'BC_SLD_CHANGELOG', 'ODQDATA_F', 'STATISTICS_ALERTS', 'STATISTICS_ALERTS_BASE',
	  'SRT_UTIL_ERRLOG', 'SRT_MONILOG_DATA', 'SRT_RTC_DT_RT', 'SRT_RTC_DATA', 'SRT_RTC_DATA_RT', 
	  'SRT_CDTC', 'SRT_MMASTER', 'SRT_SEQ_HDR_STAT', 'SRTM_SUB', 'SRT_SEQ_REORG',
	  'UJ0_STAT_DTL', 'UJ0_STAT_HDR', '/SAPTRX/APPTALOG', '/SAPTRX/AOTREF', 'SSCOOKIE',
	  'UJF_DOC', 'UJF_DOC_CLUSTER', '/AIF/PERS_XML', 'SE16N_CD_DATA', 'SE16N_CD_KEY',
	  'RSBKDATA', 'RSBKDATAINFO', 'RSBKDATAPAKID', 'RSBKDATAPAKSEL',
	  'ECLOG_CALL', 'ECLOG_DATA', 'ECLOG_EXEC', 'ECLOG_EXT', 'ECLOG_HEAD', 'ECLOG_RESTAB', 
	  'ECLOG_SCNT', 'ECLOG_SCR', 'ECLOG_SEL', 'ECLOG_XDAT',
	  'CROSS', 'WBCROSSGT', 'WBCROSSI', 'OBJECT_HISTORY', '/SSF/PTAB'
	) OR
	  ( T.TABLE_NAME LIKE 'GLOBAL%' AND T.SCHEMA_NAME = '_SYS_STATISTICS' ) OR
	  ( T.TABLE_NAME LIKE 'HOST%' AND T.SCHEMA_NAME = '_SYS_STATISTICS' ) OR
	  T.TABLE_NAME LIKE 'ZARIX%' OR
	  T.TABLE_NAME LIKE '/BI0/0%' OR
	  T.TABLE_NAME LIKE '/BIC/B%' OR
	  T.TABLE_NAME LIKE '/BI_/H%' OR
	  T.TABLE_NAME LIKE '/BI_/I%' OR
	  T.TABLE_NAME LIKE '/BI_/J%' OR
	  T.TABLE_NAME LIKE '/BI_/K%' OR
	  T.TABLE_NAME LIKE '`$BPC`$HC$%' OR
	  T.TABLE_NAME LIKE '`$BPC`$TMP%'
	  THEN 'X' ELSE ' ' END B,
	( SELECT COUNT(*) FROM INDEXES I WHERE I.SCHEMA_NAME = T.SCHEMA_NAME AND I.TABLE_NAME = T.TABLE_NAME AND I.INDEX_TYPE LIKE '%UNIQUE%' ) UNIQUE_INDEXES,
	CASE WHEN T.IS_COLUMN_TABLE = 'FALSE' THEN 'ROW' ELSE 'COLUMN' END STORE,
	( SELECT COUNT(*) FROM TABLE_COLUMNS C WHERE C.SCHEMA_NAME = T.SCHEMA_NAME AND C.TABLE_NAME = T.TABLE_NAME ) COLS,
	T.RECORD_COUNT RECORDS,
	T.TABLE_SIZE / 1024 / 1024 TABLE_MEM_MB,
	TS.LOADED,
	TS.MAX_MEM_MB,
	TP.DISK_SIZE / 1024 / 1024 TOTAL_DISK_MB,
	( SELECT GREATEST(COUNT(*), 1) FROM M_CS_PARTITIONS P WHERE P.SCHEMA_NAME = T.SCHEMA_NAME AND P.TABLE_NAME = T.TABLE_NAME ) PARTITIONS,
	( SELECT COUNT(*) FROM INDEXES I WHERE I.SCHEMA_NAME = T.SCHEMA_NAME AND I.TABLE_NAME = T.TABLE_NAME ) INDEXES,
	( SELECT IFNULL(SUM(INDEX_SIZE), 0) / 1024 / 1024 FROM M_RS_INDEXES I WHERE I.SCHEMA_NAME = T.SCHEMA_NAME AND I.TABLE_NAME = T.TABLE_NAME ) INDEX_MEM_RS_MB,
	( SELECT 
		IFNULL(SUM
		( CASE INTERNAL_ATTRIBUTE_TYPE
			WHEN 'TREX_UDIV'         THEN 0                             /* technical necessity, completely treated as `"table`" */
			WHEN 'ROWID'             THEN 0                             /* technical necessity, completely treated as `"table`" */
			WHEN 'VALID_FROM'        THEN 0                             /* technical necessity, completely treated as `"table`" */
			WHEN 'VALID_TO'          THEN 0                             /* technical necessity, completely treated as `"table`" */
			WHEN 'TEXT'              THEN MEMORY_SIZE_IN_TOTAL          /* both concat attribute and index on it treated as`"index`" */
			WHEN 'TREX_EXTERNAL_KEY' THEN MEMORY_SIZE_IN_TOTAL          /* both concat attribute and index on it treated as `"index`" */
			WHEN 'UNKNOWN'           THEN MEMORY_SIZE_IN_TOTAL          /* both concat attribute and index on it treated as `"index`" */
			WHEN 'CONCAT_ATTRIBUTE'  THEN MEMORY_SIZE_IN_TOTAL          /* both concat attribute and index on it treated as `"index`" */
			ELSE MAIN_MEMORY_SIZE_IN_INDEX + DELTA_MEMORY_SIZE_IN_INDEX /* index structures on single columns treated as `"index`" */
		  END
		), 0) / 1024 / 1024
	  FROM 
		M_CS_ALL_COLUMNS C 
	  WHERE 
		C.SCHEMA_NAME = T.SCHEMA_NAME AND 
		C.TABLE_NAME = T.TABLE_NAME
	) INDEX_MEM_CS_MB,
	( SELECT IFNULL(MAX(MAP(CS_DATA_TYPE_NAME, 'ST_MEMORY_LOB', 'M', 'LOB', 'H', 'ST_DISK_LOB', 'D', 'U')), '') || COUNT(*)
		FROM TABLE_COLUMNS C 
	  WHERE C.SCHEMA_NAME = T.SCHEMA_NAME AND C.TABLE_NAME = T.TABLE_NAME AND DATA_TYPE_NAME IN ( 'BLOB', 'CLOB', 'NCLOB', 'TEXT' ) ) LOBS,
	( SELECT IFNULL(SUM(PHYSICAL_SIZE), 0) / 1024 / 1024 FROM M_TABLE_LOB_FILES L WHERE L.SCHEMA_NAME = T.SCHEMA_NAME AND L.TABLE_NAME = T.TABLE_NAME ) LOB_MB,
	BI.ONLY_TECHNICAL_TABLES,
	BI.RESULT_ROWS,
	BI.ORDER_BY
  FROM
  ( SELECT                                       /* Modification section */
	  '%' SCHEMA_NAME,
	  '%' TABLE_NAME,
	  '%' STORE,                             /* ROW, COLUMN, % */
	  ' ' ONLY_TECHNICAL_TABLES,
	  50 RESULT_ROWS,
	  'TOTAL_DISK' ORDER_BY                    /* TOTAL_DISK, CURRENT_MEM, MAX_MEM, TABLE_MEM, INDEX_MEM */
	FROM
	  DUMMY
  ) BI,
	M_TABLES T,
	( SELECT 
		SCHEMA_NAME, 
		TABLE_NAME, 
		MAP(MIN(HOST), MAX(HOST), MIN(HOST), 'various') HOST, 
		MAP(MAX(LOADED), 'NO', 'N', 'FULL', 'Y', 'PARTIALLY', 'P') LOADED,
		SUM(ESTIMATED_MAX_MEMORY_SIZE_IN_TOTAL) / 1024 / 1024 MAX_MEM_MB
	  FROM 
		M_CS_TABLES 
	  GROUP BY 
		SCHEMA_NAME, 
		TABLE_NAME 
	  UNION
	  ( SELECT 
		  SCHEMA_NAME, 
		  TABLE_NAME, 
		  MAP(MIN(HOST), MAX(HOST), MIN(HOST), 'various') HOST, 
		  'Y' LOADED,
		  NULL MAX_MEM_MB
		FROM 
		  M_RS_TABLES 
		GROUP BY 
		  SCHEMA_NAME, 
		  TABLE_NAME 
	  )
	) TS,
	M_TABLE_PERSISTENCE_STATISTICS TP
  WHERE
	T.SCHEMA_NAME LIKE BI.SCHEMA_NAME AND
	T.TABLE_NAME LIKE BI.TABLE_NAME AND
	T.SCHEMA_NAME = TP.SCHEMA_NAME AND
	T.TABLE_NAME = TP.TABLE_NAME AND
	T.SCHEMA_NAME = TS.SCHEMA_NAME AND
	T.TABLE_NAME = TS.TABLE_NAME AND
	( BI.STORE = '%' OR
	  BI.STORE = 'ROW' AND T.IS_COLUMN_TABLE = 'FALSE' OR
	  BI.STORE = 'COLUMN' AND T.IS_COLUMN_TABLE = 'TRUE'
	)
)
WHERE
  ( ONLY_TECHNICAL_TABLES = ' ' OR B = 'X' )
)
WHERE
( RESULT_ROWS = -1 OR ROW_NUM <= RESULT_ROWS )
ORDER BY
ROW_NUM
"
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
		   

		  
		  $Resultsinv=$null
		  $Resultsinv=@(); 


		  IF($ds[0].Tables.rows)
		  {
			  foreach ($row in $ds.Tables[0].rows)
			  {
				  $Resultsinv+= New-Object PSObject -Property @{
					  HOST=$row.HOST.ToLower()
					  Instance=$sapinstance
					  CollectorType="Inventory"
					  Category="Tables"
					  Subcategory="Largest"
					  Database=$defaultdb
					  TableName=$row.TABLE_NAME
					  StoreType=$row.S
					  Loaded=$row.L
					  POS=$row.POS
					  COLS=$row.COLS
					  RECORDS=[long]$row.RECORDS    
				  }
			  }
			  $Omsinvupload+=,$Resultsinv
		  }

#inventory Sessions    
$query="SELECT  C.HOST,
LPAD(C.PORT, 5) PORT,
S.SERVICE_NAME SERVICE,
IFNULL(LPAD(C.CONN_ID, 7), '') CONN_ID,
IFNULL(LPAD(C.THREAD_ID, 9), '') THREAD_ID,
IFNULL(LPAD(C.TRANSACTION_ID, 8), '') TRANS_ID,
IFNULL(LPAD(C.UPD_TRANS_ID, 9), '') UPD_TID,
IFNULL(LPAD(C.CLIENT_PID, 10), '') CLIENT_PID,
C.CLIENT_HOST,
C.TRANSACTION_START,
IFNULL(LPAD(TO_DECIMAL(C.TRANSACTION_ACTIVE_DAYS, 10, 2), 8), '') ACT_DAYS,
C.THREAD_TYPE,
C.THREAD_STATE,
C.CALLER,
C.WAITING_FOR,
C.APPLICATION_SOURCE,
C.STATEMENT_HASH,
CASE
  WHEN MAX_THREAD_DETAIL_LENGTH = -1 THEN THREAD_DETAIL
  WHEN THREAD_DETAIL_FROM_POS <= 15 THEN
	SUBSTR(THREAD_DETAIL, 1, MAX_THREAD_DETAIL_LENGTH)
  ELSE
	SUBSTR(SUBSTR(THREAD_DETAIL, 1, LOCATE(THREAD_DETAIL, CHAR(32))) || '...' || SUBSTR(THREAD_DETAIL, THREAD_DETAIL_FROM_POS - 1), 1, MAX_THREAD_DETAIL_LENGTH) 
END THREAD_DETAIL,
IFNULL(LPAD(TO_DECIMAL(C.USED_MEMORY_SIZE / 1024 / 1024, 10, 2), 9), '') MEMORY_MB,
C.THREAD_METHOD,
C.TRANSACTION_STATE TRANS_STATE,
C.TRANSACTION_TYPE,
C.TABLE_NAME MVCC_TABLE_NAME,
C.APPLICATION_USER_NAME APP_USER
FROM
( SELECT                     /* Modification section */
  '%' HOST,
  '%' PORT,
  '%' SERVICE_NAME,
  -1 CONN_ID,
  -1 THREAD_ID,
  '%' THREAD_STATE,
  -1 TRANSACTION_ID,
  -1 UPDATE_TRANSACTION_ID,
  -1 CLIENT_PID,
  'X' ONLY_ACTIVE_THREADS,
  'X' ONLY_ACTIVE_TRANSACTIONS,
  ' ' ONLY_ACTIVE_UPDATE_TRANSACTIONS,
  ' ' ONLY_ACTIVE_SQL_STATEMENTS,
  ' ' ONLY_MVCC_BLOCKER,
  80 MAX_THREAD_DETAIL_LENGTH,
  'TRANSACTION_TIME' ORDER_BY           /* CONNECTION, THREAD, TRANSACTION, UPDATE_TRANSACTION, TRANSACTION_TIME */
FROM
  DUMMY
) BI,
M_SERVICES S,
( SELECT
  IFNULL(C.HOST, IFNULL(TH.HOST, T.HOST)) HOST,
  IFNULL(C.PORT, IFNULL(TH.PORT, T.PORT)) PORT,
  C.CONNECTION_ID CONN_ID,
  TH.THREAD_ID,
  IFNULL(TH.THREAD_STATE, '') THREAD_STATE,
  IFNULL(TH.THREAD_METHOD, '') THREAD_METHOD,
  IFNULL(TH.THREAD_TYPE, '') THREAD_TYPE,
  REPLACE(LTRIM(IFNULL(TH.THREAD_DETAIL, IFNULL(S.STATEMENT_STRING, ''))), CHAR(9), CHAR(32)) THREAD_DETAIL,
  LOCATE(LTRIM(UPPER(IFNULL(TH.THREAD_DETAIL, IFNULL(S.STATEMENT_STRING, '')))), 'FROM ') THREAD_DETAIL_FROM_POS,
  T.TRANSACTION_ID,
  IFNULL(T.TRANSACTION_STATUS, '') TRANSACTION_STATE,
  IFNULL(T.TRANSACTION_TYPE, '') TRANSACTION_TYPE,
  T.UPDATE_TRANSACTION_ID UPD_TRANS_ID,
  IFNULL(TH.CALLER, '') CALLER,
  CASE WHEN BT.LOCK_OWNER_UPDATE_TRANSACTION_ID IS NOT NULL THEN 'UPD_TID: ' || BT.LOCK_OWNER_UPDATE_TRANSACTION_ID || CHAR(32) ELSE '' END ||
	CASE WHEN TH.CALLING IS NOT NULL AND TH.CALLING != '' THEN 'CALLING: ' || TH.CALLING || CHAR(32) ELSE '' END WAITING_FOR,
  IFNULL(TO_VARCHAR(T.START_TIME, 'YYYY/MM/DD HH24:MI:SS'), '') TRANSACTION_START,
  SECONDS_BETWEEN(T.START_TIME, CURRENT_TIMESTAMP) / 86400 TRANSACTION_ACTIVE_DAYS,
  IFNULL(C.CLIENT_HOST, '') CLIENT_HOST,
  C.CLIENT_PID,
  MT.MIN_SNAPSHOT_TS,
  TA.TABLE_NAME,
  S.APPLICATION_SOURCE,
  S.STATEMENT_STRING,
  S.USED_MEMORY_SIZE,
  SC.STATEMENT_HASH,
  TH.APPLICATION_USER_NAME
FROM  
  M_CONNECTIONS C FULL OUTER JOIN
  M_SERVICE_THREADS TH ON
	TH.CONNECTION_ID = C.CONNECTION_ID AND
	TH.HOST = C.HOST AND
	TH.PORT = C.PORT FULL OUTER JOIN
  M_TRANSACTIONS T ON
	T.TRANSACTION_ID = C.TRANSACTION_ID LEFT OUTER JOIN
  M_PREPARED_STATEMENTS S ON
	C.CURRENT_STATEMENT_ID = S.STATEMENT_ID FULL OUTER JOIN
  M_SQL_PLAN_CACHE SC ON
	S.PLAN_ID = SC.PLAN_ID FULL OUTER JOIN
  M_BLOCKED_TRANSACTIONS BT ON
	T.UPDATE_TRANSACTION_ID = BT.BLOCKED_UPDATE_TRANSACTION_ID LEFT OUTER JOIN
  ( SELECT
	  HOST,
	  PORT,
	  NUM_VERSIONS,
	  TABLE_ID,
	  MIN_SNAPSHOT_TS,
	  MIN_READ_TID,
	  MIN_WRITE_TID
	FROM
	( SELECT
		HOST,
		PORT,
		MAX(MAP(NAME, 'NUM_VERSIONS',                 VALUE, 0))            NUM_VERSIONS,
		MAX(MAP(NAME, 'TABLE_ID_OF_MAX_NUM_VERSIONS', VALUE, 0))            TABLE_ID,
		MAX(MAP(NAME, 'MIN_SNAPSHOT_TS',              TO_NUMBER(VALUE), 0)) MIN_SNAPSHOT_TS,
		MAX(MAP(NAME, 'MIN_READ_TID',                 TO_NUMBER(VALUE), 0)) MIN_READ_TID,
		MAX(MAP(NAME, 'MIN_WRITE_TID',                TO_NUMBER(VALUE), 0)) MIN_WRITE_TID
	  FROM
		M_MVCC_TABLES
	  GROUP BY
		HOST,
		PORT
	) 
	WHERE
	  TABLE_ID != 0
  ) MT ON
	  MT.MIN_SNAPSHOT_TS = T.MIN_MVCC_SNAPSHOT_TIMESTAMP LEFT OUTER JOIN
	TABLES TA ON
	  TA.TABLE_OID = MT.TABLE_ID 
	  WHERE (C.START_TIME  > add_seconds(now(),-$($freq*60))) OR  (C.END_TIME  > add_seconds(now(),-$($freq*60)))
) C
WHERE
S.HOST LIKE BI.HOST AND
TO_VARCHAR(S.PORT) LIKE BI.PORT AND
S.SERVICE_NAME LIKE BI.SERVICE_NAME AND
C.HOST = S.HOST AND
C.PORT = S.PORT AND
 ( BI.CONN_ID = -1 OR BI.CONN_ID = C.CONN_ID ) AND
( BI.THREAD_ID = -1 OR BI.THREAD_ID = C.THREAD_ID ) AND
C.THREAD_STATE LIKE BI.THREAD_STATE AND
( BI.ONLY_ACTIVE_THREADS = ' ' OR C.THREAD_STATE NOT IN ( 'Inactive', '') ) AND
( BI.TRANSACTION_ID = -1 OR BI.TRANSACTION_ID = C.TRANSACTION_ID ) AND
( BI.CLIENT_PID = -1 OR BI.CLIENT_PID = C.CLIENT_PID ) AND
( BI.UPDATE_TRANSACTION_ID = -1 OR BI.UPDATE_TRANSACTION_ID = C.UPD_TRANS_ID ) AND
( BI.ONLY_ACTIVE_UPDATE_TRANSACTIONS = ' ' OR C.UPD_TRANS_ID > 0 ) AND
( BI.ONLY_ACTIVE_TRANSACTIONS = ' ' OR C.TRANSACTION_STATE = 'ACTIVE' ) AND
( BI.ONLY_ACTIVE_SQL_STATEMENTS = ' ' OR C.STATEMENT_STRING IS NOT NULL ) AND
( BI.ONLY_MVCC_BLOCKER = ' ' OR C.MIN_SNAPSHOT_TS IS NOT NULL )
ORDER BY
MAP(BI.ORDER_BY, 
  'CONNECTION',         C.CONN_ID, 
  'THREAD',             C.THREAD_ID, 
  'TRANSACTION',        C.TRANSACTION_ID,
  'UPDATE_TRANSACTION', C.UPD_TRANS_ID),
MAP(BI.ORDER_BY,
  'TRANSACTION_TIME',   C.TRANSACTION_START),
C.CONN_ID,
C.THREAD_ID,
C.TRANSACTION_ID
"
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
		   

		  $Resultsinv=$null
		  $Resultsinv=@(); 


		  IF($ds[0].Tables.rows)
		  {
			  foreach ($row in $ds.Tables[0].rows)
			  {
				  $Resultsinv+= New-Object PSObject -Property @{
					  HOST=$row.HOST.ToLower()
					  Instance=$sapinstance
					  CollectorType="Inventory"
					  Category="Sessions"
					  Database=$defaultdb
					  PORT=$row.PORT
					  SERVICE=$row.Service
					  CONN_ID=$row.CONN_ID
					  THREAD_ID=$row.THREAD_ID
					  TRANS_ID=$row.TRANS_ID
					  UPD_TID =$row.UPD_TID 
					  CLIENT_HOST=$row.CLIENT_HOST
					  TRANSACTION_START=$row.TRANSACTION_START
					  ACT_DAYS=[double]$row.ACT_DAYS
					  THREAD_TYPE=$row.THREAD_TYPE
					  THREAD_STATE =$row.THREAD_STATE 
					  THREAD_DETAIL=$row.THREAD_DETAIL
					  CALLER=$row.CALLER
					  STATEMENT_HASH =$row.STATEMENT_HASH 
					  MEMORY_MB=[double]$row.MEMORY_MB
					  THREAD_METHOD=$row.THREAD_METHOD
					  TRANS_STATE=$row.TRANS_STATE
					  TRANSACTION_TYPE =$row.TRANSACTION_TYPE 
					  APP_USER =$row.APP_USER 

				  }
			  }
			  $Omsinvupload+=,$Resultsinv
		  }

  $checkfreq=900
IF($firstrun){$checkfreq=2592000}Else{$checkfreq=900} # decide if you change 'HOUR' TIME_AGGREGATE_BY 

#backup inventory  

# not enabled 
If($MDC)
{
  $query="Select START_TIME,
HOST,
SERVICE_NAME,
DATABASE_NAME DB_NAME,
LPAD(BACKUP_ID, 13) BACKUP_ID,
BACKUP_TYPE,
DATA_TYPE,
STATUS,
LPAD(BACKUPS, 7) BACKUPS,
LPAD(TO_DECIMAL(MAP(BACKUPS, 0, 0, NUM_LOG_FULL / BACKUPS * 100), 10, 2), 12) FULL_LOG_PCT,
AGG,
LPAD(TO_DECIMAL(RUNTIME_H * 60, 10, 2), 11) RUNTIME_MIN,
LPAD(TO_DECIMAL(BACKUP_SIZE_MB, 10, 2), 14) BACKUP_SIZE_MB,
LPAD(TO_DECIMAL(MAP(RUNTIME_H, 0, 0, BACKUP_SIZE_MB / RUNTIME_H / 3600), 10, 2), 8) MB_PER_S,
LPAD(TO_DECIMAL(SECONDS_BETWEEN(MAX_START_TIME, CURRENT_TIMESTAMP) / 86400, 10, 2), 11) DAYS_PASSED,
MESSAGE
FROM
( SELECT
  START_TIME,
  HOST,
  SERVICE_NAME,
  DATABASE_NAME,
  BACKUP_ID,
  BACKUP_TYPE,
  BACKUP_DATA_TYPE DATA_TYPE,
  STATUS,
  NUM_BACKUP_RUNS BACKUPS,
  NUM_LOG_FULL,
  AGGREGATION_TYPE AGG,
  CASE AGGREGATION_TYPE
	WHEN 'SUM' THEN SUM_RUNTIME_H
	WHEN 'AVG' THEN MAP(NUM_BACKUP_RUNS, 0, 0, SUM_RUNTIME_H / NUM_BACKUP_RUNS)
	WHEN 'MAX' THEN MAX_RUNTIME_H
  END RUNTIME_H,
  CASE AGGREGATION_TYPE
	WHEN 'SUM' THEN SUM_BACKUP_SIZE_MB
	WHEN 'AVG' THEN MAP(NUM_BACKUP_RUNS, 0, 0, SUM_BACKUP_SIZE_MB / NUM_BACKUP_RUNS)
	WHEN 'MAX' THEN MAX_BACKUP_SIZE_MB
  END BACKUP_SIZE_MB,
  MAX_START_TIME,
  MESSAGE
FROM
( SELECT
	CASE 
	  WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
		CASE 
		  WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
			TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), 
			CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(B.SYS_START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE B.SYS_START_TIME END) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
		  ELSE TO_VARCHAR(CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(B.SYS_START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE B.SYS_START_TIME END, BI.TIME_AGGREGATE_BY)
		END
	  ELSE 'any' 
	END START_TIME,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST')             != 0 THEN BF.HOST                                         ELSE MAP(BI.HOST, '%', 'any', BI.HOST)                         END HOST,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SERVICE')          != 0 THEN BF.SERVICE_TYPE_NAME                            ELSE MAP(BI.SERVICE_NAME, '%', 'any', BI.SERVICE_NAME)         END SERVICE_NAME,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'DATABASE')         != 0 THEN BF.DATABASE_NAME                                ELSE MAP(BI.DB_NAME, '%', 'any', BI.DB_NAME)                   END DATABASE_NAME,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BACKUP_ID')        != 0 THEN TO_VARCHAR(B.BACKUP_ID)                         ELSE 'any'                                                     END BACKUP_ID,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BACKUP_TYPE')      != 0 THEN B.ENTRY_TYPE_NAME                               ELSE MAP(BI.BACKUP_TYPE, '%', 'any', BI.BACKUP_TYPE)           END BACKUP_TYPE,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BACKUP_DATA_TYPE') != 0 THEN BF.SOURCE_TYPE_NAME                             ELSE MAP(BI.BACKUP_DATA_TYPE, '%', 'any', BI.BACKUP_DATA_TYPE) END BACKUP_DATA_TYPE,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'STATE')            != 0 THEN B.STATE_NAME                                    ELSE MAP(BI.BACKUP_STATUS, '%', 'any', BI.BACKUP_STATUS)       END STATUS,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'MESSAGE')          != 0 THEN CASE WHEN B.MESSAGE LIKE 'Not all data could be written%' THEN 'Not all data could be written' ELSE B.MESSAGE END ELSE MAP(BI.MESSAGE, '%', 'any', BI.MESSAGE) END MESSAGE,
	COUNT(DISTINCT(B.BACKUP_ID)) NUM_BACKUP_RUNS,
	SUM(SECONDS_BETWEEN(B.SYS_START_TIME, B.SYS_END_TIME) / 3600) * SUM(BF.BACKUP_SIZE) / SUM(BF.TOTAL_BACKUP_SIZE) SUM_RUNTIME_H,
	MAX(SECONDS_BETWEEN(B.SYS_START_TIME, B.SYS_END_TIME) / 3600) * MAX(BF.BACKUP_SIZE / BF.TOTAL_BACKUP_SIZE) MAX_RUNTIME_H,
	IFNULL(SUM(BF.BACKUP_SIZE / 1024 / 1024 ), 0) SUM_BACKUP_SIZE_MB,
	IFNULL(MAX(BF.BACKUP_SIZE / 1024 / 1024 ), 0) MAX_BACKUP_SIZE_MB,
	MAX(CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(B.SYS_START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE B.SYS_START_TIME END) MAX_START_TIME,
	SUM(IFNULL(CASE WHEN B.ENTRY_TYPE_NAME = 'log backup' AND BF.SOURCE_TYPE_NAME = 'volume' AND BF.BACKUP_SIZE / 1024 / 1024 >= L.SEGMENT_SIZE * 0.95 THEN 1 ELSE 0 END, 0)) NUM_LOG_FULL,
	BI.MIN_BACKUP_TIME_S,
	BI.AGGREGATION_TYPE,
	BI.AGGREGATE_BY
  FROM
  ( SELECT
	  BEGIN_TIME,
	  END_TIME,
	  TIMEZONE,
	  HOST,
	  SERVICE_NAME,
	  DB_NAME,
	  BACKUP_TYPE,
	  BACKUP_DATA_TYPE,
	  BACKUP_STATUS,
	  MESSAGE,
	  MIN_BACKUP_TIME_S,
	  AGGREGATION_TYPE,
	  AGGREGATE_BY,
	  MAP(TIME_AGGREGATE_BY,
		'NONE',        'YYYY/MM/DD HH24:MI:SS',
		'HOUR',        'YYYY/MM/DD HH24',
		'DAY',         'YYYY/MM/DD (DY)',
		'HOUR_OF_DAY', 'HH24',
		TIME_AGGREGATE_BY ) TIME_AGGREGATE_BY
	FROM
	( SELECT                                                                  /* Modification section */
		TO_TIMESTAMP('1900/01/01 12:00:00', 'YYYY/MM/DD HH24:MI:SS') BEGIN_TIME,
		TO_TIMESTAMP('9999/01/13 12:00:00', 'YYYY/MM/DD HH24:MI:SS') END_TIME,
		'SERVER' TIMEZONE,                              /* SERVER, UTC */
		'%' HOST,
		'%' SERVICE_NAME,
		'%' DB_NAME,
		'%' BACKUP_TYPE,                             /* e.g. 'log backup', 'complete data backup', 'incremental data backup', 'differential data backup', 'data snapshot',
																'DATA_BACKUP' for all data backup and snapshot types */
		'%' BACKUP_DATA_TYPE,                            /* VOLUME -> log or data, CATALOG -> catalog, TOPOLOGY -> topology */
		'failed' BACKUP_STATUS,                                    /* e.g. 'successful', 'failed' */
		'%' MESSAGE,
		-1 MIN_BACKUP_TIME_S,
		'AVG' AGGREGATION_TYPE,     /* SUM, MAX, AVG */
		'HOST, TIME, SERVICE, BACKUP_TYPE' AGGREGATE_BY,        /* HOST, SERVICE, DB_NAME, TIME, BACKUP_ID, BACKUP_TYPE, BACKUP_DATA_TYPE, STATE, MESSAGE or comma separated list, NONE for no aggregation */
		'HOUR' TIME_AGGREGATE_BY     /* HOUR, DAY, HOUR_OF_DAY or database time pattern, TS<seconds> for time slice, NONE for no aggregation */
	  FROM
		DUMMY
	) 
  ) BI INNER JOIN
	SYS_DATABASES.M_BACKUP_CATALOG B ON
	  CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(B.SYS_START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE B.SYS_START_TIME END BETWEEN BI.BEGIN_TIME AND BI.END_TIME AND
	  ( BI.BACKUP_TYPE = 'DATA_BACKUP' AND B.ENTRY_TYPE_NAME IN ( 'complete data backup', 'differential data backup', 'incremental data backup', 'data snapshot' ) OR
		BI.BACKUP_TYPE != 'DATA_BACKUP' AND UPPER(B.ENTRY_TYPE_NAME) LIKE UPPER(BI.BACKUP_TYPE) 
	  ) AND
	  B.STATE_NAME LIKE BI.BACKUP_STATUS AND
	  B.MESSAGE LIKE BI.MESSAGE INNER JOIN
	( SELECT
		DATABASE_NAME,
		BACKUP_ID,
		SOURCE_ID,
		HOST,
		SERVICE_TYPE_NAME,
		SOURCE_TYPE_NAME,
		BACKUP_SIZE,
		SUM(BACKUP_SIZE) OVER (PARTITION BY BACKUP_ID) TOTAL_BACKUP_SIZE
	  FROM
		SYS_DATABASES.M_BACKUP_CATALOG_FILES 
	) BF ON
	  B.DATABASE_NAME = BF.DATABASE_NAME AND
	  B.BACKUP_ID = BF.BACKUP_ID AND
	  BF.HOST LIKE BI.HOST AND
	  BF.SERVICE_TYPE_NAME LIKE BI.SERVICE_NAME AND
	  BF.DATABASE_NAME LIKE BI.DB_NAME AND
	  UPPER(BF.SOURCE_TYPE_NAME) LIKE UPPER(BI.BACKUP_DATA_TYPE) LEFT OUTER JOIN
	SYS_DATABASES.M_LOG_BUFFERS L ON
	  L.HOST = BF.HOST AND
	  L.DATABASE_NAME = BF.DATABASE_NAME AND
	  L.VOLUME_ID = BF.SOURCE_ID
  GROUP BY
	CASE 
	  WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
		CASE 
		  WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
			TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), 
			CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(B.SYS_START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE B.SYS_START_TIME END) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
		  ELSE TO_VARCHAR(CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(B.SYS_START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE B.SYS_START_TIME END, BI.TIME_AGGREGATE_BY)
		END
	  ELSE 'any' 
	END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST')             != 0 THEN BF.HOST                                         ELSE MAP(BI.HOST, '%', 'any', BI.HOST)                         END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SERVICE')          != 0 THEN BF.SERVICE_TYPE_NAME                            ELSE MAP(BI.SERVICE_NAmE, '%', 'any', BI.SERVICE_NAME)         END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'DATABASE')         != 0 THEN BF.DATABASE_NAME                                ELSE MAP(BI.DB_NAME, '%', 'any', BI.DB_NAME)                   END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BACKUP_ID')        != 0 THEN TO_VARCHAR(B.BACKUP_ID)                         ELSE 'any'                                                     END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BACKUP_TYPE')      != 0 THEN B.ENTRY_TYPE_NAME                               ELSE MAP(BI.BACKUP_TYPE, '%', 'any', BI.BACKUP_TYPE)           END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BACKUP_DATA_TYPE') != 0 THEN BF.SOURCE_TYPE_NAME                             ELSE MAP(BI.BACKUP_DATA_TYPE, '%', 'any', BI.BACKUP_DATA_TYPE) END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'STATE')            != 0 THEN B.STATE_NAME                                    ELSE MAP(BI.BACKUP_STATUS, '%', 'any', BI.BACKUP_STATUS)       END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'MESSAGE')          != 0 THEN CASE WHEN B.MESSAGE LIKE 'Not all data could be written%' THEN 'Not all data could be written' ELSE B.MESSAGE END ELSE MAP(BI.MESSAGE, '%', 'any', BI.MESSAGE) END,
	BI.MIN_BACKUP_TIME_S,
	BI.AGGREGATION_TYPE,
	BI.AGGREGATE_BY
)
WHERE
( MIN_BACKUP_TIME_S = -1 OR SUM_RUNTIME_H >= MIN_BACKUP_TIME_S / 3600 )
)
ORDER BY
START_TIME DESC,
HOST,
SERVICE_NAME
WITH HINT (NO_JOIN_REMOVAL)
"
}Else
{
  $query="SELECT   START_TIME,
HOST,
SERVICE_NAME,
LPAD(BACKUP_ID, 13) BACKUP_ID,
BACKUP_TYPE,
DATA_TYPE,
STATUS,
LPAD(BACKUPS, 7) BACKUPS,
LPAD(TO_DECIMAL(MAP(BACKUPS, 0, 0, NUM_LOG_FULL / BACKUPS * 100), 10, 2), 12) FULL_LOG_PCT,
AGG,
LPAD(TO_DECIMAL(RUNTIME_H * 60, 10, 2), 11) RUNTIME_MIN,
LPAD(TO_DECIMAL(BACKUP_SIZE_MB, 10, 2), 14) BACKUP_SIZE_MB,
LPAD(TO_DECIMAL(MAP(RUNTIME_H, 0, 0, BACKUP_SIZE_MB / RUNTIME_H / 3600), 10, 2), 8) MB_PER_S,
LPAD(TO_DECIMAL(SECONDS_BETWEEN(MAX_START_TIME, CURRENT_TIMESTAMP) / 86400, 10, 2), 11) DAYS_PASSED,
MESSAGE
FROM
( SELECT
  START_TIME,
  HOST,
  SERVICE_NAME,
  BACKUP_ID,
  BACKUP_TYPE,
  BACKUP_DATA_TYPE DATA_TYPE,
  STATUS,
  NUM_BACKUP_RUNS BACKUPS,
  NUM_LOG_FULL,
  AGGREGATION_TYPE AGG,
  CASE AGGREGATION_TYPE
	WHEN 'SUM' THEN SUM_RUNTIME_H
	WHEN 'AVG' THEN MAP(NUM_BACKUP_RUNS, 0, 0, SUM_RUNTIME_H / NUM_BACKUP_RUNS)
	WHEN 'MAX' THEN MAX_RUNTIME_H
  END RUNTIME_H,
  CASE AGGREGATION_TYPE
	WHEN 'SUM' THEN SUM_BACKUP_SIZE_MB
	WHEN 'AVG' THEN MAP(NUM_BACKUP_RUNS, 0, 0, SUM_BACKUP_SIZE_MB / NUM_BACKUP_RUNS)
	WHEN 'MAX' THEN MAX_BACKUP_SIZE_MB
  END BACKUP_SIZE_MB,
  MAX_START_TIME,
  MESSAGE
FROM
( SELECT
	CASE 
	  WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
		CASE 
		  WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
			TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), 
			CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(B.SYS_START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE B.SYS_START_TIME END) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
		  ELSE TO_VARCHAR(CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(B.SYS_START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE B.SYS_START_TIME END, BI.TIME_AGGREGATE_BY)
		END
	  ELSE 'any' 
	END START_TIME,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST')             != 0 THEN BF.HOST                                         ELSE MAP(BI.HOST, '%', 'any', BI.HOST)                         END HOST,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SERVICE')          != 0 THEN BF.SERVICE_TYPE_NAME                            ELSE MAP(BI.SERVICE_NAME, '%', 'any', BI.SERVICE_NAME)         END SERVICE_NAME,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BACKUP_ID')        != 0 THEN TO_VARCHAR(B.BACKUP_ID)                         ELSE 'any'                                                     END BACKUP_ID,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BACKUP_TYPE')      != 0 THEN B.ENTRY_TYPE_NAME                               ELSE MAP(BI.BACKUP_TYPE, '%', 'any', BI.BACKUP_TYPE)           END BACKUP_TYPE,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BACKUP_DATA_TYPE') != 0 THEN BF.SOURCE_TYPE_NAME                             ELSE MAP(BI.BACKUP_DATA_TYPE, '%', 'any', BI.BACKUP_DATA_TYPE) END BACKUP_DATA_TYPE,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'STATE')            != 0 THEN B.STATE_NAME                                    ELSE MAP(BI.BACKUP_STATUS, '%', 'any', BI.BACKUP_STATUS)       END STATUS,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'MESSAGE')          != 0 THEN CASE WHEN B.MESSAGE LIKE 'Not all data could be written%' THEN 'Not all data could be written' 
	  ELSE B.MESSAGE END ELSE MAP(BI.MESSAGE, '%', 'any', BI.MESSAGE) END MESSAGE,
	COUNT(DISTINCT(B.BACKUP_ID)) NUM_BACKUP_RUNS,
	SUM(SECONDS_BETWEEN(B.SYS_START_TIME, B.SYS_END_TIME) / 3600) * SUM(BF.BACKUP_SIZE) / SUM(BF.TOTAL_BACKUP_SIZE) SUM_RUNTIME_H,
	MAX(SECONDS_BETWEEN(B.SYS_START_TIME, B.SYS_END_TIME) / 3600) * MAX(BF.BACKUP_SIZE / BF.TOTAL_BACKUP_SIZE) MAX_RUNTIME_H,
	IFNULL(SUM(BF.BACKUP_SIZE / 1024 / 1024 ), 0) SUM_BACKUP_SIZE_MB,
	IFNULL(MAX(BF.BACKUP_SIZE / 1024 / 1024 ), 0) MAX_BACKUP_SIZE_MB,
	MAX(CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(B.SYS_START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE B.SYS_START_TIME END) MAX_START_TIME,
	SUM(IFNULL(CASE WHEN B.ENTRY_TYPE_NAME = 'log backup' AND BF.SOURCE_TYPE_NAME = 'volume' AND BF.BACKUP_SIZE / 1024 / 1024 >= L.SEGMENT_SIZE * 0.95 THEN 1 ELSE 0 END, 0)) NUM_LOG_FULL,
	BI.MIN_BACKUP_TIME_S,
	BI.AGGREGATION_TYPE,
	BI.AGGREGATE_BY
  FROM
  ( SELECT
	  BEGIN_TIME,
	  END_TIME,
	  TIMEZONE,
	  HOST,
	  SERVICE_NAME,
	  BACKUP_TYPE,
	  BACKUP_DATA_TYPE,
	  BACKUP_STATUS,
	  MESSAGE,
	  MIN_BACKUP_TIME_S,
	  AGGREGATION_TYPE,
	  AGGREGATE_BY,
	  MAP(TIME_AGGREGATE_BY,
		'NONE',        'YYYY/MM/DD HH24:MI:SS',
		'HOUR',        'YYYY/MM/DD HH24',
		'DAY',         'YYYY/MM/DD (DY)',
		'HOUR_OF_DAY', 'HH24',
		TIME_AGGREGATE_BY ) TIME_AGGREGATE_BY
	FROM
	( SELECT                                                                  /* Modification section */
		/*TO_TIMESTAMP('1900/01/01 12:00:00', 'YYYY/MM/DD HH24:MI:SS') BEGIN_TIME,*/
		add_seconds(now(),-$($checkfreq*1)) BEGIN_TIME,
		TO_TIMESTAMP('9999/01/13 12:00:00', 'YYYY/MM/DD HH24:MI:SS') END_TIME,
		'SERVER' TIMEZONE,                              /* SERVER, UTC */
		'%' HOST,
		'%' SERVICE_NAME,
		'log backup' BACKUP_TYPE,                             /* e.g. 'log backup', 'complete data backup', 'incremental data backup', 'differential data backup', 'data snapshot',
																'DATA_BACKUP' for all data backup and snapshot types */
		'%' BACKUP_DATA_TYPE,                            /* VOLUME -> log or data, CATALOG -> catalog, TOPOLOGY -> topology */
		'%' BACKUP_STATUS,                                    /* e.g. 'successful', 'failed' */
		'%' MESSAGE,
		-1 MIN_BACKUP_TIME_S,
		'AVG' AGGREGATION_TYPE,     /* SUM, MAX, AVG */
		'HOST, TIME, SERVICE, BACKUP_TYPE' AGGREGATE_BY,        /* HOST, SERVICE, TIME, BACKUP_ID, BACKUP_TYPE, BACKUP_DATA_TYPE, STATE, MESSAGE or comma separated list, NONE for no aggregation */
		'HOUR' TIME_AGGREGATE_BY     /* HOUR, DAY, HOUR_OF_DAY or database time pattern, TS<seconds> for time slice, NONE for no aggregation */
	  FROM
		DUMMY
	) 
  ) BI INNER JOIN
	M_BACKUP_CATALOG B ON
	  CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(B.SYS_START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE B.SYS_START_TIME END BETWEEN BI.BEGIN_TIME AND BI.END_TIME AND
	  ( BI.BACKUP_TYPE = 'DATA_BACKUP' AND B.ENTRY_TYPE_NAME IN ( 'complete data backup', 'differential data backup', 'incremental data backup', 'data snapshot' ) OR
		BI.BACKUP_TYPE != 'DATA_BACKUP' AND UPPER(B.ENTRY_TYPE_NAME) LIKE UPPER(BI.BACKUP_TYPE) 
	  ) AND
	  B.STATE_NAME LIKE BI.BACKUP_STATUS AND
	  B.MESSAGE LIKE BI.MESSAGE INNER JOIN
	( SELECT
		BACKUP_ID,
		SOURCE_ID,
		HOST,
		SERVICE_TYPE_NAME,
		SOURCE_TYPE_NAME,
		BACKUP_SIZE,
		SUM(BACKUP_SIZE) OVER (PARTITION BY BACKUP_ID) TOTAL_BACKUP_SIZE
	  FROM
		M_BACKUP_CATALOG_FILES 
	) BF ON
	  B.BACKUP_ID = BF.BACKUP_ID AND
	  BF.HOST LIKE BI.HOST AND
	  BF.SERVICE_TYPE_NAME LIKE BI.SERVICE_NAME AND
	  UPPER(BF.SOURCE_TYPE_NAME) LIKE UPPER(BI.BACKUP_DATA_TYPE) LEFT OUTER JOIN
	M_LOG_BUFFERS L ON
	  L.HOST = BF.HOST AND
	  L.VOLUME_ID = BF.SOURCE_ID
  GROUP BY
	CASE 
	  WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
		CASE 
		  WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
			TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), 
			CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(B.SYS_START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE B.SYS_START_TIME END) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
		  ELSE TO_VARCHAR(CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(B.SYS_START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE B.SYS_START_TIME END, BI.TIME_AGGREGATE_BY)
		END
	  ELSE 'any' 
	END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST')             != 0 THEN BF.HOST                                         ELSE MAP(BI.HOST, '%', 'any', BI.HOST)                         END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SERVICE')          != 0 THEN BF.SERVICE_TYPE_NAME                            ELSE MAP(BI.SERVICE_NAmE, '%', 'any', BI.SERVICE_NAME)         END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BACKUP_ID')        != 0 THEN TO_VARCHAR(B.BACKUP_ID)                         ELSE 'any'                                                     END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BACKUP_TYPE')      != 0 THEN B.ENTRY_TYPE_NAME                               ELSE MAP(BI.BACKUP_TYPE, '%', 'any', BI.BACKUP_TYPE)           END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BACKUP_DATA_TYPE') != 0 THEN BF.SOURCE_TYPE_NAME                             ELSE MAP(BI.BACKUP_DATA_TYPE, '%', 'any', BI.BACKUP_DATA_TYPE) END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'STATE')            != 0 THEN B.STATE_NAME                                    ELSE MAP(BI.BACKUP_STATUS, '%', 'any', BI.BACKUP_STATUS)       END,
	CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'MESSAGE')          != 0 THEN CASE WHEN B.MESSAGE LIKE 'Not all data could be written%' THEN 'Not all data could be written' ELSE B.MESSAGE END 
	  ELSE MAP(BI.MESSAGE, '%', 'any', BI.MESSAGE) END,
	BI.MIN_BACKUP_TIME_S,
	BI.AGGREGATION_TYPE,
	BI.AGGREGATE_BY
)
WHERE
( MIN_BACKUP_TIME_S = -1 OR SUM_RUNTIME_H >= MIN_BACKUP_TIME_S / 3600 )
)
ORDER BY
START_TIME DESC,
HOST,
SERVICE_NAME
WITH HINT (NO_JOIN_REMOVAL)"
}

   $cmd = new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
		  $ds = New-Object system.Data.DataSet ;
$ex=$null
		  Try{
			 # $cmd.fill($ds)|out-null
		  }
		  Catch
		  {
			  $Ex=$_.Exception.MEssage
			  write-warning  $ex 
		  }


	  
		  $Resultsinv=$null
		  $Resultsinv=@(); 

#FIX TIME

	  $checkfreq=900
IF($firstrun){$checkfreq=2592000}Else{$checkfreq=900} 

$query="SELECT   BEGIN_TIME,
HOST,
LPAD(PORT, 5) PORT,
SERVICE_NAME SERVICE,
CLIENT_HOST,
LPAD(CLIENT_PID, 10) CLIENT_PID,
LPAD(CONN_ID, 10) CONN_ID,
CONNECTION_TYPE,
CONNECTION_STATUS,
LPAD(CONNS, 8) CONNS,
LPAD(CUR_CONNS, 9) CUR_CONNS,
CLOSE_REASON,
CREATED_BY,
APP_NAME,
APP_USER,
APP_VERSION,
APP_SOURCE
FROM
( SELECT
  CASE 
	WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
	  CASE 
		WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
		  TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 
		  'YYYY/MM/DD HH24:MI:SS'), CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(C.START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE C.START_TIME END) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
		ELSE TO_VARCHAR(CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(C.START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE C.START_TIME END, BI.TIME_AGGREGATE_BY)
	  END
	ELSE 'any' 
  END BEGIN_TIME,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST')         != 0 THEN C.HOST                                      ELSE MAP(BI.HOST, '%', 'any', BI.HOST)                           END HOST,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'PORT')         != 0 THEN TO_VARCHAR(C.PORT)                             ELSE MAP(BI.PORT, '%', 'any', BI.PORT)                           END PORT,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SERVICE')      != 0 THEN S.SERVICE_NAME                              ELSE MAP(BI.SERVICE_NAME, '%', 'any', BI.SERVICE_NAME)           END SERVICE_NAME,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'CLIENT_HOST')  != 0 THEN C.CLIENT_HOST                               ELSE MAP(BI.CLIENT_HOST, '%', 'any', BI.CLIENT_HOST)             END CLIENT_HOST,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'CLIENT_PID')   != 0 THEN TO_VARCHAR(C.CLIENT_PID)                       ELSE MAP(BI.CLIENT_PID, -1, 'any', TO_VARCHAR(BI.CLIENT_PID))       END CLIENT_PID,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'CONN_ID')      != 0 THEN TO_VARCHAR(C.CONNECTION_ID)                    ELSE MAP(BI.CONN_ID, -1, 'any', TO_VARCHAR(BI.CONN_ID))             END CONN_ID,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TYPE')         != 0 THEN C.CONNECTION_TYPE                           ELSE MAP(BI.CONNECTION_TYPE, '%', 'any', BI.CONNECTION_TYPE)     END CONNECTION_TYPE,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'STATUS')       != 0 THEN C.CONNECTION_STATUS                         ELSE MAP(BI.CONNECTION_STATUS, '%', 'any', BI.CONNECTION_STATUS) END CONNECTION_STATUS,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'CLOSE_REASON') != 0 THEN C.CLOSE_REASON                              ELSE MAP(BI.CLOSE_REASON, '%', 'any', BI.CLOSE_REASON)           END CLOSE_REASON,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'CREATED_BY')   != 0 THEN C.CREATED_BY                                ELSE MAP(BI.CREATED_BY, '%', 'any', BI.CREATED_BY)               END CREATED_BY,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'APP_NAME')     != 0 THEN SC.APP_NAME                                 ELSE MAP(BI.APP_NAME, '%', 'any', BI.APP_NAME)                   END APP_NAME,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'APP_USER')     != 0 THEN SC.APP_USER                                 ELSE MAP(BI.APP_USER, '%', 'any', BI.APP_USER)                   END APP_USER,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'APP_VERSION')  != 0 THEN SC.APP_VERSION                              ELSE MAP(BI.APP_VERSION, '%', 'any', BI.APP_VERSION)             END APP_VERSION,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'APP_SOURCE')   != 0 THEN SC.APP_SOURCE                               ELSE MAP(BI.APP_SOURCE, '%', 'any', BI.APP_SOURCE)               END APP_SOURCE,
  COUNT(*) CONNS,
  SUM(CASE WHEN C.CONNECTION_ID < 0 THEN 0 ELSE 1 END) CUR_CONNS,
  BI.ORDER_BY
FROM
( SELECT
	BEGIN_TIME,
	END_TIME,
	TIMEZONE,
	HOST,
	PORT,
	SERVICE_NAME,
	CLIENT_HOST,
	CLIENT_PID,
	CONN_ID,
	CONNECTION_TYPE,
	CONNECTION_STATUS,
	CLOSE_REASON,
	CREATED_BY,
	APP_NAME,
	APP_USER,
	APP_VERSION,
	APP_SOURCE,
	EXCLUDE_HISTORY_CONNECTIONS,
	AGGREGATE_BY,
	MAP(TIME_AGGREGATE_BY,
	  'NONE',        'YYYY/MM/DD HH24:MI:SS',
	  'HOUR',        'YYYY/MM/DD HH24',
	  'DAY',         'YYYY/MM/DD (DY)',
	  'HOUR_OF_DAY', 'HH24',
	  TIME_AGGREGATE_BY ) TIME_AGGREGATE_BY,
	ORDER_BY
  FROM
  ( SELECT                   /* Modification section */
	  /*TO_TIMESTAMP('1000/10/12 01:20:00', 'YYYY/MM/DD HH24:MI:SS') BEGIN_TIME,*/
	  add_seconds(now(),-$($checkfreq*1)) BEGIN_TIME,
	  TO_TIMESTAMP('9999/10/12 01:20:00', 'YYYY/MM/DD HH24:MI:SS') END_TIME,
	  'SERVER' TIMEZONE,                              /* SERVER, UTC */
	  '%' HOST,
	  '%' PORT,
	  '%' SERVICE_NAME,
	  '%' CLIENT_HOST,
	  -1 CLIENT_PID,
	  -1 CONN_ID,
	  '%' CONNECTION_TYPE,
	  '%' CONNECTION_STATUS,
	  '%' CLOSE_REASON,
	  '%' CREATED_BY,
	  '%' APP_NAME,
	  '%' APP_USER,
	  '%' APP_VERSION,
	  '%' APP_SOURCE,
	  'X' EXCLUDE_HISTORY_CONNECTIONS,
	  'NONE' AGGREGATE_BY,                  /* TIME, HOST, PORT, SERVICE, CLIENT_HOST, CLIENT_PID, TYPE, STATUS, CLOSE_REASON, CREATED_BY, APP_NAME, APP_USER, APP_VERSION, APP_SOURCE or comma separated combinations, NONE for no aggregation */
	  'TS900' TIME_AGGREGATE_BY,                 /* HOUR, DAY, HOUR_OF_DAY or database time pattern, TS<seconds> for time slice, NONE for no aggregation */
	  'CONNS' ORDER_BY                          /* TIME, HOST, CONNS */
	FROM
	  DUMMY
  )
) BI INNER JOIN
  M_SERVICES S ON
	S.HOST LIKE BI.HOST AND
	TO_VARCHAR(S.PORT) LIKE BI.PORT AND
	S.SERVICE_NAME LIKE BI.SERVICE_NAME INNER JOIN
  M_CONNECTIONS C ON
	( CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(C.START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE C.START_TIME END BETWEEN BI.BEGIN_TIME AND BI.END_TIME OR
	  CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(IFNULL(C.END_TIME, CURRENT_TIMESTAMP), SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE IFNULL(C.END_TIME, CURRENT_TIMESTAMP) END BETWEEN BI.BEGIN_TIME AND BI.END_TIME OR
	  CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(C.START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE C.START_TIME END < BI.BEGIN_TIME AND CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(IFNULL(C.END_TIME, CURRENT_TIMESTAMP), SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE IFNULL(C.END_TIME, CURRENT_TIMESTAMP) END > BI.END_TIME 
	) AND
	C.HOST LIKE BI.HOST AND
	C.PORT = S.PORT AND
	C.HOST = S.HOST AND
	C.CLIENT_HOST LIKE BI.CLIENT_HOST AND
	( BI.CLIENT_PID = -1 OR C.CLIENT_PID = BI.CLIENT_PID ) AND
	( BI.CONN_ID = -1 OR C.CONNECTION_ID = BI.CONN_ID ) AND
	UPPER(IFNULL(C.CONNECTION_STATUS, '')) LIKE UPPER(BI.CONNECTION_STATUS) AND
	UPPER(C.CONNECTION_TYPE) LIKE UPPER(BI.CONNECTION_TYPE) AND
	C.CLOSE_REASON LIKE BI.CLOSE_REASON AND
	C.CREATED_BY LIKE BI.CREATED_BY AND
	( BI.EXCLUDE_HISTORY_CONNECTIONS = ' ' OR C.CONNECTION_ID >= 0 ) LEFT OUTER JOIN
 ( SELECT
	 CONNECTION_ID,
	 MAX(MAP(KEY, 'APPLICATION', VALUE, '')) APP_NAME,
	 MAX(MAP(KEY, 'APPLICATIONUSER', VALUE, '')) APP_USER,
	 MAX(MAP(KEY, 'APPLICATIONVERSION', VALUE, '')) APP_VERSION,
	 MAX(MAP(KEY, 'APPLICATIONSOURCE', VALUE, '')) APP_SOURCE
   FROM
	 M_SESSION_CONTEXT
   GROUP BY
	 CONNECTION_ID
  ) SC ON
	SC.CONNECTION_ID = C.CONNECTION_ID
  WHERE
	SC.APP_NAME LIKE BI.APP_NAME AND
	SC.APP_USER LIKE BI.APP_USER AND
	SC.APP_VERSION LIKE BI.APP_VERSION AND
	SC.APP_SOURCE LIKE BI.APP_SOURCE
GROUP BY
  CASE 
	WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
	  CASE 
		WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
		  TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 
		  'YYYY/MM/DD HH24:MI:SS'), CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(C.START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE C.START_TIME END) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
		ELSE TO_VARCHAR(CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(C.START_TIME, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE C.START_TIME END, BI.TIME_AGGREGATE_BY)
	  END
	ELSE 'any' 
  END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST')         != 0 THEN C.HOST                                      ELSE MAP(BI.HOST, '%', 'any', BI.HOST)                           END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'PORT')         != 0 THEN TO_VARCHAR(C.PORT)                             ELSE MAP(BI.PORT, '%', 'any', BI.PORT)                           END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SERVICE')      != 0 THEN S.SERVICE_NAME                              ELSE MAP(BI.SERVICE_NAME, '%', 'any', BI.SERVICE_NAME)           END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'CLIENT_HOST')  != 0 THEN C.CLIENT_HOST                               ELSE MAP(BI.CLIENT_HOST, '%', 'any', BI.CLIENT_HOST)             END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'CLIENT_PID')   != 0 THEN TO_VARCHAR(C.CLIENT_PID)                       ELSE MAP(BI.CLIENT_PID, -1, 'any', TO_VARCHAR(BI.CLIENT_PID))       END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'CONN_ID')      != 0 THEN TO_VARCHAR(C.CONNECTION_ID)                    ELSE MAP(BI.CONN_ID, -1, 'any', TO_VARCHAR(BI.CONN_ID))             END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TYPE')         != 0 THEN C.CONNECTION_TYPE                           ELSE MAP(BI.CONNECTION_TYPE, '%', 'any', BI.CONNECTION_TYPE)     END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'STATUS')       != 0 THEN C.CONNECTION_STATUS                         ELSE MAP(BI.CONNECTION_STATUS, '%', 'any', BI.CONNECTION_STATUS) END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'CLOSE_REASON') != 0 THEN C.CLOSE_REASON                              ELSE MAP(BI.CLOSE_REASON, '%', 'any', BI.CLOSE_REASON)           END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'CREATED_BY')   != 0 THEN C.CREATED_BY                                ELSE MAP(BI.CREATED_BY, '%', 'any', BI.CREATED_BY)               END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'APP_NAME')     != 0 THEN SC.APP_NAME                                 ELSE MAP(BI.APP_NAME, '%', 'any', BI.APP_NAME)                   END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'APP_USER')     != 0 THEN SC.APP_USER                                 ELSE MAP(BI.APP_USER, '%', 'any', BI.APP_USER)                   END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'APP_VERSION')  != 0 THEN SC.APP_VERSION                              ELSE MAP(BI.APP_VERSION, '%', 'any', BI.APP_VERSION)             END,
  CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'APP_SOURCE')   != 0 THEN SC.APP_SOURCE                               ELSE MAP(BI.APP_SOURCE, '%', 'any', BI.APP_SOURCE)               END,
  ORDER_BY
)
ORDER BY
MAP(ORDER_BY, 'TIME', BEGIN_TIME) DESC,
MAP(ORDER_BY, 'CONNS', CONNS) DESC,
HOST,
PORT
WITH HINT (NO_JOIN_REMOVAL)
"

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

  $Resultsinv=$null
		  $Resultsinv=@(); 


		  IF($ds[0].Tables.rows)
		  {
			  foreach ($row in $ds.Tables[0].rows)
			  {
				  $Resultsinv+= New-Object PSObject -Property @{
					  HOST=$row.HOST.ToLower()
					  Instance=$sapinstance
					  CollectorType="Inventory"
					  Category="Connections"
					  Database=$defaultdb
					  PORT=$row.PORT
					  SERVICE=$row.Service
					  CONN_ID=$row.CONN_ID
					  CONNECTION_TYPE=$row.CONNECTION_TYPE
					  CONNECTION_STATUS=$row.CONNECTION_STATUS
					  CONNS=$row.CONNS
					  CUR_CONNS=$row.CUR_CONNS
					  CREATED_BY=$row.CREATED_BY
					  APP_NAME=$row.APP_NAME
					  APP_USER =$row.APP_USER 
					  APP_VERSION=$row.APP_VERSION
					  APP_SOURCE=$row.APP_SOURCE


									  }
			  }
			  $Omsinvupload+=,$Resultsinv
		  }




$query=" SELECT  HOST,
PORT,
SERVICE_NAME SERVICE,
SQL_TYPE,
LPAD(EXECUTIONS, 10) EXECUTIONS,
LPAD(ROUND(ELAPSED_S), 10) ELAPSED_S,
LPAD(TO_DECIMAL(ELA_PER_EXEC_MS, 10, 2), 15) ELA_PER_EXEC_MS,
LPAD(TO_DECIMAL(LOCK_PER_EXEC_MS, 10, 2), 16) LOCK_PER_EXEC_MS,
LPAD(ROUND(MAX_ELA_MS), 10) MAX_ELA_MS
FROM
( SELECT
  S.HOST,
  S.PORT,
  S.SERVICE_NAME,
  L.SQL_TYPE,
  CASE L.SQL_TYPE
	WHEN 'SELECT'                THEN SUM(C.SELECT_EXECUTION_COUNT)
	WHEN 'SELECT FOR UPDATE'     THEN SUM(C.SELECT_FOR_UPDATE_COUNT)
	WHEN 'INSERT/UPDATE/DELETE'  THEN SUM(C.UPDATE_COUNT)
	WHEN 'READ ONLY TRANSACTION' THEN SUM(C.READ_ONLY_TRANSACTION_COUNT)
	WHEN 'UPDATE TRANSACTION'    THEN SUM(C.UPDATE_TRANSACTION_COUNT)
	WHEN 'ROLLBACK'              THEN SUM(C.ROLLBACK_COUNT)
	WHEN 'OTHERS'                THEN SUM(C.OTHERS_COUNT)
	WHEN 'PREPARE'               THEN SUM(C.TOTAL_PREPARATION_COUNT)
  END EXECUTIONS,
  CASE L.SQL_TYPE
	WHEN 'SELECT'                THEN SUM(C.SELECT_TOTAL_EXECUTION_TIME)                / 1000 / 1000
	WHEN 'SELECT FOR UPDATE'     THEN SUM(C.SELECT_FOR_UPDATE_TOTAL_EXECUTION_TIME)     / 1000 / 1000
	WHEN 'INSERT/UPDATE/DELETE'  THEN SUM(C.UPDATE_TOTAL_EXECUTION_TIME)                / 1000 / 1000
	WHEN 'READ ONLY TRANSACTION' THEN SUM(C.READ_ONLY_TRANSACTION_TOTAL_EXECUTION_TIME) / 1000 / 1000
	WHEN 'UPDATE TRANSACTION'    THEN SUM(C.UPDATE_TRANSACTION_TOTAL_EXECUTION_TIME)    / 1000 / 1000
	WHEN 'ROLLBACK'              THEN SUM(C.ROLLBACK_TOTAL_EXECUTION_TIME)              / 1000 / 1000
	WHEN 'OTHERS'                THEN SUM(C.OTHERS_TOTAL_EXECUTION_TIME)                / 1000 / 1000
	WHEN 'PREPARE'               THEN SUM(C.TOTAL_PREPARATION_TIME)                     / 1000 / 1000
  END ELAPSED_S,
  CASE L.SQL_TYPE
	WHEN 'SELECT'                THEN MAP(SUM(C.SELECT_EXECUTION_COUNT),      0, 0, SUM(C.SELECT_TOTAL_EXECUTION_TIME)                / 1000 / SUM(C.SELECT_EXECUTION_COUNT))
	WHEN 'SELECT FOR UPDATE'     THEN MAP(SUM(C.SELECT_FOR_UPDATE_COUNT),     0, 0, SUM(C.SELECT_FOR_UPDATE_TOTAL_EXECUTION_TIME)     / 1000 / SUM(C.SELECT_FOR_UPDATE_COUNT))
	WHEN 'INSERT/UPDATE/DELETE'  THEN MAP(SUM(C.UPDATE_COUNT),                0, 0, SUM(C.UPDATE_TOTAL_EXECUTION_TIME)                / 1000 / SUM(C.UPDATE_COUNT))
	WHEN 'READ ONLY TRANSACTION' THEN MAP(SUM(C.READ_ONLY_TRANSACTION_COUNT), 0, 0, SUM(C.READ_ONLY_TRANSACTION_TOTAL_EXECUTION_TIME) / 1000 / SUM(C.READ_ONLY_TRANSACTION_COUNT))
	WHEN 'UPDATE TRANSACTION'    THEN MAP(SUM(C.UPDATE_TRANSACTION_COUNT),    0, 0, SUM(C.UPDATE_TRANSACTION_TOTAL_EXECUTION_TIME)    / 1000 / SUM(C.UPDATE_TRANSACTION_COUNT))
	WHEN 'ROLLBACK'              THEN MAP(SUM(C.ROLLBACK_COUNT),              0, 0, SUM(C.ROLLBACK_TOTAL_EXECUTION_TIME)              / 1000 / SUM(C.ROLLBACK_COUNT))
	WHEN 'OTHERS'                THEN MAP(SUM(C.OTHERS_COUNT),                0, 0, SUM(C.OTHERS_TOTAL_EXECUTION_TIME)                / 1000 / SUM(C.OTHERS_COUNT))
	WHEN 'PREPARE'               THEN MAP(SUM(C.TOTAL_PREPARATION_COUNT),     0, 0, SUM(C.TOTAL_PREPARATION_TIME)                     / 1000 / SUM(C.TOTAL_PREPARATION_COUNT))
  END ELA_PER_EXEC_MS,
  CASE L.SQL_TYPE
	WHEN 'SELECT' THEN 0
	WHEN 'SELECT FOR UPDATE'     THEN MAP(SUM(C.SELECT_FOR_UPDATE_COUNT), 0, 0, SUM(C.SELECT_FOR_UPDATE_TOTAL_LOCK_WAIT_TIME) / 1000 / SUM(C.SELECT_FOR_UPDATE_COUNT))
	WHEN 'INSERT/UPDATE/DELETE'  THEN MAP(SUM(C.UPDATE_COUNT),            0, 0, SUM(C.UPDATE_TOTAL_LOCK_WAIT_TIME)            / 1000 / SUM(C.UPDATE_COUNT))
	WHEN 'READ ONLY TRANSACTION' THEN 0
	WHEN 'UPDATE TRANSACTION'    THEN 0
	WHEN 'ROLLBACK'              THEN 0
	WHEN 'OTHERS'                THEN MAP(SUM(C.OTHERS_COUNT),            0, 0, SUM(C.OTHERS_TOTAL_LOCK_WAIT_TIME)            / 1000 / SUM(C.OTHERS_COUNT))
	WHEN 'PREPARE'               THEN 0
  END LOCK_PER_EXEC_MS,
  CASE L.SQL_TYPE
	WHEN 'SELECT'                THEN MAX(C.SELECT_MAX_EXECUTION_TIME)                / 1000
	WHEN 'SELECT FOR UPDATE'     THEN MAX(C.SELECT_FOR_UPDATE_MAX_EXECUTION_TIME)     / 1000
	WHEN 'INSERT/UPDATE/DELETE'  THEN MAX(C.UPDATE_MAX_EXECUTION_TIME)                / 1000
	WHEN 'READ ONLY TRANSACTION' THEN MAX(C.READ_ONLY_TRANSACTION_MAX_EXECUTION_TIME) / 1000
	WHEN 'UPDATE TRANSACTION'    THEN MAX(C.UPDATE_TRANSACTION_MAX_EXECUTION_TIME)    / 1000
	WHEN 'ROLLBACK'              THEN MAX(C.ROLLBACK_MAX_EXECUTION_TIME)              / 1000
	WHEN 'OTHERS'                THEN MAX(C.OTHERS_MAX_EXECUTION_TIME)                / 1000
	WHEN 'PREPARE'               THEN MAX(C.MAX_PREPARATION_TIME)                     / 1000
  END MAX_ELA_MS
FROM
( SELECT                                /* Modification section */
	'%' HOST,
	'%' PORT,
	'%' SERVICE_NAME,
	-1 CONN_ID
  FROM
	DUMMY
) BI,
  M_SERVICES S,
( SELECT 1 LINE_NO, 'SELECT' SQL_TYPE FROM DUMMY UNION ALL
  ( SELECT 2, 'SELECT FOR UPDATE'     FROM DUMMY ) UNION ALL
  ( SELECT 3, 'INSERT/UPDATE/DELETE'  FROM DUMMY ) UNION ALL
  ( SELECT 4, 'READ ONLY TRANSACTION' FROM DUMMY ) UNION ALL
  ( SELECT 5, 'UPDATE TRANSACTION'    FROM DUMMY ) UNION ALL
  ( SELECT 6, 'ROLLBACK'              FROM DUMMY ) UNION ALL
  ( SELECT 7, 'OTHERS'                FROM DUMMY ) UNION ALL
  ( SELECT 8, 'PREPARE'               FROM DUMMY )
) L,
  M_CONNECTION_STATISTICS C
WHERE
  S.HOST LIKE BI.HOST AND
  TO_VARCHAR(S.PORT) LIKE BI.PORT AND
  S.SERVICE_NAME LIKE BI.SERVICE_NAME AND
  C.HOST = S.HOST AND
  C.PORT = S.PORT AND
  ( BI.CONN_ID = -1 OR C.CONNECTION_ID = BI.CONN_ID )
  AND c.END_TIME  > add_seconds(now(),-$($freq*60))
GROUP BY
  S.HOST,
  S.PORT,
  S.SERVICE_NAME,
  L.SQL_TYPE,
  L.LINE_NO
)
ORDER BY
HOST,
PORT,
SQL_TYPE
"

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

		  IF ($ds.tables[0].rows)
		  {
			  Foreach($row in $ds.tables[0].rows)
			  {
				  $Resultsperf+= New-Object PSObject -Property @{
					  HOST=$SAPHOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ConnectionStatistics"
					  PerfCounter=$row.SQL_TYPE
					  PerfValue=[double]$row.EXECUTIONS
					  PerfInstance='EXECUTIONS'
					  }

				  $Resultsperf+= New-Object PSObject -Property @{
					  HOST=$SAPHOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ConnectionStatistics"
					  PerfCounter=$row.SQL_TYPE
					  PerfValue=[double]$row.ELAPSED_S
					  PerfInstance='ELAPSED_S'
					  }

				  $Resultsperf+= New-Object PSObject -Property @{
					  HOST=$SAPHOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ConnectionStatistics"
					  PerfCounter=$row.SQL_TYPE
					  PerfValue=[double]$row.ELA_PER_EXEC_MS
					  PErfInstance='ELA_PER_EXEC_MS'   
					  }

				  $Resultsperf+= New-Object PSObject -Property @{
					  HOST=$SAPHOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ConnectionStatistics"
					  PerfCounter=$row.SQL_TYPE
					  PerfValue=[double]$row.LOCK_PER_EXEC_MS
					  PerfInstance='LOCK_PER_EXEC_MS'
					  }

				  $Resultsperf+= New-Object PSObject -Property @{
					  HOST=$SAPHOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ConnectionStatistics"
					  PerfCounter=$row.SQL_TYPE
					  PerfValue=[double]$row.MAX_ELA_MS 
					  PerfInstance='MAX_ELA_MS'
					  }
				  }
				  $OmsPerfupload+=,$Resultsperf
					
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


			IF($AzLAUploadsuccess -gt 0)
			{
				if($lasttimestamp)
				{

					write-output " updating ast run time to $date"
					Set-AzureRmAutomationVariable `
						-AutomationAccountName $AAAccount `
						-Encrypted 0 `
						-Name $rbvariablename `
						-ResourceGroupName $AAResourceGroup `
						-Value $currentruntime

				}Else
				{
					New-AzureRmAutomationVariable `
					-AutomationAccountName $AAAccount `
					-ResourceGroupName $AAResourceGroup `
							-Value $currentruntime `
					-Encrypted 0 `
					-Name $rbvariablename `
					-Description "last time collection run"  -EA 0
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
					 Database=$hanadb
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
	
}


