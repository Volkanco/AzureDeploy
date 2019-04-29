param
(
[Parameter(Mandatory=$false)] [bool] $collecttableinv=$false,
[Parameter(Mandatory=$false)] [string] $configfolder="C:\HanaMonitor",
[Parameter(Mandatory=$false)] [bool] $debuglog=$false,
[Parameter(Mandatory=$false)] [bool] $useManagedIdentity=$false,
[Parameter(Mandatory=$false)] [string] $runmode="default"
)


#Runmode  options :
#   "default  - Regulat checks every 15 min"
#   "daily - Long running checks  ( Hana Config Cheks and Hana Table Inventory"
#   With Daily switch Long Running  collections can be scheduled seperately 
#


IF($runmode -eq 'default')
{
    Write-Output  " Default Runmode selected - regular checks  will be performed"
}Elseif($runmode -eq 'daily')
{
    Write-Output  " Daily Runmode selected - Hana Configurations Checks will be performed"
}Else
{
    #fallback to defualt mode 
    Write-Warning "Invalid runbmode specified"
    Write-Warning "Vaild Runmode  options ;"
    Write-Warning "default  - Regular checks every 15 min"
    Write-Warning "daily - Long running checks  ( Hana Config Cheks and aAna Table Inventory"
    $runmode="default"
}

#region login to Azure Arm and retrieve variables
Enable-AzureRmAlias  # Needed for backward compatibility in Az Powershell


IF($useManagedIdentity)
{

    try
    {
   
        Connect-AzureRmAccount -Identity
         $connectedtoAzure=$true
    }
    catch{
      
            write-warning $_.Exception

        $connectedtoAzure=$false
    }



}Else{
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

            $connectedtoAzure=$true
    }
    catch {
        if (!$servicePrincipalConnection)
        {
            $ErrorMessage = "Connection $connectionName not found."
           write-warning $ErrorMessage
        } else{
         
            write-warning $_.Exception
        }
        $connectedtoAzure=$false
    }
}

Write-output " Connected to Azure :  $connectedtoAzure"
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


#For shared key use either the primary or seconday Connected Sources client authentication key   

#define API Versions for REST API  Calls

# OMS log analytics custom log name
$logname='SAPHana'
$Starttimer=get-date

# Hana Client Dll

$sapdll="Sap.Data.Hana.v4.5.dll" 

#config folder
if(!$configfolder){$configfolder="C:\HanaMonitor"}


#AutomationVaribale to Track last run time 

$Trackvariable="HanaCollectionTime"
$RunHistory=@{}


#query time threshold for  M_SQL_PLAN_CACHE
$querythreshold=1000000
#endregion

#region Define Required Functions

# Create the function to create the authorization signature
Function Build-OMSSignature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
{
	$xHeaders = "x-ms-date:" + $date
	$stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
	$bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
	$keyBytes = [Convert]::FromBase64String($sharedKey)
	$sha256 =New-Object System.Security.Cryptography.HMACSHA256
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
    $i=0
    $trackhost=@()  
    $colstart=get-date  

	Foreach($ins in $hanaconfig.HanaConnections.Rule)
	{
	   IF($ins.Enabled -eq'true')
        {	
                
		[System.Collections.ArrayList]$Omsupload=@()
		[System.Collections.ArrayList]$OmsPerfupload=@()
		[System.Collections.ArrayList]$OmsInvupload=@()
		[System.Collections.ArrayList]$OmsStateupload=@()
        
		$saphost=$ins.'hanaserver'
        $sapport=$ins.'port'
         
		If($ins.UserAsset -match 'default')
		{
			$user=Get-AutomationVariable -Name "AzureHanaMonitorUser"
			$password= Get-AutomationVariable -Name "AzureHanaMonitorPassword"
		}else
		{
			$user=Get-AutomationVariable -Name $ins.UserAsset+"User"
			$password=Get-AutomationVariable -Name $ins.UserAsset+"Password"
		}

        Write-output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss'))  Processing $($ins.HanaServer) - $($ins.Database) "
		$constring="Server={0}:{1};Database={2};UserID={3};Password={4}" -f $ins.HanaServer,$ins.Port,$ins.Database,$user,$password
		$conn=$null
		$conn=new-object Sap.Data.Hana.HanaConnection($constring);
		$hanadb=$null
		$hanadb=$ins.Database
		
		#region PSPing Latency Check
		IF(Test-Path -Path C:\HanaMonitor\PSTools\psping.exe)
		{
            $tcpclient =new-Object system.Net.Sockets.TcpClient
            $tcpConnection=$tcpclient.BeginConnect($ins.HanaServer,22,$null,$null)
            $conntest=$tcpConnection.AsyncWaitHandle.WaitOne(2000,$false) # we will test if HAna server reachable before performing  latency test 

            If($conntest)
            {

                $ping=$out=$null
                $arg="-n 100  -i 0 -q  {0} 22  -accepteula" -f $ins.HanaServer        
                $ps =new-object System.Diagnostics.Process
                $ps.StartInfo.Filename ="C:\HanaMonitor\PSTools\psping.exe"
                $ps.StartInfo.Arguments = $arg
                $ps.StartInfo.RedirectStandardOutput = $True
                $ps.StartInfo.UseShellExecute = $false
                $ps.StartInfo.CreateNoWindow=$True
                $ps.start()
                $ps.WaitForExit()
        
                if ($ps.ExitCode  -eq 0)
                {
                    $pingresult=$null
                    $pingresult="Success"
                    [string] $Out = $ps.StandardOutput.ReadToEnd();
                    $out
                    [double]$ping=$Out.substring($Out.LastIndexOf('Average =')+9,$out.Length-$Out.LastIndexOf('Average =')-9).replace('ms','')
                }Else
                {
                    $pingresult="Fail"
                }
            }Else
            {
                Write-warning "Failed to connect $($ins.HanaServer) on port 22"
                $pingresult="Fail"
            }

        }

        #endregion
		
        #region Connect to Hana DB
        $ex=$null

		Try
		{
			$conn.open()
		}
		Catch
		{
			$Ex=$_.Exception.MEssage;write-warning $ex
		}
		
		
		
        #end region
		IF ($conn.State -eq 'open')
		{	    
			
            Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Succesfully connected to $hanadb on  $($ins.HanaServer):$($ins.Port)"
            $stopwatch=[system.diagnostics.stopwatch]::StartNew()

            $cu=$null
               $cu=[PSCustomObject]@{
				HOST=$saphost
				 PORT=$sapport
				 Database=$hanadb
				CollectorType="State"
				Category="Connectivity"
				SubCategory="Host"
				Connection="Successful"
				PingResult=$pingresult
                Latency=$ping
                
			}
            $omsStateupload.Add($cu)|Out-Null
            		

			$rbvariablename=$null
			$rbvariablename="LastRun-$saphost-$hanadb"
           

			$ex1=$null
			Try{
					$lasttimestamp=$null
		
                [datetime]$lasttimestamp=Get-AutomationVariable -Name $rbvariablename
                Get-AutomationVariable -Name $rbvariablename
			}
			Catch
			{
				$Ex1=$_.Exception.MEssage
			}
            $query="/* OMS -Query1 */SELECT CURRENT_TIMESTAMP ,add_seconds(CURRENT_TIMESTAMP,-900 ) as LastTime  FROM DUMMY"
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			$ex=$null
			
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query1"
			}

			if($lasttimestamp -eq $null)
			{
				write-warning "Last Run Time not found for $saphost-$hanadb : $ex"
				$lastruntime=$ds.Tables[0].rows[0].LastTime # we will use this to mark lasst data collection time in HANA
			}Else
			{
				$lastruntime=[datetime]$lasttimestamp  # we will use this to mark lasst data collection time in HANA				
			}
				$currentruntime=($ds.Tables[0].rows[0].CURRENT_TIMESTAMP).tostring('yyyy-MM-dd HH:mm:ss.FF')  #format ddate to Hana timestamp YYYY-MM-DD HH24:MI:SS.FF7. FF
				$timespan=([datetime]$currentruntime-[datetime]$lastruntime).Totalseconds
				Write-Output "Last Collection time was $lastruntime and currenttime is  $currentruntime , timespan $timespan seconds"
                If($timespan -gt  3600)
                {
                    $timespan=3600 # MAx collect last 1 hour

                }

            #this is used to calculate UTC time conversion in data collection 
#			$utcdiff=NEW-TIMESPAN –Start $ds[0].Tables[0].rows[0].UTC_TIMESTAMP  –End $ds[0].Tables[0].rows[0].SYS_TIMESTAMP 
			$query="/* OMS -Query2*/
			SELECT 
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

			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
					$ds=New-Object system.Data.DataSet ;
			$ex=$null
					Try{
						$cmd.fill($ds)|out-null
					}
					Catch
					{
						$Ex=$_.Exception.MEssage;write-warning "Failed to run Query2"
						write-warning  $ex 
					}
					
					$utcdiff=$ds.Tables[0].rows[0].TIMEZONE_OFFSET_S
                
    #region default collections
        If($runmode -eq 'default')
        {
	

            $query="/* OMS -Query3*/ SELECT   HOST,
  IFNULL(BUILT_BY,                'n/a') BUILT_BY,
  IFNULL(CPU_DETAILS,             'n/a') CPU_DETAILS,
  IFNULL(LPAD(CPU_CLOCK_MHZ, 7),  'n/a') CPU_MHZ,
  IFNULL(LPAD(PHYS_MEM_GB,   11), 'n/a') PHYS_MEM_GB,
  IFNULL(LPAD(SWAP_GB,        7), 'n/a') SWAP_GB,
  IFNULL(OP_SYS,                  'n/a') OP_SYS,
  IFNULL(KERNEL_VERSION,          'n/a') KERNEL_VERSION,
  IFNULL(CPU_MODEL,               'n/a') CPU_MODEL,
  IFNULL(HARDWARE_MODEL,          'n/a') HARDWARE_MODEL,
  IFNULL(SID,          'n/a') SID,
    IFNULL(BUILD_VERSION,          'n/a') BUILD_VERSION,
      IFNULL(START_TIME,          'n/a') START_TIME,
        IFNULL(BUILD_TIME,          'n/a') BUILD_TIME,
          IFNULL(TIMEZONE_OFFSET,          'n/a') TIMEZONE_OFFSETL,
            IFNULL(SAP_PATH,          'n/a') SAP_PATH,
             IFNULL(SAP_INSTANCE,          'n/a') SAP_INSTANCE,
IFNULL(LPAD(NOFILE_LIMIT, 12),  'n/a') NOFILE_LIMIT
FROM
( SELECT
    H.HOST,
    MAX(CASE WHEN KEY = 'hw_manufacturer' THEN VALUE                                                    END) BUILT_BY,
    MAX(CASE WHEN KEY = 'cpu_summary'     THEN REPLACE(VALUE, CHAR(32), '')                             END) CPU_DETAILS,
    MAX(CASE WHEN KEY = 'cpu_clock'       THEN VALUE                                                    END) CPU_CLOCK_MHZ,
    MAX(CASE WHEN KEY = 'mem_phys'        THEN TO_DECIMAL(TO_NUMBER(VALUE) / 1024 / 1024 / 1024, 10, 2) END) PHYS_MEM_GB,
    MAX(CASE WHEN KEY = 'mem_swap'        THEN TO_DECIMAL(TO_NUMBER(VALUE) / 1024 / 1024 / 1024, 10, 2) END) SWAP_GB,
    REPLACE(REPLACE(MAX(CASE WHEN KEY = 'os_name'   THEN VALUE END), 'SUSE Linux Enterprise Server', 'SLES'), 'Red Hat Enterprise Linux Server release', 'RHEL') OP_SYS,
    MAX(CASE WHEN KEY = 'os_kernel_version' THEN VALUE END) KERNEL_VERSION,
    REPLACE(MAX(CASE WHEN KEY = 'cpu_model' THEN VALUE END), '(R)', '') CPU_MODEL,
    MAX(CASE WHEN KEY = 'hw_model' THEN VALUE END) HARDWARE_MODEL,
    MAX(CASE WHEN KEY = 'sid' THEN VALUE END) SID,
    MAX(CASE WHEN KEY = 'build_version' THEN VALUE END) BUILD_VERSION,
    MAX(CASE WHEN KEY = 'start_time' THEN VALUE END) START_TIME,
    MAX(CASE WHEN KEY = 'build_time' THEN VALUE END) BUILD_TIME,
    MAX(CASE WHEN KEY = 'timezone_offset' THEN VALUE END) TIMEZONE_OFFSET,
    MAX(CASE WHEN KEY = 'sap_retrieval_path' THEN VALUE END) SAP_PATH,
    MAX(CASE WHEN KEY = 'sapsystem' THEN VALUE END) SAP_INSTANCE,    
    MAX(CASE WHEN KEY = 'os_rlimit_nofile'  THEN VALUE END) NOFILE_LIMIT,
    BI.MAX_NOFILE_LIMIT
  FROM
  ( SELECT                  /* Modification section */
      '%' HOST,
      -1 MAX_NOFILE_LIMIT
    FROM
      DUMMY
  ) BI,
    M_HOST_INFORMATION H
  WHERE
    H.HOST LIKE BI.HOST
  GROUP BY
    H.HOST,
    BI.MAX_NOFILE_LIMIT
)
WHERE
  ( MAX_NOFILE_LIMIT = -1 OR NOFILE_LIMIT <= MAX_NOFILE_LIMIT )
ORDER BY
  HOST"
					$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query3"
			}
			      

			
			$Results=$null
			$Results=@(); 
			[System.Collections.ArrayList]$Resultsinv=@(); 

			#Host Inventory 

            foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.add([PSCustomObject]@{
					HOST=$row.HOST 
					Instance=$sapinstance
				    CollectorType="Inventory"
				    Category="HostInfo"
                    BUILT_BY=$row.BUILT_BY 
                    CPU_DETAILS=$row.CPU_DETAILS
                    CPU_MHZ=$row.CPU_MHZ
                    PHYS_MEM_GB=[double]$row.PHYS_MEM_GB
                    SWAP_GB=$row.SWAP_GB
                    OP_SYS=$row.OP_SYS
                    KERNEL_VERSION=$row.KERNEL_VERSION
                    CPU_MODEL=$row.CPU_MODEL
                    HARDWARE_MODEL=$row.HARDWARE_MODEL
                    SID=$row.SID
                    BUILD_VERSION=$row.BUILD_VERSION
                    START_TIME=$row.START_TIME
                    BUILD_TIME=$row.BUILD_TIME 
                    TIMEZONE_OFFSET=$row.TIMEZONE_OFFSET
                    SAP_PATH=$row.SAP_PATH 
                    SAP_INSTANCE=$row.SAP_INSTANCE
                    NOFILE_LIMIT=$row.NOFILE_LIMIT			
				})|Out-Null

			}

			$Omsinvupload.Add($Resultsinv)|Out-Null


			$sapinstance=$ds.Tables[0].rows[0].sid+'/HDB'+$ds.Tables[0].rows[0].SAP_INSTANCE
			$sapversion=$ds.Tables[0].rows[0].BUILD_VERSION  #use build versionto decide which query to run

			$cu=$null

			$query="/* OMS -Query4*/SELECT * from  SYS.M_SYSTEM_OVERVIEW"
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			
                        Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) -Query4 -CollectorType=Inventory , Category=HostStartup"  
            $cmd.fill($ds)

			$Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 
			$Resultsstate=$null
			[System.Collections.ArrayList]$Resultsstate=@(); 

			$Resultsinv.Add([PSCustomObject]@{
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
			})|Out-Null

			$resultsstate.add([PSCustomObject]@{
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
			})|Out-Null

			$Omsinvupload.add($Resultsinv)|Out-Null
			$Omsstateupload.add($Resultsstate)|Out-Null


            If($hanadb -eq 'SYSTEMDB')
            {

			$query='/* OMS -Query5 */ Select * from SYS_Databases.M_Services'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
            Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) - Query5- CollectorType=Inventory , Category=Database"  
            $ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning write-warning "Failed to run Query5"
			}
			      

			$Results=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 
			[System.Collections.ArrayList]$Resultsstate=@(); 

				$mdc=$null
	
            If($ex)
            {
                #not multi tenant
                $MDC=$false

            }Else
            {
			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.add([PSCustomObject]@{
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
			
				})|Out-Null

				$resultsstate.add([PSCustomObject]@{
					CollectorType="State"
					Category="Database"
					Database=$row.DATABASE_NAME
					SERVICE_NAME=$row.SERVICE_NAME
					PROCESS_ID=$row.PROCESS_ID
					ACTIVE_STATUS=$row.ACTIVE_STATUS 
				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)|Out-Null
			$Omsstateupload.add($Resultsstate)|Out-Null

#get USer DB list 

			$UserDBs=@($resultsinv|where{[String]::IsNullOrEmpty($_.Database) -ne $true -and $_.SQL_PORT -ne 0 -and $_.Database -ne 'SYSTEMDB'}|select DATABASE,SQL_Port)
			$UserDBs

            $MDC=$true
            }
            }


            
            $query="/* OMS -Query6*/ SELECT L.HOST,
  L.HOST_ACTIVE ACTIVE,
  L.HOST_STATUS STATUS,
  L.NAMESERVER_CONFIG_ROLE NAME_CFG_ROLE,
  L.NAMESERVER_ACTUAL_ROLE NAME_ACT_ROLE,
  L.INDEXSERVER_CONFIG_ROLE INDEX_CFG_ROLE,
  L.INDEXSERVER_ACTUAL_ROLE INDEX_ACT_ROLE
FROM
( SELECT            /* Modification section */
    '%' HOST
  FROM
    DUMMY
) BI,
  M_LANDSCAPE_HOST_CONFIGURATION L
WHERE
  L.HOST LIKE BI.HOST
ORDER BY
  L.HOST"
					$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query6"
			}
			      

			
			$Results=$null
			$Results=@(); 
			[System.Collections.ArrayList]$Resultsinv=@(); 

			#Host Inventory 

            foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.add([PSCustomObject]@{
					HOST=$row.HOST 
					Instance=$sapinstance
				    CollectorType="Inventory"
				    Category="Landscape"
                    ACTIVE=$row.ACTIVE
                    STATUS=$row.STATUS
                    NAME_CFG_ROLE=$row.NAME_CFG_ROLE
                    NAME_ACT_ROLE =$row.NAME_ACT_ROLE 
                    INDEX_CFG_ROLE=$row.INDEX_CFG_ROLE
                    INDEX_ACT_ROLE=$row.INDEX_ACT_ROLE	
				})|Out-Null

			}

			$Omsinvupload.Add($Resultsinv)|Out-Null




			$query='/* OMS Query7*/ Select * FROM SYS.M_DATABASE'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
            Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query7  CollectorType=Inventory , Category=Database"  
            
            $ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query7"
			}
			 
			$Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 


			Write-Output ' CollectorType="Inventory" ,  Category="DatabaseInfo"'

			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="DatabaseInfo"
					SYSTEM_ID=$row.SYSTEM_ID
					Database=$row.DATABASE_NAME
					START_TIME=$row.START_TIME
					VERSION=$row.VERSION
					USAGE=$row.USAGE

				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)|Out-Null

			$query="/* OMS -Query8*/SELECT * FROM SYS.M_SERVICES"
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "failed to run query8"
			}
			 
			$Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 

            Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query8 CollectorType=Inventory -   Category=`Services"

			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.add([PSCustomObject]@{
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
				})|Out-Null

				$OmsStateupload.add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="State"
					Category="Services"
					PORT=$row.PORT
					SERVICE_NAME=$row.SERVICE_NAME
					PROCESS_ID=$row.PROCESS_ID
					ACTIVE_STATUS=$row.ACTIVE_STATUS
					
				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)|Out-Null



  			Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query9 CollectorType=Performance - Category=Host - Subcategory=OverallUsage" 
			
            $query="/* OMS Query9 */SELECT * from SYS.M_HOST_RESOURCE_UTILIZATION"
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query9"
                write-warning  $ex 
                
			
			} 

			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 
			foreach ($row in $ds.Tables[0].rows)
			{
				$Resultsperf.add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="FREE_PHYSICAL_MEMORY"
					PerfInstance=$row.HOST
					PerfValue=$row.FREE_PHYSICAL_MEMORY/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
					
				})|Out-Null

				$Resultsperf.add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="USED_PHYSICAL_MEMORY"
					PerfInstance=$row.HOST
					PerfValue=$row.USED_PHYSICAL_MEMORY/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null
				$Resultsperf.add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="FREE_SWAP_SPACE"
					PerfInstance=$row.HOST
					PerfValue=$row.FREE_SWAP_SPACE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null

				$Resultsperf.add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="USED_SWAP_SPACE"
					PerfInstance=$row.HOST
					PerfValue=$row.USED_SWAP_SPACE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="ALLOCATION_LIMIT"
					PerfInstance=$row.HOST
					PerfValue=$row.ALLOCATION_LIMIT/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="INSTANCE_TOTAL_MEMORY_USED_SIZE"
					PerfInstance=$row.HOST
					PerfValue=$row.INSTANCE_TOTAL_MEMORY_USED_SIZE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="INSTANCE_TOTAL_MEMORY_PEAK_USED_SIZE"
					PerfInstance=$row.HOST
					PerfValue=$row.INSTANCE_TOTAL_MEMORY_PEAK_USED_SIZE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="INSTANCE_TOTAL_MEMORY_ALLOCATED_SIZE"
					PerfInstance=$row.HOST
					PerfValue=$row.INSTANCE_TOTAL_MEMORY_ALLOCATED_SIZE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="INSTANCE_CODE_SIZE"
					PerfInstance=$row.HOST
					PerfValue=$row.INSTANCE_CODE_SIZE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null
				
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="INSTANCE_SHARED_MEMORY_ALLOCATED_SIZE"
					PerfInstance=$row.HOST
					PerfValue=$row.INSTANCE_SHARED_MEMORY_ALLOCATED_SIZE/1024/1024/1024
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="TOTAL_CPU_USER_TIME"
					PerfInstance=$row.HOST
					PerfValue=$row.TOTAL_CPU_USER_TIME
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="TOTAL_CPU_SYSTEM_TIME"
					PerfInstance=$row.HOST
					PerfValue=$row.TOTAL_CPU_SYSTEM_TIME
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="TOTAL_CPU_WIO_TIME"
					PerfInstance=$row.HOST
					PerfValue=$row.TOTAL_CPU_WIO_TIME
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Host"
					PerfCounter="TOTAL_CPU_IDLE_TIME"
					PerfInstance=$row.HOST
					PerfValue=$row.TOTAL_CPU_IDLE_TIME
					SYS_TIMESTAMP=$row.UTC_TIMESTAMP
				})|Out-Null

			}

			$Omsperfupload.Add($Resultsperf)|Out-Null



        #CollectorType="Inventory" or "Performance"
        Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query 10 CollectorType=Inventory - Category=BAckupCatalog"  

			$query="/* OMS Query10*/SELECT * FROM SYS.M_BACKUP_CATALOG where SYS_START_TIME    > add_seconds('"+$currentruntime+"',-$timespan)"
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query10"
                write-warning  $ex 
			}
			 
			$Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 


		
			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.Add([PSCustomObject]@{
					Hostname=$saphost
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="BackupCatalog"
					Database=$Hanadb                 
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


				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)|Out-Null

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query11 CollectorType=Inventory - Category=BAckupSize"  

			$query='/* OMS Query11*/ Select * FROM SYS.M_BACKUP_SIZE_ESTIMATIONS'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query11"
                write-warning  $ex 
			}
			 

			$Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 



			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.Add([PSCustomObject]@{
					HOST=$saphost
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="Backup"
					Database=$Hanadb
					PORT=$row.PORT
					SERVICE_NAME=$row.SERVICE_NAME 
					ENTRY_TYPE_NAME=$row.ENTRY_TYPE_NAME
					ESTIMATED_SIZE=$row.ESTIMATED_SIZE/1024/1024


				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)|Out-Null


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query12 CollectorType=Inventory - Category=Volumes"  

			$query='/* OMS -Query12*/ Select * FROM SYS.M_DATA_VOLUMES'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
            $ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query12"
                write-warning  $ex 
			}
			 

			$Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 


			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.Add([PSCustomObject]@{
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

				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)|Out-Null

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query13 CollectorType=Inventory - Category=Disks"  

			$query='/* OMS -Query13*/ Select * FROM SYS.M_DISKS'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning $query
                write-warning  $ex 
			}
			 

			$Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 


			foreach ($row in $ds.Tables[0].rows)
			{
				
				$resultsinv.Add([PSCustomObject]@{

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

				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query14 CollectorType=PErformance - Category=DiskUsage"  
			$query='/* OMS -Query14*/ Select * FROM SYS.M_DISK_USAGE'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query14"
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 


	
			foreach ($row in $ds.Tables[0].rows)
			{
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="Disk"
					PerfCounter="USED_SIZE"
					PerfInstance=$Hanadb
					USAGE_TYPE=$row.USAGE_TYPE 
					PerfValue=$row.USED_SIZE
				})|Out-Null
			}

			$Omsperfupload.Add($Resultsperf)|Out-Null

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query15 CollectorType=Inventory - Category=License"  

			$query="/* OMS Query15*/SELECT * FROM SYS.M_LICENSE"
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query15"
                write-warning  $ex 
			}
			 

			$Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 


			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.Add([PSCustomObject]@{
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

				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)





if($collecttableinv -and (get-date).Minute -lt 15)
{


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query16 CollectorType=Inventory - Category=Tables"  
			$query='/* OMS -Query16*/ Select Host,Port,Loaded,TABLE_NAME,RECORD_COUNT,RAW_RECORD_COUNT_IN_DELTA,MEMORY_SIZE_IN_TOTAL,MEMORY_SIZE_IN_MAIN,MEMORY_SIZE_IN_DELTA 
from M_CS_TABLES'

			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "failed to run Query16"
                write-warning  $ex 
			}
			 

			$Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 

### check if needed returns 111835 tables

	

			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.Add([PSCustomObject]@{
					HOST=$row.HOST.ToLower()
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="Tables"
					Database=$Hanadb
					PORT=$row.PORT
					LOADED=$row.LOADED
					TABLE_NAME=$row.TABLE_NAME
					RECORD_COUNT=$row.RECORD_COUNT
					RAW_RECORD_COUNT_IN_DELTA=$row.RAW_RECORD_COUNT_IN_DELTA
					MEMORY_SIZE_IN_TOTAL_MB=$row.MEMORY_SIZE_IN_TOTAL/1024/1024
					MEMORY_SIZE_IN_MAIN_MB=$row.MEMORY_SIZE_IN_MAIN/1024/1024
					MEMORY_SIZE_IN_DELTA_MB=$row.MEMORY_SIZE_IN_DELTA/1024/1024
				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)|Out-Null

}

			$Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query17CollectorType=Inventory - Category=Alerts"  
			$query='/* OMS Query17*/ Select * from _SYS_STATISTICS.Statistics_Current_Alerts'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning $query
                write-warning  $ex 
			}
			 


			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.Add([PSCustomObject]@{
					HOST=$row.ALERT_HOST
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="Alerts"
					Database=$Hanadb
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
				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)|Out-Null








# Service CPU 

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query18 CollectorType=PErformance - Category=Host Subcategory=OverallUsage"  
			$query='/* OMS Query18*/ Select * from SYS.M_Service_statistics'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query18"
                write-warning  $ex 
			}
			 
			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 

			IF($ds.Tables[0].rows)
			{
				foreach ($row in $ds.Tables[0].rows)
				{
					
					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="PROCESS_MEMORY_GB"
						PerfValue=$row.PROCESS_MEMORY_GB/1024/1024/1024
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="ACTIVE_REQUEST_COUNT"
						PerfValue=$row.ACTIVE_REQUEST_COUNT
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="TOTAL_CPU"
						PerfValue=$row.TOTAL_CPU
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="PROCESS_CPU_TIME"
						PerfValue=$row.PROCESS_CPU_TIME
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="PHYSICAL_MEMORY_GB"
						PerfValue=$row.PHYSICAL_MEMORY_GB/1024/1024/1024
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="OPEN_FILE_COUNT"
						PerfValue=$row.OPEN_FILE_COUNT
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="PROCESS_PHYSICAL_MEMORY_GB"
						PerfValue=$row.PROCESS_PHYSICAL_MEMORY_GB/1024/1024/1024
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="TOTAL_CPU_TIME"
						PerfValue=$row.TOTAL_CPU_TIME
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="ACTIVE_THREAD_COUNT"
						PerfValue=$row.ACTIVE_THREAD_COUNT
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="FINISHED_NON_INTERNAL_REQUEST_COUNT"
						PerfValue=$row.FINISHED_NON_INTERNAL_REQUEST_COUNT
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="PROCESS_CPU"
						PerfValue=$row.PROCESS_CPU
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="ALL_FINISHED_REQUEST_COUNT"
						PerfValue=$row.ALL_FINISHED_REQUEST_COUNT
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="REQUESTS_PER_SEC"
						PerfValue=$row.REQUESTS_PER_SEC
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="AVAILABLE_MEMORY_GB"
						PerfValue=$row.AVAILABLE_MEMORY_GB/1024/1024/1024
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="THREAD_COUNT"
						PerfValue=$row.THREAD_COUNT
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="TOTAL_MEMORY_GB"
						PerfValue=$row.TOTAL_MEMORY_GB/1024/1024/1024
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="RESPONSE_TIME"
						PerfValue=$row.RESPONSE_TIME
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SYS_TIMESTAMP).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.SERVICE_NAME
						PerfCounter="PENDING_REQUEST_COUNT"
						PerfValue=$row.PENDING_REQUEST_COUNT
					})|Out-Null
				}

			}

			$Omsperfupload.Add($Resultsperf)|Out-Null
      
#Updated CPU statictics collection 
Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query19  CollectorType=Performance - Category=Host - CPU"

			$query="/* OMS -Query19*/SELECT SAMPLE_TIME,HOST,
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
		add_seconds('"+$currentruntime+"',-$timespan) BEGIN_TIME,
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

			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query19"
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 

			IF($ds.Tables[0].rows)
			{
				foreach ($row in $ds.Tables[0].rows)
				{

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="CPU_PCT"
						PerfValue=$row.CPU_PCT
					})|Out-Null

				}
			}

			$Omsperfupload.Add($Resultsperf)|Out-Null

If($false) # Not Enabled 
{
Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query20 CollectorType=PErformance - Category=Service - Metrics CPU, Connections,Threads"

			$query="/* OMS -Query20*/Select SAMPLE_TIME ,
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
		add_seconds('"+$currentruntime+"',-$timespan) BEGIN_TIME, 
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
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query20"
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 


			IF($ds.Tables[0].rows)
			{
				foreach ($row in $ds.Tables[0].rows)
				{

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="CPU_PCT"
						PerfValue=$row.CPU
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="SYSCPU_PCT"
						PerfValue=$row.SYS
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="Connections"
						PerfValue=$row.CONNS
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="Transactions"
						PerfValue=$row.TRANS
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="Requestspersec"
						PerfValue=$row.EXE_PS
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="ActiveThreads"
						PerfValue=$row.ACT_THR
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="WaitingThreads"
						PerfValue=$row.WAIT_THR
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="ActiveSQLExecutorTHR"
						PerfValue=$row.ACT_SQL
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="PendingSessions"
						PerfValue=$row.PEND_SESS
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="Merges"
						PerfValue=$row.MERGES
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.SAMPLE_TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Service"
						PerfInstance=$row.PORT
						PerfCounter="Unloads"
						PerfValue=$row.UNLOADS
					})|Out-Null
				}
			}

			$Omsperfupload.Add($Resultsperf)|Out-Null
}

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query21 CollectorType=PErformance - Category=Memory  Subcategory=OverallUsage"


			$query="/* OMS -Query21*/SELECT * FROM SYS.M_MEMORY INNER JOIN SYS.M_Services on SYS.M_MEMORY.Port=SYS.M_Services.port Where SERVICE_NAME='indexserver'" 
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
        $ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query21"
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 

			IF ($ds.tables[0].rows)
			{
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="SYSTEM_MEMORY_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="SYSTEM_MEMORY_FREE_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="PROCESS_MEMORY_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="PROCESS_RESIDENT_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="PROCESS_CODE_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="PROCESS_STACK_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="PROCESS_ALLOCATION_LIMIT"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="GLOBAL_ALLOCATION_LIMIT"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="EFFECTIVE_PROCESS_ALLOCATION_LIMIT"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="HEAP_MEMORY_ALLOCATED_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="HEAP_MEMORY_USED_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="HEAP_MEMORY_FREE_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="HEAP_MEMORY_ROOT_ALLOCATED_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="HEAP_MEMORY_ROOT_FREE_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="SHARED_MEMORY_ALLOCATED_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="SHARED_MEMORY_USED_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="SHARED_MEMORY_FREE_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="TOTAL_MEMORY_SIZE_IN_USE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="COMPACTORS_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$SAPHOST
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="COMPACTORS_FREEABLE_SIZE"
					PerfValue=$row.Value/1024/1024/1024
				})|Out-Null

			}

			$Omsperfupload.Add($Resultsperf)|Out-Null

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query22 CollectorType=PErformance - Category=Memory  Subcategory=Service"

			$query="/* OMS -Query22 */SELECT * FROM SYS.M_SERVICE_MEMORY"
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query22"

                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 

			Write-Output '  CollectorType="Performance" - Category="Service" - Subcategory="MemoryUsage" '
			foreach ($row in $ds.Tables[0].rows)
			{
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="COMPACTORS_ALLOCATED_SIZE"
					PerfValue=$row.COMPACTORS_ALLOCATED_SIZE/1024/1024/1024
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="HEAP_MEMORY_ALLOCATED_SIZE"
					PerfValue=$row.HEAP_MEMORY_ALLOCATED_SIZE/1024/1024/1024
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="HEAP_MEMORY_USED_SIZE"
					PerfValue=$row.HEAP_MEMORY_USED_SIZE/1024/1024/1024
				})|Out-Null


				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="LOGICAL_MEMORY_SIZE"
					PerfValue=$row.LOGICAL_MEMORY_SIZE/1024/1024/1024
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="TOTAL_MEMORY_USED_SIZE"
					PerfValue=$row.TOTAL_MEMORY_USED_SIZE/1024/1024/1024
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="ALLOCATION_LIMIT"
					PerfValue=$row.ALLOCATION_LIMIT/1024/1024/1024
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="STACK_SIZE"
					PerfValue=$row.STACK_SIZE/1024/1024/1024
				})|Out-Null


				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="PHYSICAL_MEMORY_SIZE"
					PerfValue=$row.PHYSICAL_MEMORY_SIZE/1024/1024/1024
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="SHARED_MEMORY_USED_SIZE"
					PerfValue=$row.SHARED_MEMORY_USED_SIZE/1024/1024/1024
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="CODE_SIZE"
					PerfValue=$row.CODE_SIZE/1024/1024/1024
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="EFFECTIVE_ALLOCATION_LIMIT"
					PerfValue=$row.EFFECTIVE_ALLOCATION_LIMIT/1024/1024/1024
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="SHARED_MEMORY_ALLOCATED_SIZE"
					PerfValue=$row.SHARED_MEMORY_ALLOCATED_SIZE/1024/1024/1024
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					CollectorType="Performance"
					PerfObject="ServiceMemory"
					PerfInstance=$row.PORT
					PerfCounter="COMPACTORS_FREEABLE_SIZE"
					PerfValue=$row.COMPACTORS_FREEABLE_SIZE/1024/1024/1024
				})|Out-Null
			}
			$Omsperfupload.Add($Resultsperf)|Out-Null

#int ext connection count does not exit check version

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query23 CollectorType=PErformance - Category=Service Metrics"

			$query="/* OMS -Query23*/SELECT  HOST , PORT , to_varchar(time, 'YYYY-MM-DD HH24:MI') as TIME, ROUND(AVG(CPU),0)as PROCESS_CPU , ROUND(AVG(SYSTEM_CPU),0) as SYSTEM_CPU , 
MAX(MEMORY_USED) as MEMORY_USED , MAX(MEMORY_ALLOCATION_LIMIT) as MEMORY_ALLOCATION_LIMIT , SUM(HANDLE_COUNT) as HANDLE_COUNT , 
ROUND(AVG(PING_TIME),0) as PING_TIME, MAX(SWAP_IN) as SWAP_IN ,SUM(CONNECTION_COUNT) as CONNECTION_COUNT, SUM(TRANSACTION_COUNT)  as TRANSACTION_COUNT,  SUM(BLOCKED_TRANSACTION_COUNT) as BLOCKED_TRANSACTION_COUNT , SUM(STATEMENT_COUNT) as STATEMENT_COUNT
from SYS.M_LOAD_HISTORY_SERVICE 
WHERE TIME > add_seconds('"+$currentruntime+"',-$timespan)
Group by  HOST , PORT,to_varchar(time, 'YYYY-MM-DD HH24:MI')"

#double check and remove seconday CPU
			$sqcondcpu="SELECT  Time,sum(CPU) from SYS.M_LOAD_HISTORY_SERVICE 
WHERE TIME > add_seconds('"+$currentruntime+"',-$timespan)
group by Host,Time
order by Time desc"
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage
                write-warning  $ex ;write-warning "Failed to run Query23"
			}
			 

			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 

		
			foreach ($row in $ds.Tables[0].rows)
			{
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="EXTERNAL_CONNECTION_COUNT"
					PerfValue=$row.EXTERNAL_CONNECTION_COUNT
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="EXTERNAL_TRANSACTION_COUNT"
					PerfValue=$row.EXTERNAL_TRANSACTION_COUNT
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="STATEMENT_COUNT"
					PerfValue=$row.STATEMENT_COUNT
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="TRANSACTION_COUNT"
					PerfValue=$row.TRANSACTION_COUNT
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="SYSTEM_CPU"
					PerfValue=$row.SYSTEM_CPU
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="MEMORY_USED"
					PerfValue=$row.MEMORY_USED/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
                    Category='LoadHistory'
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="PROCESS_CPU"
					PerfValue=$row.PROCESS_CPU
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="IDLE_CONNECTION_COUNT"
					PerfValue=$row.IDLE_CONNECTION_COUNT
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="MEMORY_ALLOCATION_LIMIT"
					PerfValue=$row.MEMORY_ALLOCATION_LIMIT/1024/1024/1024
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="HANDLE_COUNT"
					PerfValue=$row.HANDLE_COUNT
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="INTERNAL_TRANSACTION_COUNT"
					PerfValue=$row.INTERNAL_TRANSACTION_COUNT
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="BLOCKED_TRANSACTION_COUNT"
					PerfValue=$row.BLOCKED_TRANSACTION_COUNT
				})|Out-Null

				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="USER_TRANSACTION_COUNT"
					PerfValue=$row.USER_TRANSACTION_COUNT
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="CONNECTION_COUNT"
					PerfValue=$row.CONNECTION_COUNT
				})|Out-Null


				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="SWAP_IN"
					PerfValue=$row.SWAP_IN
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="PING_TIME"
					PerfValue=$row.PING_TIME
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{

					HOST=$row.HOST
					Instance=$sapinstance
					Database=$Hanadb
					SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
					CollectorType="Performance"
					PerfObject="Service"
					PerfInstance=$row.PORT
					PerfCounter="INTERNAL_CONNECTION_COUNT"
					PerfValue=$row.INTERNAL_CONNECTION_COUNT
				})|Out-Null
			}
			$Omsperfupload.Add($Resultsperf)|Out-Null

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss'))  Query24 CollectorType=PErformance - Category=Host  Subcategory=Memory"

			$query="/* OMS - Query24 */SELECT  HOST,to_varchar(time, 'YYYY-MM-DD HH24:MI') as TIME, ROUND(AVG(CPU),0)as CPU_Total ,
ROUND(AVG(Network_IN)/1024/1024,2)as Network_IN_MB,ROUND(AVG(Network_OUT)/1024/1024,2) as Network_OUT_MB,
MAX(MEMORY_RESIDENT)/1024/1024/1024 as ResidentGB,MAX(MEMORY_TOTAL_RESIDENT/1024/1024/1024 )as TotalResidentGB
,MAX(MEMORY_USED/1024/1024/1024) as UsedMemoryGB
,MAX(MEMORY_RESIDENT-MEMORY_TOTAL_RESIDENT)/1024/1024/1024 as Database_ResidentGB
,MAX(MEMORY_ALLOCATION_LIMIT)/1024/1024/1024 as AllocationLimitGB
from SYS.M_LOAD_HISTORY_HOST
WHERE TIME > add_seconds('"+$currentruntime+"',-$timespan)
Group by  HOST ,to_varchar(time, 'YYYY-MM-DD HH24:MI')"
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query24"
                    write-warning  $ex 
			}
			 
			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 

			IF ($ds.Tables[0].rows)
			{

		

				foreach ($row in $ds.Tables[0].rows)
				{
					

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="USEDMEMORYGB"
						PerfValue=$row.USEDMEMORYGB
					})|Out-Null
					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="ALLOCATIONLIMITGB"
						PerfValue=$row.ALLOCATIONLIMITGB
					})|Out-Null
					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="RESIDENTGB"
						PerfValue=$row.RESIDENTGB
					})|Out-Null
					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="TOTALRESIDENTGB"
						PerfValue=$row.TOTALRESIDENTGB
					})|Out-Null


					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="DATABASE_RESIDENTGB"
						PerfValue=$row.DATABASE_RESIDENTGB
					})|Out-Null
					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="NETWORK_OUT_MB"
						PerfValue=$row.NETWORK_OUT_MB
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="CPU_TOTAL"
						PerfValue=$row.CPU_TOTAL
					})|Out-Null

					$Resultsperf.Add([PSCustomObject]@{

						HOST=$row.HOST
						Instance=$sapinstance
						Database=$Hanadb
						SYS_TIMESTAMP=([datetime]$row.TIME).addseconds([int]$utcdiff*(-1))
						CollectorType="Performance"
						PerfObject="Host"
						PerfInstance=$row.HOST
						PerfCounter="NETWORK_IN_MB"
						PerfValue=$row.NETWORK_IN_MB
					})|Out-Null
				}
				$Omsperfupload.Add($Resultsperf)|Out-Null

			}

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss'))  Query25 CollectorType=PErformance - Category=Table  Subcategory=MemUsage"


			$query='/* OMS -Query25*/ Select Schema_name,round(sum(Memory_size_in_total)/1024/1024) as "ColunmTablesMBUSed" from M_CS_TABLES group by Schema_name'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query25"
                write-warning  $ex 
			}

			 

			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 


			IF ($ds.Tables[0].rows)
			{
		
				foreach($row in $ds.Tables[0].rows)
				{
					$Resultsperf.Add(  [PSCustomObject]@{
						HOST=$SAPHOST
						Instance=$sapinstance
						CollectorType="Performance"
						PerfObject="Tables"
						PerfCounter="ColunmTablesMBUSed"
						PerfInstance=$row.SCHEMA_NAME
						PerfValue=$row.ColunmTablesMBUSed
					})|Out-Null


				}

			}
			$Omsperfupload.Add($Resultsperf)|Out-Null

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query26 CollectorType=PErformance - Category=Memory  Subcategory=Component"

			$query='/* OMS -Query26 */ Select  host,component, sum(Used_memory_size) USed_MEmory_size from public.m_service_component_memory group by host, component'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query26"
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 


			IF ($ds.Tables[0].rows)
			{


				foreach ($row in $ds.Tables[0].rows)
				{
					$Resultsperf.Add(  [PSCustomObject]@{
						HOST=$row.HOST
						Instance=$sapinstance
						CollectorType="Performance"
						PerfObject="Memory"
						PerfCounter="Component"
						PerfInstance=$row.COMPONENT
						PerfValue=$row.USED_MEMORY_SIZE/1024/1024

					})|Out-Null
				}

				$Omsperfupload.Add($Resultsperf)|Out-Null
			}


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query27 CollectorType=PErformance - Category=Memory  Used, Resident,PEak"


			$query='/* OMS -Query27 */ Select t1.host,round(sum(t1.Total_memory_used_size/1024/1024/1024),1) as "UsedMemoryGB",round(sum(t1.physical_memory_size/1024/1024/1024),2) "DatabaseResident" ,SUM(T2.Peak) as PeakGB from m_service_memory  as T1 
Join 
(Select  Host, ROUND(SUM(M)/1024/1024/1024,2) Peak from (Select  host,SUM(CODE_SIZE+SHARED_MEMORY_ALLOCATED_SIZE) as M from sys.M_SERVICE_MEMORY group by host  
union 
select host, sum(INCLUSIVE_PEAK_ALLOCATION_SIZE) as M from M_HEAP_MEMORY_RESET WHERE depth = 0 group by host ) group by Host )as T2 on T1.Host=T2.Host
group by T1.host'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query27"
                write-warning  $ex 
			}
			 
			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 


			IF ($ds.Tables[0].rows)
			{

				$Resultsperf.Add([PSCustomObject]@{
					HOST=$ds.tables[0].rows[0].HOST
					Database=$hanadb
					CollectorType="Performance"
					Instance=$sapinstance
					PerfObject="Memory"
					PerfCounter="UsedMemoryGB"
					PerfInstance=$ds.tables[0].rows[0].HOST
					PerfValue=$ds.tables[0].rows[0].UsedMemoryGB
					
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$ds.tables[0].rows[0].HOST
					Database=$hanadb
					CollectorType="Performance"
					Instance=$sapinstance
					PerfObject="Memory"
					PerfCounter="DatabaseResidentGB"
					PerfInstance=$ds.tables[0].rows[0].HOST
					PerfValue=$ds.tables[0].rows[0].DatabaseResident
					
				})|Out-Null
				$Resultsperf.Add([PSCustomObject]@{
					HOST=$ds.tables[0].rows[0].HOST
					Database=$hanadb
					Instance=$sapinstance
					CollectorType="Performance"
					PerfObject="Memory"
					PerfCounter="PeakUsedMemoryGB"
					PerfInstance=$ds.tables[0].rows[0].HOST
					PerfValue=$ds.tables[0].rows[0].PeakGB
					
				})|Out-Null
			}
			$Omsperfupload.Add($Resultsperf)|Out-Null

# check takes long time to calculat
IF($false) #disable Colelction
{

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query28 CollectorType=PErformance - Category=Compression  "
			$query='/* OMS -Query28  */ Select  host,schema_name ,sum(DISTINCT_COUNT) RECORD_COUNT,
	sum(MEMORY_SIZE_IN_TOTAL) COMPRESSED_SIZE,	sum(UNCOMPRESSED_SIZE) UNCOMPRESSED_SIZE, (sum(UNCOMPRESSED_SIZE)/sum(MEMORY_SIZE_IN_TOTAL)) Compression_Ratio
, 100*(sum(UNCOMPRESSED_SIZE)/sum(MEMORY_SIZE_IN_TOTAL)) Compression_PErcentage
	FROM SYS.M_CS_ALL_COLUMNS Group by host,Schema_name having sum(Uncompressed_size) >0 '

			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query28"
                write-warning  $ex 
			}
			 

			$Resultsperf=$null
			[System.Collections.ArrayList]$Resultsperf=@(); 


			IF ($ds.Tables[0].rows)
			{

				Write-Output '  CollectorType="Performance" - Category="Memory" - Subcategory="Compression" '
				foreach ($row in $ds.Tables[0].rows)
				{
					
					$Resultsperf.Add([PSCustomObject]@{
						HOST=$row.Host
						Instance=$sapinstance
						CollectorType="Performance"
						Database=$Hanadb
						PerfObject="Compression"
						PerfCounter="RECORD_COUNT"
						PerfInstance=$row.Schema_NAme
						PerfValue=$row.RECORD_COUNT
						
					})|Out-Null
					$Resultsperf.Add([PSCustomObject]@{
						HOST=$row.Host
						Instance=$sapinstance
						CollectorType="Performance"
						Database=$Hanadb
						PerfObject="Compression"
						PerfCounter="COMPRESSED_SIZE"
						PerfInstance=$row.Schema_NAme
						PerfValue=$row.COMPRESSED_SIZE/1024/1024
						
					})|Out-Null
					$Resultsperf.Add([PSCustomObject]@{
						HOST=$row.Host
						Instance=$sapinstance
						Database=$Hanadb
						CollectorType="Performance"
						PerfObject="Compression"
						PerfCounter="UNCOMPRESSED_SIZE"
						PerfInstance=$row.Schema_NAme
						PerfValue=$row.UNCOMPRESSED_SIZE/1024/1024
						
					})|Out-Null
					$Resultsperf.Add([PSCustomObject]@{
						HOST=$row.Host
						Instance=$sapinstance
						CollectorType="Performance"
						Database=$Hanadb
						PerfObject="Compression"
						PerfCounter="COMPRESSION_RATIO"
						PerfInstance=$row.Schema_NAme
						PerfValue=$row.COMPRESSION_RATIO
						
					})|Out-Null
					$Resultsperf.Add([PSCustomObject]@{
						HOST=$row.Host
						Instance=$sapinstance
						CollectorType="Performance"
						Database=$Hanadb
						PerfObject="Compression"
						PerfCounter="COMPRESSION_PERCENTAGE"
						PerfInstance=$row.Schema_NAme
						PerfValue=$row.COMPRESSION_PERCENTAGE

					})|Out-Null
				}
				$Omsperfupload.Add($Resultsperf)|Out-Null


			}

}


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query29 CollectorType=PErformance - Category=Volumes Subcategory=IOStat"
			#volume IO Latency and  throughput
					$query="/* OMS -Query29*/select host, port ,type,
					round(max_io_buffer_size / 1024,0) `"MaxBufferinKB`",
					trigger_async_write_count,
					avg_trigger_async_write_time as `"AvgTriggerAsyncWriteMicroS`",
					write_count, avg_write_time as `"AvgWriteTimeMicros`"
					,trigger_async_read_count,
					avg_trigger_async_read_time as `"AvgTriggerAsyncReadicroS`",
					read_count, avg_read_time as `"AvgReadTimeMicros`"
					
					from `"PUBLIC`".`"M_VOLUME_IO_DETAILED_STATISTICS_RESET`"
					where  volume_id in (select volume_id from m_volumes where service_name = 'indexserver')
					and (write_count <> 0 or read_count <> 0  or avg_trigger_async_write_time <> 0 or avg_trigger_async_read_time <> 0)
					"
								   
				   $cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
				   $ds=New-Object system.Data.DataSet ;
				   $ex=$null
				   Try{
					   $cmd.fill($ds)
					   }
				   Catch
				   {
					   $Ex=$_.Exception.MEssage;write-warning "Failed to run Query29"
				   }
							
				   IF ($ds.Tables[0].rows)
				   {
	   
					
					   foreach ($row in $ds.Tables[0].rows)
					   {

								$Resultsperf.Add([PSCustomObject]@{
			
									HOST=$row.HOST
									Instance=$sapinstance
									Database=$Hanadb
									SERVICE_NAME="indexserver"
									CollectorType="Performance"
									PerfObject="Volumes"
									PerfCounter="TRIGGER_ASYNC_WRITE_COUNT"
									PerfValue=[double]$row.TRIGGER_ASYNC_WRITE_COUNT
									PerfInstance=$row.Type+"|"+$row.MaxBufferinKB+"KB"
									TYPE=$row.TYPE 
								})|Out-Null
								$Resultsperf.Add([PSCustomObject]@{
			
									HOST=$row.HOST
									Instance=$sapinstance
									Database=$Hanadb
									SERVICE_NAME="indexserver"
									CollectorType="Performance"
									PerfObject="Volumes"
									PerfCounter="AVG_TRIGGER_ASYNC_WRITE_MICROS"
									PerfValue=[double]$row.AvgTriggerAsyncWriteMicroS 
									PerfInstance=$row.Type+"|"+$row.MaxBufferinKB+"KB"
									TYPE=$row.TYPE 
								})|Out-Null
								$Resultsperf.Add([PSCustomObject]@{
			
									HOST=$row.HOST
									Instance=$sapinstance
									Database=$Hanadb
									SERVICE_NAME="indexserver"
									CollectorType="Performance"
									PerfObject="Volumes"
									PerfCounter="WRITE_COUNT"
									PerfValue=[double]$row.WRITE_COUNT
									PerfInstance=$row.Type+"|"+$row.MaxBufferinKB+"KB"
									TYPE=$row.TYPE 
								})|Out-Null
								
								$Resultsperf.Add([PSCustomObject]@{
			
									HOST=$row.HOST
									Instance=$sapinstance
									Database=$Hanadb
									SERVICE_NAME="indexserver"
									CollectorType="Performance"
									PerfObject="Volumes"
									PerfCounter="AVG_WRITE_TIME_MICROS"
									PerfValue=[double]$row.AvgWriteTimeMicros
									PerfInstance=$row.Type+"|"+$row.MaxBufferinKB+"KB"
									TYPE=$row.TYPE 
								})|Out-Null

								#read
								$Resultsperf.Add([PSCustomObject]@{
			
									HOST=$row.HOST
									Instance=$sapinstance
									Database=$Hanadb
									SERVICE_NAME="indexserver"
									CollectorType="Performance"
									PerfObject="Volumes"
									PerfCounter="TRIGGER_ASYNC_READ_COUNT"
									PerfValue=[double]$row.TRIGGER_ASYNC_READ_COUNT
									PerfInstance=$row.Type+"|"+$row.MaxBufferinKB+"KB"
									TYPE=$row.TYPE 
								})|Out-Null
								$Resultsperf.Add([PSCustomObject]@{
			
								HOST=$row.HOST
								Instance=$sapinstance
								Database=$Hanadb
								SERVICE_NAME="indexserver"
								CollectorType="Performance"
								PerfObject="Volumes"
								PerfCounter="AVG_TRIGGER_ASYNC_READ_MICROS"
								PerfValue=[double]$row.AvgTriggerAsyncReadMicroS 
								PerfInstance=$row.Type+"|"+$row.MaxBufferinKB+"KB"
								TYPE=$row.TYPE 
								})|Out-Null
								$Resultsperf.Add([PSCustomObject]@{
				
									HOST=$row.HOST
									Instance=$sapinstance
									Database=$Hanadb
									SERVICE_NAME="indexserver"
									CollectorType="Performance"
									PerfObject="Volumes"
									PerfCounter="READ_COUNT"
									PerfValue=[double]$row.READ_COUNT
									PerfInstance=$row.Type+"|"+$row.MaxBufferinKB+"KB"
									TYPE=$row.TYPE 
								})|Out-Null
								
								$Resultsperf.Add([PSCustomObject]@{
				
									HOST=$row.HOST
									Instance=$sapinstance
									Database=$Hanadb
									SERVICE_NAME="indexserver"
									CollectorType="Performance"
									PerfObject="Volumes"
									PerfCounter="AVG_READ_TIME_MICROS"
									PerfValue=[double]$row.AvgReadTimeMicros
									PerfInstance=$row.Type+"|"+$row.MaxBufferinKB+"KB"
									TYPE=$row.TYPE 
								})	|Out-Null		
	   									 
					   }
	   
					   $Omsperfupload.Add($Resultsperf)|out-null
				   }

			    #volume throughput

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query30 CollectorType=PErformance - Category=Volumes Subcategory=Throughput"

				$query="/* OMS -Query30*/select v.host, v.port, v.service_name, s.type,
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
			   
			   $cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
						   $ds=New-Object system.Data.DataSet ;
			   $ex=$null
						   Try{
							   $cmd.fill($ds)
						   }
						   Catch
						   {
							   $Ex=$_.Exception.MEssage;write-warning "Failed to run Query30"
						   }
							
			   
						   $Resultsperf=$null
						   [System.Collections.ArrayList]$Resultsperf=@(); 
			   
			   
						   IF ($ds.Tables[0].rows)
						   {
			   
							   Write-Output '  CollectorType="Performance" - Category="Volume" - Subcategory="IOStat" '
							   foreach ($row in $ds.Tables[0].rows)
							   {
								   
								   $Resultsperf.Add([PSCustomObject]@{
			   
									   HOST=$row.HOST
									   Instance=$sapinstance
									   Database=$Hanadb
									   SERVICE_NAME=$row.SERVICE_NAME
									   TYPE=$row.TYPE 
									   CollectorType="Performance"
									   PerfObject="Volumes"
									   PerfInstance=$row.Type
									   PerfCounter="Read_MB_Sec"
									   PerfValue=[double]$row.ReadMBpersec
								   })|Out-Null
								   $Resultsperf.Add([PSCustomObject]@{
			   
									   HOST=$row.HOST
									   Instance=$sapinstance
									   Database=$Hanadb
									   SERVICE_NAME=$row.SERVICE_NAME
									   TYPE=$row.TYPE 
									   CollectorType="Performance"
									   PerfObject="Volumes"
									   PerfInstance=$row.Type
									   PerfCounter="Write_MB_Sec"
									   PerfValue=[double]$row.WriteMBpersec
								   })|Out-Null
			   
													 
							   }
			   
							   $Omsperfupload.Add($Resultsperf)|Out-Null
						   }
			   #Save Point Duration

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query31 CollectorType=PErformance - Category=Savepoint"
			   
			   $query="/* OMS - Query31 */select start_time, volume_id,
				round(duration / 1000000) as `"DurationSec`",
				round(critical_phase_duration / 1000000) as `"CriticalSeconds`",
				round(total_size / 1024 / 1024) as `"SizeMB`",
				round(total_size / duration) as `"Appro. MB/sec`",
				round (flushed_rowstore_size / 1024 / 1024) as `"Row Store Part MB`"
			   from m_savepoints where start_time  > add_seconds('"+$currentruntime+"',-$timespan);"
			   
			   
			   $cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
						   $ds=New-Object system.Data.DataSet ;
			   $ex=$null
						   Try{
							   $cmd.fill($ds)
						   }
						   Catch
						   {
							   $Ex=$_.Exception.MEssage;write-warning "Failed to run Query31"
						   }
								 
						   $Resultsperf=$null
						   [System.Collections.ArrayList]$Resultsperf=@(); 
			   
			   
						   IF ($ds.Tables[0].rows)
						   {
			   
							   Write-Output '  CollectorType="Performance" - Category="Volume" - Subcategory="IOStat" '
							   foreach ($row in $ds.Tables[0].rows)
							   {
								   
								   $Resultsperf.Add([PSCustomObject]@{
			   
									   HOST=$row.HOST
									   Instance=$sapinstance
									   Database=$Hanadb
									   TIMESTamp=$row.START_TIME
									   VOLUME_ID =$row.VOLUME_ID 
									   CollectorType="Performance"
									   PerfObject="SavePoint"
									   PerfInstance=$row.VOLUME_ID
									   PerfCounter="DurationSec"
									   PerfValue=[double]$row.DurationSec
								   })|Out-Null
								   $Resultsperf.Add([PSCustomObject]@{
			   
									   HOST=$row.HOST
									   Instance=$sapinstance
									   Database=$Hanadb
									   TIMESTamp=$row.START_TIME
									   VOLUME_ID =$row.VOLUME_ID 
									   CollectorType="Performance"
									   PerfObject="SavePoint"
									   PerfInstance=$row.VOLUME_ID
									   PerfCounter="CriticalSeconds"
									   PerfValue=[double]$row.CriticalSeconds
								   })|Out-Null
								   $Resultsperf.Add([PSCustomObject]@{
			   
									   HOST=$row.HOST
									   Instance=$sapinstance
									   Database=$Hanadb
									   TIMESTamp=$row.START_TIME
									   VOLUME_ID =$row.VOLUME_ID 
									   CollectorType="Performance"
									   PerfObject="SavePoint"
									   PerfInstance=$row.VOLUME_ID
									   PerfCounter="SizeMB"
									   PerfValue=[double]$row.SizeMB
								   })|Out-Null
			   
													 
							   }
			   
							   $Omsperfupload.Add($Resultsperf)|Out-Null
						   }
	Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query32 CollectorType=PErformance - Category=Statement Subcategory=Expensive"		   

			$query="/* OMS -Query32*/Select HOST,
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
CPU_TIME FROM PUBLIC.M_EXPENSIVE_STATEMENTS WHERE  START_TIME> add_seconds('"+$currentruntime+"',-$timespan)"

			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query32"
                write-warning  $ex 
			}
			 

			$Resultsinv=$null
			[System.Collections.ArrayList][System.Collections.ArrayList]$Resultsinv=@(); 


			IF($ds.Tables[0])
			{

				foreach ($row in $ds.Tables[0].rows)
				{
					$resultsinv.add([PSCustomObject]@{
						HOST=$row.Host
						Instance=$sapinstance
						CollectorType="Inventory"
						Category="ExpensiveStatements"
						Database=$Hanadb
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
					})|Out-Null
				}
				$Omsinvupload.Add($Resultsinv)
			}



	Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query33 CollectorType=Inventory - Category=Statement"
				

			$query="/* OMS -Query33 */SELECT 
			HOST,
			PORT,
			SCHEMA_NAME,
			STATEMENT_HASH,
			STATEMENT_STRING,
			USER_NAME,
			ACCESSED_TABLE_NAMES,
			TABLE_TYPES STORE,
			PLAN_SHARING_TYPE SHARING_TYPE,
			LAST_EXECUTION_TIMESTAMP,
			IS_DISTRIBUTED_EXECUTION,
			IS_INTERNAL,PLAN_ID,
			TABLE_LOCATIONS TABLE_LOCATION,
			EXECUTION_COUNT,TOTAL_EXECUTION_TIME,AVG_EXECUTION_TIME,
			TOTAL_RESULT_RECORD_COUNT,
			TOTAL_EXECUTION_TIME + TOTAL_PREPARATION_TIME TOTAL_ELAPSED_TIME,
			TOTAL_PREPARATION_TIME,
			TOTAL_LOCK_WAIT_DURATION,
			TOTAL_LOCK_WAIT_COUNT,
			TOTAL_SERVICE_NETWORK_REQUEST_DURATION,
			TOTAL_CALLED_THREAD_COUNT, 
			TOTAL_EXECUTION_MEMORY_SIZE

			FROM
			M_SQL_PLAN_CACHE where LAST_EXECUTION_TIMESTAMP >  add_seconds('"+$currentruntime+"',-$timespan) and AVG_EXECUTION_TIME > $querythreshold"

			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
					$ds=New-Object system.Data.DataSet ;
			$ex=$null
		  Try{
			  $cmd.fill($ds)
		  }
		  Catch
		  {
			  $Ex=$_.Exception.MEssage;write-warning "Failed to run Query33"
			  write-warning  $ex 
		  }
		   

		  $Resultsinv=$null
		  [System.Collections.ArrayList]$Resultsinv=@(); 

		  foreach ($row in $ds.Tables[0].rows)
		  {

				  $resultsinv.Add([PSCustomObject]@{

				  HOST=$row.HOST
				  Instance=$sapinstance
				  Database=$Hanadb
				  PORT=$row.PORT
				  Schema_Name=$row.SCHEMA_NAME
				  SYS_TIMESTAMP=([datetime]$row.LAST_EXECUTION_TIMESTAMP).addseconds([int]$utcdiff*(-1))
				  CollectorType="Inventory"
				  Category="Statement"
				  STATEMENT_HASH=$row.STATEMENT_HASH
				  STATEMENT_STRING=$row.STATEMENT_STRING
				  USER_NAME=$row.USER_NAME
				  ACCESSED_TABLE_NAMES=$row.ACCESSED_TABLE_NAMES 
				  STORE=$row.STORE
				  SHARING_TYPE=$row.SHARING_TYPE
				  LAST_EXECUTION_TIMESTAMP=$row.LAST_EXECUTION_TIMESTAMP
				  IS_DISTRIBUTED_EXECUTION=$row.IS_DISTRIBUTED_EXECUTION 
				  IS_INTERNAL =$row.IS_INTERNAL
				  IS_PINNED_PLAN=$row.IS_PINNED_PLAN
				  PLAN_ID=$row.PLAN_ID
				  TABLE_LOCATION=$row.TABLE_LOCATION
				  EXECUTION_COUNT=$row.EXECUTION_COUNT  
				  TOTAL_EXECUTION_TIME=$row.TOTAL_EXECUTION_TIME
				  AVG_EXECUTION_TIME=$row.AVG_EXECUTION_TIME
				  TOTAL_RESULT_RECORD_COUNT=$row.TOTAL_RESULT_RECORD_COUNT
				  TOTAL_ELAPSED_TIME=$row.TOTAL_ELAPSED_TIME
				  TOTAL_PREPARATION_TIME =$row.TOTAL_PREPARATION_TIME
				  TOTAL_LOCK_WAIT_DURATION=$row.TOTAL_LOCK_WAIT_DURATION
				  TOTAL_LOCK_WAIT_COUNT=$row.TOTAL_LOCK_WAIT_COUNT
				  TOTAL_SERVICE_NETWORK_REQUEST_DURATION =$row.TOTAL_SERVICE_NETWORK_REQUEST_DURATION
				  TOTAL_CALLED_THREAD_COUNT=$row.TOTAL_CALLED_THREAD_COUNT
				  TOTAL_EXECUTION_MEMORY_SIZE=$row.TOTAL_EXECUTION_MEMORY_SIZE                                   
			   })|Out-Null
		  }
		  $Omsinvupload.Add($Resultsinv)|Out-Null


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query34 CollectorType=Inventory - Category=Threads"				


$query="/* OMS -Query34*/SELECT HOST,
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
$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
		  $ds=New-Object system.Data.DataSet ;
$ex=$null
		  Try{
			  $cmd.fill($ds)|out-null
		  }
		  Catch
		  {
			  $Ex=$_.Exception.MEssage;write-warning "Failed to run Query34"
			  write-warning  $ex 
		  }
		   

		  $Resultsinv=$null
		  [System.Collections.ArrayList]$Resultsinv=@(); 

		  IF($ds[0].Tables.rows)
		  {
			  foreach ($row in $ds.Tables[0].rows)
			  {
				  $resultsinv.Add([PSCustomObject]@{
					  HOST=$row.HOST.ToLower()
					  Instance=$sapinstance
					  CollectorType="Inventory"
					  Category="Thread"
					  Subcategory="Current"
					  Database=$Hanadb
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
				  })|Out-Null
			  }
			  $Omsinvupload.Add($Resultsinv)|Out-Null
		  }


#inventory Sessions    


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query35 CollectorType=Inventory - Category=Sessions"		


$query="/* OMS -Query35*/SELECT  C.HOST,
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
	  WHERE (C.START_TIME  > add_seconds('"+$currentruntime+"',-$timespan)) OR  (C.END_TIME  > add_seconds('"+$currentruntime+"',-$timespan))
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
		   $cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
		  $ds=New-Object system.Data.DataSet ;
	  $ex=$null
		  Try{
			  $cmd.fill($ds)|out-null
		  }
		  Catch
		  {
			  $Ex=$_.Exception.MEssage;write-warning "Failed to run Query35"
			  write-warning  $ex 
		  }
		   

		  $Resultsinv=$null
		  [System.Collections.ArrayList]$Resultsinv=@(); 


		  IF($ds[0].Tables.rows)
		  {
			  foreach ($row in $ds.Tables[0].rows)
			  {
				  $resultsinv.Add([PSCustomObject]@{
					  HOST=$row.HOST.ToLower()
					  Instance=$sapinstance
					  CollectorType="Inventory"
					  Category="Sessions"
					  Database=$Hanadb
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

				  })|Out-Null
			  }
			  $Omsinvupload.Add($Resultsinv)|Out-Null
		  }

  $checkfreq=$timespan 
IF($firstrun){$checkfreq=3600}Else{$checkfreq=$timespan } # decide if you change 'HOUR' TIME_AGGREGATE_BY 


	
#backup inventory  

 
IF($false) # not enabled
{
If($MDC)
{
  $query="/* OMS */Select START_TIME,
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
  $query="/* OMS */SELECT   START_TIME,
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
		add_seconds('"+$currentruntime+"',-$($checkfreq*1)) BEGIN_TIME,
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

   $cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
		  $ds=New-Object system.Data.DataSet ;
$ex=$null
		  Try{
			 $cmd.fill($ds)|out-null
		  }
		  Catch
		  {
			  $Ex=$_.Exception.MEssage;write-warning $query
			  write-warning  $ex 
		  }

}
	  
		  $Resultsinv=$null
		  [System.Collections.ArrayList]$Resultsinv=@(); 

#FIX TIME

	  $checkfreq=$timespan 
IF($firstrun){$checkfreq=3600}Else{$checkfreq=$timespan } 

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query36 CollectorType=Inventory - Category=Connections"	

$query="/* OMS -Query36*/SELECT   BEGIN_TIME,
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
	  add_seconds('"+$currentruntime+"',-$($checkfreq*1)) BEGIN_TIME,
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

  $cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
		  $ds=New-Object system.Data.DataSet ;
$ex=$null
		  Try{
			  $cmd.fill($ds)|out-null
		  }
		  Catch
		  {
			  $Ex=$_.Exception.MEssage;write-warning "Failed to run Query36"
			  write-warning  $ex 
		  }

  $Resultsinv=$null
		  [System.Collections.ArrayList]$Resultsinv=@(); 


		  IF($ds[0].Tables.rows)
		  {
			  foreach ($row in $ds.Tables[0].rows)
			  {
				  $resultsinv.Add([PSCustomObject]@{
					  HOST=$row.HOST.ToLower()
					  Instance=$sapinstance
					  CollectorType="Inventory"
					  Category="Connections"
					  Database=$Hanadb
					  PORT=[int]$row.PORT
					  SERVICE=$row.Service
					  CONN_ID=[int32]$row.CONN_ID
					  CONNECTION_TYPE=$row.CONNECTION_TYPE
					  CONNECTION_STATUS=$row.CONNECTION_STATUS
					  CONNS=[int32]$row.CONNS
					  CUR_CONNS=[int32]$row.CUR_CONNS
					  CREATED_BY=$row.CREATED_BY
					  APP_NAME=$row.APP_NAME
					  APP_USER =$row.APP_USER 
					  APP_VERSION=$row.APP_VERSION
					  APP_SOURCE=$row.APP_SOURCE


									  })|Out-Null
			  }
			  $Omsinvupload.Add($Resultsinv)|Out-Null
		  }


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query37 CollectorType=PErformance - Category=ConnectionStatistics"	

$query="/* OMS -Query37*/ SELECT  HOST,
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
  AND c.END_TIME  > add_seconds('"+$currentruntime+"',-$timespan)
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

  $cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
		  $ds=New-Object system.Data.DataSet ;
$ex=$null
		  Try{
			  $cmd.fill($ds)|out-null
		  }
		  Catch
		  {
			  $Ex=$_.Exception.MEssage;write-warning "Failed to run Query37"
			  write-warning  $ex 
		  }
		   
		 
		  $Resultsperf=$null
		  [System.Collections.ArrayList]$Resultsperf=@(); 

		  IF ($ds.tables[0].rows)
		  {
			  Foreach($row in $ds.tables[0].rows)
			  {
				  $Resultsperf.Add([PSCustomObject]@{
					  HOST=$row.HOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ConnectionStatistics"
					  PerfCounter=$row.SQL_TYPE
					  PerfValue=[double]$row.EXECUTIONS
					  PerfInstance='EXECUTIONS'
					  })|Out-Null

				  $Resultsperf.Add([PSCustomObject]@{
					  HOST=$row.HOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ConnectionStatistics"
					  PerfCounter=$row.SQL_TYPE
					  PerfValue=[double]$row.ELAPSED_S
					  PerfInstance='ELAPSED_S'
					  })|Out-Null

				  $Resultsperf.Add([PSCustomObject]@{
					  HOST=$row.HOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ConnectionStatistics"
					  PerfCounter=$row.SQL_TYPE
					  PerfValue=[double]$row.ELA_PER_EXEC_MS
					  PErfInstance='ELA_PER_EXEC_MS'   
					  })|Out-Null

				  $Resultsperf.Add([PSCustomObject]@{
					  HOST=$row.HOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ConnectionStatistics"
					  PerfCounter=$row.SQL_TYPE
					  PerfValue=[double]$row.LOCK_PER_EXEC_MS
					  PerfInstance='LOCK_PER_EXEC_MS'
					  })|Out-Null

				  $Resultsperf.Add([PSCustomObject]@{
					  HOST=$row.HOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ConnectionStatistics"
					  PerfCounter=$row.SQL_TYPE
					  PerfValue=[double]$row.MAX_ELA_MS 
					  PerfInstance='MAX_ELA_MS'
					  })|Out-Null
				  }
				  $Omsperfupload.Add($Resultsperf)|Out-Null
					
		  }




Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query38 CollectorType=Inventory - Category=Replication_Status"	

$query="/* OMS -Query38*/ SELECT   R.SITE_NAME ,R.SECONDARY_SITE_NAME,R.HOST,R.SECONDARY_HOST,
 R.SITE_NAME || ' -> ' || R.SECONDARY_SITE_NAME PATH,
  R.HOST || ' -> ' || R.SECONDARY_HOST HOSTS,
  LPAD(TO_VARCHAR(R.PORT), 5) PORT,
  S.SERVICE_NAME SERVICE,
  LPAD(TO_DECIMAL(SECONDS_BETWEEN(R.SHIPPED_LOG_POSITION_TIME, R.LAST_LOG_POSITION_TIME) / 3600, 10, 2), 12) SHIP_DELAY_H,
  LPAD(TO_DECIMAL((R.LAST_LOG_POSITION - R.SHIPPED_LOG_POSITION) * 64 / 1024 / 1024, 10, 2), 18) ASYNC_BUFF_USED_MB,
  R.REPLICATION_MODE MODE,
  R.REPLICATION_STATUS STATUS,
  R.REPLICATION_STATUS_DETAILS STATUS_DETAILS,
  R.SECONDARY_ACTIVE_STATUS SEC_ACTIVE
FROM
( SELECT                  /* Modification section */
    '%' HOST,
    '%' PORT,
    '%' SERVICE_NAME,
    '%' REPLICATION_STATUS,
    '%' REPLICATION_STATUS_DETAILS,
    -1 MIN_LOG_SHIPPING_DELAY_S
  FROM
    DUMMY
) BI,
  M_SERVICES S,
  M_SERVICE_REPLICATION R
WHERE
  S.HOST LIKE BI.HOST AND
  TO_VARCHAR(S.PORT) LIKE BI.PORT AND
  S.SERVICE_NAME LIKE BI.SERVICE_NAME AND
  R.HOST = S.HOST AND
  R.PORT = S.PORT AND
  R.REPLICATION_STATUS LIKE BI.REPLICATION_STATUS AND
  UPPER(R.REPLICATION_STATUS_DETAILS) LIKE UPPER(BI.REPLICATION_STATUS_DETAILS) AND
  ( BI.MIN_LOG_SHIPPING_DELAY_S = -1 OR 
    SECONDS_BETWEEN(R.SHIPPED_LOG_POSITION_TIME, R.LAST_LOG_POSITION_TIME) >= BI.MIN_LOG_SHIPPING_DELAY_S
  )
ORDER BY
  1, 2, 3
"

			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query38"
                write-warning  $ex 
			}

	        $Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 





			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
					CollectorType="Inventory"
					Category="ReplicationStatus"
                    SITE_NAME=$row.SITE_NAME
                    SECONDARY_SITE_NAME=$row.SECONDARY_SITE_NAME
                    SECONDARY_HOST=$row.SECONDARY_HOST   
                    PATH=$row.PATH 
                    PORT=$row.PORT 
                    SERVICE=$row.SERVICE 
                    SHIP_DELAY_H=[double]$row.SHIP_DELAY_H
                    ASYNC_BUFF_USED_MB=[double]$row.ASYNC_BUFF_USED_MB
                    MODE=$row.MODE
                    STATUS=$row.STATUS
                    STATUS_DETAILS=$row.STATUS_DETAILS
                    SEC_ACTIVE=$row.SEC_ACTIVE
				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)|Out-Null


#Replication_Bandwidth

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query39 CollectorType=Inventory - Category=Replication_Bandwith"	

$query="/* OMS -Query39 */ SELECT  SNAPSHOT_TIME,
  HOST,
  LPAD(TO_DECIMAL(PERSISTENCE_MB / 1024, 10, 2) , 14) PERSISTENCE_GB,
  LPAD(TO_DECIMAL(DATA_SIZE_MB / 1024, 10, 2), 12) DATA_SIZE_GB,
  LPAD(TO_DECIMAL(LOG_SIZE_MB / 1024, 10, 2), 11) LOG_SIZE_GB,
  LPAD(TO_DECIMAL(TOTAL_SIZE_MB / 1024, 10, 2), 13) TOTAL_SIZE_GB,
  LPAD(TO_DECIMAL(MAP(TOTAL_SIZE_MB, 0, 0, LOG_SIZE_MB / TOTAL_SIZE_MB * 100), 10, 2), 7) LOG_PCT,
  MAP(SECONDS, -1, 'n/a', LPAD(TO_DECIMAL(TOTAL_SIZE_MB / SECONDS * 8, 10, 2), 18)) AVG_BANDWIDTH_MBIT,
  LPAD(TO_DECIMAL(PERSISTENCE_MB / 86400 * 8, 10, 2), 21) SIMPLE_BANDWIDTH_MBIT
FROM
( SELECT
    CASE 
      WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
        CASE 
          WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
            TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 
            'YYYY/MM/DD HH24:MI:SS'), CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(I.SERVER_TIMESTAMP, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE I.SERVER_TIMESTAMP END) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
          ELSE TO_VARCHAR(CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(I.SERVER_TIMESTAMP, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE I.SERVER_TIMESTAMP END, BI.TIME_AGGREGATE_BY)
        END
      ELSE 'any' 
    END SNAPSHOT_TIME,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST') != 0 THEN I.HOST ELSE MAP(BI.HOST, '%', 'any', BI.HOST) END HOST,
    SUM(I.LOG_SIZE_MB) LOG_SIZE_MB,
    SUM(I.DATA_SIZE_MB) DATA_SIZE_MB,
    SUM(I.LOG_SIZE_MB + I.DATA_SIZE_MB) TOTAL_SIZE_MB,
    MAX(P.PERSISTENCE_MB) PERSISTENCE_MB,
    CASE 
      WHEN BI.TIME_AGGREGATE_BY = 'YYYY/MM/DD HH24' THEN 3600
      WHEN BI.TIME_AGGREGATE_BY = 'YYYY/MM/DD (DY)' THEN 86400
      WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN SUBSTR(BI.TIME_AGGREGATE_BY, 3)
      ELSE -1
    END SECONDS
  FROM
  ( SELECT
      BEGIN_TIME,
      END_TIME,
      TIMEZONE,
      HOST,
      AGGREGATE_BY,
      MAP(TIME_AGGREGATE_BY,
        'NONE',        'YYYY/MM/DD HH24:MI:SS',
        'HOUR',        'YYYY/MM/DD HH24',
        'DAY',         'YYYY/MM/DD (DY)',
        'HOUR_OF_DAY', 'HH24',
        TIME_AGGREGATE_BY ) TIME_AGGREGATE_BY
    FROM
    ( SELECT                                 /* Modification section */
        /*TO_TIMESTAMP('1000/01/01 18:00:00', 'YYYY/MM/DD HH24:MI:SS') BEGIN_TIME,  */
        add_seconds('"+$currentruntime+"',-$timespan) BEGIN_TIME,
        TO_TIMESTAMP('9999/12/31 18:10:00', 'YYYY/MM/DD HH24:MI:SS') END_TIME,
        'SERVER,UTC' TIMEZONE,                              /* SERVER, UTC */
        '%' HOST,
        'TIME,HOST' AGGREGATE_BY,         /* TIME, HOST and comma separated combinations or NONE for no aggregation */
        'TS300' TIME_AGGREGATE_BY     /* HOUR, DAY, HOUR_OF_DAY or database time pattern, TS<seconds> for time slice, NONE for no aggregation */
      FROM
        DUMMY
    )
  ) BI,
  ( SELECT 
      C.SYS_START_TIME SERVER_TIMESTAMP,
      CF.HOST,
      CF.BACKUP_SIZE / 1024 / 1024 LOG_SIZE_MB,
      0 DATA_SIZE_MB
    FROM
      M_BACKUP_CATALOG C,
      M_BACKUP_CATALOG_FILES CF
    WHERE
      C.ENTRY_ID = CF.ENTRY_ID AND
      C.ENTRY_TYPE_NAME = 'log backup' AND
      CF.SOURCE_ID > 0 
    UNION ALL
    ( SELECT
        SERVER_TIMESTAMP,
        HOST,
        LOG_SIZE_MB,
        DATA_SIZE_MB
      FROM
      ( SELECT
          SERVER_TIMESTAMP,
          HOST,
          LOG_SIZE_MB,
          DATA_SIZE_MB - LEAD(DATA_SIZE_MB, 1) OVER (PARTITION BY HOST ORDER BY SERVER_TIMESTAMP DESC) DATA_SIZE_MB
        FROM
        ( SELECT
            SERVER_TIMESTAMP SERVER_TIMESTAMP,
            HOST,
            0 LOG_SIZE_MB,
            SUM(TOTAL_WRITE_SIZE) / 1024 / 1024  DATA_SIZE_MB
          FROM
            _SYS_STATISTICS.HOST_VOLUME_IO_TOTAL_STATISTICS
          WHERE
            TYPE = 'DATA'
          GROUP BY
            SERVER_TIMESTAMP,
            HOST
        )
      )
      WHERE
        DATA_SIZE_MB > 0
    )
  ) I,
  ( SELECT
      HOST,
      SUM(USED_BLOCK_COUNT * PAGE_SIZE) / 1024 / 1024 PERSISTENCE_MB
    FROM
      M_DATA_VOLUME_PAGE_STATISTICS
    GROUP BY
      HOST
  ) P
  WHERE
    I.HOST LIKE BI.HOST AND
    CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(I.SERVER_TIMESTAMP, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE I.SERVER_TIMESTAMP END BETWEEN BI.BEGIN_TIME AND BI.END_TIME AND
    I.HOST = P.HOST
  GROUP BY
    CASE 
      WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
        CASE 
          WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
            TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 
            'YYYY/MM/DD HH24:MI:SS'), CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(I.SERVER_TIMESTAMP, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE I.SERVER_TIMESTAMP END) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
          ELSE TO_VARCHAR(CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(I.SERVER_TIMESTAMP, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE I.SERVER_TIMESTAMP END, BI.TIME_AGGREGATE_BY)
        END
      ELSE 'any' 
    END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST') != 0 THEN I.HOST ELSE MAP(BI.HOST, '%', 'any', BI.HOST) END,
    BI.TIME_AGGREGATE_BY
)
WHERE
  DATA_SIZE_MB > 0 AND
  LOG_SIZE_MB > 0
ORDER BY
  SNAPSHOT_TIME DESC,
  HOST
"

			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query39"
                write-warning  $ex 
			}

		 

		  $Resultsperf=$null
		  [System.Collections.ArrayList]$Resultsperf=@(); 

		  IF ($ds.tables[0].rows)
		  {
			  Foreach($row in $ds.tables[0].rows)
			  {
				  $Resultsperf.Add([PSCustomObject]@{
					  HOST=$SAPHOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ReplicationBandwidth"
                      SYS_TIMESTAMP=$row.SNAPSHOT_TIME 
					  PerfCounter='PERSISTENCE_GB'
					  PerfValue=[double]$row.PERSISTENCE_GB
					  PerfInstance=$hanadb
		    		  })|Out-Null

                        $Resultsperf.Add([PSCustomObject]@{
					  HOST=$SAPHOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ReplicationBandwidth"
                      SYS_TIMESTAMP=$row.SNAPSHOT_TIME 
					  PerfCounter='DATA_SIZE_GB'
					  PerfValue=[double]$row.DATA_SIZE_GB
					  PerfInstance=$hanadb
		    		  })|Out-Null

                        $Resultsperf.Add([PSCustomObject]@{
					  HOST=$SAPHOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ReplicationBandwidth"
                      SYS_TIMESTAMP=$row.SNAPSHOT_TIME 
					  PerfCounter='LOG_SIZE_GB'
					  PerfValue=[double]$row.LOG_SIZE_GB
					  PerfInstance=$hanadb
		    		  })|Out-Null

                        $Resultsperf.Add([PSCustomObject]@{
					  HOST=$SAPHOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ReplicationBandwidth"
                      SYS_TIMESTAMP=$row.SNAPSHOT_TIME 
					  PerfCounter='TOTAL_SIZE_GB'
					  PerfValue=[double]$row.TOTAL_SIZE_GB 
					  PerfInstance=$hanadb
		    		  })|Out-Null

                        $Resultsperf.Add([PSCustomObject]@{
					  HOST=$SAPHOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ReplicationBandwidth"
                      SYS_TIMESTAMP=$row.SNAPSHOT_TIME 
					  PerfCounter='LOG_PCT'
					  PerfValue=[double]$row.LOG_PCT
					  PerfInstance=$hanadb
		    		  })|Out-Null

                        $Resultsperf.Add([PSCustomObject]@{
					  HOST=$SAPHOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ReplicationBandwidth"
                      SYS_TIMESTAMP=$row.SNAPSHOT_TIME 
					  PerfCounter='AVG_BANDWIDTH_MBIT'
					  PerfValue=[double]$row.AVG_BANDWIDTH_MBIT
					  PerfInstance=$hanadb
		    		  })|Out-Null

                        $Resultsperf.Add([PSCustomObject]@{
					  HOST=$SAPHOST
					  Instance=$sapinstance
					  CollectorType="Performance"
					  PerfObject="ReplicationBandwidth"
                      SYS_TIMESTAMP=$row.SNAPSHOT_TIME 
					  PerfCounter='SIMPLE_BANDWIDTH_MBIT'
					  PerfValue=[double]$row.SIMPLE_BANDWIDTH_MBIT
					  PerfInstance=$hanadb
		    		  })|Out-Null
					  
				  }
				  $Omsperfupload.Add($Resultsperf)|Out-Null
					
		  }


# Table Locations
Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query40 CollectorType=Inventory - Category=TableLocations"	

$query="/* OMS -Query40 */SELECT HOST,
  PORT,
  SERVICE_NAME SERVICE,
  SCHEMA_NAME,
  TABLE_NAME,
  LOCATION,
  LPAD(NUM, 6) NUM
FROM
( SELECT
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST')     != 0 THEN TL.HOST          ELSE MAP(BI.HOST,        '%', 'any', BI.HOST)          END HOST,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'PORT')     != 0 THEN TO_VARCHAR(TL.PORT) ELSE MAP(BI.PORT,        '%', 'any', BI.PORT)          END PORT,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SERVICE')  != 0 THEN S.SERVICE_NAME   ELSE MAP(BI.SERVICE_NAME, '%', 'any', BI.SERVICE_NAME) END SERVICE_NAME,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SCHEMA')   != 0 THEN TL.SCHEMA_NAME   ELSE MAP(BI.SCHEMA_NAME, '%', 'any', BI.SCHEMA_NAME)   END SCHEMA_NAME,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TABLE')    != 0 THEN TL.TABLE_NAME || MAP(TL.PART_ID, 0, '', CHAR(32) || '(' || TL.PART_ID || ')') 
                                                                                                        ELSE MAP(BI.TABLE_NAME,  '%', 'any', BI.TABLE_NAME)    END TABLE_NAME,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'LOCATION') != 0 THEN TL.LOCATION      ELSE MAP(BI.LOCATION,    '%', 'any', BI.LOCATION)      END LOCATION,
    COUNT(*) NUM
  FROM
  ( SELECT                /* Modification section */
      '%' HOST,
      '%' PORT,
      '%' SERVICE_NAME,
      '%' SCHEMA_NAME,
      '%' TABLE_NAME,
      '%' LOCATION,
      'HOST, PORT, SERVICE, SCHEMA, LOCATION' AGGREGATE_BY            /* HOST, PORT, SERVICE, SCHEMA, TABLE, LOCATION or comma separated combinations, NONE for no aggregation */
    FROM
      DUMMY
  ) BI,
    M_SERVICES S,
    M_TABLE_LOCATIONS TL
  WHERE
    S.HOST LIKE BI.HOST AND
    TO_VARCHAR(S.PORT) LIKE BI.PORT AND
    S.SERVICE_NAME LIKE BI.SERVICE_NAME AND
    TL.HOST = S.HOST AND
    TL.PORT = S.PORT AND
    TL.SCHEMA_NAME LIKE BI.SCHEMA_NAME AND
    TL.TABLE_NAME LIKE BI.TABLE_NAME AND
    TL.LOCATION LIKE BI.LOCATION
  GROUP BY
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST')     != 0 THEN TL.HOST          ELSE MAP(BI.HOST,        '%', 'any', BI.HOST)          END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'PORT')     != 0 THEN TO_VARCHAR(TL.PORT) ELSE MAP(BI.PORT,        '%', 'any', BI.PORT)          END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SERVICE')  != 0 THEN S.SERVICE_NAME   ELSE MAP(BI.SERVICE_NAME, '%', 'any', BI.SERVICE_NAME) END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SCHEMA')   != 0 THEN TL.SCHEMA_NAME   ELSE MAP(BI.SCHEMA_NAME, '%', 'any', BI.SCHEMA_NAME)   END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TABLE')    != 0 THEN TL.TABLE_NAME || MAP(TL.PART_ID, 0, '', CHAR(32) || '(' || TL.PART_ID || ')') 
                                                                                                        ELSE MAP(BI.TABLE_NAME,  '%', 'any', BI.TABLE_NAME)    END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'LOCATION') != 0 THEN TL.LOCATION      ELSE MAP(BI.LOCATION,    '%', 'any', BI.LOCATION)      END
)
ORDER BY
  HOST,
  PORT,
  SCHEMA_NAME,
  TABLE_NAME,
  LOCATION
"

	$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query40"
                write-warning  $ex 
			}

       
            $Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 



	

			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.Add([PSCustomObject]@{
					HOST=$row.HOST
					Instance=$sapinstance
                    Database=$hanadb
					CollectorType="Inventory"
					Category="TableLocations"
                    PORT=$row.PORT 
                    SERVICE=$row.SERVICE 
                    SCHEMA_NAME=$row.SCHEMA_NAME
                    TABLE_NAME=$row.TABLE_NAME
                    LOCATION=$row.LOCATION
                    NUM=[int]$row.NUM
				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)|Out-Null


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query41 CollectorType=Inventory - Category=Locks"	


            $query="/* OMS -Query41 */SELECT SNAPSHOT_TIME,
  LPAD(TO_DECIMAL(ROUND(WAIT_S), 10, 0), 7) WAIT_S,
  SCHEMA_NAME SCHEMA,
  TABLE_NAME,
  LOCK_TYPE,
  LOCK_MODE,
  FINAL_BLOCKING_SESSION,
  ACTIVE,
  LPAD(IFNULL(WAIT_CONN, ''), 9) WAIT_CONN,
  LPAD(WAIT_UTID, 11) WAIT_UTID,
  IFNULL(WAIT_STATEMENT_HASH, '') WAIT_STATEMENT_HASH,
  LPAD(BLK_CONN, 9) BLK_CONN,
  LPAD(BLK_UTID, 11) BLK_UTID,
  CLIENT_HOST || CHAR(32) || '/' || CHAR(32) || CLIENT_PID BLK_CLIENT_HOST_PID,
  IFNULL(BLK_APP_SOURCE, '') BLK_APP_SOURCE,
  IFNULL(BLK_STATEMENT_HASH, '') BLK_STATEMENT_HASH,
  HOST,
  LPAD(PORT, 5) PORT,
  RECORD_ID RECORD_ID,
  LPAD(COUNT, 5) COUNT
FROM
( SELECT
    CASE 
      WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
        CASE 
          WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
            TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 
            'YYYY/MM/DD HH24:MI:SS'), CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(BT.END_TIMESTAMP, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE BT.END_TIMESTAMP END) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
          ELSE TO_VARCHAR(CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(BT.END_TIMESTAMP, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE BT.END_TIMESTAMP END, BI.TIME_AGGREGATE_BY)
        END
      ELSE 'any' 
    END SNAPSHOT_TIME,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST')       != 0 THEN BT.HOST                                         ELSE MAP(BI.HOST,        '%', 'any', BI.HOST)                                END HOST,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'PORT')       != 0 THEN TO_VARCHAR(BT.PORT)                             ELSE MAP(BI.PORT,        '%', 'any', BI.PORT)                                END PORT,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SCHEMA')     != 0 THEN BT.SCHEMA_NAME                                  ELSE MAP(BI.SCHEMA_NAME, '%', 'any', BI.SCHEMA_NAME)                         END SCHEMA_NAME,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TABLE')      != 0 THEN BT.TABLE_NAME                                   ELSE MAP(BI.TABLE_NAME,  '%', 'any', BI.TABLE_NAME)                          END TABLE_NAME,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TYPE')       != 0 THEN BT.LOCK_TYPE                                    ELSE MAP(BI.LOCK_TYPE,   '%', 'any', BI.LOCK_TYPE)                           END LOCK_TYPE,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'MODE')       != 0 THEN BT.LOCK_MODE                                    ELSE MAP(BI.LOCK_MODE,   '%', 'any', BI.LOCK_MODE)                           END LOCK_MODE,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'WAIT_CONN')  != 0 THEN TO_VARCHAR(BT.BLOCKED_CONNECTION_ID)            ELSE 'any'                                                                   END WAIT_CONN,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'WAIT_UTID')  != 0 THEN TO_VARCHAR(BT.BLOCKED_UPDATE_TRANSACTION_ID)    ELSE 'any'                                                                   END WAIT_UTID,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'WAIT_HASH')  != 0 THEN BT.BLOCKED_STATEMENT_HASH                       ELSE MAP(BI.BLOCKED_STATEMENT_HASH, '%', 'any', BI.BLOCKED_STATEMENT_HASH)   END WAIT_STATEMENT_HASH,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BLK_CONN')   != 0 THEN TO_VARCHAR(BT.LOCK_OWNER_CONNECTION_ID)         ELSE 'any'                                                                   END BLK_CONN,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BLK_UTID')   != 0 THEN TO_VARCHAR(BT.LOCK_OWNER_UPDATE_TRANSACTION_ID) ELSE 'any'                                                                   END BLK_UTID,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BLK_HASH')   != 0 THEN BT.LOCK_OWNER_STATEMENT_HASH                    ELSE MAP(BI.BLOCKING_STATEMENT_HASH, '%', 'any', BI.BLOCKING_STATEMENT_HASH) END BLK_STATEMENT_HASH,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BLK_PID')    != 0 THEN TO_VARCHAR(BT.LOCK_OWNER_CLIENT_PID)            ELSE 'any'                                                                   END CLIENT_PID,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BLK_HOST')   != 0 THEN TO_VARCHAR(BT.LOCK_OWNER_CLIENT_HOST)           ELSE 'any'                                                                   END CLIENT_HOST,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'RECORD_ID')  != 0 THEN BT.WAITING_RECORD_ID                            ELSE MAP(BI.RECORD_ID, '%', 'any', BI.RECORD_ID)                             END RECORD_ID,
    MAP(MIN(BT.LOCK_OWNER_APPLICATION_SOURCE), MAX(BT.LOCK_OWNER_APPLICATION_SOURCE), MIN(BT.LOCK_OWNER_APPLICATION_SOURCE), 'any') BLK_APP_SOURCE,
    MAP(MIN(BT.FINAL_BLOCKING_SESSION), MAX(BT.FINAL_BLOCKING_SESSION), MIN(BT.FINAL_BLOCKING_SESSION), 'any') FINAL_BLOCKING_SESSION,
    MAP(MIN(BT.ACTIVE), MAX(BT.ACTIVE), MIN(BT.ACTIVE), 'any') ACTIVE,
    COUNT(*) COUNT,
    AVG(NANO100_BETWEEN(BT.START_TIMESTAMP, BT.END_TIMESTAMP) / 10000000) WAIT_S,
    BI.ORDER_BY
  FROM
  ( SELECT
      BEGIN_TIME,
      END_TIME,
      TIMEZONE,
      HOST,
      PORT,
      SCHEMA_NAME,
      TABLE_NAME,
      LOCK_TYPE,
      LOCK_MODE,
      BLOCKED_STATEMENT_HASH,
      BLOCKING_CONN_ID,
      BLOCKING_STATEMENT_HASH,
      RECORD_ID,
      MIN_WAIT_TIME_S,
      DATA_SOURCE,
      AGGREGATE_BY,
      MAP(TIME_AGGREGATE_BY,
        'NONE',        'YYYY/MM/DD HH24:MI:SS.FF3',
        'HOUR',        'YYYY/MM/DD HH24',
        'DAY',         'YYYY/MM/DD (DY)',
        'HOUR_OF_DAY', 'HH24',
        TIME_AGGREGATE_BY ) TIME_AGGREGATE_BY,
      ORDER_BY
    FROM
    ( SELECT                            /* Modification section */
       -- TO_TIMESTAMP('2019/02/18 05:15:00', 'YYYY/MM/DD HH24:MI:SS') BEGIN_TIME,
        --TO_TIMESTAMP('2019/02/18 09:20:00', 'YYYY/MM/DD HH24:MI:SS') END_TIME,
            add_seconds('"+$currentruntime+"',(-900-$utcdiff)) BEGIN_TIME ,
          TO_TIMESTAMP('9999/02/18 09:20:00', 'YYYY/MM/DD HH24:MI:SS') END_TIME, 
        'UTC' TIMEZONE,                              /* SERVER, UTC */
        '%' HOST,
        '%' PORT,
        '%' SCHEMA_NAME,
        '%' TABLE_NAME,
        '%' LOCK_TYPE,                /* RECORD_LOCK, TABLE_LOCK, OBJECT_LOCK, METADATA_LOCK */
        '%' LOCK_MODE,                /* SHARED, EXCLUSIVE, INTENTIONAL EXCLUSIVE */
        '%' BLOCKED_STATEMENT_HASH,
        -1 BLOCKING_CONN_ID,
        '%' BLOCKING_STATEMENT_HASH,
        '%' RECORD_ID,
         5 MIN_WAIT_TIME_S,
        'HISTORY' DATA_SOURCE,
        'NONE' AGGREGATE_BY,          /* TIME, SCHEMA, TABLE, TYPE, MODE, WAIT_CONN, WAIT_UTID, WAIT_HASH, BLK_CONN, BLK_UTID, BLK_PID, BLK_SOURCE, BLK_HASH, HOST, PORT, RECORD_ID or
                                         comma separated values, NONE for no aggregation */
        'NONE' TIME_AGGREGATE_BY,     /* HOUR, DAY, HOUR_OF_DAY or database time pattern, TS<seconds> for time slice, NONE for no aggregation */
        'TIME' ORDER_BY               /* TIME, COUNT, TABLE */
      FROM
        DUMMY
    )
  ) BI,
  ( SELECT
      'CURRENT' DATA_SOURCE,
      CURRENT_TIMESTAMP END_TIMESTAMP,
      BT.HOST,
      BT.PORT,
      BT.LOCK_TYPE,
      BT.LOCK_MODE,
      BT.WAITING_SCHEMA_NAME SCHEMA_NAME,
      BT.WAITING_OBJECT_NAME TABLE_NAME,
      BT.WAITING_RECORD_ID,
      BT.BLOCKED_TIME START_TIMESTAMP,
      BT.BLOCKED_CONNECTION_ID,
      BT.BLOCKED_UPDATE_TRANSACTION_ID,
      IFNULL(( SELECT MAX(TH.STATEMENT_HASH) FROM M_SERVICE_THREADS TH WHERE TH.UPDATE_TRANSACTION_ID = BT.BLOCKED_UPDATE_TRANSACTION_ID ), '') BLOCKED_STATEMENT_HASH,
      BT.LOCK_OWNER_CONNECTION_ID,
      BT.LOCK_OWNER_UPDATE_TRANSACTION_ID,
      C.CLIENT_HOST LOCK_OWNER_CLIENT_HOST,
      C.CLIENT_PID LOCK_OWNER_CLIENT_PID,
      SC.VALUE LOCK_OWNER_APPLICATION_SOURCE,
      IFNULL(( SELECT MAX(TH.STATEMENT_HASH) FROM M_SERVICE_THREADS TH WHERE TH.UPDATE_TRANSACTION_ID = BT.LOCK_OWNER_UPDATE_TRANSACTION_ID ), '') LOCK_OWNER_STATEMENT_HASH,
      CASE ( SELECT COUNT(*) WAITERS FROM M_BLOCKED_TRANSACTIONS BT2 WHERE BT2.BLOCKED_UPDATE_TRANSACTION_ID = BT.LOCK_OWNER_UPDATE_TRANSACTION_ID ) WHEN 0 THEN 'X' ELSE ' ' END FINAL_BLOCKING_SESSION,
      CASE ( SELECT COUNT(*) FROM M_SERVICE_THREADS TH WHERE TH.UPDATE_TRANSACTION_ID = BT.LOCK_OWNER_UPDATE_TRANSACTION_ID ) WHEN 0 THEN ' ' ELSE 'X' END ACTIVE
    FROM
      M_BLOCKED_TRANSACTIONS BT,
      M_CONNECTIONS C,
      M_TRANSACTIONS T LEFT OUTER JOIN
      M_SESSION_CONTEXT SC ON
        SC.HOST = T.HOST AND
        SC.PORT = T.PORT AND
        SC.CONNECTION_ID = T.CONNECTION_ID AND
        SC.KEY = 'APPLICATIONSOURCE'
    WHERE
      T.UPDATE_TRANSACTION_ID = BT.LOCK_OWNER_UPDATE_TRANSACTION_ID AND
      C.HOST = T.HOST AND
      C.PORT = T.PORT AND
      C.CONNECTION_ID = T.CONNECTION_ID
    UNION ALL
    SELECT
      'HISTORY' DATA_SOURCE,
      BT.SERVER_TIMESTAMP END_TIMESTAMP,
      BT.HOST,
      BT.PORT,
      BT.LOCK_TYPE,
      BT.LOCK_MODE,
      BT.WAITING_SCHEMA_NAME SCHEMA_NAME,
      BT.WAITING_OBJECT_NAME TABLE_NAME,
      BT.WAITING_RECORD_ID,
      BT.BLOCKED_TIME START_TIMESTAMP,
      BT.BLOCKED_CONNECTION_ID,
      BT.BLOCKED_UPDATE_TRANSACTION_ID,
      BT.BLOCKED_STATEMENT_HASH,
      BT.LOCK_OWNER_CONNECTION_ID,
      BT.LOCK_OWNER_UPDATE_TRANSACTION_ID,
      BT.LOCK_OWNER_HOST LOCK_OWNER_CLIENT_HOST,
      BT.LOCK_OWNER_PID LOCK_OWNER_CLIENT_PID,
      BT.LOCK_OWNER_APPLICATION_SOURCE,
      BT.LOCK_OWNER_STATEMENT_HASH,
      CASE ( SELECT COUNT(*) WAITERS FROM _SYS_STATISTICS.HOST_BLOCKED_TRANSACTIONS BT2 WHERE BT2.SNAPSHOT_ID = BT.SNAPSHOT_ID AND BT2.BLOCKED_UPDATE_TRANSACTION_ID = BT.LOCK_OWNER_UPDATE_TRANSACTION_ID ) WHEN 0 THEN 'X' ELSE ' ' END FINAL_BLOCKING_SESSION,
      '' ACTIVE
    FROM
      _SYS_STATISTICS.HOST_BLOCKED_TRANSACTIONS BT
  ) BT
  WHERE
    ( BI.DATA_SOURCE = 'CURRENT' OR 
      CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(BT.START_TIMESTAMP, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE BT.START_TIMESTAMP END BETWEEN BI.BEGIN_TIME AND BI.END_TIME OR 
      CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(BT.END_TIMESTAMP, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE BT.END_TIMESTAMP END BETWEEN BI.BEGIN_TIME AND BI.END_TIME ) AND
    BT.HOST LIKE BI.HOST AND
    TO_VARCHAR(BT.PORT) LIKE BI.PORT AND
    IFNULL(BT.SCHEMA_NAME, '') LIKE BI.SCHEMA_NAME AND
    IFNULL(BT.TABLE_NAME, '') LIKE BI.TABLE_NAME AND
    IFNULL(BT.LOCK_TYPE, '') LIKE BI.LOCK_TYPE AND
    IFNULL(BT.LOCK_MODE, '') LIKE BI.LOCK_MODE AND
    IFNULL(BT.BLOCKED_STATEMENT_HASH, '') LIKE BI.BLOCKED_STATEMENT_HASH AND
    ( BI.BLOCKING_CONN_ID = -1 OR BT.LOCK_OWNER_CONNECTION_ID = BI.BLOCKING_CONN_ID ) AND
    IFNULL(BT.LOCK_OWNER_STATEMENT_HASH, '') LIKE BI.BLOCKING_STATEMENT_HASH AND
    IFNULL(BT.WAITING_RECORD_ID, '') LIKE BI.RECORD_ID AND
    ( BI.MIN_WAIT_TIME_S = -1 OR SECONDS_BETWEEN(BT.START_TIMESTAMP, BT.END_TIMESTAMP) >= BI.MIN_WAIT_TIME_S ) AND
    BI.DATA_SOURCE = BT.DATA_SOURCE
  GROUP BY
    CASE 
      WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TIME') != 0 THEN 
        CASE 
          WHEN BI.TIME_AGGREGATE_BY LIKE 'TS%' THEN
            TO_VARCHAR(ADD_SECONDS(TO_TIMESTAMP('2014/01/01 00:00:00', 'YYYY/MM/DD HH24:MI:SS'), FLOOR(SECONDS_BETWEEN(TO_TIMESTAMP('2014/01/01 00:00:00', 
            'YYYY/MM/DD HH24:MI:SS'), CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(BT.END_TIMESTAMP, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE BT.END_TIMESTAMP END) / SUBSTR(BI.TIME_AGGREGATE_BY, 3)) * SUBSTR(BI.TIME_AGGREGATE_BY, 3)), 'YYYY/MM/DD HH24:MI:SS')
          ELSE TO_VARCHAR(CASE BI.TIMEZONE WHEN 'UTC' THEN ADD_SECONDS(BT.END_TIMESTAMP, SECONDS_BETWEEN(CURRENT_TIMESTAMP, CURRENT_UTCTIMESTAMP)) ELSE BT.END_TIMESTAMP END, BI.TIME_AGGREGATE_BY)
        END
      ELSE 'any' 
    END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'HOST')       != 0 THEN BT.HOST                                         ELSE MAP(BI.HOST,        '%', 'any', BI.HOST)                                END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'PORT')       != 0 THEN TO_VARCHAR(BT.PORT)                             ELSE MAP(BI.PORT,        '%', 'any', BI.PORT)                                END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'SCHEMA')     != 0 THEN BT.SCHEMA_NAME                                  ELSE MAP(BI.SCHEMA_NAME, '%', 'any', BI.SCHEMA_NAME)                         END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TABLE')      != 0 THEN BT.TABLE_NAME                                   ELSE MAP(BI.TABLE_NAME,  '%', 'any', BI.TABLE_NAME)                          END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'TYPE')       != 0 THEN BT.LOCK_TYPE                                    ELSE MAP(BI.LOCK_TYPE,   '%', 'any', BI.LOCK_TYPE)                           END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'MODE')       != 0 THEN BT.LOCK_MODE                                    ELSE MAP(BI.LOCK_MODE,   '%', 'any', BI.LOCK_MODE)                           END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'WAIT_CONN')  != 0 THEN TO_VARCHAR(BT.BLOCKED_CONNECTION_ID)            ELSE 'any'                                                                   END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'WAIT_UTID')  != 0 THEN TO_VARCHAR(BT.BLOCKED_UPDATE_TRANSACTION_ID)    ELSE 'any'                                                                   END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'WAIT_HASH')  != 0 THEN BT.BLOCKED_STATEMENT_HASH                       ELSE MAP(BI.BLOCKED_STATEMENT_HASH, '%', 'any', BI.BLOCKED_STATEMENT_HASH)   END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BLK_CONN')   != 0 THEN TO_VARCHAR(BT.LOCK_OWNER_CONNECTION_ID)         ELSE 'any'                                                                   END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BLK_UTID')   != 0 THEN TO_VARCHAR(BT.LOCK_OWNER_UPDATE_TRANSACTION_ID) ELSE 'any'                                                                   END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BLK_HASH')   != 0 THEN BT.LOCK_OWNER_STATEMENT_HASH                    ELSE MAP(BI.BLOCKING_STATEMENT_HASH, '%', 'any', BI.BLOCKING_STATEMENT_HASH) END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BLK_PID')    != 0 THEN TO_VARCHAR(BT.LOCK_OWNER_CLIENT_PID)            ELSE 'any'                                                                   END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'BLK_HOST')   != 0 THEN TO_VARCHAR(BT.LOCK_OWNER_CLIENT_HOST)           ELSE 'any'                                                                   END,
    CASE WHEN BI.AGGREGATE_BY = 'NONE' OR INSTR(BI.AGGREGATE_BY, 'RECORD_ID')  != 0 THEN BT.WAITING_RECORD_ID                            ELSE MAP(BI.RECORD_ID, '%', 'any', BI.RECORD_ID)                             END,
    BI.ORDER_BY
)
ORDER BY
 MAP(ORDER_BY, 'TIME', SNAPSHOT_TIME) DESC,
  MAP(ORDER_BY, 'COUNT', COUNT) DESC,
  SCHEMA_NAME,
  TABLE_NAME"

            $cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query43 - Locking Threads"
                write-warning  $ex 
			}

       
            $Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 



	

			foreach ($row in $ds.Tables[0].rows)
			{
				$resultsinv.Add([PSCustomObject]@{
					HOST=$row.HOST
                    PORT=$row.PORT
					Instance=$sapinstance
                    Database=$hanadb
					CollectorType="Inventory"
					Category="Locks"
                    WAITS=[int]$row.WAIT_S
                    SCHEMA=$row.SCHEMA
                    TABLE_NAME=$row.TABLE_NAME
                     LOCK_TYPE=$row.LOCK_TYPE
                     LOCK_MODE=$row.LOCK_MODE
                     FINAL_BLOCKING_SESSION=$row.FINAL_BLOCKING_SESSION
                    ACTIVE=$row.ACTIVE
                    WAIT_CONN=$row.WAIT_CONN
                    WAIT_UTID=$row.WAIT_UTID
                    WAIT_STATEMENT_HASH=$row.WAIT_STATEMENT_HASH
                    BLK_CONN =$row.BLK_CONN 
                    BLK_UTID=$row.BLK_UTID
                    BLK_CLIENT_HOST_PID=$row.BLK_CLIENT_HOST_PID
                    BLK_APP_SOURCE=$row.BLK_APP_SOURCE 
                    BLK_STATEMENT_HASH=$row.BLK_STATEMENT_HASH
                    RECORD_ID=$row.RECORD_ID 
                    SYS_TIMESTAMP=$row.SNAPSHOT_TIME 
				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)|Out-Null


        
            Write-Output "Elapsed Time : $([math]::round($stopwatch.Elapsed.TotalSeconds,0))"



			$AzLAUploadsuccess=0
			$AzLAUploaderror=0
			

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
    }

    #endregion



#region SAP Mini Checks

IF($runmode -eq 'daily') 
{

        #hana checks and large table query moved to AzureSAPHanaConfigChecks-MS runbook 




}
 #endregion



            
            	$colend=get-date
            
            $cu=$null
			$cu=@([PSCustomObject]@{
				HOST=$saphost
				Database=$hanadb
				CollectorType="Performance"
				PerfObject="Colllector"
				PerfCounter="Duration_sec"
				PerfValue=($colend-$colstart).Totalseconds
				
			})

            $stopwatch.stop()

			$message="Collection Time : $([math]::round($stopwatch.Elapsed.TotalSeconds,0)) seconds , {0} inventory data, {1}  state data and {2} performance data will be uploaded to OMS Log Analytics " -f $Omsinvupload.count,$OmsStateupload.count,$OmsPerfupload.count
			write-output $message
            $jsonlogs=$null
			$dataitem=$null
	        $jsonlogs= ConvertTo-Json -InputObject $cu
			$post=$null; 
			$post=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
					



 			IF($AzLAUploadsuccess -gt 0)
			{
                if($lasttimestamp)
				{

					write-output " updating last run time to $currentruntime for $rbvariablename "
	
                    Set-AutomationVariable -Name $rbvariablename  -Value $currentruntime 

				}Else
				{
					
                    write-output "Creating last run time for   $rbvariablename with value $currentruntime "
                    New-AzureRmAutomationVariable -Name $rbvariablename  -Encrypted 0 -Description "last time collection run" -Value $currentruntime -ResourceGroupName $AAResourceGroup -AutomationAccountName $AAAccount -Verbose
                }
                      		

			}


			
			$conn.Close()



		}Else
		{

				#send connectivity failure event
			
		
		    write-warning "Uploading connection failed event for $saphost : $hanadb "
				
				$Cu=([PSCustomObject]@{
					HOST=$saphost
					 PORT=$sapport
					 Database=$hanadb
					CollectorType="State"
					Category="Connectivity"
					SubCategory="Host"
					Connection="Failed"
					ErrorMessage=$ex
					PingResult=$pingresult	
                    Latency=$ping				
				})
				$jsonlogs=$null
				

			   $jsonlogs= ConvertTo-Json -InputObject $cu
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
        $i++
      }Else
      {

        Write-output "$($rule.Database)  is not enabled for data collection in config file"
      }

	}


	$colend=Get-date
	write-output "Collected all data in  $(($colend-$colstart).Totalseconds)  seconds"
	
}


