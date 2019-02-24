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

#################
#
# add managed identity section
#
##################
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

     #Enable collection of config minicheck and table inventory at 4 AM 
    IF((get-date).Minute -in (0..14) -and (get-date).Hour -eq 4)
    {
        $runconfigchecks=$true
    }Else{

        $runconfigchecks=$false    
    }

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
			$Ex=$_.Exception.MEssage;write-warning $query
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
			$query="/* OMS */
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
						$Ex=$_.Exception.MEssage;write-warning $query
						write-warning  $ex 
					}
					
					$utcdiff=$ds.Tables[0].rows[0].TIMEZONE_OFFSET_S
                
    #region default collections
        If($runmode -eq 'default')
        {
	

            $query="/* OMS -Query2*/ SELECT   HOST,
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
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query2"
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
                    NOFILE_LIMIT=$row.NOFILE_LIMIT			
				})|Out-Null

			}

			$Omsinvupload.Add($Resultsinv)|Out-Null


			$sapinstance=$cu.sid+'-'+$cu.sapsystem
			$sapversion=$ds.Tables[0].rows[0].BUILD_VERSION  #use build versionto decide which query to run

			$cu=$null

			$query="/* OMS -Query3*/SELECT * from  SYS.M_SYSTEM_OVERVIEW"
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			
                        Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) -Query3 -CollectorType=Inventory , Category=HostStartup"  
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

			$query='/* OMS -Query4 */ Select * from SYS_Databases.M_Services'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
            Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) - Query4- CollectorType=Inventory , Category=Database"  
            $ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning write-warning "Failed to run Query4"
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


            
            $query="/* OMS -Query45*/ SELECT L.HOST,
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
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query45"
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




			$query='/* OMS */ Select * FROM SYS.M_DATABASE'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
            Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) CollectorType=Inventory , Category=Database"  
            
            $ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning $query
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
					Category="Database"
					SYSTEM_ID=$row.SYSTEM_ID
					Database=$row.DATABASE_NAME
					START_TIME=$row.START_TIME
					VERSION=$row.VERSION
					USAGE=$row.USAGE

				})|Out-Null
			}

			$Omsinvupload.Add($Resultsinv)|Out-Null

			$query="/* OMS */SELECT * FROM SYS.M_SERVICES"
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
			$ex=$null
            Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning $query
			}
			 
			$Resultsinv=$null
			[System.Collections.ArrayList]$Resultsinv=@(); 

			Write-Output 'CollectorType="Inventory" -   Category="Services"'

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



  			Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) CollectorType=Performance - Category=Host - Subcategory=OverallUsage"  
			$query="/* OMS */SELECT * from SYS.M_HOST_RESOURCE_UTILIZATION"
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
        Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) CollectorType=Inventory - Category=BAckupCatalog"  

			$query="/* OMS */SELECT * FROM SYS.M_BACKUP_CATALOG where SYS_START_TIME    > add_seconds('"+$currentruntime+"',-$timespan)"
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) CollectorType=Inventory - Category=BAckupSize"  

			$query='/* OMS */ Select * FROM SYS.M_BACKUP_SIZE_ESTIMATIONS'
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


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) CollectorType=Inventory - Category=Volumes"  

			$query='/* OMS */ Select * FROM SYS.M_DATA_VOLUMES'
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) CollectorType=Inventory - Category=Disks"  

			$query='/* OMS */ Select * FROM SYS.M_DISKS'
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) CollectorType=PErformance - Category=DiskUsage"  
			$query='/* OMS */ Select * FROM SYS.M_DISK_USAGE'
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) CollectorType=Inventory - Category=License"  

			$query="/* OMS */SELECT * FROM SYS.M_LICENSE"
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


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) CollectorType=Inventory - Category=Tables"  
			$query='/* OMS */ Select Host,Port,Loaded,TABLE_NAME,RECORD_COUNT,RAW_RECORD_COUNT_IN_DELTA,MEMORY_SIZE_IN_TOTAL,MEMORY_SIZE_IN_MAIN,MEMORY_SIZE_IN_DELTA 
from M_CS_TABLES'

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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) CollectorType=Inventory - Category=Alerts"  
			$query='/* OMS */ Select * from _SYS_STATISTICS.Statistics_Current_Alerts'
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query5 CollectorType=PErformance - Category=Host Subcategory=OverallUsage"  
			$query='/* OMS Query5*/ Select * from SYS.M_Service_statistics'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query5"
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
Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query6  CollectorType=Performance - Category=Host - CPU"

			$query="/* OMS -Query6*/SELECT SAMPLE_TIME,HOST,
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
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query6"
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
Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query7 CollectorType=PErformance - Category=Service - Metrics CPU, Connections,Threads"

			$query="/* OMS -Query7*/Select SAMPLE_TIME ,
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
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query7"
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query8 CollectorType=PErformance - Category=Memory  Subcategory=OverallUsage"


			$query="/* OMS -Query8*/SELECT * FROM SYS.M_MEMORY INNER JOIN SYS.M_Services on SYS.M_MEMORY.Port=SYS.M_Services.port Where SERVICE_NAME='indexserver'" 
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
        $ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query8"
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query9 CollectorType=PErformance - Category=Memory  Subcategory=Service"

			$query="/* OMS -Query9 */SELECT * FROM SYS.M_SERVICE_MEMORY"
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query10 CollectorType=PErformance - Category=Service Metrics"

			$query="/* OMS -Query10*/SELECT  HOST , PORT , to_varchar(time, 'YYYY-MM-DD HH24:MI') as TIME, ROUND(AVG(CPU),0)as PROCESS_CPU , ROUND(AVG(SYSTEM_CPU),0) as SYSTEM_CPU , 
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
                write-warning  $ex ;write-warning "Failed to run Query10"
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss'))  Query11 CollectorType=PErformance - Category=Host  Subcategory=Memory"

			$query="/* OMS - Query11 */SELECT  HOST,to_varchar(time, 'YYYY-MM-DD HH24:MI') as TIME, ROUND(AVG(CPU),0)as CPU_Total ,
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
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query11"
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss'))  Query12 CollectorType=PErformance - Category=Table  Subcategory=MemUsage"


			$query='/* OMS -Query12*/ Select Schema_name,round(sum(Memory_size_in_total)/1024/1024) as "ColunmTablesMBUSed" from M_CS_TABLES group by Schema_name'
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query13 CollectorType=PErformance - Category=Memory  Subcategory=Component"

			$query='/* OMS -Query13 */ Select  host,component, sum(Used_memory_size) USed_MEmory_size from public.m_service_component_memory group by host, component'
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
$ex=$null
			Try{
				$cmd.fill($ds)
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query13"
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


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query14 CollectorType=PErformance - Category=Memory  Used, Resident,PEak"


			$query='/* OMS -Query14 */ Select t1.host,round(sum(t1.Total_memory_used_size/1024/1024/1024),1) as "UsedMemoryGB",round(sum(t1.physical_memory_size/1024/1024/1024),2) "DatabaseResident" ,SUM(T2.Peak) as PeakGB from m_service_memory  as T1 
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
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query14"
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query15 CollectorType=PErformance - Category=Compression  "
			$query='/* OMS -Query15  */ Select  host,schema_name ,sum(DISTINCT_COUNT) RECORD_COUNT,
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
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query15"
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


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query16 CollectorType=PErformance - Category=Volumes Subcategory=IOStat"
			#volume IO Latency and  throughput
					$query="/* OMS -Query16*/select host, port ,type,
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
					   $Ex=$_.Exception.MEssage;write-warning "Failed to run Query16"
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query17 CollectorType=PErformance - Category=Volumes Subcategory=Throughput"

				$query="/* OMS -Query17*/select v.host, v.port, v.service_name, s.type,
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
							   $Ex=$_.Exception.MEssage;write-warning $query
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query18 CollectorType=PErformance - Category=Savepoint"
			   
			   $query="/* OMS - Query18 */select start_time, volume_id,
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
							   $Ex=$_.Exception.MEssage;write-warning $query
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
	Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query19 CollectorType=PErformance - Category=Statement Subcategory=Expensive"		   

			$query="/* OMS -Query19*/Select HOST,
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
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query19"
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



	Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query20 CollectorType=Inventory - Category=Statement"
				

			$query="/* OMS -Query20 */SELECT 
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


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query21 CollectorType=Inventory - Category=Threads"				


$query="/* OMS -Query21*/SELECT HOST,
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
			  $Ex=$_.Exception.MEssage;write-warning "Failed to run Query21"
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


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query23 CollectorType=Inventory - Category=Sessions"		


$query="/* OMS -Query23*/SELECT  C.HOST,
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
			  $Ex=$_.Exception.MEssage;write-warning "Failed to run Query23"
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
IF($firstrun){$checkfreq=2592000}Else{$checkfreq=$timespan } # decide if you change 'HOUR' TIME_AGGREGATE_BY 


	
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
IF($firstrun){$checkfreq=2592000}Else{$checkfreq=$timespan } 

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query24 CollectorType=Inventory - Category=Connections"	

$query="/* OMS -Query24*/SELECT   BEGIN_TIME,
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
			  $Ex=$_.Exception.MEssage;write-warning "Failed to run Query24"
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


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query25 CollectorType=PErformance - Category=ConnectionStatistics"	

$query="/* OMS -Query25*/ SELECT  HOST,
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
			  $Ex=$_.Exception.MEssage;write-warning "Failed to run Query25"
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




Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query26 CollectorType=Inventory - Category=Replication_Status"	

$query="/* OMS -Query26*/ SELECT   R.SITE_NAME ,R.SECONDARY_SITE_NAME,R.HOST,R.SECONDARY_HOST,
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
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query26"
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

Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query27 CollectorType=Inventory - Category=Replication_Bandwith"	

$query="/* OMS -Query27 */ SELECT  SNAPSHOT_TIME,
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
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query27"
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
Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query28 CollectorType=Inventory - Category=TableLocations"	

$query="/* OMS -Query28 */SELECT HOST,
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
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query28"
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


Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query43 CollectorType=Inventory - Category=Locks"	


            $query="/* OMS -Query43 */SELECT SNAPSHOT_TIME,
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

$query="/* OMS -Query29 */WITH  
TEMP_INDEXES AS
( SELECT
    *
  FROM
    INDEXES
),
TEMP_M_BACKUP_CATALOG AS
( SELECT
    *
  FROM
    M_BACKUP_CATALOG
),
TEMP_M_BACKUP_CATALOG_FILES AS
( SELECT
    *
  FROM
    M_BACKUP_CATALOG_FILES
),
TEMP_M_CS_ALL_COLUMNS AS
( SELECT
    *
  FROM
    M_CS_ALL_COLUMNS
),
TEMP_M_CS_TABLES AS
( SELECT
    *
  FROM
    M_CS_TABLES
),
TEMP_M_MVCC_TABLES AS
( SELECT
    *
  FROM
    M_MVCC_TABLES
),
TEMP_M_RS_MEMORY AS
( SELECT
    *
  FROM
    M_RS_MEMORY
),
TEMP_M_RS_TABLES AS
( SELECT
    *
  FROM
    M_RS_TABLES
),
TEMP_M_SQL_PLAN_CACHE AS
( SELECT
    *
  FROM
    M_SQL_PLAN_CACHE
),
TEMP_M_SQL_PLAN_CACHE_OVERVIEW AS
( SELECT
    *
  FROM
    M_SQL_PLAN_CACHE_OVERVIEW
),
TEMP_M_TABLE_PERSISTENCE_STATISTICS AS
( SELECT
    *
  FROM
    M_TABLE_PERSISTENCE_STATISTICS
),
TEMP_M_TRANSACTIONS AS
( SELECT
    *
  FROM
    M_TRANSACTIONS
),
TEMP_TABLE_COLUMNS AS
( SELECT
    *
  FROM
    TABLE_COLUMNS
),
TEMP_TABLES AS
( SELECT
    *
  FROM
    TABLES
)
SELECT
  CASE 
    WHEN NAME = 'BLANK_LINE' THEN ''
    WHEN NAME = 'INFO_LINE' THEN '****' 
    WHEN ONLY_POTENTIALLY_CRITICAL_RESULTS = 'X' OR ROW_NUM = 1 OR ORDER_BY = 'HOST' THEN LPAD(CHECK_ID, 5) 
    ELSE '' 
  END CHID,
  Category,
  NAME,
  CASE WHEN ONLY_POTENTIALLY_CRITICAL_RESULTS = 'X' OR ROW_NUM = 1 OR ORDER_BY = 'HOST' THEN DESCRIPTION ELSE '' END DESCRIPTION,
  IFNULL(HOST, '') HOST,
  MAP(VALUE, '999999', 'never', '999999.00', 'never', '-999999', 'never', '-999999.00', 'never', NULL, 'n/a', 
    CASE WHEN MAX_VALUE_LENGTH = -1 OR LENGTH(VALUE) <= MAX_VALUE_LENGTH THEN VALUE 
      ELSE SUBSTR(VALUE, 1, VALUE_FRAGMENT_LENGTH) || '...' || SUBSTR(VALUE, LENGTH(VALUE) - (VALUE_FRAGMENT_LENGTH - 1), VALUE_FRAGMENT_LENGTH) END) VALUE,
  CASE
    WHEN EXPECTED_OP = 'any'  THEN ''
    WHEN EXPECTED_OP = '='    THEN EXPECTED_OP || CHAR(32) || EXPECTED_VALUE
    WHEN EXPECTED_OP = 'like' THEN EXPECTED_OP || CHAR(32) || CHAR(39) || EXPECTED_VALUE || CHAR(39)
    ELSE EXPECTED_OP || CHAR(32) || EXPECTED_VALUE
  END EXPECTED_VALUE,
  POTENTIALLY_CRITICAL C,
  LPAD(SAP_NOTE, 8) SAP_NOTE
FROM
( SELECT
    CC.CHECK_ID,
    CC.NAME,
    CC.Category,
    CC.DESCRIPTION,
    C.HOST,
    C.VALUE,
    CC.SAP_NOTE,
    CC.EXPECTED_OP,
    CC.EXPECTED_VALUE,
    CASE
      WHEN C.VALUE IN ('999999', '999999.00', '-999999', '-999999.00')                                            THEN ' '
      WHEN CC.EXPECTED_OP = 'any' OR UPPER(C.VALUE) = 'NONE'                                                      THEN ' '
      WHEN CC.EXPECTED_OP = 'not'      AND LPAD(UPPER(C.VALUE), 100) =        LPAD(UPPER(CC.EXPECTED_VALUE), 100) THEN 'X'
      WHEN CC.EXPECTED_OP = '='        AND LPAD(UPPER(C.VALUE), 100) !=       LPAD(UPPER(CC.EXPECTED_VALUE), 100) THEN 'X'
      WHEN CC.EXPECTED_OP = '>='       AND LPAD(UPPER(C.VALUE), 100) <        LPAD(UPPER(CC.EXPECTED_VALUE), 100) THEN 'X'
      WHEN CC.EXPECTED_OP = '>'        AND LPAD(UPPER(C.VALUE), 100) <=       LPAD(UPPER(CC.EXPECTED_VALUE), 100) THEN 'X'
      WHEN CC.EXPECTED_OP = CHAR(60) || '=' AND LPAD(UPPER(C.VALUE), 100) >   LPAD(UPPER(CC.EXPECTED_VALUE), 100) THEN 'X'
      WHEN CC.EXPECTED_OP = CHAR(60)   AND LPAD(UPPER(C.VALUE), 100) >=       LPAD(UPPER(CC.EXPECTED_VALUE), 100) THEN 'X'
      WHEN CC.EXPECTED_OP = 'like'     AND UPPER(C.VALUE)            NOT LIKE UPPER(CC.EXPECTED_VALUE)            THEN 'X'
      WHEN CC.EXPECTED_OP = 'not like' AND UPPER(C.VALUE)            LIKE     UPPER(CC.EXPECTED_VALUE)            THEN 'X'
      ELSE ''
    END POTENTIALLY_CRITICAL,
    BI.ONLY_POTENTIALLY_CRITICAL_RESULTS,
    BI.MAX_VALUE_LENGTH,
    FLOOR(BI.MAX_VALUE_LENGTH / 2 - 0.5) VALUE_FRAGMENT_LENGTH,
    BI.ORDER_BY,
    ROW_NUMBER () OVER ( PARTITION BY CC.DESCRIPTION ORDER BY C.HOST, C.VALUE ) ROW_NUM
  FROM
/* TMC_GENERATION_START_1 */
  ( SELECT
      'REVISION_LEVEL' NAME,
      '' HOST,
      MAP(VALUE, '.00', '0.00', VALUE) VALUE
    FROM
    ( SELECT
        LTRIM(SUBSTR(VALUE, LOCATE(VALUE, '.', 1, 2) + 1, LOCATE(VALUE, '.', 1, 4) - LOCATE(VALUE, '.', 1, 2) - 1), '0') VALUE
      FROM 
        M_SYSTEM_OVERVIEW 
      WHERE 
        SECTION = 'System' AND 
        NAME = 'Version' 
    )
    UNION ALL
    ( SELECT
        'VERSION_LEVEL',
        '',
        SUBSTR(VALUE, 1, 3)
      FROM
        M_SYSTEM_OVERVIEW 
      WHERE 
        SECTION = 'System' AND 
        NAME = 'Version' 
    )
    UNION ALL
    ( SELECT
        'CHECK_VERSION',
        '',
        '2.00+ / 1.9.1 (2017/11/17)'
      FROM
        DUMMY
    )
    UNION ALL
    ( SELECT
        'BLANK_LINE',
        '',
        ''
      FROM
        DUMMY
    )
    UNION ALL
    ( SELECT
        'INFO_LINE',
        '',
        ''
      FROM
        DUMMY
    )
    UNION ALL
    ( SELECT
        'EVERYTHING_STARTED',
        '',
        LOWER(VALUE)
      FROM
        M_SYSTEM_OVERVIEW
      WHERE
        SECTION = 'Services' AND
        NAME = 'All Started'
    )
    UNION ALL
    ( SELECT /* no longer relevant with RHEL >= 7.x and SLES 12.x where usually the intel_pstate driver is used */
        'SLOW_CPU',
        H1.HOST,
        H1.VALUE
      FROM
        M_LANDSCAPE_HOST_CONFIGURATION L,
        M_HOST_INFORMATION H1,
        M_HOST_INFORMATION H2
      WHERE
        L.HOST = H1.HOST AND
        H1.HOST = H2.HOST AND
        L.HOST_CONFIG_ROLES != 'STREAMING' AND
        H1.HOST = H2.HOST AND
        H1.KEY = 'cpu_clock' AND
        H2.KEY = 'os_name' AND
        ( H2.VALUE LIKE 'SUSE Linux Enterprise Server 11%' OR
          H2.VALUE LIKE 'Red Hat Enterprise Linux Server release 6%' OR
          H2.VALUE LIKE 'Linux 2.6.32%'
        )
    )
    UNION ALL
    ( SELECT  /* no longer relevant with RHEL >= 7.x and SLES 12.x where usually the intel_pstate driver is used */
        'VARYING_CPU',
        '',
        CASE WHEN MAX(H1.VALUE) IS NULL OR MAX(H1.VALUE) - MIN(H1.VALUE) < 100 THEN 'no' ELSE 'yes' END
      FROM
        M_LANDSCAPE_HOST_CONFIGURATION L,
        M_HOST_INFORMATION H1,
        M_HOST_INFORMATION H2
      WHERE
        L.HOST = H1.HOST AND
        H1.HOST = H2.HOST AND
        L.HOST_CONFIG_ROLES != 'STREAMING' AND
        H1.KEY = 'cpu_clock' AND
        H2.KEY = 'os_name' AND
        ( H2.VALUE LIKE 'SUSE Linux Enterprise Server 11%' OR
          H2.VALUE LIKE 'Red Hat Enterprise Linux Server release 6%' OR
          H2.VALUE LIKE 'Linux 2.6.32%'
        )
    )
    UNION ALL
    ( SELECT
        'HOST_START_TIME_VARIATION',
        '',
        TO_VARCHAR(MAX(SECONDS_BETWEEN(MIN_TIME, MAX_TIME)))
      FROM
      ( SELECT
          MIN(VALUE) MIN_TIME,
          MAX(VALUE) MAX_TIME
        FROM
          M_HOST_INFORMATION H,
          M_LANDSCAPE_HOST_CONFIGURATION L
        WHERE
          H.HOST = L.HOST AND
          H.KEY = 'start_time' AND
          L.HOST_CONFIG_ROLES != 'STREAMING'
      )
    )
    UNION ALL
    ( SELECT 
        'PERFORMANCE_TRACE',
        '',
        MAP(STATUS, 'STOPPED', 'no', 'yes') 
      FROM 
        M_PERFTRACE
    )
    UNION ALL
    ( SELECT 
        'FUNCTION_PROFILER',
        '',
        CASE WHEN STATUS != 'STOPPED' AND FUNCTION_PROFILER != 'FALSE' THEN 'yes' ELSE 'no' END
      FROM 
        M_PERFTRACE
    )
    UNION ALL
    ( SELECT
        'LOG_WAIT_RATIO',
        HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(
          CASE
          WHEN SUM(SWITCH_NOWAIT_COUNT) + SUM(SWITCH_WAIT_COUNT) = 0 THEN 0
          ELSE SUM(SWITCH_WAIT_COUNT) / (SUM(SWITCH_NOWAIT_COUNT) + SUM(SWITCH_WAIT_COUNT)) * 100 END ), 10, 0 ) ) 
      FROM
        M_LOG_BUFFERS
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'LOG_RACE_RATIO',
        HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(
          CASE
          WHEN SUM(SWITCH_NOWAIT_COUNT) + SUM(SWITCH_OPEN_COUNT) = 0 THEN 0
          ELSE SUM(SWITCH_OPEN_COUNT) / (SUM(SWITCH_NOWAIT_COUNT) + SUM(SWITCH_OPEN_COUNT)) * 100 END ), 10, 0 ) ) 
      FROM
        M_LOG_BUFFERS
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'OPEN_ALERTS_HIGH',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        _SYS_STATISTICS.STATISTICS_CURRENT_ALERTS
      WHERE
        ALERT_RATING = 4
    )
    UNION ALL
    ( SELECT
        'OPEN_ALERTS_ERROR',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        _SYS_STATISTICS.STATISTICS_CURRENT_ALERTS
      WHERE
        ALERT_RATING = 5
    )
    UNION ALL
    ( SELECT
        'STAT_SERVER_INTERNAL_ERRORS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        _SYS_STATISTICS.STATISTICS_ALERTS
      WHERE
        ALERT_TIMESTAMP >= ADD_SECONDS(CURRENT_TIMESTAMP, -86400) AND
        ALERT_ID = 0
    )
    UNION ALL
    ( SELECT
        'CHECKS_NOT_RUNNING',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        _SYS_STATISTICS.STATISTICS_SCHEDULE
      WHERE
        STATUS != 'Inactive' AND
        SECONDS_BETWEEN(LATEST_START_SERVERTIME, CURRENT_TIMESTAMP) / 2 > INTERVALLENGTH
    )
    UNION ALL
    ( SELECT
        'STAT_SERVER_NO_WORKERS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_SERVICE_THREADS
      WHERE
        THREAD_TYPE LIKE 'WorkerThread%'
    )
    UNION ALL
    ( SELECT
        'OPEN_EVENTS',
        HOST,
        TO_VARCHAR(SUM(MAP(ACKNOWLEDGED, 'FALSE', 1, 0)))
      FROM
        DUMMY LEFT OUTER JOIN
        M_EVENTS ON
          ACKNOWLEDGED = 'FALSE' AND
          SECONDS_BETWEEN(CREATE_TIME, CURRENT_TIMESTAMP) >= 1800
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT 
        'OS_OPEN_FILES',
        HOST,
        LTRIM(MIN(LPAD(VALUE, 20)))
      FROM
        M_HOST_INFORMATION
      WHERE 
        KEY = 'os_rlimit_nofile'
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'ROW_STORE_CONTAINERS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        TEMP_M_RS_TABLES
      WHERE
        CONTAINER_COUNT > 1
    )
    UNION ALL
    ( SELECT 
        'ROW_STORE_FRAGMENTATION',
        IFNULL(HOST, ''),
        IFNULL(TO_VARCHAR(TO_DECIMAL(ROUND(MAP(ALLOCATED_SIZE, 0, NULL, FREE_SIZE / ALLOCATED_SIZE * 100)), 10, 0)), 'none')
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          HOST,
          SUM(FREE_SIZE) FREE_SIZE,
          SUM(ALLOCATED_SIZE) ALLOCATED_SIZE
        FROM
          TEMP_M_RS_MEMORY
        WHERE 
          CATEGORY IN ( 'TABLE' , 'CATALOG' ) 
        GROUP BY
          HOST
        HAVING
          SUM(ALLOCATED_SIZE) >= 10737418240
      ) ON
        1 = 1
    )
    UNION ALL
    ( SELECT TOP 1
        'ROW_STORE_SIZE',
        HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(SUM(ALLOCATED_SIZE) / 1024 / 1024 / 1024), 10, 0))
      FROM
        TEMP_M_RS_MEMORY
      GROUP BY
        HOST
      ORDER BY
        SUM(ALLOCATED_SIZE) DESC
    )      
    UNION ALL
    ( SELECT
        'VERSIONS_ROW_STORE_CURR',
        HOST,
        TO_VARCHAR(SUM(VERSION_COUNT))
      FROM
        M_MVCC_OVERVIEW
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'MVCC_REC_VERSIONS_ROW_STORE',
        HOST,
        TO_VARCHAR(MAX(TO_NUMBER(VALUE)))
      FROM
        TEMP_M_MVCC_TABLES
      WHERE
        NAME = 'MAX_VERSIONS_PER_RECORD'
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        C.NAME,
        M.HOST,
        MAP(C.NAME,
          'ACTIVE_UPDATE_TID_RANGE', TO_VARCHAR(M.CUR_UPDATE_TID - M.MIN_UPDATE_TID),
          'ACTIVE_COMMIT_ID_RANGE', TO_VARCHAR(M.CUR_COMMIT_ID - M.MIN_COMMIT_ID))
      FROM
      ( SELECT 'ACTIVE_UPDATE_TID_RANGE' NAME FROM DUMMY UNION ALL
        SELECT 'ACTIVE_COMMIT_ID_RANGE' FROM DUMMY 
      ) C,         
      ( SELECT
          HOST,
          MIN(MAP(NAME, 'MIN_SNAPSHOT_TS',              TO_NUMBER(VALUE), 999999999999999999999)) MIN_COMMIT_ID,
          MAX(MAP(NAME, 'GLOBAL_TS',                    TO_NUMBER(VALUE), 0)) CUR_COMMIT_ID,
          MIN(MAP(NAME, 'MIN_WRITE_TID',                TO_NUMBER(VALUE), 999999999999999999999)) MIN_UPDATE_TID,
          MAX(MAP(NAME, 'NEXT_WRITE_TID',               TO_NUMBER(VALUE), 0)) CUR_UPDATE_TID
        FROM
          TEMP_M_MVCC_TABLES
        GROUP BY
          HOST
      ) M
    )
    UNION ALL
    ( SELECT
        'LICENSE_LIMIT',
        '',
        CASE WHEN PRODUCT_LIMIT = 0 THEN '0' ELSE TO_VARCHAR(TO_DECIMAL(ROUND(PRODUCT_USAGE / PRODUCT_LIMIT * 100), 10, 0)) END
      FROM 
        M_LICENSE
    )
    UNION ALL
    ( SELECT
        'LAST_DATA_BACKUP',
        '',
        TO_VARCHAR(TO_DECIMAL(MAP(MAX(SYS_START_TIME), NULL, 999999, SECONDS_BETWEEN(MAX(SYS_START_TIME), CURRENT_TIMESTAMP) / 86400), 10, 2))
      FROM
        DUMMY LEFT OUTER JOIN
        TEMP_M_BACKUP_CATALOG ON
          1 = 1
      WHERE
        ENTRY_TYPE_NAME IN ( 'complete data backup', 'differential data backup', 'incremental data backup', 'data snapshot' ) AND
        STATE_NAME = 'successful'
    )
    UNION ALL
    ( SELECT
        'LAST_DATA_BACKUP_ERROR',
        '',
        IFNULL(TO_VARCHAR(TO_DECIMAL(SECONDS_BETWEEN(MAX(SYS_START_TIME), CURRENT_TIMESTAMP) / 86400, 10, 2)), '999999') VALUE
      FROM
        DUMMY LEFT OUTER JOIN
        TEMP_M_BACKUP_CATALOG ON
          ENTRY_TYPE_NAME IN ( 'complete data backup', 'differential data backup', 'incremental data backup', 'data snapshot' ) AND
          STATE_NAME NOT IN ( 'successful', 'running' )
    )
    UNION ALL
    ( SELECT
        NAME,
        '',
        CASE
          WHEN NAME = 'MIN_DATA_BACKUP_THROUGHPUT' THEN TO_VARCHAR(TO_DECIMAL(MIN(MAP(BACKUP_DURATION_H, 0, 999999, BACKUP_SIZE_GB / BACKUP_DURATION_H)), 10, 2))
          WHEN NAME = 'AVG_DATA_BACKUP_THROUGHPUT' THEN TO_VARCHAR(TO_DECIMAL(AVG(MAP(BACKUP_DURATION_H, 0, 0,      BACKUP_SIZE_GB / BACKUP_DURATION_H)), 10, 2))
        END
      FROM
      ( SELECT
          C.NAME,
          SECONDS_BETWEEN(B.SYS_START_TIME, B.SYS_END_TIME) / 3600 BACKUP_DURATION_H,
          ( SELECT SUM(BACKUP_SIZE) / 1024 / 1024 / 1024 FROM TEMP_M_BACKUP_CATALOG_FILES BF WHERE BF.BACKUP_ID = B.BACKUP_ID ) BACKUP_SIZE_GB
        FROM
        ( SELECT 'MIN_DATA_BACKUP_THROUGHPUT' NAME FROM DUMMY UNION ALL
          SELECT 'AVG_DATA_BACKUP_THROUGHPUT' FROM DUMMY 
        ) C,
          TEMP_M_BACKUP_CATALOG B
        WHERE
          B.ENTRY_TYPE_NAME IN ( 'complete data backup', 'differential data backup', 'incremental data backup', 'data snapshot' ) AND
          B.STATE_NAME = 'successful' AND
          DAYS_BETWEEN(B.SYS_START_TIME, CURRENT_TIMESTAMP) <= 7
      )
      GROUP BY
        NAME
    )
    UNION ALL
    ( SELECT
        'LAST_LOG_BACKUP',
        '',
        TO_VARCHAR(TO_DECIMAL(MAP(MAX(SYS_START_TIME), NULL, 999999, GREATEST(0, SECONDS_BETWEEN(MAX(SYS_START_TIME), CURRENT_TIMESTAMP)) / 3600), 10, 2))
      FROM
        DUMMY LEFT OUTER JOIN
        TEMP_M_BACKUP_CATALOG ON
          1 = 1
      WHERE
        ENTRY_TYPE_NAME = 'log backup' AND
        STATE_NAME = 'successful'
    )
    UNION ALL
    ( SELECT
        'LAST_LOG_BACKUP_ERROR',
        '',
        IFNULL(TO_VARCHAR(TO_DECIMAL(SECONDS_BETWEEN(MAX(SYS_START_TIME), CURRENT_TIMESTAMP) / 86400, 10, 2)), '999999') VALUE
      FROM
        DUMMY LEFT OUTER JOIN
        TEMP_M_BACKUP_CATALOG ON
          ENTRY_TYPE_NAME = 'log backup' AND
          STATE_NAME NOT IN ( 'successful', 'running' )
    )
    UNION ALL
    ( SELECT
        'LOG_BACKUP_ERRORS_LAST_MONTH',
        '',
        TO_VARCHAR(COUNT(*)) VALUE
      FROM
        TEMP_M_BACKUP_CATALOG
      WHERE
        ENTRY_TYPE_NAME = 'log backup' AND
        STATE_NAME NOT IN ( 'successful', 'running' ) AND
        SECONDS_BETWEEN(SYS_START_TIME, CURRENT_TIMESTAMP) < 86400 * 30
    )
    UNION ALL
    ( SELECT
        I.NAME,
        IFNULL(HOST, ''),
        CASE I.NAME
          WHEN 'CURRENT_LARGE_HEAP_AREAS' THEN IFNULL(CATEGORY || ' (' || TO_DECIMAL(ROUND(EXCLUSIVE_SIZE_IN_USE / 1024 / 1024 / 1024), 10, 0) || ' GB)', 'none')
          WHEN 'FREQUENT_ALLOCATORS' THEN IFNULL(CATEGORY || ' (' || NUM_INSTANTIATIONS || ')', 'none')
        END
      FROM
      ( SELECT 'CURRENT_LARGE_HEAP_AREAS' NAME FROM DUMMY UNION ALL
        SELECT 'FREQUENT_ALLOCATORS' FROM DUMMY
      ) I LEFT OUTER JOIN
      ( SELECT
          HOST,
          CATEGORY,
          SUM(EXCLUSIVE_SIZE_IN_USE) EXCLUSIVE_SIZE_IN_USE,
          COUNT(*) NUM_INSTANTIATIONS
        FROM
          M_HEAP_MEMORY
        GROUP BY
          HOST,
          CATEGORY
      ) M ON
        ( I.NAME = 'CURRENT_LARGE_HEAP_AREAS' AND
          M.EXCLUSIVE_SIZE_IN_USE >= 53687091200 AND
          M.CATEGORY NOT LIKE 'Pool/AttributeEngine%' AND
          M.CATEGORY NOT LIKE 'Pool/ColumnStore%' AND
          M.CATEGORY NOT IN
          ( 'Pool/malloc/libhdbcstypes.so',
            'Pool/NameIdMapping/RoDict',
            'Pool/PersistenceManager/PersistentSpace(0)/DefaultLPA/Page',
            'Pool/PersistenceManager/PersistentSpace/DefaultLPA/Page',
            'Pool/PersistenceManager/PersistentSpace(0)/StaticLPA/Page',
            'Pool/PersistenceManager/PersistentSpace/StaticLPA/Page',
            'Pool/RowEngine/CpbTree',
            'Pool/RowStoreTables/CpbTree',
            'StackAllocator'
          )
        ) OR
        ( I.NAME = 'FREQUENT_ALLOCATORS' AND
          M.NUM_INSTANTIATIONS >= 10000
        )
    )
    UNION ALL
    ( SELECT
        'RECENT_LARGE_HEAP_AREAS',
        IFNULL(HOST, ''),
        IFNULL(CATEGORY || ' (' || TO_DECIMAL(ROUND(EXCLUSIVE_SIZE_IN_USE / 1024 / 1024 / 1024), 10, 0) || ' GB)', 'none')
      FROM
        DUMMY LEFT OUTER JOIN
        ( SELECT
            HOST,
            CATEGORY,
            MAX(EXCLUSIVE_SIZE_IN_USE) EXCLUSIVE_SIZE_IN_USE
          FROM
            _SYS_STATISTICS.HOST_HEAP_ALLOCATORS
          WHERE
            SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) <= 90000 AND
            CATEGORY NOT LIKE 'Pool/AttributeEngine%' AND
            CATEGORY NOT LIKE 'Pool/ColumnStore%' AND
            CATEGORY NOT IN
            ( 'Pool/malloc/libhdbcstypes.so',
              'Pool/NameIdMapping/RoDict',
              'Pool/PersistenceManager/PersistentSpace(0)/DefaultLPA/Page',
              'Pool/PersistenceManager/PersistentSpace/DefaultLPA/Page',
              'Pool/PersistenceManager/PersistentSpace(0)/StaticLPA/Page',
              'Pool/PersistenceManager/PersistentSpace/StaticLPA/Page',
              'Pool/RowEngine/CpbTree',
              'Pool/RowStoreTables/CpbTree',
              'StackAllocator'
            )
          GROUP BY
            HOST,
            CATEGORY
        ) ON
          EXCLUSIVE_SIZE_IN_USE >= 107374182400
      ORDER BY
        EXCLUSIVE_SIZE_IN_USE DESC
    )
    UNION ALL
    ( SELECT
        'HISTORIC_LARGE_HEAP_AREAS',
        IFNULL(HOST, ''),
        IFNULL(CATEGORY || ' (' || TO_DECIMAL(ROUND(EXCLUSIVE_SIZE_IN_USE / 1024 / 1024 / 1024), 10, 0) || ' GB)', 'none')
      FROM
        DUMMY LEFT OUTER JOIN
        ( SELECT
            HOST,
            CATEGORY,
            MAX(EXCLUSIVE_SIZE_IN_USE) EXCLUSIVE_SIZE_IN_USE
          FROM
            _SYS_STATISTICS.HOST_HEAP_ALLOCATORS
          WHERE
            CATEGORY NOT LIKE 'Pool/AttributeEngine%' AND
            CATEGORY NOT LIKE 'Pool/ColumnStore%' AND
            CATEGORY NOT IN
            ( 'Pool/malloc/libhdbcstypes.so',
              'Pool/NameIdMapping/RoDict',
              'Pool/PersistenceManager/PersistentSpace(0)/DefaultLPA/Page',
              'Pool/PersistenceManager/PersistentSpace/DefaultLPA/Page',
              'Pool/PersistenceManager/PersistentSpace(0)/StaticLPA/Page',
              'Pool/PersistenceManager/PersistentSpace/StaticLPA/Page',
              'Pool/RowEngine/CpbTree',
              'Pool/RowStoreTables/CpbTree',
              'StackAllocator'
            )
          GROUP BY
            HOST,
            CATEGORY
        ) ON
          EXCLUSIVE_SIZE_IN_USE >= 214748364800
      ORDER BY
        EXCLUSIVE_SIZE_IN_USE DESC
    )
    UNION ALL
    ( SELECT
        'MANY_PARTITIONS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
      ( SELECT
          SCHEMA_NAME,
          TABLE_NAME
        FROM
          TEMP_M_CS_TABLES
        GROUP BY
          SCHEMA_NAME,
          TABLE_NAME
        HAVING
          COUNT(*) > 100
      )
    )  
    UNION ALL
    ( SELECT
        'ACTIVE_UPDATE_TRANS_TIME',
        IFNULL(HOST, '') HOST,
        IFNULL(TO_VARCHAR(MAX(GREATEST(0, SECONDS_BETWEEN(START_TIME, CURRENT_TIMESTAMP)))), '0')
      FROM
        DUMMY LEFT OUTER JOIN
        TEMP_M_TRANSACTIONS ON
          UPDATE_TRANSACTION_ID > 0 AND 
          TRANSACTION_STATUS = 'ACTIVE'
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        C.NAME,
        O.HOST,
        CASE
          WHEN C.NAME = 'CPU_BUSY_CURRENT' THEN
            TO_VARCHAR(TO_DECIMAL(ROUND(MAX(MAP(TOTAL_CPU_USER_TIME_DELTA + TOTAL_CPU_SYSTEM_TIME_DELTA + TOTAL_CPU_WIO_TIME_DELTA + TOTAL_CPU_IDLE_TIME_DELTA, 0, 0, 
              (TOTAL_CPU_USER_TIME_DELTA + TOTAL_CPU_SYSTEM_TIME_DELTA) / (TOTAL_CPU_USER_TIME_DELTA + TOTAL_CPU_SYSTEM_TIME_DELTA + TOTAL_CPU_WIO_TIME_DELTA + TOTAL_CPU_IDLE_TIME_DELTA)) * 100)), 10, 0))
          WHEN C.NAME = 'MEMORY_USED_CURRENT' THEN
            TO_VARCHAR(TO_DECIMAL(ROUND(MAX(MAP(FREE_PHYSICAL_MEMORY + USED_PHYSICAL_MEMORY, 0, 0, USED_PHYSICAL_MEMORY / (FREE_PHYSICAL_MEMORY + USED_PHYSICAL_MEMORY)) * 100)), 10, 0))
          WHEN C.NAME = 'SWAP_SPACE_USED_CURRENT' THEN
            TO_VARCHAR(TO_DECIMAL(ROUND(MAX(USED_SWAP_SPACE) / 1024 / 1024 / 1024), 10, 0))
        END
      FROM
      ( SELECT 'CPU_BUSY_CURRENT' NAME FROM DUMMY UNION ALL
        SELECT 'MEMORY_USED_CURRENT' FROM DUMMY UNION ALL
        SELECT 'SWAP_SPACE_USED_CURRENT' FROM DUMMY
      ) C,
      ( SELECT 
          * 
        FROM 
          _SYS_STATISTICS.HOST_RESOURCE_UTILIZATION_STATISTICS 
        WHERE 
        SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) <= 600 AND
        TOTAL_CPU_USER_TIME_DELTA + TOTAL_CPU_SYSTEM_TIME_DELTA + TOTAL_CPU_WIO_TIME_DELTA + TOTAL_CPU_IDLE_TIME_DELTA > 0
      ) O
      GROUP BY
        C.NAME,
        O.HOST
    )
    UNION ALL
    ( SELECT
        C.NAME,
        R.HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(MAX(CASE C.NAME
          WHEN 'CPU_BUSY_RECENT' THEN 
            (R.TOTAL_CPU_USER_TIME_DELTA + R.TOTAL_CPU_SYSTEM_TIME_DELTA) / 
            (R.TOTAL_CPU_USER_TIME_DELTA + R.TOTAL_CPU_SYSTEM_TIME_DELTA + R.TOTAL_CPU_WIO_TIME_DELTA + R.TOTAL_CPU_IDLE_TIME_DELTA) * 100
          WHEN 'CPU_BUSY_SYSTEM_RECENT' THEN
            R.TOTAL_CPU_SYSTEM_TIME_DELTA /
            (R.TOTAL_CPU_USER_TIME_DELTA + R.TOTAL_CPU_SYSTEM_TIME_DELTA + R.TOTAL_CPU_WIO_TIME_DELTA + R.TOTAL_CPU_IDLE_TIME_DELTA) * 100
        END)), 10, 0))
      FROM
      ( SELECT 'CPU_BUSY_RECENT' NAME FROM DUMMY UNION ALL
        SELECT 'CPU_BUSY_SYSTEM_RECENT' FROM DUMMY
      ) C,
      ( SELECT
          HOST,
          AVG(TOTAL_CPU_USER_TIME_DELTA) TOTAL_CPU_USER_TIME_DELTA,
          AVG(TOTAL_CPU_SYSTEM_TIME_DELTA) TOTAL_CPU_SYSTEM_TIME_DELTA,
          AVG(TOTAL_CPU_WIO_TIME_DELTA) TOTAL_CPU_WIO_TIME_DELTA,
          AVG(TOTAL_CPU_IDLE_TIME_DELTA) TOTAL_CPU_IDLE_TIME_DELTA
        FROM
          _SYS_STATISTICS.HOST_RESOURCE_UTILIZATION_STATISTICS
        WHERE
          SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) <= 86400 AND
          TOTAL_CPU_USER_TIME_DELTA + TOTAL_CPU_SYSTEM_TIME_DELTA + TOTAL_CPU_WIO_TIME_DELTA + TOTAL_CPU_IDLE_TIME_DELTA > 0
        GROUP BY
          HOST,
          FLOOR(SECONDS_BETWEEN(CURRENT_TIMESTAMP, SERVER_TIMESTAMP) / 300)
      ) R
      GROUP BY
        C.NAME,
        R.HOST 
    )
    UNION ALL
    ( SELECT
        'CPU_BUSY_HISTORY',
        HOST,
        IFNULL(TO_VARCHAR(TO_DECIMAL(SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) / 3600, 10, 2)), '999999')
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          HOST,
          MAX(SERVER_TIMESTAMP) SERVER_TIMESTAMP
        FROM
          _SYS_STATISTICS.HOST_RESOURCE_UTILIZATION_STATISTICS 
        WHERE
          MAP(TOTAL_CPU_USER_TIME_DELTA + TOTAL_CPU_SYSTEM_TIME_DELTA + TOTAL_CPU_WIO_TIME_DELTA + TOTAL_CPU_IDLE_TIME_DELTA, 0, 0,
            ( TOTAL_CPU_USER_TIME_DELTA + TOTAL_CPU_SYSTEM_TIME_DELTA ) / 
            ( TOTAL_CPU_USER_TIME_DELTA + TOTAL_CPU_SYSTEM_TIME_DELTA + TOTAL_CPU_WIO_TIME_DELTA + TOTAL_CPU_IDLE_TIME_DELTA ) * 100) > 95
        GROUP BY
          HOST
      ) ON
          1 = 1
    )
    UNION ALL
    ( SELECT
        'SWAP_SPACE_USED_HISTORY',
        HOST,
        IFNULL(TO_VARCHAR(TO_DECIMAL(ROUND(SECONDS_BETWEEN(MAX(SERVER_TIMESTAMP), CURRENT_TIMESTAMP) / 3600), 10, 0)), '999999')
      FROM
        DUMMY LEFT OUTER JOIN
        _SYS_STATISTICS.HOST_RESOURCE_UTILIZATION_STATISTICS ON
          TO_DECIMAL(ROUND(USED_SWAP_SPACE / 1024 / 1024 / 1024), 10, 0) > 0
      GROUP BY 
        HOST
    )
    UNION ALL
    ( SELECT
        C.NAME,
        '',
        CASE
          WHEN C.NAME = 'HIGH_CRIT_SAVEPOINT_PHASE'  THEN TO_VARCHAR(SUM(CASE WHEN (CRITICAL_PHASE_WAIT_TIME + CRITICAL_PHASE_DURATION) / 1000000 > 10 THEN 1 ELSE 0 END))
          WHEN C.NAME = 'AVG_CRIT_SAVEPOINT_PHASE'   THEN TO_VARCHAR(TO_DECIMAL(IFNULL(AVG((CRITICAL_PHASE_WAIT_TIME + CRITICAL_PHASE_DURATION) / 1000000), 0), 10, 2))
          WHEN C.NAME = 'MAX_CRIT_SAVEPOINT_PHASE'   THEN TO_VARCHAR(TO_DECIMAL(IFNULL(MAX((CRITICAL_PHASE_WAIT_TIME + CRITICAL_PHASE_DURATION) / 1000000), 0), 10, 2))
          WHEN C.NAME = 'ENTER_CRIT_SAVEPOINT_PHASE' THEN TO_VARCHAR(SUM(CASE WHEN CRITICAL_PHASE_WAIT_TIME / 1000000 > 10 THEN 1 ELSE 0 END))
          WHEN C.NAME = 'CRIT_SAVEPOINT_PHASE'       THEN TO_VARCHAR(SUM(CASE WHEN CRITICAL_PHASE_DURATION / 1000000 > 10 AND CRITICAL_PHASE_WAIT_TIME / 1000000 <= 10 THEN 1 ELSE 0 END))
        END
      FROM
        ( SELECT 'HIGH_CRIT_SAVEPOINT_PHASE' NAME FROM DUMMY UNION ALL
          SELECT 'AVG_CRIT_SAVEPOINT_PHASE'       FROM DUMMY UNION ALL
          SELECT 'MAX_CRIT_SAVEPOINT_PHASE'       FROM DUMMY UNION ALL
          SELECT 'ENTER_CRIT_SAVEPOINT_PHASE'     FROM DUMMY UNION ALL
          SELECT 'CRIT_SAVEPOINT_PHASE'           FROM DUMMY
        ) C LEFT OUTER JOIN
          _SYS_STATISTICS.HOST_SAVEPOINTS S ON
            S.SERVER_TIMESTAMP >= ADD_SECONDS(CURRENT_TIMESTAMP, -86400)
      GROUP BY
        C.NAME
    )
    UNION ALL
    ( SELECT
        'DISK_SIZE',
        MAP(HOST, CHAR(60) || 'all>', '', HOST),
        TO_VARCHAR(TO_DECIMAL(ROUND(MAX(MAP(TOTAL_SIZE, 0, 0, USED_SIZE / TOTAL_SIZE)) * 100), 10, 0))
      FROM
        M_DISKS 
      WHERE
        TOTAL_SIZE > 0
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'OLDEST_LOCK_WAIT',
        '',
        TO_VARCHAR(IFNULL(GREATEST(MAX(SECONDS_BETWEEN(BLOCKED_TIME, CURRENT_TIMESTAMP)), 0), 0))
      FROM
        M_BLOCKED_TRANSACTIONS 
    )
    UNION ALL
    ( SELECT
        'MVCC_TRANS_START_TIME',
        '', 
        IFNULL(TO_VARCHAR(SECONDS_BETWEEN(MIN(START_TIME), CURRENT_TIMESTAMP)), '0')
      FROM
        TEMP_M_TRANSACTIONS
      WHERE
        MIN_MVCC_SNAPSHOT_TIMESTAMP = ( SELECT MIN(VALUE) FROM TEMP_M_MVCC_TABLES WHERE NAME = 'MIN_SNAPSHOT_TS' )
    )
    UNION ALL
    ( SELECT
        'LONG_TABLE_MERGE_TIME',
        '',
        MAP(M.TABLE_NAME, NULL, 'none', M.TABLE_NAME || CHAR(32) || '(' || RUNTIME_H || CHAR(32) || 'h)')
      FROM
      ( SELECT 1 FROM DUMMY ) LEFT OUTER JOIN
      ( SELECT
          TABLE_NAME,
          TO_DECIMAL(SUM(EXECUTION_TIME) / 1000 / 3600, 10, 2) RUNTIME_H
        FROM
        ( SELECT DISTINCT(HOST) HOST FROM M_HOST_INFORMATION ) H,
        ( SELECT DISTINCT HOST, START_TIME, EXECUTION_TIME, SCHEMA_NAME, TABLE_NAME, PART_ID FROM _SYS_STATISTICS.HOST_DELTA_MERGE_STATISTICS ) M
        WHERE
          H.HOST = M.HOST AND
          SECONDS_BETWEEN(START_TIME, CURRENT_TIMESTAMP) <= 86400
        GROUP BY
          TABLE_NAME
        HAVING
          SUM(EXECUTION_TIME) > 7200000
      ) M ON
      1 = 1
    )
    UNION ALL
    ( SELECT
        'LONG_DELTA_MERGES',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        ( SELECT DISTINCT(HOST) HOST FROM M_HOST_INFORMATION ) H,
        ( SELECT DISTINCT HOST, START_TIME, EXECUTION_TIME, SCHEMA_NAME, TABLE_NAME, PART_ID FROM _SYS_STATISTICS.HOST_DELTA_MERGE_STATISTICS ) M
      WHERE
        H.HOST = M.HOST AND
        SECONDS_BETWEEN(START_TIME, CURRENT_TIMESTAMP) <= 86400 AND
        EXECUTION_TIME > 900000
    )
    UNION ALL
    ( SELECT
        C.NAME,
        M.HOST,
        CASE 
          WHEN C.NAME = 'FAILING_DELTA_MERGES_INFO' THEN TO_VARCHAR(SUM(CASE WHEN 
            M.ERROR_DESCRIPTION LIKE '%2465%' OR
            M.ERROR_DESCRIPTION LIKE '%2480%' OR
            M.ERROR_DESCRIPTION LIKE '%2481%' OR
            M.ERROR_DESCRIPTION LIKE '%2482%' OR
            M.ERROR_DESCRIPTION LIKE '%2486%' THEN 1 ELSE 0 END ))
          WHEN C.NAME = 'FAILING_DELTA_MERGES_ERROR' THEN TO_VARCHAR(SUM(CASE WHEN
            M.LAST_ERROR != 0 AND
            ( M.ERROR_DESCRIPTION NOT LIKE '%2465%' AND
              M.ERROR_DESCRIPTION NOT LIKE '%2480%' AND
              M.ERROR_DESCRIPTION NOT LIKE '%2481%' AND
              M.ERROR_DESCRIPTION NOT LIKE '%2482%' AND
              M.ERROR_DESCRIPTION NOT LIKE '%2486%' 
            ) THEN 1 ELSE 0 END ))
        END
      FROM
        ( SELECT 'FAILING_DELTA_MERGES_INFO' NAME FROM DUMMY UNION ALL
          SELECT 'FAILING_DELTA_MERGES_ERROR' FROM DUMMY
        ) C,
        M_DELTA_MERGE_STATISTICS M
      WHERE
        SECONDS_BETWEEN(M.START_TIME, CURRENT_TIMESTAMP) <= 86400 
      GROUP BY
        C.NAME,
        M.HOST
    )
    UNION ALL
    ( SELECT
        C.NAME,
        HOST,
        CASE
          WHEN C.NAME = 'NUM_TRACEFILES_TOTAL' THEN TO_VARCHAR(COUNT(*))
          WHEN C.NAME = 'SIZE_TRACEFILES_TOTAL' THEN TO_VARCHAR(TO_DECIMAL(SUM(FILE_SIZE) / 1024 / 1024 / 1024, 10, 2))
          WHEN C.NAME = 'LARGEST_TRACEFILE' THEN TO_VARCHAR(TO_DECIMAL(MAX(FILE_SIZE) / 1024 / 1024, 10, 2))
        END
      FROM
      ( SELECT 'NUM_TRACEFILES_TOTAL' NAME FROM DUMMY UNION ALL
        SELECT 'SIZE_TRACEFILES_TOTAL' FROM DUMMY UNION ALL
        SELECT 'LARGEST_TRACEFILE' FROM DUMMY
      ) C LEFT OUTER JOIN
        M_TRACEFILES T ON
          1 = 1
      GROUP BY
        C.NAME,
        T.HOST
    )
    UNION ALL
    ( SELECT
        C.NAME,
        HOST,
        CASE
          WHEN C.NAME = 'NUM_TRACEFILES_DAY' THEN TO_VARCHAR(COUNT(*))
          WHEN C.NAME = 'SIZE_TRACEFILES_DAY' THEN TO_VARCHAR(TO_DECIMAL(SUM(FILE_SIZE) / 1024 / 1024 / 1024, 10, 2))
          WHEN C.NAME = 'NUM_OOM_TRACEFILES' THEN TO_VARCHAR(SUM(CASE WHEN FILE_NAME LIKE '%rtedump%oom%' AND FILE_NAME NOT LIKE '%compositelimit_oom%' THEN 1 ELSE 0 END))
          WHEN C.NAME = 'NUM_COMP_OOM_TRACEFILES' THEN TO_VARCHAR(SUM(CASE WHEN FILE_NAME LIKE '%rtedump%%compositelimit_oom%' THEN 1 ELSE 0 END))
          WHEN C.NAME = 'NUM_CRASHDUMP_TRACEFILES' THEN TO_VARCHAR(SUM(CASE WHEN FILE_NAME LIKE '%crashdump%' THEN 1 ELSE 0 END))
          WHEN C.NAME = 'NUM_RTEDUMP_TRACEFILES' THEN TO_VARCHAR(SUM(CASE WHEN FILE_NAME LIKE '%rtedump%' AND FILE_NAME NOT LIKE '%rtedump%oom%' AND FILE_NAME NOT LIKE '%rtedump%page%' THEN 1 ELSE 0 END))
          WHEN C.NAME = 'NUM_PAGEDUMP_TRACEFILES' THEN TO_VARCHAR(SUM(CASE WHEN FILE_NAME LIKE '%rtedump%page%' THEN 1 ELSE 0 END))
        END
      FROM
      ( SELECT 'NUM_TRACEFILES_DAY' NAME FROM DUMMY UNION ALL
        SELECT 'SIZE_TRACEFILES_DAY' FROM DUMMY UNION ALL
        SELECT 'NUM_OOM_TRACEFILES' FROM DUMMY UNION ALL
        SELECT 'NUM_COMP_OOM_TRACEFILES' FROM DUMMY UNION ALL
        SELECT 'NUM_CRASHDUMP_TRACEFILES' FROM DUMMY UNION ALL
        SELECT 'NUM_RTEDUMP_TRACEFILES' FROM DUMMY UNION ALL
        SELECT 'NUM_PAGEDUMP_TRACEFILES' FROM DUMMY
      ) C LEFT OUTER JOIN
        M_TRACEFILES T ON
          1 = 1
      WHERE
        SECONDS_BETWEEN(T.FILE_MTIME, CURRENT_TIMESTAMP) <= 86400
      GROUP BY
        C.NAME,
        T.HOST
    )
    UNION ALL
    ( SELECT
        'NUM_TRACE_ENTRIES_HOUR',
        HOST,
        TO_VARCHAR(COUNT(*))
      FROM
        M_MERGED_TRACES
      WHERE
        TIMESTAMP >= ADD_SECONDS(CURRENT_TIMESTAMP, -3600) AND
        TRACE_FILE_NAME NOT LIKE 'nameserver%0000.%'
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'EXP_TRACE_LONG_RUNNING_SQL',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_EXPENSIVE_STATEMENTS
      WHERE
        SECONDS_BETWEEN(START_TIME, CURRENT_TIMESTAMP) <= 86400 AND
        DURATION_MICROSEC / 1000000 > 3600 AND
        UPPER(TO_VARCHAR(STATEMENT_STRING)) NOT LIKE 'BACKUP%'
    )
    UNION ALL
    ( SELECT TOP 1
        'ANALYSIS_DATE',
        '',
        TO_VARCHAR(CURRENT_TIMESTAMP, 'YYYY/MM/DD HH24:MI:SS') || CHAR(32) || '(' || VALUE || ')'
      FROM
        M_HOST_INFORMATION
      WHERE
        KEY = 'timezone_name'
    )
    UNION ALL
    ( SELECT
        'DATABASE_NAME',
        '',
        DATABASE_NAME
      FROM
        M_DATABASE
    )
    UNION ALL
    ( SELECT
        C.NAME,
        '',
        MAP(TABLE_NAME, NULL, 'none', TABLE_NAME || MAP(PART_ID, 0, '', CHAR(32) || '(' || PART_ID || ')') || CHAR(32) || '(' || 
          MAP(C.NAME, 'LARGE_MEMORY_TABLES', TO_DECIMAL(ROUND(MEMORY_SIZE_IN_TOTAL / 1024 / 1024 / 1024), 10, 0) || CHAR(32) || 'GB)', 
            'LARGE_ALLOC_LIM_TABLES', TO_DECIMAL(ROUND(T.MEMORY_SIZE_IN_TOTAL / T.GLOBAL_ALLOCATION_LIMIT * 100), 10, 0) || CHAR(32) || '%)'))
      FROM
      ( SELECT 'LARGE_MEMORY_TABLES' NAME FROM DUMMY UNION ALL
        SELECT 'LARGE_ALLOC_LIM_TABLES'   FROM DUMMY
      ) C LEFT OUTER JOIN
      ( SELECT
          T.TABLE_NAME,
          T.PART_ID,
          T.MEMORY_SIZE_IN_TOTAL,
          H.ALLOCATION_LIMIT GLOBAL_ALLOCATION_LIMIT
        FROM
          TEMP_M_CS_TABLES T,
          M_HOST_RESOURCE_UTILIZATION H
        WHERE
          T.HOST = H.HOST AND
          ( T.MEMORY_SIZE_IN_TOTAL / 1024 / 1024 / 1024 > 100 OR
            T.MEMORY_SIZE_IN_TOTAL > 0.1 * H.ALLOCATION_LIMIT AND
          H.ALLOCATION_LIMIT > 0
          )
      ) T ON
        C.NAME = 'LARGE_MEMORY_TABLES'    AND T.MEMORY_SIZE_IN_TOTAL / 1024 / 1024 / 1024 > 100 OR
        C.NAME = 'LARGE_ALLOC_LIM_TABLES' AND T.MEMORY_SIZE_IN_TOTAL > 0.1 * T.GLOBAL_ALLOCATION_LIMIT
    )
    UNION ALL
    ( SELECT
        C.NAME,
        '',
        CASE C.NAME
          WHEN 'LARGE_DELTA_STORAGE_AUTO'   THEN IFNULL(TABLE_NAME || ' (' || TO_DECIMAL(MEMORY_SIZE_IN_DELTA / 1024 / 1024 / 1024, 10, 2) || ' GB)', 'none')
          WHEN 'MANY_DELTA_RECORDS_AUTO'    THEN IFNULL(TABLE_NAME || ' (' || RAW_RECORD_COUNT_IN_DELTA || ' rows, ' || DELTA_PCT || ' %)', 'none')
          WHEN 'LARGE_DELTA_STORAGE_NOAUTO' THEN IFNULL(TABLE_NAME || ' (' || TO_DECIMAL(MEMORY_SIZE_IN_DELTA / 1024 / 1024 / 1024, 10, 2) || ' GB)', 'none')
          WHEN 'MANY_DELTA_RECORDS_NOAUTO'  THEN IFNULL(TABLE_NAME || ' (' || RAW_RECORD_COUNT_IN_DELTA || ' rows, ' || DELTA_PCT || ' %)', 'none')
        END
      FROM
      ( SELECT 'LARGE_DELTA_STORAGE_AUTO' NAME FROM DUMMY UNION ALL
        SELECT 'MANY_DELTA_RECORDS_AUTO'       FROM DUMMY UNION ALL
        SELECT 'LARGE_DELTA_STORAGE_NOAUTO'    FROM DUMMY UNION ALL
        SELECT 'MANY_DELTA_RECORDS_NOAUTO'     FROM DUMMY
      ) C LEFT OUTER JOIN
      ( SELECT
          CT.TABLE_NAME,
          T.AUTO_MERGE_ON,
          MAX(NUM_HOURS) NUM_HOURS,
          SUM(CT.MEMORY_SIZE_IN_TOTAL) MEMORY_SIZE_IN_TOTAL,
          SUM(CT.MEMORY_SIZE_IN_DELTA) MEMORY_SIZE_IN_DELTA,
          SUM(CT.RAW_RECORD_COUNT_IN_MAIN) RAW_RECORD_COUNT_IN_MAIN,
          SUM(CT.RAW_RECORD_COUNT_IN_DELTA) RAW_RECORD_COUNT_IN_DELTA,
          TO_DECIMAL(ROUND(MAP(SUM(CT.RAW_RECORD_COUNT_IN_DELTA + CT.RAW_RECORD_COUNT_IN_MAIN), 0, 0, SUM(CT.RAW_RECORD_COUNT_IN_DELTA) / SUM(CT.RAW_RECORD_COUNT_IN_DELTA + CT.RAW_RECORD_COUNT_IN_MAIN) * 100)), 10, 0) DELTA_PCT,
          SUM(TH.MIN_RECENT_MEMORY_SIZE_IN_DELTA) MIN_RECENT_MEMORY_SIZE_IN_DELTA,
          SUM(TH.MIN_RECENT_RAW_RECORD_COUNT_IN_DELTA) MIN_RECENT_RAW_RECORD_COUNT_IN_DELTA
        FROM
          TEMP_M_CS_TABLES CT INNER JOIN
          TEMP_TABLES T ON
            CT.SCHEMA_NAME = T.SCHEMA_NAME AND
            CT.TABLE_NAME = T.TABLE_NAME LEFT OUTER JOIN
          ( SELECT
              SCHEMA_NAME,
              TABLE_NAME,
              COUNT(DISTINCT(TO_VARCHAR(SERVER_TIMESTAMP, 'HH24'))) NUM_HOURS,
              MIN(RAW_RECORD_COUNT_IN_DELTA) MIN_RECENT_RAW_RECORD_COUNT_IN_DELTA,
              MIN(MEMORY_SIZE_IN_DELTA) MIN_RECENT_MEMORY_SIZE_IN_DELTA
            FROM
              _SYS_STATISTICS.HOST_COLUMN_TABLES_PART_SIZE
            WHERE
              SERVER_TIMESTAMP > ADD_SECONDS(CURRENT_TIMESTAMP, -86400)
            GROUP BY
              SCHEMA_NAME,
              TABLE_NAME
          ) TH ON
            TH.SCHEMA_NAME = T.SCHEMA_NAME AND
            TH.TABLE_NAME = T.TABLE_NAME
        GROUP BY
          CT.TABLE_NAME,
          T.AUTO_MERGE_ON
        HAVING
          SUM(CT.MEMORY_SIZE_IN_DELTA) > 5368709120 OR
          SUM(CT.RAW_RECORD_COUNT_IN_DELTA) >= GREATEST(9 * SUM(CT.RAW_RECORD_COUNT_IN_MAIN), 1000000)
      ) T ON
          C.NAME = 'LARGE_DELTA_STORAGE_AUTO' AND T.AUTO_MERGE_ON = 'TRUE' AND T.MEMORY_SIZE_IN_DELTA >= GREATEST(T.MEMORY_SIZE_IN_TOTAL / 10, 5368709120) OR
          C.NAME = 'MANY_DELTA_RECORDS_AUTO' AND T.AUTO_MERGE_ON = 'TRUE' AND T.RAW_RECORD_COUNT_IN_DELTA >= GREATEST(9 * T.RAW_RECORD_COUNT_IN_MAIN, 1000000) OR
          C.NAME = 'LARGE_DELTA_STORAGE_NOAUTO' AND T.AUTO_MERGE_ON = 'FALSE' AND T.MEMORY_SIZE_IN_DELTA >= GREATEST(T.MEMORY_SIZE_IN_TOTAL / 10, 5368709120) AND T.NUM_HOURS >= 20 AND
            ( T.MIN_RECENT_MEMORY_SIZE_IN_DELTA > 5368709120 OR T.MIN_RECENT_MEMORY_SIZE_IN_DELTA IS NULL ) OR
          C.NAME = 'MANY_DELTA_RECORDS_NOAUTO' AND T.AUTO_MERGE_ON = 'FALSE' AND T.RAW_RECORD_COUNT_IN_DELTA >= GREATEST(9 * T.RAW_RECORD_COUNT_IN_MAIN, 1000000) AND T.NUM_HOURS >= 20 AND
            ( T.MIN_RECENT_RAW_RECORD_COUNT_IN_DELTA IS NULL OR T.MIN_RECENT_RAW_RECORD_COUNT_IN_DELTA >= GREATEST(9 * T.RAW_RECORD_COUNT_IN_MAIN, 1000000) )
      ORDER BY
        T.MEMORY_SIZE_IN_DELTA DESC
    )
    UNION ALL
    ( SELECT
        I.NAME,
        '',
        TO_VARCHAR(SUM(MAP(U.REASON, NULL, 0, 1)))
      FROM
      ( SELECT 'CURRENT_UNLOADS' NAME,   'LOW MEMORY' REASON FROM DUMMY UNION ALL
        SELECT 'CURRENT_SHRINK_UNLOADS', 'SHRINK'            FROM DUMMY
      ) I LEFT OUTER JOIN
      ( SELECT
          U.HOST,
          U.REASON
        FROM
          TEMP_TABLES T,
          M_CS_UNLOADS U
        WHERE
          T.SCHEMA_NAME = U.SCHEMA_NAME AND
          T.TABLE_NAME = U.TABLE_NAME AND
          T.UNLOAD_PRIORITY <= 5 AND
          U.UNLOAD_TIME >= ADD_SECONDS(CURRENT_TIMESTAMP, -86400) AND
          U.REASON = 'LOW MEMORY'
      ) U ON
        I.REASON = U.REASON
      GROUP BY
        I.NAME
    )
    UNION ALL
    ( SELECT
        'LAST_UNLOAD',
        IFNULL(HOST, ''),
        MAP(U.UNLOAD_TIME, NULL, '999999', TO_VARCHAR(TO_DECIMAL(SECONDS_BETWEEN(U.UNLOAD_TIME, CURRENT_TIMESTAMP) / 86400, 10, 2)))
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          U.HOST,
          MAX(U.UNLOAD_TIME) UNLOAD_TIME
        FROM
          TEMP_TABLES T,
          M_CS_UNLOADS U
        WHERE
          T.SCHEMA_NAME = U.SCHEMA_NAME AND
          T.TABLE_NAME = U.TABLE_NAME AND
          T.UNLOAD_PRIORITY <= 5 AND
          U.REASON = 'LOW MEMORY'
        GROUP BY
          U.HOST
      ) U ON
        1 = 1
    )
    UNION ALL
    ( SELECT
        'COLUMN_UNLOAD_SIZE',
        IFNULL(U.HOST, ''),
        TO_VARCHAR(TO_DECIMAL(IFNULL(SUM(C.MEMORY_SIZE_IN_TOTAL), 0) / 1024 / 1024 / 1024, 10, 2))
      FROM
        DUMMY D LEFT OUTER JOIN
        M_CS_UNLOADS U ON
          U.UNLOAD_TIME > ADD_SECONDS(CURRENT_TIMESTAMP, -86400) AND
          U.REASON != 'MERGE' LEFT OUTER JOIN
        TEMP_M_CS_ALL_COLUMNS C ON
          U.SCHEMA_NAME = C.SCHEMA_NAME AND
          U.TABLE_NAME = C.TABLE_NAME AND
          U.PART_ID = C.PART_ID AND
          U.COLUMN_NAME = C.COLUMN_NAME
      GROUP BY
        U.HOST
    )
    UNION ALL
    ( SELECT
        'SQL_CACHE_EVICTIONS_LAST_DAY',
        HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(SUM(EVICT_PER_HOUR)), 10, 0))
      FROM
      ( SELECT
          HOST,
          ( GREATEST( 0, EVICTED_PLAN_COUNT - LAG(EVICTED_PLAN_COUNT, 1) OVER ( PARTITION BY HOST, PORT ORDER BY SERVER_TIMESTAMP ) ) ) / 24 EVICT_PER_HOUR
        FROM
          _SYS_STATISTICS.HOST_SQL_PLAN_CACHE_OVERVIEW
        WHERE
          SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) <= 88000
      )
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'SQL_CACHE_EVICTIONS',
        HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(SUM(EVICT_PER_HOUR)), 10, 0))
      FROM
      ( SELECT
          S.HOST,
          S.PORT,
          EVICTED_PLAN_COUNT / SECONDS_BETWEEN(SS.START_TIME, CURRENT_TIMESTAMP) * 3600 EVICT_PER_HOUR
        FROM
          TEMP_M_SQL_PLAN_CACHE_OVERVIEW S,
          M_SERVICE_STATISTICS SS
        WHERE
          S.HOST = SS.HOST AND
          S.PORT = SS.PORT
      )
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'EXPENSIVE_SQL_TRACE_RECORDS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_EXPENSIVE_STATEMENTS
      WHERE
        SECONDS_BETWEEN(START_TIME, CURRENT_TIMESTAMP) <= 86400 AND
        OPERATION IN ('AGGREGATED_EXECUTION', 'CALL')
    )
    UNION ALL
    ( SELECT
        'TIME_SINCE_LAST_SAVEPOINT',
        HOST,
        TO_VARCHAR(GREATEST(0, SECONDS_BETWEEN(MAX(START_TIME), CURRENT_TIMESTAMP)))
      FROM
        M_SAVEPOINTS
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'LICENSE_EXPIRATION',
        '',
        TO_VARCHAR(MAP(EXPIRATION_DATE, NULL, '999999', DAYS_BETWEEN(CURRENT_DATE, EXPIRATION_DATE)))
      FROM 
        M_LICENSE
    )
    UNION ALL
    ( SELECT
        'SECURE_STORE_AVAILABLE',
        HOST,
        VALUE
      FROM
        M_HOST_INFORMATION
      WHERE
        KEY = 'secure_store'
    )
    UNION ALL
    ( SELECT
        'PERMANENT_LICENSE',
        '',
        MAP(PERMANENT, 'TRUE', 'yes', 'no')
      FROM
        M_LICENSE
    )
    UNION ALL
    ( SELECT
        'SERVICE_START_TIME_VARIATION',
        S.HOST,
        TO_VARCHAR(SECONDS_BETWEEN(MIN(S.START_TIME), MAX(S.START_TIME)))
      FROM
        M_SERVICE_STATISTICS S,
        M_LANDSCAPE_HOST_CONFIGURATION L
      WHERE
        S.HOST = L.HOST AND
        L.HOST_CONFIG_ROLES != 'STREAMING' AND
        S.SERVICE_NAME != 'webdispatcher'
      GROUP BY
        S.HOST
    )
    UNION ALL
    ( SELECT TOP 1
        'BACKUP_CATALOG_SIZE',
        '',
        TO_VARCHAR(TO_DECIMAL(BF.BACKUP_SIZE / 1024 / 1024, 10, 2))
      FROM
        TEMP_M_BACKUP_CATALOG B,
        TEMP_M_BACKUP_CATALOG_FILES BF
      WHERE
        B.BACKUP_ID = BF.BACKUP_ID AND
        BF.SOURCE_TYPE_NAME = 'catalog' AND
        B.STATE_NAME = 'successful'
     ORDER BY
       B.SYS_START_TIME DESC
    )         
    UNION ALL
    ( SELECT
        'OLDEST_BACKUP_IN_CATALOG',
        '',
        TO_VARCHAR(DAYS_BETWEEN(MIN(SYS_START_TIME), CURRENT_TIMESTAMP))
      FROM
        TEMP_M_BACKUP_CATALOG
    )
    UNION ALL
    ( SELECT
        NAME,
        HOST,
        TO_VARCHAR(VALUE)
      FROM
      ( SELECT
          C.NAME,
          L.HOST,
          CASE C.NAME
            WHEN 'LOG_SEGMENTS_FREE'     THEN SUM(MAP(L.STATE, 'Free', 1, 0))
            WHEN 'LOG_SEGMENTS_NOT_FREE' THEN SUM(MAP(L.STATE, 'Free', 0, 1))
          END VALUE
        FROM
        ( SELECT 'LOG_SEGMENTS_FREE' NAME FROM DUMMY UNION ALL
          SELECT 'LOG_SEGMENTS_NOT_FREE' FROM DUMMY
        ) C,
          M_LOG_SEGMENTS L
        GROUP By
          C.NAME,
          L.HOST
      )
    )
    UNION ALL
    ( SELECT
        'MAX_GC_HISTORY_COUNT',
        HOST,
        TO_VARCHAR(SUM(HISTORY_COUNT))
      FROM
        M_GARBAGE_COLLECTION_STATISTICS
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'GC_UNDO_FILE_COUNT',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_UNDO_CLEANUP_FILES
      WHERE
        TYPE != 'FREE'
    )
    UNION ALL
    ( SELECT
        'GC_UNDO_FILE_SIZE',
        '',
        TO_VARCHAR(TO_DECIMAL(SUM(IFNULL(RAW_SIZE, 0)) / 1024 / 1024 / 1024, 10, 2))
      FROM
        M_UNDO_CLEANUP_FILES
      WHERE
        TYPE != 'FREE'
    )
    UNION ALL
    ( SELECT
        C.NAME,
        SN.HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(MAP(C.NAME, 
          'SERVICE_SEND_INTRANODE', CASE WHEN SUM(SN.SEND_SIZE_INTRA) / 1024 / 1024 / 1024 < 10 THEN 
             999999 ELSE MAP(SUM(SN.SEND_DURATION_INTRA), 0, 0, SUM(SN.SEND_SIZE_INTRA) / 1024 / 1024 / ( MAP(SUM(SN.SEND_DURATION_INTRA), 0, 0, SUM(SN.SEND_DURATION_INTRA) / 1000 / 1000 ))) END,
          'SERVICE_SEND_INTERNODE', CASE WHEN SUM(SN.SEND_SIZE_INTER) / 1024 / 1024 / 1024 < 10 THEN 
             999999 ELSE MAP(SUM(SN.SEND_DURATION_INTER), 0, 0, SUM(SN.SEND_SIZE_INTER) / 1024 / 1024 / ( MAP(SUM(SN.SEND_DURATION_INTER), 0, 0, SUM(SN.SEND_DURATION_INTER) / 1000 / 1000 ))) END,
          'NETWORK_VOLUME_INTRANODE', SUM(MAP(SN.SECONDS, 0, 0, (SN.SEND_SIZE_INTRA + SN.RECEIVE_SIZE_INTRA) / SN.SECONDS)) / 1024 / 1024,
          'NETWORK_VOLUME_INTERNODE', SUM(MAP(SN.SECONDS, 0, 0, (SN.SEND_SIZE_INTER + SN.RECEIVE_SIZE_INTER) / SN.SECONDS)) / 1024 / 1024
        )), 10, 0))
      FROM
      ( SELECT 'SERVICE_SEND_INTRANODE' NAME FROM DUMMY UNION ALL
        SELECT 'SERVICE_SEND_INTERNODE'      FROM DUMMY UNION ALL
        SELECT 'NETWORK_VOLUME_INTRANODE'    FROM DUMMY UNION ALL
        SELECT 'NETWORK_VOLUME_INTERNODE'    FROM DUMMY
      ) C LEFT OUTER JOIN
      ( SELECT
          SECONDS_BETWEEN(S.START_TIME, CURRENT_TIMESTAMP) SECONDS,
          SENDER_HOST HOST,
          CASE WHEN SENDER_HOST = RECEIVER_HOST THEN SEND_SIZE        ELSE 0                END SEND_SIZE_INTRA,
          CASE WHEN SENDER_HOST = RECEIVER_HOST THEN 0                ELSE SEND_SIZE        END SEND_SIZE_INTER,
          CASE WHEN SENDER_HOST = RECEIVER_HOST THEN SEND_DURATION    ELSE 0                END SEND_DURATION_INTRA,
          CASE WHEN SENDER_HOST = RECEIVER_HOST THEN 0                ELSE SEND_DURATION    END SEND_DURATION_INTER,
          CASE WHEN SENDER_HOST = RECEIVER_HOST THEN RECEIVE_SIZE     ELSE 0                END RECEIVE_SIZE_INTRA,
          CASE WHEN SENDER_HOST = RECEIVER_HOST THEN 0                ELSE RECEIVE_SIZE     END RECEIVE_SIZE_INTER,
          CASE WHEN SENDER_HOST = RECEIVER_HOST THEN RECEIVE_DURATION ELSE 0                END RECEIVE_DURATION_INTRA,
          CASE WHEN SENDER_HOST = RECEIVER_HOST THEN 0                ELSE RECEIVE_DURATION END RECEIVE_DURATION_INTER
        FROM
          M_SERVICE_NETWORK_IO N,
          M_SERVICE_STATISTICS S
        WHERE
          S.HOST = N.SENDER_HOST AND
          S.PORT = N.SENDER_PORT
      ) SN ON
        1 = 1
      GROUP BY
        C.NAME,
        SN.HOST
    )
    UNION ALL
    ( SELECT
        'ST_POINT_TABLES',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        TEMP_TABLES T,
        TEMP_TABLE_COLUMNS C
      WHERE
        T.SCHEMA_NAME = C.SCHEMA_NAME AND
        T.TABLE_NAME = C.TABLE_NAME AND
        C.DATA_TYPE_NAME = 'ST_POINT' AND
        T.TABLE_TYPE = 'ROW' AND
        T.IS_USER_DEFINED_TYPE != 'TRUE'
    )
    UNION ALL
    ( SELECT
        C.NAME,
        '',
        CASE C.NAME
          WHEN 'STAT_SERVER_TABLE_SIZE'  THEN TO_VARCHAR(TO_DECIMAL(SUM(TABLE_SIZE) / 1024 / 1024 / 1024, 10, 2))
          WHEN 'STAT_SERVER_TABLE_SHARE' THEN TO_VARCHAR(TO_DECIMAL(MAP(M.GAL, 0, 0, SUM(TABLE_SIZE) / AVG(M.GAL) * 100), 10, 2))
        END
      FROM
      ( SELECT 'STAT_SERVER_TABLE_SIZE' NAME FROM DUMMY UNION ALL
        SELECT 'STAT_SERVER_TABLE_SHARE'    FROM DUMMY
      ) C,
      ( SELECT
          MAX(ALLOCATION_LIMIT) GAL
        FROM
          M_HOST_RESOURCE_UTILIZATION
      ) M,
      ( SELECT
          SCHEMA_NAME,
          TABLE_NAME,
          ALLOCATED_FIXED_PART_SIZE + ALLOCATED_VARIABLE_PART_SIZE TABLE_SIZE
        FROM
          TEMP_M_RS_TABLES 
        WHERE
          SCHEMA_NAME = '_SYS_STATISTICS'
        UNION ALL
        SELECT
          SCHEMA_NAME,
          TABLE_NAME,
          INDEX_SIZE TABLE_SIZE
        FROM
          M_RS_INDEXES
        WHERE
          SCHEMA_NAME = '_SYS_STATISTICS'
        UNION ALL
        SELECT
          SCHEMA_NAME,
          TABLE_NAME,
          MEMORY_SIZE_IN_TOTAL SIZE_BYTE
        FROM
          TEMP_M_CS_TABLES 	
        WHERE
          SCHEMA_NAME = '_SYS_STATISTICS'
      )
      GROUP BY
        M.GAL,
        C.NAME
    )
    UNION ALL
    ( SELECT
        'VARYING_MEMORY',
        '',
        CASE WHEN MAX(VALUE) - MIN(VALUE) <= 1024 * 1024 * 1024 THEN 'no' ELSE 'yes' END
      FROM
        M_HOST_INFORMATION
      WHERE
        KEY = 'mem_phys'
    )
    UNION ALL
    ( SELECT
        N.NAME,
        '',
        TO_VARCHAR(SUM(MAP(T.TABLE_NAME, NULL, 0, 1)))
      FROM
      ( SELECT 'QCM_TABLES' NAME, 'QCM%' PATTERN FROM DUMMY UNION ALL
        SELECT 'BPC_TABLES',      '`$BPC`$HC$%'    FROM DUMMY UNION ALL
        SELECT 'BPC_TABLES',      '`$BPC`$TMP%'    FROM DUMMY
      ) N LEFT OUTER JOIN
        TEMP_TABLES T ON
          T.TABLE_NAME LIKE N.PATTERN AND
          T.IS_TEMPORARY = 'FALSE'
      GROUP BY
        N.NAME
    )
    UNION ALL
    ( SELECT
        'NAMESERVER_SHARED_MEMORY',
        HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(MAP(SHARED_MEMORY_ALLOCATED_SIZE, 0, 0, SHARED_MEMORY_USED_SIZE / SHARED_MEMORY_ALLOCATED_SIZE * 100)), 10, 0))
      FROM
        M_SERVICE_MEMORY
      WHERE
        SERVICE_NAME = 'nameserver'
    )
    UNION ALL
    ( SELECT
        'DISK_DATA_FRAGMENTATION',
        IFNULL(HOST, ''),
        IFNULL(TO_VARCHAR(TO_DECIMAL(ROUND((1 - MAP(SUM(F.TOTAL_SIZE), 0, 0, SUM(F.USED_SIZE) / SUM(F.TOTAL_SIZE))) * 100), 10, 0)), '999999')
      FROM
        DUMMY D LEFT OUTER JOIN
        M_VOLUME_FILES F ON
          1 = 1
      WHERE
        F.FILE_TYPE = 'DATA'
      GROUP BY
        F.HOST
      HAVING
        SUM(F.USED_SIZE) / 1024 / 1024 / 1024 >= 5
    )
/*    UNION ALL
    ( SELECT
        'DISK_DATA_MEMORY_RATIO',
        M.HOST,
        TO_VARCHAR(TO_DECIMAL(MAP(M.MEM_SIZE_GB, 0, 0, ( DF.DISK_FREE_GB + DU.DATA_USED_GB ) / M.MEM_SIZE_GB), 10, 2))
      FROM
      ( SELECT HOST, MAX(VALUE) / 1024 / 1024 / 1024 MEM_SIZE_GB FROM M_MEMORY WHERE NAME = 'GLOBAL_ALLOCATION_LIMIT' GROUP BY HOST ) M,
      ( SELECT HOST, SUM(TOTAL_SIZE - USED_SIZE) / 1024 / 1024 / 1024 DISK_FREE_GB FROM M_DISKS WHERE USAGE_TYPE = 'DATA' GROUP BY HOST ) DF,
      ( SELECT HOST, SUM(TOTAL_SIZE) / 1024 / 1024 / 1024 DATA_USED_GB FROM M_VOLUME_FILES WHERE FILE_TYPE = 'DATA' GROUP BY HOST ) DU
      WHERE
        M.HOST = DU.HOST AND
        DU.HOST = DF.HOST
    ) */
    UNION ALL
    ( SELECT
        'EMBEDDED_STAT_SERVER_USED',
        '',
        MAP(IFNULL(SYSTEM_VALUE, IFNULL(HOST_VALUE, DEFAULT_VALUE)), 'true', 'yes', 'false', 'no', 'unknown')     
      FROM
      ( SELECT 
          MAX(MAP(LAYER_NAME, 'DEFAULT', VALUE)) DEFAULT_VALUE,
          MAX(MAP(LAYER_NAME, 'HOST',    VALUE)) HOST_VALUE,
          MAX(MAP(LAYER_NAME, 'SYSTEM',  VALUE, 'DATABASE', VALUE)) SYSTEM_VALUE
        FROM
          M_INIFILE_CONTENTS 
        WHERE 
          FILE_NAME IN ('indexserver.ini', 'nameserver.ini') AND
          SECTION = 'statisticsserver' AND
          KEY = 'active'
      )
    )
    UNION ALL
    ( SELECT
        'CATALOG_READ_GRANTED',
        '',
        MAP(COUNT(*), 0, 'no', 'yes')
      FROM
        EFFECTIVE_PRIVILEGES
      WHERE
        USER_NAME = CURRENT_USER AND
        PRIVILEGE = 'CATALOG READ'
    )
    UNION ALL
    ( SELECT
        NAME,
        '',
        CASE NAME
          WHEN 'TABLES_AUTOMERGE_DISABLED' THEN TO_VARCHAR(SUM(MAP(AUTO_MERGE_ON, 'FALSE', 1, 0)))
          WHEN 'TABLES_AUTOCOMP_DISABLED'  THEN TO_VARCHAR(SUM(MAP(AUTO_OPTIMIZE_COMPRESSION_ON, 'FALSE', 1, 0)))
        END
      FROM
      ( SELECT 'TABLES_AUTOMERGE_DISABLED' NAME FROM DUMMY UNION ALL
        SELECT 'TABLES_AUTOCOMP_DISABLED' NAME FROM DUMMY
      ) BI,
        TEMP_TABLES T
      WHERE
        ( TABLE_NAME NOT LIKE '/B%/%' OR TABLE_NAME LIKE '/BA1/%' ) AND
        TABLE_NAME NOT LIKE '0BW:BIA%' AND
        TABLE_NAME NOT LIKE '`$BPC`$HC$%' AND
        TABLE_NAME NOT LIKE '`$BPC`$TMP%' AND
        SUBSTR(TABLE_NAME, 1, 3) != 'TR_' AND            /* BW transformation tables */
        IS_COLUMN_TABLE = 'TRUE' AND
        IS_TEMPORARY = 'FALSE'
      GROUP BY
        NAME
    )
    UNION ALL
    ( SELECT
        'TABLES_PERSMERGE_DISABLED',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        TEMP_M_CS_TABLES
      WHERE
        PERSISTENT_MERGE = 'FALSE' 
    )
    UNION ALL
    ( SELECT
        'OLDEST_REPLICATION_SNAPSHOT',
        IFNULL(HOST, ''),
        TO_VARCHAR(TO_DECIMAL(SECONDS_BETWEEN(MIN(TIMESTAMP), CURRENT_TIMESTAMP) / 3600, 10, 2))
      FROM
        DUMMY LEFT OUTER JOIN
        M_SNAPSHOTS ON
          FOR_BACKUP = 'FALSE'
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'OLDEST_BACKUP_SNAPSHOT',
        IFNULL(HOST, ''),
        TO_VARCHAR(TO_DECIMAL(SECONDS_BETWEEN(MIN(TIMESTAMP), CURRENT_TIMESTAMP) / 86400, 10, 2))
      FROM
        DUMMY LEFT OUTER JOIN
        M_SNAPSHOTS ON
          FOR_BACKUP = 'TRUE'
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'SAVEPOINT_THROUGHPUT',
        HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(MAP(SUM(TOTAL_SIZE), 0, NULL, MAP(SUM(DURATION - CRITICAL_PHASE_WAIT_TIME), 0, 0, SUM(TOTAL_SIZE)) / SUM(DURATION - CRITICAL_PHASE_WAIT_TIME)) / 1024 / 1024 * 1000 * 1000), 10, 0))
      FROM
        M_SAVEPOINTS
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'LONG_RUNNING_SAVEPOINTS',
        IFNULL(HOST, '') HOST,
        TO_VARCHAR(IFNULL(LONG_SAVEPOINTS, 0))
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          HOST,
          COUNT(*) LONG_SAVEPOINTS
        FROM
          _SYS_STATISTICS.HOST_SAVEPOINTS
        WHERE
          SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) <= 86400 AND
          DURATION > 900000000
        GROUP BY
          HOST
      ) ON
        1 = 1
    )
    UNION ALL
    ( SELECT
        'LARGE_TABLES_NOT_COMPRESSED',
        '',
        TO_VARCHAR(COUNT(DISTINCT(CT.SCHEMA_NAME || CT.TABLE_NAME)))
      FROM
        TEMP_TABLES T,
        TEMP_M_CS_TABLES CT
      WHERE
        T.SCHEMA_NAME = CT.SCHEMA_NAME AND
        T.TABLE_NAME = CT.TABLE_NAME AND
        T.IS_TEMPORARY = 'FALSE' AND
        CT.LAST_COMPRESSED_RECORD_COUNT = 0 AND
        CT.RAW_RECORD_COUNT_IN_MAIN > 10000000
    )
    UNION ALL
    ( SELECT
        'TABLE_ALLOCATION_LIMIT_RATIO',
        H.HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(MAP(H.ALLOCATION_LIMIT, 0, 0, T.TABLE_MEMORY_BYTES / H.ALLOCATION_LIMIT) * 100), 10, 0))
      FROM
        M_HOST_RESOURCE_UTILIZATION H,
        ( SELECT 
            HOST,
            SUM(USED_MEMORY_SIZE) TABLE_MEMORY_BYTES
          FROM
            M_SERVICE_COMPONENT_MEMORY
          WHERE
            UPPER(COMPONENT) IN 
            ( 'ROW STORE TABLES',
              'ROW STORE TABLES + INDEXES', 
              'COLUMN STORE TABLES'
            )
          GROUP BY
            HOST
        ) T
      WHERE
        H.HOST = T.HOST
    )
    UNION ALL
    ( SELECT
        'HOST_SQL_PLAN_CACHE_ZERO',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        _SYS_STATISTICS.HOST_SQL_PLAN_CACHE
      WHERE
        EXECUTION_COUNT = 0
    )
    UNION ALL
    ( SELECT
        'HOST_OBJ_LOCK_UNKNOWN',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        _SYS_STATISTICS.HOST_OBJECT_LOCK_STATISTICS_BASE
      WHERE
        OBJECT_NAME = '(unknown)'
    )
    UNION ALL
    ( SELECT
        I.NAME,
        '',
        CASE I.NAME
          WHEN 'ABAP_BUFFER_LOADING' THEN
            TO_VARCHAR(TO_DECIMAL(SUM(CASE WHEN TO_VARCHAR(SUBSTR(STATEMENT_STRING, 1, 5000)) LIKE '%/* Buffer Loading */%' THEN TOTAL_EXECUTION_TIME ELSE 0 END) / 1000000 / 86400, 10, 2))
          WHEN 'FDA_WRITE' THEN
            TO_VARCHAR(TO_DECIMAL(SUM(CASE WHEN TO_VARCHAR(SUBSTR(STATEMENT_STRING, 1, 5000)) LIKE '%' || CHAR(63) || ' AS `"t_00`"%' THEN TOTAL_EXECUTION_TIME ELSE 0 END) / 1000000 / 86400, 10, 2))
        END
      FROM
      ( SELECT 'ABAP_BUFFER_LOADING' NAME FROM DUMMY UNION ALL
        SELECT 'FDA_WRITE'                FROM DUMMY
      ) I,
       _SYS_STATISTICS.HOST_SQL_PLAN_CACHE S
      WHERE
        SERVER_TIMESTAMP >= ADD_SECONDS(CURRENT_TIMESTAMP, -88000)
      GROUP BY
        I.NAME
    )
    UNION ALL
    ( SELECT
        'CPBTREE_LEAK',
        '',
        TO_VARCHAR(TO_DECIMAL(GREATEST(0, HEAP_SIZE_GB - INDEX_SIZE_GB), 10, 2))
      FROM
      ( SELECT
          ( SELECT IFNULL(SUM(INDEX_SIZE) / 1024 / 1024 / 1024, 0) FROM M_RS_INDEXES ) INDEX_SIZE_GB,
          ( SELECT IFNULL(SUM(EXCLUSIVE_SIZE_IN_USE) / 1024 / 1024 / 1024, 0) FROM M_HEAP_MEMORY WHERE CATEGORY like 'Pool/Row%/CpbTree' ) HEAP_SIZE_GB
        FROM
          DUMMY
      ) 
    )
    UNION ALL
    ( SELECT
        'ROW_STORE_TABLE_LEAK',
        '',
        TO_VARCHAR ( TO_DECIMAL ( GREATEST ( 0, ( GLOBAL_USED - SUM_INDIVIDUAL_USED ) / 1024 / 1024 / 1024 ), 10, 2 ) )
      FROM
      ( SELECT SUM(USED_SIZE) GLOBAL_USED FROM TEMP_M_RS_MEMORY WHERE CATEGORY = 'TABLE' ),
      ( SELECT SUM(ALLOCATED_FIXED_PART_SIZE + ALLOCATED_VARIABLE_PART_SIZE) SUM_INDIVIDUAL_USED FROM TEMP_M_RS_TABLES )
    )
    UNION ALL
    ( SELECT
        'SQL_PREPARATION_SHARE',
        HOST,
        TO_VARCHAR(TO_DECIMAL(MAP(ELAPSED_TIME, 0, 0, PREP_TIME / ELAPSED_TIME * 100), 10, 2))  
      FROM
      ( SELECT
          HOST,
          SUM(TOTAL_EXECUTION_TIME) + SUM(TOTAL_PREPARATION_TIME) ELAPSED_TIME,
          SUM(TOTAL_PREPARATION_TIME) PREP_TIME
        FROM
          TEMP_M_SQL_PLAN_CACHE
        GROUP BY
          HOST
      )
    )
    UNION ALL
    ( SELECT
        'SQL_CACHE_USED_BY_TABLE',
        HOST,
        TO_VARCHAR(MAP(HOST, NULL, 0, COUNT(*)))
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          HOST
        FROM
        ( SELECT
            SUM(PLAN_MEMORY_SIZE) OVER (PARTITION BY HOST) TOTAL_PLAN_MEMORY_SIZE,
            *
          FROM
            TEMP_M_SQL_PLAN_CACHE
        )
        GROUP BY
          HOST,
          TOTAL_PLAN_MEMORY_SIZE,
          ACCESSED_OBJECTS
        HAVING
          SUM(PLAN_MEMORY_SIZE) * 10 > TOTAL_PLAN_MEMORY_SIZE
      ) ON
          1 = 1
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'AVG_DB_REQUEST_TIME',
        '',
        TO_VARCHAR(TO_DECIMAL(MAP(SUM(EXECUTION_COUNT), 0, 0, SUM(TOTAL_EXECUTION_TIME) / SUM(EXECUTION_COUNT)) / 1000, 10, 2))
      FROM
        TEMP_M_SQL_PLAN_CACHE
    )
    UNION ALL
    ( SELECT
        'REPLICATION_ERROR',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_SERVICE_REPLICATION
      WHERE
        REPLICATION_STATUS = 'ERROR'
    )
    UNION ALL
    ( SELECT
        'REPLICATION_UNKNOWN',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_SERVICES S,
        M_SERVICE_REPLICATION SR
      WHERE
        S.HOST = SR.HOST AND
        S.PORT = SR.PORT AND
        S.COORDINATOR_TYPE != 'STANDBY' AND
        SR.REPLICATION_STATUS = 'UNKNOWN'
    )
    UNION ALL
    ( SELECT
        'OLD_LOG_POSITION',
        '',
        TO_VARCHAR(TO_DECIMAL(ROUND(MAX(LOG_POS_DIFF)), 10, 0))
      FROM
      ( SELECT
          L.HOST,
          L.PORT,
          GREATEST(0, (MAX(L.MAX_POSITION) - MAX(R.LAST_LOG_POSITION)) / 1024 / 16) LOG_POS_DIFF
        FROM
          M_LOG_SEGMENTS L,
          M_SERVICE_REPLICATION R
        WHERE
          L.HOST = R.HOST AND
          L.PORT = R.PORT
        GROUP BY
          L.HOST,
          L.PORT
      )
    )
    UNION ALL
    ( SELECT
        'LOG_SHIPPING_DELAY',
        '',
        IFNULL(TO_VARCHAR(MAX(SECONDS_BETWEEN(SHIPPED_LOG_POSITION_TIME, LAST_LOG_POSITION_TIME))), '0')
      FROM
        DUMMY LEFT OUTER JOIN
        M_SERVICE_REPLICATION ON
          1 = 1
    )
    UNION ALL
    ( SELECT
        'LOG_SHIPPING_ASYNC_BUFF_FILL',
        R.HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(MAP(P.BUFFER_SIZE, 0, 0, R.BUFFER_FILLED / P.BUFFER_SIZE * 100)), 10, 0))
      FROM
      ( SELECT
          IFNULL(TO_BIGINT(SYSTEM_VALUE), IFNULL(TO_BIGINT(HOST_VALUE), TO_BIGINT(DEFAULT_VALUE))) BUFFER_SIZE
        FROM
        ( SELECT 
            MAX(MAP(LAYER_NAME, 'DEFAULT', VALUE)) DEFAULT_VALUE,
            MAX(MAP(LAYER_NAME, 'HOST',    VALUE)) HOST_VALUE,
            MAX(MAP(LAYER_NAME, 'SYSTEM',  VALUE)) SYSTEM_VALUE
          FROM
            M_INIFILE_CONTENTS 
          WHERE 
            FILE_NAME = 'global.ini' AND
            SECTION = 'system_replication' AND
            KEY = 'logshipping_async_buffer_size'
        )
      ) P LEFT OUTER JOIN
      ( SELECT
          HOST,
          MAX( LAST_LOG_POSITION - SHIPPED_LOG_POSITION ) * 64 BUFFER_FILLED
        FROM
          M_SERVICE_REPLICATION
        GROUP BY
          HOST
      ) R ON
        1 = 1
      GROUP BY
        R.HOST,
        P.BUFFER_SIZE,
        R.BUFFER_FILLED
    )
    UNION ALL
    ( SELECT
        NAME,
        HOST,
        CASE NAME
          WHEN 'SYNC_LOG_SHIPPING_TIME_HIST' THEN TO_VARCHAR(TO_DECIMAL(MAX_LOG_SHIP_MS_PER_REQ, 10, 2))
          ELSE TO_VARCHAR(TO_DECIMAL(IFNULL(MAP(LOG_SHIP_CNT, 0, 0, LOG_SHIP_MS / LOG_SHIP_CNT), 0), 10, 2))
        END
      FROM
      ( SELECT
          C.NAME,
          R.HOST,
          SUM(CASE WHEN SECONDS_BETWEEN(R.SERVER_TIMESTAMP, M.SERVER_TIMESTAMP) <= C.SECONDS THEN R.LOG_SHIP_CNT ELSE 0 END) LOG_SHIP_CNT,
          SUM(CASE WHEN SECONDS_BETWEEN(R.SERVER_TIMESTAMP, M.SERVER_TIMESTAMP) <= C.SECONDS THEN R.LOG_SHIP_MS ELSE 0 END) LOG_SHIP_MS,
          MAX(MAP(LOG_SHIP_CNT, 0, 0, LOG_SHIP_MS / LOG_SHIP_CNT)) MAX_LOG_SHIP_MS_PER_REQ
        FROM
        ( SELECT 'SYNC_LOG_SHIPPING_TIME_CURR' NAME, 1 SECONDS FROM DUMMY UNION ALL
          SELECT 'SYNC_LOG_SHIPPING_TIME_REC',       86400     FROM DUMMY UNION ALL
          SELECT 'SYNC_LOG_SHIPPING_TIME_HIST',      99999999  FROM DUMMY
        ) C,
        ( SELECT
            MAX(SERVER_TIMESTAMP) SERVER_TIMESTAMP,
            HOST
          FROM
            _SYS_STATISTICS.HOST_SERVICE_REPLICATION
          GROUP BY HOST
        ) M,
        ( SELECT
            SERVER_TIMESTAMP,
            HOST,
            LOG_SHIP_CNT,
            LOG_SHIP_MS
          FROM
          ( SELECT
              SERVER_TIMESTAMP,
              HOST,
              ( SUM(SHIPPED_LOG_BUFFERS_COUNT)      - LAG(SUM(SHIPPED_LOG_BUFFERS_COUNT), 1)      OVER (PARTITION BY HOST ORDER BY SERVER_TIMESTAMP))        LOG_SHIP_CNT,
              ( SUM(SHIPPED_LOG_BUFFERS_DURATION)   - LAG(SUM(SHIPPED_LOG_BUFFERS_DURATION), 1)   OVER (PARTITION BY HOST ORDER BY SERVER_TIMESTAMP)) / 1000 LOG_SHIP_MS
            FROM
              _SYS_STATISTICS.HOST_SERVICE_REPLICATION
            WHERE
              REPLICATION_MODE LIKE 'SYNC%'
            GROUP BY
              SERVER_TIMESTAMP,
              HOST
          )
          WHERE
            LOG_SHIP_CNT >= 0
        ) R
        GROUP BY
          C.NAME,
          R.HOST
      )
    )
    UNION ALL
    ( SELECT
        'ASYNC_BUFFER_FULL_LAST_DAY',
        R.HOST,
        TO_VARCHAR(BUFF_FULL)
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          SUM(BUFF_FULL) BUFF_FULL,
          HOST
        FROM
        ( SELECT
            SERVER_TIMESTAMP,
            HOST,
            ASYNC_BUFFER_FULL_COUNT - LAG(ASYNC_BUFFER_FULL_COUNT, 1) OVER (PARTITION BY HOST, PORT ORDER BY SERVER_TIMESTAMP) BUFF_FULL
          FROM
            _SYS_STATISTICS.HOST_SERVICE_REPLICATION
          WHERE
            SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) <= 88000
        )
        WHERE
          BUFF_FULL >= 0
        GROUP BY
          HOST
      ) R ON
        1 = 1
    )
    UNION ALL
    ( SELECT
        'LAST_SPECIAL_DUMP',
        '',
        TO_VARCHAR(TO_DECIMAL(SECONDS_BETWEEN(MAX(FILE_MTIME), CURRENT_TIMESTAMP) / 86400, 10, 2))
      FROM
        M_TRACEFILES
      WHERE
        FILE_NAME LIKE '%.crashdump.%.trc' OR
        FILE_NAME LIKE '%.emergencydump.%.trc' OR
        FILE_NAME LIKE '%.rtedump.%.trc'
    )
    UNION ALL
    ( SELECT
       'SQL_CACHE_LONG_INLIST',
       '',
       TO_VARCHAR(TO_DECIMAL(MAP(TOTAL_SIZE, 0, 0, INLIST_SIZE / TOTAL_SIZE * 100), 10, 2))
      FROM
        ( SELECT 
            SUM(PLAN_MEMORY_SIZE) INLIST_SIZE
          FROM
            TEMP_M_SQL_PLAN_CACHE
          WHERE
            TO_VARCHAR(SUBSTR(STATEMENT_STRING, 1, 5000)) LIKE '%' || RPAD('', 396, CHAR(63) || CHAR(32) || ',' || CHAR(32)) || '%' OR
            LOCATE(SUBSTR(STATEMENT_STRING, 1, 5000), '(' || CHAR(63) || ',' || CHAR(32) || CHAR(63), 1, 100) != 0
        ),
        ( SELECT SUM(CACHED_PLAN_SIZE) TOTAL_SIZE FROM TEMP_M_SQL_PLAN_CACHE_OVERVIEW )
    )
    UNION ALL
    ( SELECT
        C.NAME,
        SC.HOST,
        CASE C.NAME
          WHEN 'SQL_CACHE_DUPLICATE_HASHES' THEN 
            TO_VARCHAR(TO_DECIMAL(MAP(SC.TOTAL_ENTRIES, 0, 0, 100 - SC.DISTINCT_HASHES / SC.TOTAL_ENTRIES * 100), 10, 2)) 
          WHEN 'SQL_CACHE_SESSION_LOCAL' THEN 
            TO_VARCHAR(TO_DECIMAL(MAP(SC.TOTAL_ENTRIES, 0, 0, SC.SESSION_LOCAL_ENTRIES / SC.TOTAL_ENTRIES * 100), 10, 2))
          WHEN 'SQL_CACHE_PINNED' THEN
            TO_VARCHAR(TO_DECIMAL(MAP(SC.TOTAL_PLAN_SIZE, 0, 0, SC.REFERENCED_PLAN_SIZE / SC.TOTAL_PLAN_SIZE * 100), 10, 2))
        END
      FROM
      ( SELECT 'SQL_CACHE_DUPLICATE_HASHES' NAME FROM DUMMY UNION ALL
        SELECT 'SQL_CACHE_SESSION_LOCAL' FROM DUMMY UNION ALL
        SELECT 'SQL_CACHE_PINNED' FROM DUMMY
      ) C,
      ( SELECT
          HOST,
          COUNT(*) TOTAL_ENTRIES,
          COUNT(DISTINCT(STATEMENT_HASH)) DISTINCT_HASHES,
          SUM(MAP(PLAN_SHARING_TYPE, 'SESSION LOCAL', 1, 0)) SESSION_LOCAL_ENTRIES,
          SUM(PLAN_MEMORY_SIZE) TOTAL_PLAN_SIZE,
          SUM(MAP(REFERENCE_COUNT, 0, 0, PLAN_MEMORY_SIZE)) REFERENCED_PLAN_SIZE
        FROM
          TEMP_M_SQL_PLAN_CACHE
        GROUP BY
          HOST
      ) SC
    )
    UNION ALL
    ( SELECT
        'UDIV_OVERHEAD',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        TEMP_M_CS_TABLES
      WHERE
        MAX_UDIV >= 10000000 AND
        MAX_UDIV >= ( RAW_RECORD_COUNT_IN_MAIN + RAW_RECORD_COUNT_IN_DELTA ) * 2
    )
    UNION ALL
    ( SELECT
        'REP_PARAMETER_DEVIATION',
        '',
        TO_VARCHAR(COUNT(DISTINCT(SUBSTR_AFTER(ALERT_DETAILS, 'parameter mismatch'))))
      FROM
        _SYS_STATISTICS.STATISTICS_ALERTS
      WHERE
        ALERT_ID IN ( 21, 79 ) AND
        SECONDS_BETWEEN(ALERT_TIMESTAMP, CURRENT_TIMESTAMP) <= 7200 AND
        ALERT_DETAILS LIKE '%parameter mismatch%'
    )
    UNION ALL
    ( SELECT
        'SDI_SUBSCRIPTION_EXCEPTIONS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        REMOTE_SUBSCRIPTION_EXCEPTIONS
      WHERE
        SECONDS_BETWEEN(EXCEPTION_TIME, CURRENT_TIMESTAMP) <= 86400
    )
    UNION ALL
    ( SELECT
        'EMPTY_TABLE_PLACEMENT',
        '',
        CASE WHEN B.IS_BW_USED = 'Yes' AND P.NUM_ENTRIES = 0 THEN 'yes' ELSE 'no' END
      FROM
        ( SELECT
            COUNT(*) NUM_ENTRIES 
          FROM 
            TABLE_PLACEMENT
          WHERE
            GROUP_TYPE LIKE 'sap.bw.%'
        ) P,
        ( SELECT
            CASE WHEN IFNULL(SUM(RECORD_COUNT), 0) <= 10 THEN 'No' ELSE 'Yes' END IS_BW_USED
          FROM
            TEMP_M_CS_TABLES
          WHERE
            TABLE_NAME = '/BI0/SREQUID'
        ) B
    )
    UNION ALL
    ( SELECT
        'BW_SCALEOUT_TWO_NODES',
        '',
        CASE WHEN IS_BW_USED = 'Yes' AND D.NUM_HOSTS = 2 THEN 'yes' ELSE 'no' END
      FROM
      ( SELECT
          COUNT(*) NUM_HOSTS
        FROM
          M_LANDSCAPE_HOST_CONFIGURATION
        WHERE
          HOST_ACTUAL_ROLES != 'STANDBY'
      ) D,
      ( SELECT
          CASE WHEN IFNULL(SUM(RECORD_COUNT), 0) <= 10 THEN 'No' ELSE 'Yes' END IS_BW_USED
        FROM
          M_CS_TABLES
        WHERE
          TABLE_NAME = '/BI0/SREQUID'
      ) B
    )
    UNION ALL
    ( SELECT /* Starting with SAP HANA Rev. 1.00.122.03 only PREFIXED is critical, SPARSE will no longer be reported */
        'INDEXES_ON_SPARSE_PREFIXED',
        '',
        TO_CHAR(COUNT(DISTINCT(IC.SCHEMA_NAME || IC.TABLE_NAME || IC.INDEX_NAME)))
      FROM
      ( SELECT
          SCHEMA_NAME,
          TABLE_NAME,
          INDEX_NAME,
          COLUMN_NAME
        FROM
        ( SELECT
            SCHEMA_NAME,
            TABLE_NAME,
            INDEX_NAME,
            COLUMN_NAME,
            CONSTRAINT,
            COUNT(*) OVER (PARTITION BY SCHEMA_NAME, TABLE_NAME, INDEX_NAME) NUM_COLUMNS
          FROM
            INDEX_COLUMNS
        )
        WHERE
          NUM_COLUMNS = 1 OR ( CONSTRAINT IN ('PRIMARY KEY', 'UNIQUE', 'NOT NULL UNIQUE' ) )
      ) IC,
      ( SELECT
          SCHEMA_NAME,
          TABLE_NAME,
          COLUMN_NAME
        FROM
          M_CS_COLUMNS,
        ( SELECT
            SUBSTR(VALUE, 1, LOCATE(VALUE, '.', 1, 2) - 1) VERSION,
            TO_NUMBER(SUBSTR(VALUE, LOCATE(VALUE, '.', 1, 2) + 1, LOCATE(VALUE, '.', 1, 3) - LOCATE(VALUE, '.', 1, 2) - 1) ||
            MAP(LOCATE(VALUE, '.', 1, 4), 0, '', '.' || SUBSTR(VALUE, LOCATE(VALUE, '.', 1, 3) + 1, LOCATE(VALUE, '.', 1, 4) - LOCATE(VALUE, '.', 1, 3) - 1 ))) REVISION 
          FROM 
            M_SYSTEM_OVERVIEW 
          WHERE 
            SECTION = 'System' AND 
            NAME = 'Version' 
        )
        WHERE
          COUNT > 1000000 AND
          ( COMPRESSION_TYPE = 'PREFIXED' OR
            COMPRESSION_TYPE = 'SPARSE' AND VERSION = '1.00' AND TO_NUMBER(REVISION) <= 122.02
          )
      ) C
      WHERE
        IC.SCHEMA_NAME = C.SCHEMA_NAME AND
        IC.TABLE_NAME = C.TABLE_NAME AND
        IC.COLUMN_NAME = C.COLUMN_NAME AND NOT EXISTS
        ( SELECT
            *
          FROM
            INDEXES IR,
            INDEX_COLUMNS ICR
          WHERE
            IR.SCHEMA_NAME = ICR.SCHEMA_NAME AND
            IR.TABLE_NAME = ICR.TABLE_NAME AND
            IR.INDEX_NAME = ICR.INDEX_NAME AND
            IR.INDEX_TYPE = 'FULLTEXT' AND
            C.SCHEMA_NAME = ICR.SCHEMA_NAME AND
            C.TABLE_NAME = ICR.TABLE_NAME AND
            C.COLUMN_NAME = ICR.COLUMN_NAME
        )
    )
    UNION ALL
    ( SELECT
        'MISSING_INVERTED_INDEXES',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        TEMP_M_CS_ALL_COLUMNS C,
        ( SELECT IC.*, COUNT(*) OVER (PARTITION BY SCHEMA_NAME, TABLE_NAME, INDEX_NAME) NUM_COLUMNS FROM INDEX_COLUMNS IC ) IC
      WHERE
        C.SCHEMA_NAME = IC.SCHEMA_NAME AND
        C.TABLE_NAME = IC.TABLE_NAME AND
        C.COLUMN_NAME = IC.COLUMN_NAME AND
        C.LOADED = 'TRUE' AND
        C.INDEX_TYPE = 'NONE' AND
        ( IC.CONSTRAINT IN ('PRIMARY KEY', 'UNIQUE', 'NOT NULL UNIQUE' ) OR
          IC.NUM_COLUMNS = 1
        ) AND NOT EXISTS
        ( SELECT
            *
          FROM
            TEMP_INDEXES IR,
            INDEX_COLUMNS ICR
          WHERE
            IR.SCHEMA_NAME = ICR.SCHEMA_NAME AND
            IR.TABLE_NAME = ICR.TABLE_NAME AND
            IR.INDEX_NAME = ICR.INDEX_NAME AND
            IR.INDEX_TYPE LIKE 'FULLTEXT%' AND
            C.SCHEMA_NAME = ICR.SCHEMA_NAME AND
            C.TABLE_NAME = ICR.TABLE_NAME AND
            C.COLUMN_NAME = ICR.COLUMN_NAME
        )
    )
    UNION ALL
    ( SELECT
        'LARGE_COLUMNS_NOT_COMPRESSED',
        '',
        TO_VARCHAR(COUNT(DISTINCT(C.SCHEMA_NAME || C.TABLE_NAME || C.COLUMN_NAME)))
      FROM
        M_CS_COLUMNS C,
        TABLE_COLUMNS TC
      WHERE
        C.SCHEMA_NAME = TC.SCHEMA_NAME AND
        C.TABLE_NAME = TC.TABLE_NAME AND
        C.COLUMN_NAME = TC.COLUMN_NAME AND
        C.COUNT > 10000000 AND
        C.DISTINCT_COUNT <= COUNT * 0.05 AND
        C.COMPRESSION_TYPE = 'DEFAULT' AND
        TC.GENERATION_TYPE IS NULL AND
        C.MEMORY_SIZE_IN_TOTAL >= 500 * 1024 * 1024
    )
    UNION ALL
    ( SELECT
        'MAX_CURR_SERV_ALL_LIMIT_USED',
        HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(MAX(MAP(EFFECTIVE_ALLOCATION_LIMIT, 0, 0, TOTAL_MEMORY_USED_SIZE / EFFECTIVE_ALLOCATION_LIMIT * 100))), 10, 0))
      FROM
        M_SERVICE_MEMORY
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'MAX_HIST_SERV_ALL_LIMIT_USED',
        IFNULL(HOST, ''),
        IFNULL(TO_VARCHAR(HOURS), '999999')
      FROM
        DUMMY BI LEFT OUTER JOIN
      ( SELECT
          HOST,
          TO_DECIMAL(ROUND(MIN(SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) / 3600)), 10, 0) HOURS
        FROM
          _SYS_STATISTICS.HOST_SERVICE_MEMORY
        WHERE
          TOTAL_MEMORY_USED_SIZE > EFFECTIVE_ALLOCATION_LIMIT * 0.8
        GROUP BY
          HOST
      ) R ON
        1 = 1
    )
    UNION ALL
    ( SELECT
        'AUDIT_LOG_SIZE',
        '',
        TO_VARCHAR(TO_DECIMAL(SUM(DISK_SIZE) / 1024 / 1024 / 1024, 10, 2))
      FROM
        TEMP_M_TABLE_PERSISTENCE_STATISTICS
      WHERE
        SCHEMA_NAME = '_SYS_AUDIT' AND
        TABLE_NAME = 'CS_AUDIT_LOG_'
    )
    UNION ALL
    ( SELECT
        'LARGE_SWAP_SPACE',
        HOST,
        TO_VARCHAR(TO_DECIMAL(VALUE / 1024 / 1024 / 1024, 10, 2))
      FROM
        M_HOST_INFORMATION
      WHERE
        KEY = 'mem_swap' 
    )
    UNION ALL
    ( SELECT
        'TEMPORARY_TABLES',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_TEMPORARY_TABLES 
    )
    UNION ALL
    ( SELECT
        C.NAME,
        '',
        TO_VARCHAR(MAP(MAX(T.TABLE_NAME), NULL, 0, COUNT(*)))
      FROM
      ( SELECT 'MANY_RECORDS' NAME            FROM DUMMY UNION ALL
        SELECT 'SID_TABLES_WITH_MANY_RECORDS' FROM DUMMY UNION ALL
        SELECT 'MANY_RECORDS_HISTORY'         FROM DUMMY UNION ALL
        SELECT 'MANY_RECORDS_UDIV'            FROM DUMMY
      ) C LEFT OUTER JOIN
        TEMP_M_CS_TABLES T ON
        ( C.NAME = 'MANY_RECORDS' AND T.RECORD_COUNT > 1500000000 AND T.TABLE_NAME NOT LIKE '/B%/S%' ) OR
        ( C.NAME = 'SID_TABLES_WITH_MANY_RECORDS' AND T.RECORD_COUNT > 1500000000 AND T.TABLE_NAME LIKE '/B%/S%' ) OR
        ( C.NAME = 'MANY_RECORDS_HISTORY' AND T.RAW_RECORD_COUNT_IN_HISTORY_MAIN + T.RAW_RECORD_COUNT_IN_HISTORY_DELTA > 1500000000 ) OR
        ( C.NAME = 'MANY_RECORDS_UDIV' AND T.MAX_UDIV > 1500000000 AND T.RECORD_COUNT < 1500000000 )
      GROUP BY
        C.NAME
    )
    UNION ALL
    ( SELECT
        C.NAME,
        '',
        TO_VARCHAR(MAP(MAX(T.TABLE_NAME), NULL, 0, COUNT(*)))
      FROM
      ( SELECT 'NUM_PARTITIONED_SID_TABLES' NAME FROM DUMMY UNION ALL
        SELECT 'NUM_PART_SPECIAL_TABLES'         FROM DUMMY
      ) C LEFT OUTER JOIN
      ( SELECT
          SCHEMA_NAME,
          TABLE_NAME,
          SUM(RECORD_COUNT) RECORD_COUNT
        FROM
          TEMP_M_CS_TABLES
        WHERE
          TABLE_NAME LIKE '/B%/%'
        GROUP BY
          SCHEMA_NAME,
          TABLE_NAME
        HAVING
          COUNT(*) > 1
      ) T ON
      ( C.NAME = 'NUM_PARTITIONED_SID_TABLES' AND T.TABLE_NAME LIKE '/B%/S%' ) OR
      ( C.NAME = 'NUM_PART_SPECIAL_TABLES' AND T.RECORD_COUNT <= 1500000000 AND
        ( TABLE_NAME LIKE '/B%/H%' OR TABLE_NAME LIKE '/B%/I%' OR TABLE_NAME LIKE '/B%/J%' OR
          TABLE_NAME LIKE '/B%/K%' OR TABLE_NAME LIKE '/B%/P%' OR TABLE_NAME LIKE '/B%/Q%' OR
          TABLE_NAME LIKE '/B%/T%' OR TABLE_NAME LIKE '/B%/X%' OR TABLE_NAME LIKE '/B%/Y%' 
        )
      )
      GROUP BY
        C.NAME
    )
    UNION ALL
    ( SELECT
        'TABLES_WRONG_SERVICE',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        TEMP_M_CS_TABLES T,
        M_SERVICES S,
      ( SELECT
          MAP(COUNT(*), 0, 'No', 'Yes') IS_SYSTEMDB
        FROM
          M_DATABASE D1,
          M_DATABASES D2
        WHERE
          D1.DATABASE_NAME = D2.DATABASE_NAME AND
          D2.DESCRIPTION LIKE 'SystemDB%'
      ) M
      WHERE
        S.PORT = T.PORT AND
        ( M.IS_SYSTEMDB = 'No' AND S.SERVICE_NAME != 'indexserver' OR
          M.IS_SYSTEMDB = 'Yes' AND S.SERVICE_NAME NOT IN ( 'indexserver', 'nameserver')
        )
    )
    UNION ALL
    ( SELECT
        'TABLES_WITH_EMPTY_LOCATION',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_TABLE_LOCATIONS
      WHERE
        LOCATION IS NULL OR LOCATION = ''
    )
    UNION ALL
    ( SELECT
        'UNKNOWN_HARDWARE',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_HOST_INFORMATION
      WHERE
        KEY IN ( 'hw_model', 'hw_manufacturer' ) AND
        UPPER(VALUE) = '<UNKNOWN>'
    )
    UNION ALL
    ( SELECT
        'OS_RELEASE',
        HOST,
        CASE OS_PPMS_NAME
          WHEN 'LINUX_PPC64' THEN
            CASE 
              WHEN OS_NAME = 'SUSE Linux Enterprise Server 11.4'           AND VERSION = 1.00                                           THEN 'yes' 
              WHEN OS_NAME = 'SUSE Linux Enterprise Server 12.1'           AND VERSION = 2.00                                           THEN 'yes' 
              ELSE 'no (' || OS_NAME || ')'
            END
          ELSE
            CASE 
              WHEN OS_NAME = 'SUSE Linux Enterprise Server 11.1'           AND VERSION = 1.00 AND REVISION <  100                                           THEN 'yes'
              WHEN OS_NAME = 'SUSE Linux Enterprise Server 11.2'           AND VERSION = 1.00 AND REVISION <  120                                           THEN 'yes'
              WHEN OS_NAME = 'SUSE Linux Enterprise Server 11.3'           AND VERSION = 1.00 AND REVISION <  130                                           THEN 'yes'
              WHEN OS_NAME = 'SUSE Linux Enterprise Server 11.4'           AND VERSION = 1.00 AND REVISION >= 100                                           THEN 'yes'
              WHEN OS_NAME = 'SUSE Linux Enterprise Server 12.0'           AND VERSION = 1.00 AND REVISION >= 100                                           THEN 'yes'
              WHEN OS_NAME = 'SUSE Linux Enterprise Server 12.1'           AND ( VERSION = 1.00 AND REVISION >= 120 OR VERSION = 2.00 )                     THEN 'yes'
              WHEN OS_NAME = 'SUSE Linux Enterprise Server 12.2'           AND ( VERSION = 1.00 AND REVISION >= 120 OR VERSION = 2.00 AND REVISION >= 10 )  THEN 'yes'
              WHEN OS_NAME = 'Red Hat Enterprise Linux Server release 6.5' AND VERSION = 1.00 AND REVISION <  120                                           THEN 'yes'
              WHEN OS_NAME = 'Red Hat Enterprise Linux Server release 6.6' AND VERSION = 1.00 AND REVISION <  120                                           THEN 'yes'
              WHEN OS_NAME = 'Red Hat Enterprise Linux Server release 6.7' AND VERSION = 1.00 AND REVISION >= 110                                           THEN 'yes'
              WHEN OS_NAME = 'Red Hat Enterprise Linux Server release 7.2' AND ( VERSION = 1.00 AND REVISION >= 120 OR VERSION = 2.00 )                     THEN 'yes'
              WHEN OS_NAME = 'Red Hat Enterprise Linux Server release 7.3' AND ( VERSION = 1.00 AND REVISION >= 120 OR VERSION = 2.00 AND REVISION >=  21 ) THEN 'yes'
              WHEN OS_NAME LIKE 'Linux 2.6.32-431%'                        AND VERSION = 1.00 AND REVISION <  120                                           THEN 'yes'
              WHEN OS_NAME LIKE 'Linux 2.6.32-504%'                        AND VERSION = 1.00 AND REVISION <  120                                           THEN 'yes'
              WHEN OS_NAME LIKE 'Linux 2.6.32-573%'                        AND VERSION = 1.00 AND REVISION >= 110                                           THEN 'yes'
              WHEN OS_NAME LIKE 'Linux 3.10.0-327%'                        AND ( VERSION = 1.00 AND REVISION >= 120 OR VERSION = 2.00 )                     THEN 'yes'
              ELSE 'no (' || OS_NAME || ')'
          END
        END
      FROM
      ( SELECT
          HOST,
          MAX(MAP(KEY, 'os_name', VALUE)) OS_NAME,
          MAX(MAP(KEY, 'os_ppms_name', VALUE)) OS_PPMS_NAME
        FROM
          M_HOST_INFORMATION
        GROUP BY
          HOST
      ),
      ( SELECT
          TO_NUMBER(SUBSTR(VALUE, 1, 4)) VERSION,
          TO_NUMBER(LTRIM(CASE
            WHEN LOCATE(VALUE, '.', 1, 4) - LOCATE(VALUE, '.', 1, 3) = 3 THEN
              SUBSTR(VALUE, LOCATE(VALUE, '.', 1, 2) + 1, LOCATE(VALUE, '.', 1, 4) - LOCATE(VALUE, '.', 1, 2) - 1)
            ELSE 
              SUBSTR(VALUE, LOCATE(VALUE, '.', 1, 2) + 1, LOCATE(VALUE, '.', 1, 3) - LOCATE(VALUE, '.', 1, 2) - 1) || '.00'
          END, '0')) REVISION
        FROM 
          M_SYSTEM_OVERVIEW 
        WHERE 
          SECTION = 'System' AND 
          NAME = 'Version' 
      )
    )
    UNION ALL
    ( SELECT
        'OS_KERNEL_BIGMEM',
        IFNULL(HOST, ''),
        MAP(HOST, NULL, 'no', 'yes')
      FROM
        DUMMY D LEFT OUTER JOIN
      ( SELECT
          HOST
        FROM
        ( SELECT
            HOST,
            MAX(MAP(KEY, 'os_name', VALUE)) OS_NAME,
            MAX(MAP(KEY, 'os_ppms_name', VALUE)) OS_PPMS_NAME,
            MAX(MAP(KEY, 'os_kernel_version', VALUE)) OS_KERNEL_VERSION
          FROM
            M_HOST_INFORMATION
          GROUP BY
            HOST
        )
        WHERE
          OS_NAME LIKE 'SUSE Linux Enterprise Server 11%' AND
          OS_PPMS_NAME = 'LINUX_PPC64' AND
          OS_KERNEL_VERSION NOT LIKE '%bigmem%'
      ) ON
        1 = 1
    )
    UNION ALL
    ( SELECT /* Needs to be able to extract the first up to three numbers after the first `"-`" (e.g. 0, 47, 71) from versions like 
                3.0.101-0.47.71.7930.0.PTF-default, 3.0.101-0.47-bigsmp or 3.0.101-0.47.71-default or 
                3.0.101-63-default / 3.0.101-65.1.9526.1.PTF-default (SLES 11.4, 12.1) / 3.12.62-60.62-default,
                3.10.0-327.el7.x86_64, 3.10.0-327.44.2.el7.x86_64 (same also with `"el6`")
                `".1`" is usually redundant, so 88.1 is identical to 88  */
        'OS_KERNEL_VERSION',
        HOST,
        CASE 
          WHEN OS_NAME = 'SUSE Linux Enterprise Server 11.2' AND NFS_USED = 'X' AND ( KV_2 < 7   OR KV_2 = 7   AND KV_3 < 23 )                                          THEN 'no' || CHAR(32) || '(' || KV || ' instead of >= 0.7.23)'
          WHEN OS_NAME = 'SUSE Linux Enterprise Server 11.3' AND NFS_USED = 'X' AND ( KV_2 < 40 )                                                                       THEN 'no' || CHAR(32) || '(' || KV || ' instead of >= 0.40)'
          WHEN OS_NAME = 'SUSE Linux Enterprise Server 11.3' AND XFS_USED = 'X' AND ( KV_2 < 47  OR KV_2 = 47  AND KV_3 < 71 )                                          THEN 'no' || CHAR(32) || '(' || KV || ' instead of >= 0.47.71)'
          WHEN OS_NAME = 'SUSE Linux Enterprise Server 11.4'                    AND ( KV_1 < 108 OR KV_1 = 108 AND KV_2 < 7  )                                          THEN 'no' || CHAR(32) || '(' || KV || ' instead of >= 0.108.7)'
          WHEN OS_NAME = 'SUSE Linux Enterprise Server 12'                      AND ( KV_1 < 52  OR KV_1 = 52  AND KV_2 < 72 )                                          THEN 'no' || CHAR(32) || '(' || KV || ' instead of >= 52.72)'
          WHEN OS_NAME = 'SUSE Linux Enterprise Server 12.1'                    AND ( KV_1 < 60  OR KV_1 = 60  AND KV_2 < 64 OR KV_1 = 60 AND KV_2 = 64 AND KV_3 < 40 ) THEN 'no' || CHAR(32) || '(' || KV || ' instead of >= 60.64.40)'
          WHEN OS_NAME = 'SUSE Linux Enterprise Server 12.2'                    AND ( KV_1 < 92  OR KV_1 = 92  AND KV_2 < 35 )                                          THEN 'no' || CHAR(32) || '(' || KV || ' instead of >= 92.35)'
          ELSE 'yes'
        END 
      FROM
      ( SELECT
          HOST,
          OS_NAME,
          OS_PPMS_NAME,
          TO_NUMBER(CASE 
            WHEN LOCATE(KV, '.', 1, 1) = 0 THEN KV 
            ELSE SUBSTR(KV, 1, LOCATE(KV, '.', 1, 1) - 1)
          END )  KV_1,
          TO_NUMBER(CASE 
            WHEN LOCATE(KV, '.', 1, 1) = 0 THEN 1 
            WHEN LOCATE(KV, '.', 1, 2) = 0 THEN SUBSTR(KV, LOCATE(KV, '.', 1, 1) + 1)
            ELSE SUBSTR(KV, LOCATE(KV, '.', 1, 1) + 1, LOCATE(KV, '.', 1, 2) - LOCATE(KV, '.', 1, 1) - 1)
          END ) KV_2,
          TO_NUMBER(CASE 
            WHEN LOCATE(KV, '.', 1, 2) = 0 THEN 1 
            WHEN LOCATE(KV, '.', 1, 3) = 0 THEN SUBSTR(KV, LOCATE(KV, '.', 1, 2) + 1)
            ELSE SUBSTR(KV, LOCATE(KV, '.', 1, 2) + 1, LOCATE(KV, '.', 1, 3) - LOCATE(KV, '.', 1, 2) - 1)
          END ) KV_3,
          KV_ORIG KV,
          NFS_USED,
          XFS_USED
        FROM
        ( SELECT
            O.HOST,
            O.OS_NAME,
            O.OS_PPMS_NAME,
            CASE
              WHEN KV LIKE '%.el_.%' THEN
                SUBSTR(KV, LOCATE(KV, '-', 1, 1) + 1, LEAST(LOCATE(KV, '.el', 1, 1), MAP(LOCATE(KV, '.', 1, 5), 0, 999, LOCATE(KV, '.', 1, 5))) - LOCATE(KV, '-', 1, 1) - 1)
              ELSE
                SUBSTR(KV, LOCATE(KV, '-', 1, 1) + 1, LEAST(LOCATE(KV, '-', 1, 2),   MAP(LOCATE(KV, '.', 1, 5), 0, 999, LOCATE(KV, '.', 1, 5))) - LOCATE(KV, '-', 1, 1) - 1)
            END KV,
            O.KV KV_ORIG,
            D.NFS_USED,
            D.XFS_USED
          FROM
          ( SELECT
              HOST,
              MAX(MAP(KEY, 'os_name', VALUE)) OS_NAME,
              MAX(MAP(KEY, 'os_ppms_name', VALUE)) OS_PPMS_NAME,
              MAX(MAP(KEY, 'os_kernel_version', VALUE)) KV
            FROM
              M_HOST_INFORMATION
            GROUP BY
              HOST
          ) O,
          ( SELECT 
              CASE SUM(MAP(FILESYSTEM_TYPE, 'nfs', 1, 0)) WHEN 0 THEN ' ' ELSE 'X' END NFS_USED,
              CASE SUM(MAP(FILESYSTEM_TYPE, 'xfs', 1, 0)) WHEN 0 THEN ' ' ELSE 'X' END XFS_USED 
            FROM 
              M_DISKS 
          ) D
        )
      )
    )
    UNION ALL
    ( SELECT
        'SERVICE_LOG_BACKUPS',
        '',
        TO_VARCHAR(MAX(LOG_BACKUPS))
      FROM
      ( SELECT
          CF.HOST,
          CF.SERVICE_TYPE_NAME,
          COUNT(*) LOG_BACKUPS
        FROM
          TEMP_M_BACKUP_CATALOG C,
          TEMP_M_BACKUP_CATALOG_FILES CF
        WHERE
          C.BACKUP_ID = CF.BACKUP_ID AND
          C.ENTRY_TYPE_NAME = 'log backup' AND
          C.STATE_NAME = 'successful' AND
          C.SYS_START_TIME >= ADD_SECONDS(CURRENT_TIMESTAMP, -86400) AND
          CF.SOURCE_TYPE_NAME = 'volume'
        GROUP BY
          CF.HOST,
          CF.SERVICE_TYPE_NAME
      )
    )
    UNION ALL
    ( SELECT
        'OPEN_CONNECTIONS',
        HOST,
        TO_VARCHAR(TO_DECIMAL(MAP(MAX_CONNECTIONS, 0, 0, NUM_CONNECTIONS / MAX_CONNECTIONS * 100), 10, 2))
      FROM
      ( SELECT
          C.HOST,
          C.NUM_CONNECTIONS,
          IFNULL(P.SYSTEM_VALUE, IFNULL(P.HOST_VALUE, IFNULL(P.DEFAULT_VALUE, 65536))) MAX_CONNECTIONS
        FROM
        ( SELECT
            HOST,
            COUNT(*) NUM_CONNECTIONS
          FROM
            M_CONNECTIONS
          WHERE
            CONNECTION_TYPE IN ('Local', 'Remote')
          GROUP BY
            HOST
        ) C LEFT OUTER JOIN
        ( SELECT 
            HOST,
            MAX(MAP(LAYER_NAME, 'DEFAULT', VALUE)) DEFAULT_VALUE,
            MAX(MAP(LAYER_NAME, 'HOST',    VALUE)) HOST_VALUE,
            MAX(MAP(LAYER_NAME, 'SYSTEM',  VALUE)) SYSTEM_VALUE
          FROM
            M_INIFILE_CONTENTS 
          WHERE 
            FILE_NAME = 'indexserver.ini' AND
            SECTION = 'session' AND
            KEY = 'maximum_connections'
          GROUP BY
            HOST
        ) P ON
          C.HOST = P.HOST
      )
    )
    UNION ALL
    ( SELECT
        'OPEN_TRANSACTIONS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        TEMP_M_TRANSACTIONS
    )
    UNION ALL
    ( SELECT
        'SERVER_TIME_VARIATION',
        '',
        TO_VARCHAR(SECONDS_BETWEEN(MIN(SYS_TIMESTAMP), MAX(SYS_TIMESTAMP)))
      FROM
        M_HOST_RESOURCE_UTILIZATION
    )
    UNION ALL
    ( SELECT
        'CALCENGINE_CACHE_UTILIZATION',
        '',
        TO_VARCHAR(TO_DECIMAL(ROUND(MAP(P.CONF_SIZE_KB, 0, 100, C.USED_SIZE_KB / P.CONF_SIZE_KB * 100)), 10, 0)) USED_PCT
      FROM
      ( SELECT
          IFNULL(MAX(USED_SIZE_BYTE) / 1024, 0) USED_SIZE_KB
        FROM
        ( SELECT
            SUM(MEMORY_SIZE) USED_SIZE_BYTE
          FROM
            M_CE_CALCSCENARIOS
          WHERE 
            IS_PERSISTENT = 'TRUE'
          GROUP BY
            HOST,
            PORT
        )
      ) C,
      ( SELECT
          MAP(VALUE, NULL, 1048576, VALUE) CONF_SIZE_KB
        FROM
          DUMMY LEFT OUTER JOIN
          M_INIFILE_CONTENTS ON
            FILE_NAME = 'indexserver.ini' AND
            SECTION = 'calcengine' AND
            KEY = 'max_cache_size_kb'
      ) P
    )
    UNION ALL
    ( SELECT
        'SQL_CACHE_FREQUENT_HASH',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
      ( SELECT
          STATEMENT_HASH
        FROM
          TEMP_M_SQL_PLAN_CACHE
        WHERE
        ( STATEMENT_HASH IS NOT NULL AND STATEMENT_HASH != '' )
        GROUP BY
          HOST,
          STATEMENT_HASH
        HAVING
          COUNT(*) > 100
      )
    )
    UNION ALL
    ( SELECT
        'INVALID_PROCEDURES',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        PROCEDURES
      WHERE
        IS_VALID = 'FALSE'
    )
    UNION ALL
    ( SELECT
        'PARKED_JOBWORKERS',
        '',
        TO_VARCHAR(TO_DECIMAL(MAX(MAP(TOTAL_WORKER_COUNT, 0, 0, PARKED_WORKER_COUNT / TOTAL_WORKER_COUNT)), 10, 2))
      FROM
        M_JOBEXECUTORS
    )
    UNION ALL
    ( SELECT
        'QUEUED_JOBWORKERS',
        '',
        TO_VARCHAR(MAX(QUEUED_JOBS))
      FROM
      ( SELECT
          SUM(QUEUED_WAITING_JOB_COUNT) QUEUED_JOBS
        FROM
          M_JOBEXECUTORS
        GROUP BY
         HOST
      )
    )
    UNION ALL
    ( SELECT
        C.NAME,
        '',
        CASE C.NAME
          WHEN 'TRANSACTIONS_LARGE_UNDO' THEN TO_VARCHAR(TO_DECIMAL(MAX(UNDO_LOG_AMOUNT / 1024 / 1024), 10, 2))
          WHEN 'TRANSACTIONS_LARGE_REDO' THEN TO_VARCHAR(TO_DECIMAL(MAX(REDO_LOG_AMOUNT / 1024 / 1024), 10, 2))
        END
      FROM
      ( SELECT 'TRANSACTIONS_LARGE_UNDO' NAME FROM DUMMY UNION ALL
        SELECT 'TRANSACTIONS_LARGE_REDO' FROM DUMMY
      ) C,
        TEMP_M_TRANSACTIONS T
      GROUP BY
        C.NAME
    )
    UNION ALL
    ( SELECT
        'LONG_RUNNING_JOB',
        '',
        TO_VARCHAR(IFNULL(MAX(GREATEST( 0, SECONDS_BETWEEN(START_TIME, CURRENT_TIMESTAMP))), 0))
      FROM
        M_JOB_PROGRESS
    )
    UNION ALL
    ( SELECT
        'TOPOLOGY_DAEMON_INCONSISTENT',
        S.HOST,
        TO_VARCHAR(SUM(MAP(S.ACTIVE_STATUS, 'NO', 1, 0)))
      FROM
        M_SERVICES D,
        M_SERVICES S
      WHERE
        D.SERVICE_NAME = 'daemon' AND
        D.ACTIVE_STATUS = 'YES' AND
        S.HOST = D.HOST
      GROUP BY
        S.HOST
    )
    UNION ALL
    ( SELECT
        'TOPOLOGY_ROLES_INCONSISTENT',
        '',
        MAP(C.CONF_WORKERS, A.ACT_WORKERS, 'no', 'yes')
      FROM
      ( SELECT COUNT(*) CONF_WORKERS FROM M_LANDSCAPE_HOST_CONFIGURATION WHERE INDEXSERVER_CONFIG_ROLE = 'WORKER' ) C,
      ( SELECT COUNT(*) ACT_WORKERS  FROM M_LANDSCAPE_HOST_CONFIGURATION WHERE INDEXSERVER_ACTUAL_ROLE IN ('MASTER', 'SLAVE' ) ) A
    )
    UNION ALL
    ( SELECT
        'NOLOGGING_TABLES',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        TEMP_TABLES
      WHERE
        IS_LOGGED = 'FALSE'
    )
    UNION ALL
    ( SELECT
        'ABAP_POOL_CLUSTER_TABLES',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        TEMP_M_CS_TABLES
      WHERE
        TABLE_NAME IN ('CDCLS', 'EDI40', 'KAPOL', 'KOCLU', 'RFBLG' ) AND
        RECORD_COUNT > 0
    )
/*  UNION ALL
    ( SELECT
        'SR_LOGREPLAY',
        '',
        CASE WHEN R.SR_USED = 'Yes' AND S.OPERATION_MODE = 'delta_datashipping' THEN 'no' ELSE 'yes' END       
      FROM
      ( SELECT
          MAP(COUNT(*), 0, 'No', 'Yes') SR_USED
        FROM
          M_SERVICE_REPLICATION
        WHERE
          REPLICATION_MODE != '' 
      ) R,
      ( SELECT MAX(OPERATION_MODE) OPERATION_MODE FROM M_SYSTEM_REPLICATION ) S
    ) */
    UNION ALL
    ( SELECT
        I.NAME,
        '',
        TO_VARCHAR(SUM(CASE I.NAME
          WHEN 'TRANS_LOCKS_GLOBAL' THEN 1
          WHEN 'OLD_TRANS_LOCKS'    THEN CASE WHEN R.ACQUIRED_TIME != '' AND SECONDS_BETWEEN(R.ACQUIRED_TIME, CURRENT_TIMESTAMP) >= 86400 THEN 1 ELSE 0 END
        END))
      FROM
      ( SELECT 'TRANS_LOCKS_GLOBAL' NAME FROM DUMMY UNION ALL
        SELECT 'OLD_TRANS_LOCKS' FROM DUMMY
      ) I LEFT OUTER JOIN
      ( SELECT ACQUIRED_TIME FROM M_OBJECT_LOCKS UNION ALL
        SELECT ACQUIRED_TIME FROM M_RECORD_LOCKS WHERE TABLE_NAME LIKE '%'
      ) R ON
        1 = 1
      GROUP BY
        I.NAME
    )
    UNION ALL
    ( SELECT
        'MULTI_COLUMN_HASH_PART',
        '',
        TO_VARCHAR(SUM(MAP(LOCATE(HASH_SPEC, ','), 0, 0, 1)))
      FROM
      ( SELECT 
          TABLE_NAME,
          SUBSTR(PARTITION_SPEC, 1, MAP(LOCATE(PARTITION_SPEC, ';', 1), 0, 9999, LOCATE(PARTITION_SPEC, ';', 1)) - 1) HASH_SPEC
        FROM 
          TEMP_TABLES 
        WHERE 
          PARTITION_SPEC LIKE 'HASH%' AND
          TABLE_NAME NOT LIKE '/B%/%' AND
          SUBSTR(TABLE_NAME, 1, 3) != 'TR_'             /* BW transformation tables */
      )
    )
    UNION ALL
    ( SELECT
        'CONNECTIONS_CANCEL_REQUESTED',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_CONNECTIONS
      WHERE
        CONNECTION_STATUS LIKE '%CANCEL REQUESTED%' AND
        CREATED_BY != 'Dynamic Range Partitioning'
    )
    UNION ALL
    ( SELECT
        'TWO_COLUMN_MANDT_INDEXES',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
      ( SELECT
          SCHEMA_NAME,
          INDEX_NAME,
          SUM(MAP(COLUMN_NAME, 'MANDT', 1, 'MANDANT', 1, 'CLIENT', 1, 'DCLIENT', 1, 0)) NUM_CLIENT_COLUMNS,
          COUNT(*) NUM_COLUMNS
        FROM
          INDEX_COLUMNS
        WHERE
          CONSTRAINT NOT LIKE '%UNIQUE%' AND CONSTRAINT NOT LIKE '%PRIMARY KEY%'
        GROUP BY
          SCHEMA_NAME,
          INDEX_NAME
      )
      WHERE
        NUM_CLIENT_COLUMNS > 0 AND
        NUM_COLUMNS = 2
    )
    UNION ALL
    ( SELECT
        'UNSUPPORTED_FILESYSTEMS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_DISKS
      WHERE
        FILESYSTEM_TYPE LIKE 'UNSUPPORTED%'
    )
    UNION ALL
    ( SELECT
        'DPSERVER_ON_SLAVE_NODES',
        '', 
        TO_VARCHAR(COUNT(*))
      FROM
      ( SELECT DISTINCT HOST FROM M_SERVICES WHERE SERVICE_NAME = 'dpserver' ) S1,
      ( SELECT DISTINCT HOST FROM M_SERVICES WHERE SERVICE_NAME = 'indexserver' AND COORDINATOR_TYPE != 'MASTER' ) S2
      WHERE
        S1.HOST = S2.HOST 
    )
    UNION ALL
    ( SELECT
        'TEMPORARY_BW_TABLES',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        TEMP_TABLES
      WHERE
        TABLE_NAME LIKE '/BI0/0%'
    )
    UNION ALL
    ( SELECT
        'HDBSTUDIO_CONNECTIONS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_SESSION_CONTEXT
      WHERE
        KEY = 'APPLICATION' AND
        VALUE = 'HDBStudio'
    )
    UNION ALL
    ( SELECT
        'OUTDATED_HDBSTUDIO_VERSION',
        '',
        TO_VARCHAR(SUM( CASE 
          WHEN D.VERSION = '1' AND D.SUBVERSION = '12' AND SC2.VALUE < '2.3' THEN 1
          WHEN D.VERSION = '1' AND D.SUBVERSION = '11' AND SC2.VALUE < '2.2' THEN 1
          WHEN D.VERSION = '1' AND D.SUBVERSION = '10' AND SC2.VALUE < '2.1' THEN 1
          WHEN D.VERSION = '1' AND D.SUBVERSION = '90' AND SC2.VALUE < '2.0' THEN 1
          ELSE 0 END ))
      FROM
        ( SELECT SUBSTR(VERSION, 1, 1) VERSION, SUBSTR(VERSION, 6, 2) SUBVERSION FROM M_DATABASE ) D,
        M_SESSION_CONTEXT SC1,
        M_SESSION_CONTEXT SC2
      WHERE
        SC1.HOST = SC2.HOST AND
        SC1.PORT = SC2.PORT AND
        SC1.CONNECTION_ID = SC2.CONNECTION_ID AND
        SC1.KEY = 'APPLICATION' AND
        SC1.VALUE = 'HDBStudio' AND
        SC2.KEY = 'APPLICATIONVERSION' 
    )
    UNION ALL
    ( SELECT
        'SHADOW_PAGE_SIZE',
        HOST, 
        TO_VARCHAR(TO_DECIMAL(MAX(SIZE_GB), 10, 2))
      FROM
      ( SELECT
          HOST,
          SUM(PAGE_SIZE * SHADOW_BLOCK_COUNT) / 1024 / 1024 / 1024 SIZE_GB
        FROM
          _SYS_STATISTICS.HOST_DATA_VOLUME_PAGE_STATISTICS
        WHERE
          SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) <= 86400
        GROUP BY
          HOST,
          SERVER_TIMESTAMP
      )
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'DATASHIPPING_LOGRETENTION',
        '',
        CASE WHEN OPERATION_MODE = 'delta_datashipping' AND LOG_RETENTION = 'on' THEN 'yes' ELSE 'no' END
      FROM
      ( SELECT MAX(OPERATION_MODE) OPERATION_MODE FROM M_SYSTEM_REPLICATION ) R,
      ( SELECT
          MAX(MAP(KEY, 'enable_log_retention', IFNULL(SYSTEM_VALUE, IFNULL(HOST_VALUE, IFNULL(DEFAULT_VALUE, KEY))))) LOG_RETENTION
        FROM
        ( SELECT
            KEY,
            MAX(MAP(LAYER_NAME, 'DEFAULT', VALUE)) DEFAULT_VALUE,
            MAX(MAP(LAYER_NAME, 'HOST',    VALUE)) HOST_VALUE,
            MAX(MAP(LAYER_NAME, 'SYSTEM',  VALUE)) SYSTEM_VALUE
          FROM
            M_INIFILE_CONTENTS 
          WHERE 
            FILE_NAME = 'global.ini' AND
            SECTION = 'system_replication' AND
            KEY = 'enable_log_retention'
          GROUP BY
            KEY
        )
      )
    )
    UNION ALL
    ( SELECT
        'REPLICATION_SAVEPOINT_DELAY',
        '',
        TO_VARCHAR(TO_DECIMAL(MAX(SECONDS_BETWEEN(R.SHIPPED_SAVEPOINT_START_TIME, CURRENT_TIMESTAMP) / 3600), 10, 2))
      FROM
        M_SERVICE_REPLICATION R,
        M_SYSTEM_REPLICATION S
      WHERE
        R.SITE_ID = S.SITE_ID AND
        S.OPERATION_MODE = 'delta_datashipping'
    )
    UNION ALL
    ( SELECT
        'HOST_NAME_RESOLUTION',
        '',
        TO_CHAR(COUNT(*))
      FROM
        M_INIFILE_CONTENTS
      WHERE
        SECTION = 'internal_hostname_resolution' AND
        KEY NOT LIKE '%.%.%.%' AND
        KEY != ''
    )
    UNION ALL
    ( SELECT /* Intel: V3 - Haswell, V4 - Broadwell, V5 or Platinum - Skylake, V6 - Kaby Lake */
        'WRONG_CPU_TYPE',
        '',
        TO_CHAR(SUM(CASE
          WHEN OS_PPMS_NAME = 'LINUX_X86_64' AND CPU_MODEL NOT LIKE '% V3 @%' AND CPU_MODEL NOT LIKE '% V4 @%' AND CPU_MODEL NOT LIKE '%Platinum%' AND 
            CPU_MODEL NOT LIKE '% V5 @%' AND CPU_MODEL NOT LIKE '% V6 @%' THEN 1
          WHEN OS_PPMS_NAME = 'LINUX_PPC64' AND CPU_MODEL NOT LIKE 'POWER8%' THEN 1
          ELSE 0
        END))
      FROM
      ( SELECT
          UPPER(VALUE) CPU_MODEL
        FROM
          M_HOST_INFORMATION
        WHERE
          KEY = 'cpu_model'
      ),
      ( SELECT
          UPPER(VALUE) OS_PPMS_NAME
        FROM
          M_HOST_INFORMATION
        WHERE
          KEY = 'os_ppms_name'
      )
    )
    UNION ALL
    ( SELECT
        'INVERTED_HASH_ON_BW_TABLE',
        '',
        TO_VARCHAR(COUNT(DISTINCT(TABLE_NAME)))
      FROM
        TEMP_INDEXES
      WHERE
        INDEX_TYPE = 'INVERTED HASH' AND
        TABLE_NAME LIKE '/B%/%'
    )
    UNION ALL
    ( SELECT
        'INVERTED_HASH_ON_PART_TABLE',
        '',
        TO_VARCHAR(COUNT(DISTINCT(I.TABLE_NAME)))
      FROM
        TEMP_INDEXES I,
        TEMP_TABLES T
      WHERE
        I.SCHEMA_NAME = T.SCHEMA_NAME AND
        I.TABLE_NAME = T.TABLE_NAME AND
        I.INDEX_TYPE = 'INVERTED HASH' AND
        TO_VARCHAR(T.PARTITION_SPEC) != CHAR(63)
    )
    UNION ALL
    ( SELECT
        'LAST_CTC_RUN',
        '',
        IFNULL(TO_VARCHAR(TO_DECIMAL(MAX(SECONDS) / 86400, 10, 2)), 'never')
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          SECONDS_BETWEEN(LATEST_START_SERVERTIME, CURRENT_TIMESTAMP) SECONDS
        FROM
          _SYS_STATISTICS.STATISTICS_SCHEDULE
        WHERE
          ID = 5047
        UNION ALL
        SELECT
          SECONDS_BETWEEN(MAX(SERVER_TIMESTAMP), CURRENT_TIMESTAMP) SECONDS
        FROM
          _SYS_STATISTICS.HOST_SERVICE_THREAD_SAMPLES
        WHERE
          UPPER(THREAD_DETAIL) LIKE '%CALL%CHECK_TABLE_CONSISTENCY%' || CHAR(39) || 'CHECK' || CHAR(39) || '%NULL%NULL%' OR
          ( APPLICATION_SOURCE LIKE 'CL_SQL_STATEMENT==============CP%' AND THREAD_DETAIL LIKE 'CALL `"CHECK_TABLE_CONSISTENCY`"(' || CHAR(32) || CHAR(32) || CHAR(63) || CHAR(32) || ',' || 
            CHAR(32) || CHAR(32) || CHAR(63) || CHAR(32) || ',' || CHAR(32) || CHAR(32) || CHAR(63) || CHAR(32) || CHAR(32) || ')%' )
      ) ON
        1 = 1
    )
    UNION ALL
    ( SELECT
        'ADDRESS_SPACE_UTILIZATION',
        M.HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(M.SIZE_GB / L.LIMIT_GB * 100), 10, 0))
      FROM
      ( SELECT
          HOST,
          SUM(EXCLUSIVE_SIZE_IN_USE) / 1024 / 1024 / 1024 SIZE_GB
        FROM
          M_HEAP_MEMORY
        WHERE
          CATEGORY = 'AllocateOnlyAllocator-unlimited/FLA-UL<24592,1>/MemoryMapLevel3Nodes'
        GROUP BY
          HOST
      ) M,
      ( SELECT
          HOST,
          CASE 
            WHEN OS_PPMS_NAME = 'LINUX_X86_64'                                      THEN 768
            WHEN OS_PPMS_NAME = 'LINUX_PPC64' AND OS_KERNEL_VERSION LIKE '%bigmem%' THEN 384
            ELSE                                                                         96
          END LIMIT_GB
        FROM
        ( SELECT
            HOST,
            MAX(MAP(KEY, 'os_name', VALUE)) OS_NAME,
            MAX(MAP(KEY, 'os_ppms_name', VALUE)) OS_PPMS_NAME,
            MAX(MAP(KEY, 'os_kernel_version', VALUE)) OS_KERNEL_VERSION
          FROM
            M_HOST_INFORMATION
          GROUP BY
            HOST
        )
      ) L
      WHERE
        M.HOST = L.HOST
    )
    UNION ALL
    ( SELECT
        'METADATA_DEP_INCONSISTENT',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        OBJECT_DEPENDENCIES D
      WHERE
        NOT EXISTS
        ( SELECT
            *
          FROM
            OBJECTS O
          WHERE
            O.SCHEMA_NAME = D.BASE_SCHEMA_NAME AND
            O.OBJECT_NAME = D.BASE_OBJECT_NAME AND
            O.OBJECT_TYPE = D.BASE_OBJECT_TYPE 
        ) OR
        NOT EXISTS
        ( SELECT
            *
          FROM
            OBJECTS O
          WHERE
            O.SCHEMA_NAME = D.DEPENDENT_SCHEMA_NAME AND
            O.OBJECT_NAME = D.DEPENDENT_OBJECT_NAME AND
            O.OBJECT_TYPE = D.DEPENDENT_OBJECT_TYPE
        )
    )
    UNION ALL
    ( SELECT
        'LAST_HDBCONS_EXECUTION',
        '',
        IFNULL(TO_VARCHAR(TO_DECIMAL(ROUND(SECONDS_BETWEEN(MAX(TIMESTAMP), CURRENT_TIMESTAMP) / 3600), 10, 0)), 'never')
      FROM
      ( SELECT
          MAX(TIMESTAMP) TIMESTAMP
        FROM
          M_SERVICE_THREAD_SAMPLES
        WHERE
          THREAD_METHOD IN ('core/ngdb_console', 'ngdb_console', 'ServerJob') OR
          UPPER(THREAD_DETAIL) LIKE '%CALL%MANAGEMENT_CONSOLE_PROC%'
        UNION ALL
        SELECT
          MAX(TIMESTAMP) TIMESTAMP
        FROM
          _SYS_STATISTICS.HOST_SERVICE_THREAD_SAMPLES
        WHERE
          THREAD_METHOD IN ('core/ngdb_console', 'ngdb_console', 'ServerJob') OR
          UPPER(THREAD_DETAIL) LIKE '%CALL%MANAGEMENT_CONSOLE_PROC%'
      )
    )
    UNION ALL
    ( SELECT
        'CONNECTION_USER_EXPIRATION',
        '',
        IFNULL(U.USER_NAME, 'none')
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          U.USER_NAME
        FROM
          USERS U,
        ( SELECT
            USER_NAME
          FROM
            M_CONNECTIONS
          WHERE
            CONNECTION_ID > 0
          GROUP BY
            USER_NAME
          HAVING
            COUNT(*) >= 20
        ) C
        WHERE
          U.USER_NAME = C.USER_NAME AND
          U.USER_NAME != 'SYSTEM' AND
          ( U.VALID_UNTIL IS NOT NULL OR
            U.PASSWORD_CHANGE_TIME IS NOT NULL )
      ) U ON
        1 = 1
    )
    UNION ALL
    ( SELECT
        'LAST_TRACEFILE_MODIFICATION',
        T.HOST,
        TO_VARCHAR(GREATEST(0, SECONDS_BETWEEN(MAX(FILE_MTIME), CURRENT_TIMESTAMP)))
      FROM
        M_TRACEFILES T,
        M_SERVICES S
      WHERE
        T.HOST = S.HOST AND
        FILE_NAME LIKE '%.trc' AND
        S.COORDINATOR_TYPE != 'STANDBY' AND
        S.SERVICE_NAME IN ('nameserver', 'indexserver')
      GROUP BY
        T.HOST
    )
    UNION ALL
    ( SELECT
        'SUSPENDED_SQL',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_ACTIVE_STATEMENTS
      WHERE
        STATEMENT_STATUS = 'SUSPENDED'
    )
    UNION ALL
    ( SELECT
        'SNAP_GROWTH_LAST_DAY',
        '',
        MAP(TH.DISK_SIZE, NULL, 'n/a', TO_VARCHAR(TO_DECIMAL(GREATEST(0, (TC.DISK_SIZE - TH.DISK_SIZE) / 1024 / 1024 / 1024), 10, 2)))
      FROM
        DUMMY D LEFT OUTER JOIN
      ( SELECT
          MAX(DISK_SIZE) DISK_SIZE
        FROM
          TEMP_M_TABLE_PERSISTENCE_STATISTICS TC
        WHERE
          TABLE_NAME = 'SNAP'
      ) TC ON
        1 = 1 LEFT OUTER JOIN
      ( SELECT TOP 1
          MAX(TA.DISK_SIZE) DISK_SIZE
        FROM
          _SYS_STATISTICS.GLOBAL_TABLE_PERSISTENCE_STATISTICS TA,
        ( SELECT
            MAX(SERVER_TIMESTAMP) SERVER_TIMESTAMP
          FROM
            _SYS_STATISTICS.GLOBAL_TABLE_PERSISTENCE_STATISTICS
          WHERE
            TABLE_NAME = 'SNAP' AND
            SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) > 88000
        ) TI
        WHERE
          TA.TABLE_NAME = 'SNAP' AND
          TA.SERVER_TIMESTAMP = TI.SERVER_TIMESTAMP
      ) TH ON
        1 = 1
    )
    UNION ALL
    ( SELECT
        'CUR_HIGH_DURATION_THREADS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_SERVICE_THREADS
      WHERE
        IS_ACTIVE = 'TRUE' AND
        THREAD_TYPE = 'SqlExecutor' AND
        DURATION / 1000 > 60
    )
    UNION ALL
    ( SELECT
        'CUR_APP_USER_THREADS',
        '',
        IFNULL(T.APPLICATION_USER_NAME || CHAR(32) || '(' || T.NUM_THREADS || CHAR(32) || 'threads)', 'none')
      FROM
        DUMMY D LEFT OUTER JOIN
      ( SELECT
          APPLICATION_USER_NAME,
          COUNT(*) NUM_THREADS
        FROM
          M_SERVICE_THREADS
        WHERE
          IS_ACTIVE = 'TRUE' AND
          CONNECTION_ID != CURRENT_CONNECTION AND
          APPLICATION_USER_NAME != ''
        GROUP BY
          APPLICATION_USER_NAME
        HAVING
          COUNT(*) > 30
      ) T ON
        1 = 1
    )
    UNION ALL
    ( SELECT
        'REC_POPULAR_THREAD_METHODS',
        '',
        IFNULL(T.THREAD_METHOD || CHAR(32) || '(' || TO_DECIMAL(T.ACTIVE_THREADS, 10, 2) || CHAR(32) || 'threads)', 'none')
      FROM
        DUMMY D LEFT OUTER JOIN
      ( SELECT
          THREAD_METHOD,
          COUNT(*) / 3600 ACTIVE_THREADS
        FROM
          M_SERVICE_THREAD_SAMPLES
        WHERE
          SECONDS_BETWEEN(TIMESTAMP, CURRENT_TIMESTAMP) <= 3600 AND
          THREAD_METHOD NOT IN ('ExecutePrepared', 'PlanExecutor calc', CHAR(63))
        GROUP BY
          THREAD_METHOD
        HAVING
          COUNT(*) > 3600 * 3
      ) T ON
        1 = 1
    )
    UNION ALL
    ( SELECT
        'ACTIVE_DML_AUDIT_POLICIES',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        AUDIT_POLICIES
      WHERE
        EVENT_ACTION IN ('DELETE', 'INSERT', 'SELECT', 'UPDATE', 'UPSERT') AND
        IS_AUDIT_POLICY_ACTIVE = 'TRUE'
    )
    UNION ALL
    ( SELECT
        'DEVIATING_MAX_CONCURRENCY',
        '',
        CASE 
          WHEN P.CONF_MAX_CONCURRENCY =  0 AND H.INT_MAX_CONCURRENCY != T.CPU_THREADS          THEN 'yes' || CHAR(32) || '(' || H.INT_MAX_CONCURRENCY || CHAR(32) || 'instead of' || CHAR(32) || T.CPU_THREADS          || ')'
          WHEN P.CONF_MAX_CONCURRENCY != 0 AND H.INT_MAX_CONCURRENCY != P.CONF_MAX_CONCURRENCY THEN 'yes' || CHAR(32) || '(' || H.INT_MAX_CONCURRENCY || CHAR(32) || 'instead of' || CHAR(32) || P.CONF_MAX_CONCURRENCY || ')'
          ELSE 'no'
        END
      FROM
      ( SELECT HOST, GREATEST(VALUE, 4) CPU_THREADS FROM M_HOST_INFORMATION WHERE KEY = 'cpu_threads' ) T,
      ( SELECT HOST, MAX(MAX_CONCURRENCY) INT_MAX_CONCURRENCY FROM M_JOBEXECUTORS GROUP BY HOST ) H,
      ( SELECT
          IFNULL(HOST_VALUE, IFNULL(SYSTEM_VALUE, DEFAULT_VALUE)) CONF_MAX_CONCURRENCY
        FROM
        ( SELECT
            MIN(MAP(LAYER_NAME, 'DEFAULT', VALUE)) DEFAULT_VALUE,
            MIN(MAP(LAYER_NAME, 'HOST',    VALUE)) HOST_VALUE,
            MIN(MAP(LAYER_NAME, 'SYSTEM',  VALUE, 'DATABASE', VALUE)) SYSTEM_VALUE
          FROM
            M_INIFILE_CONTENTS 
          WHERE 
            SECTION = 'execution' AND
            KEY = 'max_concurrency'
        )
      ) P
      WHERE
        T.HOST = H.HOST
    )
/* Available as of Revision 60 */
    UNION ALL
    ( SELECT
        'LONGEST_CURRENT_SQL',
        '',
        TO_VARCHAR(MAX(TO_DECIMAL(SECONDS_BETWEEN(LAST_EXECUTED_TIME, CURRENT_TIMESTAMP) / 3600, 10, 2)))
      FROM
        M_ACTIVE_STATEMENTS
      WHERE
        LAST_EXECUTED_TIME IS NOT NULL
    )
    UNION ALL
    ( SELECT 
        'TRIGGER_READ_RATIO',
        HOST,
        IFNULL(TO_VARCHAR(TO_DECIMAL(MAX(TRIGGER_READ_RATIO), 5, 2)), '999999')
      FROM
        DUMMY LEFT OUTER JOIN
        M_VOLUME_IO_TOTAL_STATISTICS
      ON
        TYPE = 'DATA' AND
        TOTAL_READ_SIZE > 1024 * 1024 * 1024
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT 
        'TRIGGER_WRITE_RATIO',
        HOST,
        IFNULL(TO_VARCHAR(TO_DECIMAL(MAX(TRIGGER_WRITE_RATIO), 5, 2)), '999999')
      FROM
        DUMMY LEFT OUTER JOIN
        M_VOLUME_IO_TOTAL_STATISTICS
      ON
        TYPE IN ( 'DATA', 'LOG' ) AND
        TOTAL_WRITE_SIZE > 1024 * 1024 * 1024
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        C.NAME,
        I.HOST,
        CASE
          WHEN C.NAME = 'FAILED_IO_READS' THEN TO_VARCHAR(SUM(TOTAL_FAILED_READS))
          WHEN C.NAME = 'FAILED_IO_WRITES' THEN TO_VARCHAR(SUM(TOTAL_FAILED_WRITES))
        END
      FROM
      ( SELECT 'FAILED_IO_READS' NAME FROM DUMMY UNION ALL
        SELECT 'FAILED_IO_WRITES' FROM DUMMY 
      ) C,
        M_VOLUME_IO_TOTAL_STATISTICS_RESET I
      GROUP BY
        C.NAME,
        I.HOST
    )
    UNION ALL
    ( SELECT
        C.NAME || '_' || I.TYPE,
        I.HOST,
        CASE
          WHEN C.NAME = 'MIN_IO_READ_THROUGHPUT'  THEN TO_VARCHAR(TO_DECIMAL(ROUND(MIN(CASE WHEN I.TOTAL_READ_SIZE / 1000000000 < 3 AND I.TOTAL_READ_TIME < 60000000 THEN 999999 ELSE I.TOTAL_READ_SIZE / I.TOTAL_READ_TIME END )), 10, 0))
          WHEN C.NAME = 'AVG_IO_READ_THROUGHPUT'  THEN TO_VARCHAR(TO_DECIMAL(ROUND(CASE WHEN SUM(I.TOTAL_READ_SIZE) / 1000000000 < 10 AND SUM(I.TOTAL_READ_TIME) < 200000000 THEN 999999 ELSE SUM(I.TOTAL_READ_SIZE) / SUM(I.TOTAL_READ_TIME) END ), 10, 0))
          WHEN C.NAME = 'MIN_IO_WRITE_THROUGHPUT' THEN TO_VARCHAR(TO_DECIMAL(ROUND(MIN(CASE WHEN I.TOTAL_WRITE_SIZE / 1000000000 < 3 AND I.TOTAL_WRITE_TIME < 60000000 THEN 999999 ELSE I.TOTAL_WRITE_SIZE / I.TOTAL_WRITE_TIME END )), 10, 0))
          WHEN C.NAME = 'AVG_IO_WRITE_THROUGHPUT' THEN TO_VARCHAR(TO_DECIMAL(ROUND(CASE WHEN SUM(I.TOTAL_WRITE_SIZE) / 1000000000 < 10 AND SUM(I.TOTAL_WRITE_TIME) < 200000000 THEN 999999 ELSE SUM(I.TOTAL_WRITE_SIZE) / SUM(I.TOTAL_WRITE_TIME) END ), 10, 0))
          WHEN C.NAME = 'MAX_IO_READ_LATENCY'     THEN TO_VARCHAR(MAX(CASE WHEN I.TOTAL_READ_TIME < 60000000 THEN -999999 ELSE TO_DECIMAL(I.TOTAL_READ_TIME / I.TOTAL_READS / 1000, 10, 2) END))
          WHEN C.NAME = 'AVG_IO_READ_LATENCY'     THEN TO_VARCHAR(CASE WHEN SUM(I.TOTAL_READ_TIME) < 200000000 THEN 999999 ELSE TO_DECIMAL(SUM(I.TOTAL_READ_TIME) / SUM(I.TOTAL_READS) / 1000, 10, 2) END)
          WHEN C.NAME = 'MAX_IO_WRITE_LATENCY'    THEN TO_VARCHAR(MAX(CASE WHEN I.TOTAL_WRITE_TIME < 60000000 THEN -999999 ELSE TO_DECIMAL(I.TOTAL_WRITE_TIME / I.TOTAL_WRITES / 1000, 10, 2) END))
          WHEN C.NAME = 'AVG_IO_WRITE_LATENCY'    THEN TO_VARCHAR(CASE WHEN SUM(I.TOTAL_WRITE_TIME) < 200000000 THEN 999999 ELSE TO_DECIMAL(SUM(I.TOTAL_WRITE_TIME) / SUM(I.TOTAL_WRITES) / 1000, 10, 2) END)
        END VALUE
      FROM
      ( SELECT 'MIN_IO_READ_THROUGHPUT' NAME FROM DUMMY UNION ALL
        SELECT 'AVG_IO_READ_THROUGHPUT' FROM DUMMY UNION ALL
        SELECT 'MAX_IO_READ_LATENCY' FROM DUMMY UNION ALL
        SELECT 'AVG_IO_READ_LATENCY' FROM DUMMY UNION ALL
        SELECT 'MIN_IO_WRITE_THROUGHPUT' FROM DUMMY UNION ALL
        SELECT 'AVG_IO_WRITE_THROUGHPUT' FROM DUMMY UNION ALL
        SELECT 'MAX_IO_WRITE_LATENCY' FROM DUMMY UNION ALL
        SELECT 'AVG_IO_WRITE_LATENCY' FROM DUMMY
      ) C,
      ( SELECT
          HOST,
          TYPE,
          SUM(TOTAL_READS) TOTAL_READS,
          SUM(TOTAL_READ_SIZE) TOTAL_READ_SIZE,
          SUM(TOTAL_READ_TIME) TOTAL_READ_TIME,
          SUM(TOTAL_WRITES) TOTAL_WRITES,
          SUM(TOTAL_WRITE_SIZE) TOTAL_WRITE_SIZE,
          SUM(TOTAL_WRITE_TIME) TOTAL_WRITE_TIME
        FROM
        ( SELECT
            HOST,
            TYPE,
            SERVER_TIMESTAMP,
            TOTAL_READS + TOTAL_TRIGGER_ASYNC_READS - LEAD(TOTAL_READS + TOTAL_TRIGGER_ASYNC_READS, 1) OVER (PARTITION BY HOST, PORT, TYPE, PATH ORDER BY SERVER_TIMESTAMP DESC) + 0.01 TOTAL_READS,
            TOTAL_READ_SIZE - LEAD(TOTAL_READ_SIZE, 1) OVER (PARTITION BY HOST, PORT, TYPE, PATH ORDER BY SERVER_TIMESTAMP DESC) + 0.01 TOTAL_READ_SIZE,
            TOTAL_READ_TIME - LEAD(TOTAL_READ_TIME, 1) OVER (PARTITION BY HOST, PORT, TYPE, PATH ORDER BY SERVER_TIMESTAMP DESC) + 0.01 TOTAL_READ_TIME,
            TOTAL_WRITES + TOTAL_TRIGGER_ASYNC_WRITES - LEAD(TOTAL_WRITES + TOTAL_TRIGGER_ASYNC_WRITES, 1) OVER (PARTITION BY HOST, PORT, TYPE, PATH ORDER BY SERVER_TIMESTAMP DESC) + 0.01 TOTAL_WRITES,
            TOTAL_WRITE_SIZE - LEAD(TOTAL_WRITE_SIZE, 1) OVER (PARTITION BY HOST, PORT, TYPE, PATH ORDER BY SERVER_TIMESTAMP DESC) + 0.01 TOTAL_WRITE_SIZE,
            TOTAL_WRITE_TIME - LEAD(TOTAL_WRITE_TIME, 1) OVER (PARTITION BY HOST, PORT, TYPE, PATH ORDER BY SERVER_TIMESTAMP DESC) + 0.01 TOTAL_WRITE_TIME
          FROM
            _SYS_STATISTICS.HOST_VOLUME_IO_TOTAL_STATISTICS
          WHERE
            SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) <= 86400 AND
            TYPE IN ('LOG', 'DATA')
        )
        WHERE
          TOTAL_READS >= 0 AND
          TOTAL_READS >= 0 AND
          TOTAL_WRITES >= 0 AND
          TOTAL_READ_SIZE >= 0 AND
          TOTAL_READ_TIME >= 0 AND
          TOTAL_WRITE_SIZE >= 0 AND
          TOTAL_WRITE_TIME >= 0
        GROUP BY
          HOST,
          TYPE,
          TO_VARCHAR(SERVER_TIMESTAMP, 'YYYY/MM/DD HH24')
      ) I
      GROUP BY
        C.NAME,
        I.HOST,
        I.TYPE
    )
    UNION ALL
    ( SELECT
        'IO_READ_BANDWIDTH_STARTUP',
        HOST,
        MAP(READ_TIME_S, 0, NULL, NULL, NULL, TO_VARCHAR(TO_DECIMAL(READ_SIZE_MB / READ_TIME_S, 10, 2))) 
      FROM
      ( SELECT
          H.HOST,
          SUM(GREATEST(I.TOTAL_READ_SIZE_DELTA, 0)) / 1024 / 1024 READ_SIZE_MB,
          SUM(GREATEST(I.TOTAL_READ_TIME_DELTA, 0)) / 1000000 READ_TIME_S
        FROM
          M_HOST_INFORMATION H LEFT OUTER JOIN
          _SYS_STATISTICS.HOST_VOLUME_IO_TOTAL_STATISTICS I ON
            H.KEY = 'start_time' AND
            I.HOST = H.HOST AND
            I.SERVER_TIMESTAMP BETWEEN TO_TIMESTAMP(H.VALUE) AND ADD_SECONDS(TO_TIMESTAMP(H.VALUE), 18000)
        GROUP BY
          H.HOST
      )
    )
    UNION ALL
    ( SELECT
        'CURR_ALLOCATION_LIMIT_USED',
        HOST,
        TO_VARCHAR(TO_DECIMAL(ROUND(MAP(ALLOCATION_LIMIT, 0, 0, INSTANCE_TOTAL_MEMORY_USED_SIZE / ALLOCATION_LIMIT * 100)), 10, 0))
      FROM
        M_HOST_RESOURCE_UTILIZATION
    )
    UNION ALL
    ( SELECT
        'HIST_ALLOCATION_LIMIT_USED',
        IFNULL(HOST, ''),
        IFNULL(TO_VARCHAR(HOURS), '999999')
      FROM
        DUMMY BI LEFT OUTER JOIN
      ( SELECT
          HOST,
          TO_DECIMAL(ROUND(MIN(SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP)) / 3600), 10, 0) HOURS
        FROM
          _SYS_STATISTICS.HOST_RESOURCE_UTILIZATION_STATISTICS
        WHERE
          INSTANCE_TOTAL_MEMORY_USED_SIZE > ALLOCATION_LIMIT * 0.8
        GROUP BY
          HOST
      ) R ON
        1 = 1
    )
    UNION ALL
    ( SELECT
        'DDLOG_SEQUENCE_CACHING',
        '',
        TO_VARCHAR(MIN(CACHE_SIZE))
      FROM
        SEQUENCES
      WHERE
        SEQUENCE_NAME = 'DDLOG_SEQ'
    )
    UNION ALL
    ( SELECT
        'LONG_LOCK_WAITS',
        '',
        TO_VARCHAR(COUNT(DISTINCT(BLOCKED_TIME||BLOCKED_CONNECTION_ID)))
      FROM
        DUMMY LEFT OUTER JOIN
        _SYS_STATISTICS.HOST_BLOCKED_TRANSACTIONS ON
          1 = 1
      WHERE
        SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) <= 86400 AND
        SECONDS_BETWEEN(BLOCKED_TIME, SERVER_TIMESTAMP) > 600
    )
    UNION ALL
    ( SELECT
        'LOCKED_THREADS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_SERVICE_THREADS T
      WHERE
        T.THREAD_STATE IN 
        ( 'BarrierSemaphore Wait', 'Barrier Wait', 'ConditionalVariable Wait', 'ExclusiveLock Enter', 'IntentLock Enter', 'Mutex Wait', 
          'Semaphore Wait', 'SharedLock Enter', 'Speculative Lock Retry backoff', 'Speculative Lock Wait for fallback' ) AND
        ( T.CALLING IS NULL OR T.CALLING = '' ) AND
        T.CONNECTION_ID != CURRENT_CONNECTION AND NOT
        ( T.THREAD_TYPE = 'AgentPingThread'                 AND T.THREAD_STATE = 'Semaphore Wait'           AND T.LOCK_WAIT_NAME = 'DPPeriodicThreadWaitSemaphore'                     OR
          T.THREAD_TYPE = 'BackupMonitor_TransferThread'    AND T.THREAD_STATE = 'Sleeping'                                                                                            OR
          T.THREAD_TYPE = 'Generic'                         AND T.THREAD_STATE = 'Running'                                                                                             OR
          T.THREAD_TYPE = 'PostCommitExecutor'              AND T.THREAD_STATE = 'ConditionalVariable Wait' AND T.LOCK_WAIT_NAME = 'RegularTaskQueueCV'                                OR
          T.THREAD_TYPE = 'PriPostCommitExecutor'           AND T.THREAD_STATE = 'ConditionalVariable Wait' AND T.LOCK_WAIT_NAME = 'PrioritizedTaskQueueCV'                            OR
          T.THREAD_TYPE = 'StatsThread'                     AND T.THREAD_STATE = 'ConditionalVariable Wait' AND T.LOCK_WAIT_NAME = 'DPStatsThreadCond'                                 OR
          T.THREAD_TYPE = 'SystemReplicationAsyncLogSender' AND T.THREAD_STATE = 'Semaphore Wait'           AND T.LOCK_WAIT_NAME = 'system replication: AsyncLogBufferHandlerQueueSem'
        )
    )
    UNION ALL
    ( SELECT
        'TOP_SQL_SQLCACHE',
        '',
        IFNULL(STATEMENT_HASH || ' (' || TO_DECIMAL(TOTAL_EXECUTION_TIME / 1000000 / 86400, 10, 2) || ' connections)', 'none')
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          STATEMENT_HASH,
          SUM(TOTAL_EXECUTION_TIME) TOTAL_EXECUTION_TIME
        FROM
          _SYS_STATISTICS.HOST_SQL_PLAN_CACHE 
        WHERE
          SECONDS_BETWEEN(SERVER_TIMESTAMP, CURRENT_TIMESTAMP) <= 88200
        GROUP BY
          STATEMENT_HASH
        HAVING
          SUM(TOTAL_EXECUTION_TIME) / 1000000 > 86400
      ) ON
        1 = 1
      ORDER BY
        TOTAL_EXECUTION_TIME DESC
    ) 
    UNION ALL
    ( SELECT
        'HIGH_SELFWATCHDOG_ACTIVITY',
        HOST,
        TO_VARCHAR(TO_DECIMAL(COUNT(*) / 3600 * 100, 10, 2))
      FROM
        DUMMY LEFT OUTER JOIN
        M_SERVICE_THREAD_SAMPLES ON 
          SECONDS_BETWEEN(TIMESTAMP, CURRENT_TIMESTAMP) <= 3600 AND
          THREAD_TYPE = 'SelfWatchDog'
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'TOP_SQL_THREADSAMPLES_CURR',
        '',
        IFNULL(STATEMENT_HASH || ' (' || TO_DECIMAL(ELAPSED_S / 3600, 10, 2) || ' threads)', 'none')
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          STATEMENT_HASH,
          COUNT(*) ELAPSED_S
        FROM
          M_SERVICE_THREAD_SAMPLES 
        WHERE
          SECONDS_BETWEEN(TIMESTAMP, CURRENT_TIMESTAMP) <= 3600 AND
          STATEMENT_HASH != CHAR(63)
        GROUP BY
          STATEMENT_HASH
        HAVING
          COUNT(*) > 3600
      ) ON
        1 = 1
      ORDER BY
        ELAPSED_S DESC
    ) 
    UNION ALL
    ( SELECT
        'INTERNAL_LOCKS_LAST_HOUR',
        '',
        IFNULL(LOCK_WAIT_NAME || ' (' || TO_DECIMAL(ELAPSED_S / 3600, 10, 2) || ' threads)', 'none')
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          LOCK_WAIT_NAME,
          COUNT(*) ELAPSED_S
        FROM
          M_SERVICE_THREAD_SAMPLES T
        WHERE
          SECONDS_BETWEEN(TIMESTAMP, CURRENT_TIMESTAMP) <= 3600 AND
          THREAD_STATE != 'Job Exec Waiting' AND
          LOCK_WAIT_NAME NOT IN ('', CHAR(63), 'capacityReached', 'ChannelUtilsSynchronousCopyHandler', 'CSPlanExecutorLock', 'CSPlanExecutorWaitForResult', 
            'JoinEvaluator_JEPlanData_Lock', 'RecordLockWaitCondStat', 'SaveMergedAttributeJobSemaphore', 'TableLockWaitCondStat', 'TransactionLockWaitCondStat') AND
          LOCK_WAIT_NAME NOT LIKE '%TRexAPI::Mergedog::checkAutomerge%' AND NOT
        ( T.THREAD_TYPE = 'AgentPingThread'                 AND T.THREAD_STATE = 'Semaphore Wait'           AND T.LOCK_WAIT_NAME = 'DPPeriodicThreadWaitSemaphore'                     OR
          T.THREAD_TYPE = 'BackupMonitor_TransferThread'    AND T.THREAD_STATE = 'Sleeping'                                                                                            OR
          T.THREAD_TYPE = 'PostCommitExecutor'              AND T.THREAD_STATE = 'ConditionalVariable Wait' AND T.LOCK_WAIT_NAME = 'RegularTaskQueueCV'                                OR
          T.THREAD_TYPE = 'PriPostCommitExecutor'           AND T.THREAD_STATE = 'ConditionalVariable Wait' AND T.LOCK_WAIT_NAME = 'PrioritizedTaskQueueCV'                            OR
          T.THREAD_TYPE = 'StatsThread'                     AND T.THREAD_STATE = 'ConditionalVariable Wait' AND T.LOCK_WAIT_NAME = 'DPStatsThreadCond'                                 OR
          T.THREAD_TYPE = 'SystemReplicationAsyncLogSender' AND T.THREAD_STATE = 'Semaphore Wait'           AND T.LOCK_WAIT_NAME = 'system replication: AsyncLogBufferHandlerQueueSem'
        )
        GROUP BY
          LOCK_WAIT_NAME
        HAVING
          COUNT(*) > 3600
       ) ON
         1 = 1
    )
    UNION ALL
    ( SELECT
        'MAX_LOG_BACKUP_DURATION',
        '',
        TO_VARCHAR(MAX(SECONDS_BETWEEN(SYS_START_TIME, SYS_END_TIME)))
      FROM
        TEMP_M_BACKUP_CATALOG
      WHERE
        ENTRY_TYPE_NAME = 'log backup' AND
        SECONDS_BETWEEN(SYS_START_TIME, CURRENT_TIMESTAMP) <= 86400
    )
    UNION ALL
    ( SELECT
        'CATALOG_BACKUP_SIZE_SHARE',
        '',
        TO_VARCHAR(TO_DECIMAL(MAP(TOTAL_SIZE, 0, 0, CATALOG_SIZE / TOTAL_SIZE * 100), 10, 2))
      FROM
      ( SELECT
          SUM(CF.BACKUP_SIZE) TOTAL_SIZE,
          SUM(CASE WHEN CF.SOURCE_TYPE_NAME = 'catalog' THEN CF.BACKUP_SIZE ELSE 0 END) CATALOG_SIZE
        FROM
          TEMP_M_BACKUP_CATALOG C,
          TEMP_M_BACKUP_CATALOG_FILES CF
        WHERE
          C.BACKUP_ID = CF.BACKUP_ID AND
          SECONDS_BETWEEN(C.SYS_END_TIME, CURRENT_TIMESTAMP) <= 86400
      )
    )
/* Available as of Revision 70 */
    UNION ALL
    ( SELECT
        'AVG_COMMIT_IO_TIME',
        HOST,
        TO_VARCHAR(TO_DECIMAL(MAP(SUM(COMMIT_COUNT), 0, 0, SUM(SUM_COMMIT_IO_LATENCY) / SUM(COMMIT_COUNT) / 1000), 10, 2))
      FROM
        M_LOG_PARTITIONS
      GROUP BY
        HOST
    )
    UNION ALL
    ( SELECT
        'LARGE_MEMORY_LOBS',
        '',
        TO_VARCHAR(COUNT(DISTINCT(T.SCHEMA_NAME || T.TABLE_NAME)))
      FROM
        M_TABLES T,
        TEMP_TABLE_COLUMNS C
      WHERE
        T.SCHEMA_NAME = C.SCHEMA_NAME AND
        T.TABLE_NAME = C.TABLE_NAME AND
        C.CS_DATA_TYPE_NAME = 'ST_MEMORY_LOB' AND
        T.TABLE_NAME != 'CE_SCENARIOS_' AND
        T.TABLE_SIZE / 1024 / 1024 / 1024 >= 2
    )
    UNION ALL
    ( SELECT
        C.NAME,
        '',
        IFNULL(CASE C.NAME
          WHEN 'CONCAT_ATTRIBUTES_SIZE'  THEN TO_VARCHAR(TO_DECIMAL(SUM(IFNULL(AC.SIZE_GB, 0)), 10, 2))
          WHEN 'CONCAT_ATTRIBUTES_PCT'   THEN TO_VARCHAR(TO_DECIMAL(MAP(AVG(H.GAL_GB), 0, 0, SUM(IFNULL(AC.SIZE_GB, 0)) / AVG(H.GAL_GB) * 100), 10, 2))
        END, '0')
      FROM
      ( SELECT
          SUM(ALLOCATION_LIMIT) / 1024 / 1024 / 1024 GAL_GB
        FROM
          M_HOST_RESOURCE_UTILIZATION
      ) H,
      ( SELECT 'CONCAT_ATTRIBUTES_SIZE' NAME FROM DUMMY UNION ALL
        SELECT 'CONCAT_ATTRIBUTES_PCT'       FROM DUMMY
      ) C LEFT OUTER JOIN
      ( SELECT
          C.TABLE_NAME,
          C.COLUMN_NAME,
          TC.CS_DATA_TYPE_NAME DATA_TYPE,
          C.INTERNAL_ATTRIBUTE_TYPE,
          C.MEMORY_SIZE_IN_TOTAL / 1024 / 1024 / 1024 SIZE_GB
        FROM
          TEMP_M_CS_ALL_COLUMNS C LEFT OUTER JOIN
          TEMP_TABLE_COLUMNS TC ON
            TC.SCHEMA_NAME = C.SCHEMA_NAME AND
            TC.TABLE_NAME = C.TABLE_NAME AND
            TC.COLUMN_NAME = C.COLUMN_NAME
      ) AC ON
        ( C.NAME LIKE 'CONCAT_ATTRIBUTES%' AND AC.INTERNAL_ATTRIBUTE_TYPE = 'CONCAT_ATTRIBUTE' AND AC.COLUMN_NAME NOT LIKE '`$uc%' OR
          C.NAME = 'TREX_UDIV_FRAGMENTATION' AND AC.COLUMN_NAME = '`$trex_udiv$' )
      GROUP BY
        C.NAME
    )
    UNION ALL
    ( SELECT
        'LOCKED_THREADS_LAST_DAY',
        '',
        TO_VARCHAR(CEILING(MAX(SAMPLES_PER_MINUTE) / 60))
      FROM
      ( SELECT
          COUNT(*) SAMPLES_PER_MINUTE
        FROM
          M_SERVICE_THREAD_SAMPLES T
        WHERE
          T.THREAD_STATE IN 
          ( 'BarrierSemaphore Wait', 'Barrier Wait', 'ConditionalVariable Wait', 'ExclusiveLock Enter', 'IntentLock Enter', 'Mutex Wait', 
            'Semaphore Wait', 'SharedLock Enter', 'Speculative Lock Retry backoff', 'Speculative Lock Wait for fallback' ) AND
          T.TIMESTAMP BETWEEN ADD_SECONDS(CURRENT_TIMESTAMP, -86400) AND CURRENT_TIMESTAMP AND
          ( T.CALLING IS NULL OR T.CALLING = '' ) AND NOT
          ( T.THREAD_TYPE = 'AgentPingThread'                 AND T.THREAD_STATE = 'Semaphore Wait'           AND T.LOCK_WAIT_NAME = 'DPPeriodicThreadWaitSemaphore'                     OR
            T.THREAD_TYPE = 'BackupMonitor_TransferThread'    AND T.THREAD_STATE = 'Sleeping'                                                                                       OR
            T.THREAD_TYPE = 'PostCommitExecutor'              AND T.THREAD_STATE = 'ConditionalVariable Wait' AND T.LOCK_WAIT_NAME = 'RegularTaskQueueCV'                                OR
            T.THREAD_TYPE = 'PriPostCommitExecutor'           AND T.THREAD_STATE = 'ConditionalVariable Wait' AND T.LOCK_WAIT_NAME = 'PrioritizedTaskQueueCV'                            OR
            T.THREAD_TYPE = 'StatsThread'                     AND T.THREAD_STATE = 'ConditionalVariable Wait' AND T.LOCK_WAIT_NAME = 'DPStatsThreadCond'                                 OR
            T.THREAD_TYPE = 'SystemReplicationAsyncLogSender' AND T.THREAD_STATE = 'Semaphore Wait'           AND T.LOCK_WAIT_NAME = 'system replication: AsyncLogBufferHandlerQueueSem'
        )
        GROUP BY
          TO_VARCHAR(TIMESTAMP, 'YYYY/MM/DD HH24:MI')
      )
    ) 
    UNION ALL
    ( SELECT
        'SQL_CACHE_HIT_RATIO',
        HOST,
        TO_VARCHAR(TO_DECIMAL(PLAN_CACHE_HIT_RATIO * 100, 10, 2))
      FROM
        TEMP_M_SQL_PLAN_CACHE_OVERVIEW
      WHERE
        CACHED_PLAN_SIZE >= 100000000
    )
    UNION ALL
    ( SELECT
        'KERNEL_PROFILER',
        '',
        MAP(COUNT(*), 0, 'no', 'yes')
      FROM
        M_KERNEL_PROFILER
    )
/* Available as of Revision 90 */
    UNION ALL
    ( SELECT
        'LARGE_CS_MVCC_TIMESTAMPS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
      ( SELECT
          SUM( CTS_MEMORY_SIZE + DTS_MEMORY_SIZE ) / 1024 / 1024 / 1024 TS_SIZE_GB
        FROM
          M_CS_MVCC
        GROUP BY
          SCHEMA_NAME,
          TABLE_NAME
      )
      WHERE
        TS_SIZE_GB > 5
    )
    UNION ALL
    ( SELECT
        'TABLE_MVCC_SNAPSHOT_RANGE',
        '',
        IFNULL(TO_VARCHAR(CUR_COMMIT_ID - MIN_TS_ID), '0')
      FROM
      ( SELECT
          (MIN(MIN_MVCC_SNAPSHOT_TIMESTAMP)) MIN_TS_ID
        FROM
          M_TABLE_SNAPSHOTS
      ),
      ( SELECT
          MAX(TO_NUMBER(VALUE)) CUR_COMMIT_ID
        FROM
          TEMP_M_MVCC_TABLES
      )
    )
    UNION ALL
    ( SELECT
        C.NAME,
        L.HOST,
        CASE C.NAME
          WHEN 'PING_TIME_HOUR'        THEN TO_VARCHAR(TO_DECIMAL(GREATEST(0, AVG(PING_TIME)), 10, 2))
          WHEN 'CONC_BLOCK_TRANS_HOUR' THEN TO_VARCHAR(GREATEST(0, MAX(L.BLOCKED_TRANSACTION_COUNT)))
        END
      FROM
      ( SELECT 'PING_TIME_HOUR' NAME FROM DUMMY UNION ALL
        SELECT 'CONC_BLOCK_TRANS_HOUR' NAME FROM DUMMY
      ) C,
        M_LOAD_HISTORY_SERVICE L
      WHERE
        SECONDS_BETWEEN(L.TIME, CURRENT_TIMESTAMP) <= 3600
      GROUP BY
        C.NAME,
        L.HOST
    )
    UNION ALL
    ( SELECT
        C.NAME,
        L.HOST,
        CASE C.NAME
          WHEN 'PING_TIME_DAY'              THEN TO_VARCHAR(TO_DECIMAL(AVG(PING_TIME), 10, 2))
          WHEN 'CONC_BLOCK_TRANS_DAY'       THEN TO_VARCHAR(MAX(GREATEST(0, L.BLOCKED_TRANSACTION_COUNT)))
          WHEN 'VERSIONS_ROW_STORE_DAY'     THEN TO_VARCHAR(MAX(GREATEST(0, L.MVCC_VERSION_COUNT)))
          WHEN 'ACTIVE_COMMIT_ID_RANGE_DAY' THEN TO_VARCHAR(MAX(GREATEST(0, L.COMMIT_ID_RANGE)))
          WHEN 'WRONG_SYSTEM_CPU'           THEN CASE WHEN SUM(CPU) < 10 THEN NULL ELSE MAP(SUM(CPU), SUM(SYSTEM_CPU), 'yes', 'no') END
        END
      FROM
      ( SELECT 'PING_TIME_DAY' NAME         FROM DUMMY UNION ALL
        SELECT 'CONC_BLOCK_TRANS_DAY'       FROM DUMMY UNION ALL
        SELECT 'VERSIONS_ROW_STORE_DAY'     FROM DUMMY UNION ALL
        SELECT 'ACTIVE_COMMIT_ID_RANGE_DAY' FROM DUMMY UNION ALL
        SELECT 'WRONG_SYSTEM_CPU'           FROM DUMMY
      ) C,
        M_LOAD_HISTORY_SERVICE L
      WHERE
        SECONDS_BETWEEN(L.TIME, CURRENT_TIMESTAMP) <= 86400
      GROUP BY
        C.NAME,
        L.HOST
    )
    UNION ALL
    ( SELECT
        'PENDING_SESSIONS_CURRENT',
        '',
        TO_VARCHAR(GREATEST(0, SUM(PENDING_SESSION_COUNT)))
      FROM
        M_LOAD_HISTORY_SERVICE
      WHERE
        TIME = ( SELECT MAX(TIME) FROM M_LOAD_HISTORY_SERVICE )
    )
    UNION ALL
    ( SELECT
        'PENDING_SESSIONS_RECENT',
        '',
        TO_VARCHAR(TO_DECIMAL(GREATEST(0, AVG(PENDING_SESSION_COUNT)), 10, 2))
      FROM
      ( SELECT
          SUM(PENDING_SESSION_COUNT) PENDING_SESSION_COUNT
        FROM
          M_LOAD_HISTORY_SERVICE
        WHERE
          SECONDS_BETWEEN(TIME, CURRENT_TIMESTAMP) <= 86400
        GROUP BY
          TIME
      )
    )
/* Available with embedded statistics server (ESS) */
    UNION ALL
    ( SELECT
        'INTERNAL_LOCKS_LAST_DAY',
        '',
        IFNULL(LOCK_WAIT_NAME || ' (' || TO_DECIMAL(ELAPSED_S / 86400, 10, 2) || ' threads)', 'none')
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          LOCK_WAIT_NAME,
          COUNT(*) * 50 ELAPSED_S
        FROM
          _SYS_STATISTICS.HOST_SERVICE_THREAD_SAMPLES T
        WHERE
          SECONDS_BETWEEN(TIMESTAMP, CURRENT_TIMESTAMP) <= 88000 AND
          THREAD_STATE != 'Job Exec Waiting' AND
          LOCK_WAIT_NAME NOT IN ('', CHAR(63), 'capacityReached', 'ChannelUtilsSynchronousCopyHandler', 'CSPlanExecutorLock', 'CSPlanExecutorWaitForResult', 
            'JoinEvaluator_JEPlanData_Lock', 'RecordLockWaitCondStat', 'SaveMergedAttributeJobSemaphore', 'TableLockWaitCondStat', 'TransactionLockWaitCondStat') AND
          LOCK_WAIT_NAME NOT LIKE '%TRexAPI::Mergedog::checkAutomerge%' AND NOT
        ( T.THREAD_TYPE = 'AgentPingThread'                 AND T.THREAD_STATE = 'Semaphore Wait'           AND T.LOCK_WAIT_NAME = 'DPPeriodicThreadWaitSemaphore'                     OR
          T.THREAD_TYPE = 'BackupMonitor_TransferThread'    AND T.THREAD_STATE = 'Sleeping'                                                                                            OR
          T.THREAD_TYPE = 'PostCommitExecutor'              AND T.THREAD_STATE = 'ConditionalVariable Wait' AND T.LOCK_WAIT_NAME = 'RegularTaskQueueCV'                                OR
          T.THREAD_TYPE = 'PriPostCommitExecutor'           AND T.THREAD_STATE = 'ConditionalVariable Wait' AND T.LOCK_WAIT_NAME = 'PrioritizedTaskQueueCV'                            OR
          T.THREAD_TYPE = 'StatsThread'                     AND T.THREAD_STATE = 'ConditionalVariable Wait' AND T.LOCK_WAIT_NAME = 'DPStatsThreadCond'                                 OR
          T.THREAD_TYPE = 'SystemReplicationAsyncLogSender' AND T.THREAD_STATE = 'Semaphore Wait'           AND T.LOCK_WAIT_NAME = 'system replication: AsyncLogBufferHandlerQueueSem'
        )
        GROUP BY
          LOCK_WAIT_NAME
        HAVING
          COUNT(*) > 1728
       ) ON
         1 = 1
    )
    UNION ALL
    ( SELECT
        'TOP_SQL_THREADSAMPLES_HIST',
        '',
        IFNULL(STATEMENT_HASH || ' (' || TO_DECIMAL(ELAPSED_S / 86400, 10, 2) || ' threads)', 'none')
      FROM
        DUMMY LEFT OUTER JOIN
      ( SELECT
          STATEMENT_HASH,
          COUNT(*) * 50 ELAPSED_S
        FROM
          _SYS_STATISTICS.HOST_SERVICE_THREAD_SAMPLES 
        WHERE
          SECONDS_BETWEEN(TIMESTAMP, CURRENT_TIMESTAMP) <= 88000 AND
          STATEMENT_HASH != CHAR(63)
        GROUP BY
          STATEMENT_HASH
        HAVING
          COUNT(*) > 1728
      ) ON
        1 = 1
      ORDER BY
        ELAPSED_S DESC
    ) 
    UNION ALL
    ( SELECT
        'OLD_PENDING_ALERT_EMAILS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        _SYS_STATISTICS.STATISTICS_EMAIL_PROCESSING 
      WHERE
        SECONDS_BETWEEN(SNAPSHOT_ID, CURRENT_TIMESTAMP) > 3 * 24 * 3600
    )
    UNION ALL
    ( SELECT
        'STAT_SERVER_DISABLED_CHECKS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        _SYS_STATISTICS.STATISTICS_SCHEDULE
      WHERE
        STATUS = 'Disabled'
    )
    UNION ALL
    ( SELECT
        'STAT_SERVER_UNKNOWN_STATES',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        _SYS_STATISTICS.STATISTICS_SCHEDULE
      WHERE
       STATUS NOT IN ( 'Disabled', 'Idle', 'Inactive', 'Scheduled' )
    )
    UNION ALL
    ( SELECT
        'STAT_SERVER_INACTIVE_CHECKS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        `"_SYS_STATISTICS`".`"STATISTICS_SCHEDULE`" 
      WHERE
       STATUS = 'Inactive' AND
       ID NOT IN (41, 58, 77, 83, 95, 96, 5008, 5024, 5025, 5033, 5035, 5047)
    )
    UNION ALL
    ( SELECT
        'STAT_SERVER_WRONG_HOST',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_TABLE_LOCATIONS
      WHERE
        SCHEMA_NAME = '_SYS_STATISTICS' AND
        LOCATION !=
        ( SELECT 
            HOST || ':' || PORT
          FROM
            M_SERVICES
          WHERE
            SERVICE_NAME = 'indexserver' AND
            DETAIL = 'master'
        )
    )
    UNION ALL
    ( SELECT
        'ESS_MIGRATION_SUCCESSFUL',
        '',
        LOWER(SUBSTR(VALUE, 1, LOCATE(VALUE, ')')))
      FROM
        DUMMY LEFT OUTER JOIN
        _SYS_STATISTICS.STATISTICS_PROPERTIES 
      ON
        KEY = 'internal.installation.state'
    )
    UNION ALL
    ( SELECT
        'STAT_SERVER_LAST_ACTIVE',
        '',
        TO_VARCHAR(SECONDS_BETWEEN(MAX(LATEST_START_SERVERTIME), CURRENT_TIMESTAMP))
      FROM
        _SYS_STATISTICS.STATISTICS_SCHEDULE
    )
    UNION ALL
    ( SELECT
        'STAT_SERVER_RETENTION',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        _SYS_STATISTICS.STATISTICS_SCHEDULE SS,
        _SYS_STATISTICS.STATISTICS_OBJECTS SO
      WHERE
        SS.ID = SO.ID AND
        SO.TYPE = 'Collector' AND
        SS.ID NOT IN ( 5008, 5024, 5025, 5026, 5033, 5035 ) AND
        IFNULL(SS.RETENTION_DAYS_CURRENT, SS.RETENTION_DAYS_DEFAULT) < 42
    )
    UNION ALL
    ( SELECT
        MAP(ID, 5033, 'HOST_RECORD_LOCKS_ACTIVE', 'HOST_CS_UNLOADS_ACTIVE'),
        '',
        MAP(STATUS, 'Inactive', 'no', 'yes')
      FROM
        _SYS_STATISTICS.STATISTICS_SCHEDULE
      WHERE
        ID IN ( 5033, 5035 )
    )
    UNION ALL
    ( SELECT
        'REP_CONNECTION_CLOSED',
        '',
        TO_VARCHAR(MAP(COUNT(*), 0, 'no', 'yes'))
      FROM
        _SYS_STATISTICS.STATISTICS_ALERTS_BASE
      WHERE
        SECONDS_BETWEEN(ALERT_TIMESTAMP, CURRENT_TIMESTAMP) <= 86400 AND
        ALERT_ID = 78
    )
    UNION ALL
    ( SELECT
        'STAT_SERVER_OLD_ALERTS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        _SYS_STATISTICS.STATISTICS_ALERTS_BASE
      WHERE
        ALERT_TIMESTAMP < ADD_DAYS(CURRENT_TIMESTAMP, -42)
    )
    UNION ALL
    ( SELECT
        'STAT_SERVER_FREQUENT_ALERTS',
        '',
        TO_VARCHAR(SUM(CASE WHEN NUM_ALERTS > 1000000 THEN 1 ELSE 0 END ))
      FROM
      ( SELECT
          ALERT_ID,
          COUNT(*) NUM_ALERTS
        FROM
          DUMMY LEFT OUTER JOIN
          _SYS_STATISTICS.STATISTICS_ALERTS_BASE
        ON
          1 = 1
        GROUP BY
          ALERT_ID
      )
    )
/* Available as of Revision 100 */
    UNION ALL
    ( SELECT
        'CTC_ERRORS_LAST_MONTH',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        _SYS_STATISTICS.GLOBAL_TABLE_CONSISTENCY
      WHERE
        SERVER_TIMESTAMP >= ADD_DAYS(CURRENT_TIMESTAMP, -31) AND
        ERROR_CODE > 0
    )
    UNION ALL
    ( SELECT
        C.NAME,
        '',
        CASE C.NAME
          WHEN 'TCP_RETRANSMITTED_SEGMENTS' THEN
            TO_VARCHAR(MAX(TO_DECIMAL(MAP(N.TCP_SEGMENTS_SENT_OUT, 0, 0, N.TCP_SEGMENTS_RETRANSMITTED * 100 / N.TCP_SEGMENTS_SENT_OUT), 9, 5)))
          WHEN 'TCP_BAD_SEGMENTS' THEN
            TO_VARCHAR(MAX(TO_DECIMAL(MAP(N.TCP_SEGMENTS_RECEIVED, 0, 0, N.TCP_BAD_SEGMENTS_RECEIVED * 100 / N.TCP_SEGMENTS_RECEIVED), 9, 5)))
        END 
      FROM
      ( SELECT 'TCP_RETRANSMITTED_SEGMENTS' NAME FROM DUMMY UNION ALL
        SELECT 'TCP_BAD_SEGMENTS' FROM DUMMY
      ) C,
        M_HOST_NETWORK_STATISTICS N
      GROUP BY
        C.NAME
    )
/* Available as of Revision 102.01 */
    UNION ALL
    ( SELECT 
        'AVG_COMMIT_TIME',
        HOST,
        MAP(SUM(COMMIT_COUNT), 0, 'n/a', TO_VARCHAR(TO_DECIMAL(SUM(COMMIT_TOTAL_EXECUTION_TIME) / 1000 / SUM(COMMIT_COUNT), 10, 2)))
      FROM
        M_CONNECTION_STATISTICS
      GROUP BY
        HOST
    )
/* Available as of Revision 1.00.120 */
    UNION ALL
    ( SELECT
        'OOM_EVENTS_LAST_HOUR',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_OUT_OF_MEMORY_EVENTS
      WHERE
        SECONDS_BETWEEN(TIME, CURRENT_TIMESTAMP) <= 3600
    )
    UNION ALL
    ( SELECT
        'INACTIVE_TABLE_REPLICAS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        M_TABLE_REPLICAS
      WHERE
        REPLICATION_STATUS != 'ENABLED' AND NOT
        ( REPLICATION_STATUS = 'DISABLED' AND LAST_ERROR_CODE = 0 )
    )
    UNION ALL
    ( SELECT
        'SR_LOGREPLAY_BACKLOG',
        '',
        TO_VARCHAR(TO_DECIMAL(MAP(MAX(OPERATION_MODE), 'logreplay', 
          IFNULL(SUM(MAP(REPLAYED_LOG_POSITION, 0, 0, SHIPPED_LOG_POSITION - REPLAYED_LOG_POSITION)) * 64 / 1024 / 1024 / 1024, 0), 0), 10, 2))
      FROM
        M_SYSTEM_REPLICATION S,
        M_SERVICE_REPLICATION R
      WHERE
        S.SITE_ID = R.SITE_ID
    )
/* Available as of SAP HANA 2.0 */
    UNION ALL
    ( SELECT
        'SDA_TABLES_WITHOUT_STATS',
        '',
        TO_VARCHAR(COUNT(*))
      FROM
        VIRTUAL_TABLES T
      WHERE
        NOT EXISTS ( SELECT 1 FROM DATA_STATISTICS S WHERE S.DATA_SOURCE_SCHEMA_NAME = T.SCHEMA_NAME AND S.DATA_SOURCE_OBJECT_NAME = T.TABLE_NAME )
    )
/* TMC_GENERATION_END_1 */
  ) C,
  ( SELECT                                               /* Modification section */
      '%' HOST,
      ' ' ONLY_POTENTIALLY_CRITICAL_RESULTS,
      52 MAX_VALUE_LENGTH,
      -1 CHECK_ID,
      '%' CHECK_GROUP,
      'CHECK' ORDER_BY                            /* HOST, CHECK */
    FROM
      DUMMY
  ) BI,
  ( SELECT
      TO_NUMBER(SUBSTR(VALUE, LOCATE(VALUE, '.', 1, 2) + 1, LOCATE(VALUE, '.', 1, 3) - LOCATE(VALUE, '.', 1, 2) - 1) ||
      MAP(LOCATE(VALUE, '.', 1, 4), 0, '', '.' || SUBSTR(VALUE, LOCATE(VALUE, '.', 1, 3) + 1, LOCATE(VALUE, '.', 1, 4) - LOCATE(VALUE, '.', 1, 3) - 1 ))) REVISION 
    FROM 
      M_SYSTEM_OVERVIEW 
    WHERE 
      SECTION = 'System' AND 
      NAME = 'Version' 
  ) REL,
  ( SELECT -1 CHECK_ID,'' Category, '' NAME,                  '' DESCRIPTION,                                    '' SAP_NOTE, '' EXPECTED_OP, '' EXPECTED_VALUE, -1 MIN_REV, -1 MAX_REV FROM DUMMY WHERE 1 = 0 UNION ALL
( SELECT    9,'SAP HANA MINI CHECKS', 'CHECK_VERSION',                'Mini check version',                              '',        'any',      'any',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT   10,'SAP HANA MINI CHECKS', 'ANALYSIS_DATE',                'Analysis date',                                   '',        'any',      'any',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT   11,'SAP HANA MINI CHECKS', 'DATABASE_NAME',                'Database name',                                   '',        'any',      'any',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT   12,'SAP HANA MINI CHECKS', 'REVISION_LEVEL',               'Revision level',                                  '2378962', '>=',       '0.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT   13,'SAP HANA MINI CHECKS', 'VERSION_LEVEL',                'Version',                                         '2378962', 'any',      'any',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  110,'SAP HANA MINI CHECKS', 'EVERYTHING_STARTED',           'Everything started',                              '2177064', '=',        'yes',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  111,'SAP HANA MINI CHECKS', 'HOST_START_TIME_VARIATION',    'Host startup time variation (s)',                 '2177064', '<=',       '600',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  115,'SAP HANA MINI CHECKS', 'SERVICE_START_TIME_VARIATION', 'Service startup time variation (s)',              '2177064', '<=',       '600',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  207,'OPERATING SYSTEM', 'OS_KERNEL_BIGMEM',             'Recommended bigmem kernel flavor not used',       '2240716', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  208,'OPERATING SYSTEM', 'OS_RELEASE',                   'Supported operating system',                      '2235581', '=',        'yes',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  209,'OPERATING SYSTEM', 'OS_KERNEL_VERSION',            'Recommended operating system kernel version',     '2235581', '=',        'yes',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  210,'OPERATING SYSTEM', 'SLOW_CPU',                     'Minimum CPU rate (MHz)',                          '1890444', '>=',       '1950',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  211,'OPERATING SYSTEM', 'VARYING_CPU',                  'Hosts with varying CPU rates',                    '1890444', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  215,'OPERATING SYSTEM', 'WRONG_CPU_TYPE',               'Hosts with wrong CPU type',                       '2399995', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  220,'OPERATING SYSTEM', 'CPU_BUSY_CURRENT',             'Current CPU utilization (%)',                     '2100040', '<=',       '80',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  221,'OPERATING SYSTEM', 'CPU_BUSY_RECENT',              'Peak CPU utilization (% last day )',              '2100040', '<=',       '90',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  222,'OPERATING SYSTEM', 'CPU_BUSY_HISTORY',             'Time since CPU utilization > 95 % (h)',           '2100040', '>=',       '12.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  226,'OPERATING SYSTEM', 'CPU_BUSY_SYSTEM_RECENT',       'Peak system CPU utilization (% last day )',       '2100040', '<=',       '30',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  228,'OPERATING SYSTEM', 'WRONG_SYSTEM_CPU',             'Erroneous system CPU calculation',                '2222110', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  235,'OPERATING SYSTEM', 'VARYING_MEMORY',               'Hosts with varying physical memory size',         '1999997', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  245,'OPERATING SYSTEM', 'LARGE_SWAP_SPACE',             'Swap space size (GB)',                            '1999997', '<=',       '35.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  250,'OPERATING SYSTEM', 'DISK_SIZE',                    'Max. used disk size (%)',                         '1870858', '<=',       '90',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  260,'OPERATING SYSTEM', 'OS_OPEN_FILES',                'Open files limit (OS)',                           '1771873', '>=',       '100000',        -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  270,'OPERATING SYSTEM', 'UNKNOWN_HARDWARE',             'Unknown hardware components',                     '1828631', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  280,'OPERATING SYSTEM', 'SERVER_TIME_VARIATION',        'Maximum time variation between hosts (s)',        '',        '<=',       '5',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  312,'DISKS', 'MAX_IO_READ_LATENCY_DATA',     'I/O read latency data max. (ms last day )',       '1999930', '<=',       '20.00',         -1,    -1 FROM DUMMY ) UNION ALL  
    ( SELECT  313,'DISKS',  'AVG_IO_READ_LATENCY_DATA',     'I/O read latency data avg. (ms last day )',       '1999930', '<=',       '10.00',         -1,    -1 FROM DUMMY ) UNION ALL  
    ( SELECT  314,'DISKS',  'IO_READ_BANDWIDTH_STARTUP',    'I/O read reload throughput avg. (MB/s)',          '1999930', '>=',       '200.00',        -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  315,'DISKS',  'MIN_IO_WRITE_THROUGHPUT_DATA', 'I/O write throughput data min. (MB/s last day )', '1999930', '>=',       '20',            -1,    -1 FROM DUMMY ) UNION ALL  
    ( SELECT  316,'DISKS',  'AVG_IO_WRITE_THROUGHPUT_DATA', 'I/O write throughput data avg. (MB/s last day )', '1999930', '>=',       '100',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  327,'DISKS',  'MAX_IO_WRITE_LATENCY_LOG',     'I/O write latency log max. (ms last day )',       '1999930', '<=',       '20.00',         -1,    -1 FROM DUMMY ) UNION ALL  
    ( SELECT  329,'DISKS',  'AVG_IO_WRITE_LATENCY_LOG',     'I/O write latency log avg. (ms last day )',       '1999930', '<=',       '10.00',         -1,    -1 FROM DUMMY ) UNION ALL  
    ( SELECT  330,'DISKS',  'TRIGGER_READ_RATIO',           'Max. trigger read ratio (data)',                  '1930979', '<=',       '0.50',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  331,'DISKS',  'TRIGGER_WRITE_RATIO',          'Max. trigger write ratio (data log)',            '1930979', '<=',       '0.50',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  340,'DISKS',  'LOG_WAIT_RATIO',               'Log switch wait count ratio (%)',                 '2215131', '<=',       '1',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  341,'DISKS',  'LOG_RACE_RATIO',               'Log switch race count ratio (%)',                 '2215131', '<=',       '1',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  346,'DISKS',  'ENTER_CRIT_SAVEPOINT_PHASE',   'Long waitForLock savepoint phases (last day)',    '2100009', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  348,'DISKS','CRIT_SAVEPOINT_PHASE',         'Long critical savepoint phases (last day)',       '2100009', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  351,'DISKS','AVG_CRIT_SAVEPOINT_PHASE',     'Blocking savepoint phase avg. (s last day )',     '2100009', '<=',       '2.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  355,'DISKS','TIME_SINCE_LAST_SAVEPOINT',    'Time since last savepoint (s)',                   '2100009', '<=',       '900',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  357,'DISKS',  'SAVEPOINT_THROUGHPUT',         'Savepoint write throughput (MB/s)',               '2100009', '>=',       '100',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  358,'DISKS',  'LONG_RUNNING_SAVEPOINTS',      'Savepoints taking longer than 900 s (last day)',  '2100009', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  360,'DISKS',  'FAILED_IO_READS',              'Number of failed I/O reads',                      '1999930', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  361,'DISKS',  'FAILED_IO_WRITES',             'Number of failed I/O writes',                     '1999930', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  367,'DISKS',  'UNSUPPORTED_FILESYSTEMS',      'Filesystems with unsupported types',              '1999930', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  370,'DISKS',  'DISK_DATA_FRAGMENTATION',      'Unused space in data files (%)',                  '1870858', '<=',       '40',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  380,'DISKS',  'OLDEST_BACKUP_SNAPSHOT',       'Age of oldest backup snapshot (days)',            '2100009', '<=',       '30.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  383,'DISKS',  'SHADOW_PAGE_SIZE',             'Max. size of shadow pages (GB last day )',        '2100009', '<=',       '200.00',        -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  410,'MEMORY', 'CURR_ALLOCATION_LIMIT_USED',   'Current allocation limit used (%)',               '1999997', '<=',       '80',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  411,'MEMORY', 'TABLE_ALLOCATION_LIMIT_RATIO', 'Current allocation limit used by tables (%)',     '1999997', '<=',       '50',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  413,'MEMORY', 'HIST_ALLOCATION_LIMIT_USED',   'Time since allocation limit used > 80 % (h)',     '1999997', '>=',       '24',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  415,'MEMORY', 'MAX_CURR_SERV_ALL_LIMIT_USED', 'Curr. max. service allocation limit used (%)',    '1999997', '<=',       '80',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  417,'MEMORY', 'MAX_HIST_SERV_ALL_LIMIT_USED', 'Time since service alloc. limit used > 80 % (h)', '1999997', '>=',       '24',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  420,'MEMORY', 'CURRENT_LARGE_HEAP_AREAS',     'Heap areas currently larger than 50 GB',          '1999997', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  421,'MEMORY', 'RECENT_LARGE_HEAP_AREAS',      'Heap areas larger than 100 GB (last day)',        '1999997', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  422,'MEMORY', 'HISTORIC_LARGE_HEAP_AREAS',    'Heap areas larger than 200 GB (history)',         '1999997', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  425,'MEMORY', 'CPBTREE_LEAK',                 'Pool/RowEngine/CpbTree leak size (GB)',           '1999997', '<=',       '20.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  426,'MEMORY', 'ROW_STORE_TABLE_LEAK',         'Row store table leak size (GB)',                  '2362759', '<=',       '20.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  430,'MEMORY', 'CURRENT_UNLOADS',              'Number of low memory column unloads (last day)',  '2127458', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  431,'MEMORY', 'LAST_UNLOAD',                  'Time since last low memory column unload (days)', '2127458', '>=',       '5.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  435,'MEMORY', 'CURRENT_SHRINK_UNLOADS',       'Number of shrink column unloads (last day)',      '2127458', '<=',       '1000',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  437,'MEMORY', 'COLUMN_UNLOAD_SIZE',           'Size of unloaded columns (GB last day )',         '2127458', '<=',       '20.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  440,'MEMORY', 'NAMESERVER_SHARED_MEMORY',     'Shared memory utilization of nameserver (%)',     '1977101', '<=',       '70',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  445,'MEMORY', 'OOM_EVENTS_LAST_HOUR',         'Number of OOM events (last hour)',                '1999997', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  450,'MEMORY', 'LARGE_MEMORY_LOBS',            'Tables with memory LOBs > 2 GB',                  '1994962', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  454,'MEMORY', 'CONCAT_ATTRIBUTES_PCT',        'Size of non-unique concat attributes (%)',        '1986747', '<=',       '5.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  460,'MEMORY', 'CALCENGINE_CACHE_UTILIZATION', 'Calc engine cache utilization (%)',               '2000002', '<=',       '70',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  470,'MEMORY', 'FREQUENT_ALLOCATORS',          'Heap allocators with many instantiations',        '1999997', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  480,'MEMORY', 'ADDRESS_SPACE_UTILIZATION',    'Address space utilization (%)',                   '1999997', '<=',       '80',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  510,'TABLES', 'MANY_PARTITIONS',              'Tables with > 100 partitions',                    '2044468', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  512,'TABLES', 'MULTI_COLUMN_HASH_PART',       'Hash partitioning on multiple columns',           '2044468', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  515,'TABLES', 'INVERTED_HASH_ON_PART_TABLE',  'Partitioned tables with inverted hash indexes',   '2436619', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  520,'TABLES', 'MANY_RECORDS',                 'Tables / partitions > 1.5 billion rows',          '1921694', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  521,'TABLES', 'MANY_RECORDS_HISTORY',         'Table histories > 1.5 billion rows',              '1921694', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  522,'TABLES', 'MANY_RECORDS_UDIV',            'Tables / partitions > 1.5 billion UDIV rows',     '2112604', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  525,'TABLES', 'LARGE_MEMORY_TABLES',          'Tables / partitions with large memory size',      '2044468', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  526,'TABLES', 'LARGE_ALLOC_LIM_TABLES',       'Tables / partitions with large memory share',     '2044468', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  530,'TABLES', 'ROW_STORE_SIZE',               'Row store size (GB)',                             '2050579', '<=',       '300',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  533,'TABLES', 'ROW_STORE_CONTAINERS',         'Row store tables with more than 1 container',     '2000002', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  535,'TABLES', 'ROW_STORE_FRAGMENTATION',      'Row store fragmentation (%)',                     '1813245', '<=',       '30',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  537,'TABLES', 'LONG_TABLE_MERGE_TIME',        'Tables with long total merge time (last day)',    '2057046', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  538,'TABLES', 'LONG_DELTA_MERGES',            'Delta merges > 900 s (last day)',                 '2057046', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  540,'TABLES', 'FAILING_DELTA_MERGES_INFO',    'Failing delta merges (info messages last day )',  '2057046', '<=',       '5000',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  541,'TABLES', 'FAILING_DELTA_MERGES_ERROR',   'Failing delta merges (error messages last day )', '2057046', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  542,'TABLES', 'LARGE_DELTA_STORAGE_AUTO',     'Auto merge tables with delta storage > 5 GB',     '2057046', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  543,'TABLES', 'MANY_DELTA_RECORDS_AUTO',      'Auto merge tables with many delta records',       '2057046', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  544,'TABLES', 'LARGE_DELTA_STORAGE_NOAUTO',   'Non-auto merge tables with delta storage > 5 GB', '2057046', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  545,'TABLES', 'MANY_DELTA_RECORDS_NOAUTO',    'Non-auto merge tables with many delta records',   '2057046', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  547,'TABLES', 'TABLES_AUTOMERGE_DISABLED',    'Non BW tables with disabled auto merge',          '2057046', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  548,'TABLES', 'TABLES_PERSMERGE_DISABLED',    'Tables with disabled persistent merge',           '2057046', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  549,'TABLES', 'TABLES_AUTOCOMP_DISABLED',     'Non BW tables with disabled auto compression',    '2112604', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  550,'TABLES', 'ST_POINT_TABLES',              'Row store tables with ST_POINT columns',          '2038897', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  560,'TABLES', 'LARGE_TABLES_NOT_COMPRESSED',  'Tables > 10 Mio. rows not compressed',            '2105761', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  561,'TABLES', 'LARGE_COLUMNS_NOT_COMPRESSED', 'Columns > 10 Mio. rows not compressed',           '2112604', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  562,'TABLES', 'MISSING_INVERTED_INDEXES',     'Columns with missing inverted indexes',           '2160391', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  563,'TABLES', 'INDEXES_ON_SPARSE_PREFIXED',   'Indexes on large SPARSE / PREFIXED columns',      '2112604', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  565,'TABLES', 'UDIV_OVERHEAD',                'Tables > 10 Mio. rows and > 200 % UDIV rows',     '2112604', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  566,'TABLES', 'TREX_UDIV_FRAGMENTATION',      'Tables with fragmented `$trex_udiv$ column',       '2112604', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  567,'TABLES', 'LARGE_CS_MVCC_TIMESTAMPS',     'Tables with MVCC timestamps > 5 GB',              '2112604', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  570,'TABLES', 'TEMPORARY_TABLES',             'Number of temporary tables',                      '',        '<=',       '100000',        -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  572,'TABLES', 'NOLOGGING_TABLES',             'Number of NO LOGGING tables',                     '',        '<=',       '7000',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  580,'TABLES', 'TABLES_WRONG_SERVICE',         'Tables assigned to wrong service',                '',        '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  582,'TABLES', 'TABLES_WITH_EMPTY_LOCATION',   'Tables with empty table location',                '',        '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  610,'TRACES/DUMPS/LOGS', 'KERNEL_PROFILER',              'Kernel profiler active',                          '1804811', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  612,'TRACES/DUMPS/LOGS', 'PERFORMANCE_TRACE',            'Performance trace enabled',                       '1787489', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  613,'TRACES/DUMPS/LOGS', 'FUNCTION_PROFILER',            'Function profiler enabled',                       '1787489', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  623,'TRACES/DUMPS/LOGS', 'EXPENSIVE_SQL_TRACE_RECORDS',  'Traced expensive SQL statements (last day)',      '2180165', '<=',       '5000',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  639,'TRACES/DUMPS/LOGS', 'NUM_TRACE_ENTRIES_HOUR',       'Number of trace entries (last hour)',             '2380176', '<=',       '1000',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  640,'TRACES/DUMPS/LOGS', 'NUM_TRACEFILES_TOTAL',         'Number of trace files (total)',                   '1977162', '<=',       '200',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  641,'TRACES/DUMPS/LOGS', 'NUM_TRACEFILES_DAY',           'Number of trace files (last day)',                '1977162', '<=',       '30',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  642,'TRACES/DUMPS/LOGS', 'SIZE_TRACEFILES_TOTAL',        'Size of trace files (GB total)',                 '1977162', '<=',       '6.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  643,'TRACES/DUMPS/LOGS', 'SIZE_TRACEFILES_DAY',          'Size of trace files (GB last day )',              '1977162', '<=',       '1.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  644,'TRACES/DUMPS/LOGS', 'LARGEST_TRACEFILE',            'Size of largest trace file (MB)',                 '1977162', '<=',       '50.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  645,'TRACES/DUMPS/LOGS', 'NUM_OOM_TRACEFILES',           'Number of OOM trace files (last day)',            '1999997', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  646,'TRACES/DUMPS/LOGS', 'NUM_COMP_OOM_TRACEFILES',      'Number of statement OOM trace files (last day)',  '1999997', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  650,'TRACES/DUMPS/LOGS', 'NUM_CRASHDUMP_TRACEFILES',     'Number of crash dumps (last day)',                '2177064', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  652,'TRACES/DUMPS/LOGS', 'NUM_PAGEDUMP_TRACEFILES',      'Number of page dumps (last day)',                 '1977242', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  655,'TRACES/DUMPS/LOGS', 'NUM_RTEDUMP_TRACEFILES',       'Number of RTE dumps (last day)',                  '2119087', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  658,'TRACES/DUMPS/LOGS', 'LAST_SPECIAL_DUMP',            'Time since last dump (days)',                     '2119087', '>=',       '7.00',          -1,    -1 FROM DUMMY ) UNION ALL  
    ( SELECT  670,'TRACES/DUMPS/LOGS', 'LAST_TRACEFILE_MODIFICATION',  'Time since last trace file modification (s)',     '2119087', '<=',       '600',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  710,'STATISTICS SERVER', 'OPEN_ALERTS_HIGH',             'Open alerts (high priority)',                     '2053330', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  711,'STATISTICS SERVER', 'OPEN_ALERTS_ERROR',            'Open alerts (error state)',                       '2053330', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  712,'STATISTICS SERVER', 'STAT_SERVER_INTERNAL_ERRORS',  'Internal statistics server errors (last day)',    '2147247', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  715,'STATISTICS SERVER', 'CHECKS_NOT_RUNNING',           'Number of actions not executed as expected',      '2147247', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  716,'STATISTICS SERVER', 'STAT_SERVER_NO_WORKERS',       'Number of statistics server worker threads',      '2147247', '>=',       '1',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  717,'STATISTICS SERVER', 'STAT_SERVER_DISABLED_CHECKS',  'Number of disabled actions',                      '2113228', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  718,'STATISTICS SERVER', 'STAT_SERVER_INACTIVE_CHECKS',  'Number of relevant inactive actions',             '2147247', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  719,'STATISTICS SERVER', 'STAT_SERVER_UNKNOWN_STATES',   'Number of actions with unknown state',            '2147247', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  720,'STATISTICS SERVER', 'OPEN_EVENTS',                  'Events not acknowledged since >= 1800 s',         '2126236', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  730,'STATISTICS SERVER', 'OLD_PENDING_ALERT_EMAILS',     'Pending e-mails older than 3 days',               '2133799', '<=',       '100',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  735,'STATISTICS SERVER', 'STAT_SERVER_OLD_ALERTS',       'Alerts older than 42 days',                       '2170779', '<=',       '10000',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  736,'STATISTICS SERVER', 'STAT_SERVER_FREQUENT_ALERTS',  'Alerts reported frequently',                      '2147247', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  740,'STATISTICS SERVER', 'STAT_SERVER_LAST_ACTIVE',      'Time since statistics server run (s)',            '2147247', '<=',       '3600',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  745,'STATISTICS SERVER', 'STAT_SERVER_TABLE_SIZE',       'Total size of statistics server tables (GB)',     '2147247', '<=',       '30.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  746,'STATISTICS SERVER', 'STAT_SERVER_TABLE_SHARE',      'Total memory share of statistics server (%)',     '2147247', '<=',       '2.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  747,'STATISTICS SERVER', 'HOST_SQL_PLAN_CACHE_ZERO',     'Number of zero entries in HOST_SQL_PLAN_CACHE',   '2084747', '<=',       '1000000',       -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  748,'STATISTICS SERVER', 'HOST_CS_UNLOADS_ACTIVE',       'History of M_CS_UNLOADS collected',               '2147247', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  749,'STATISTICS SERVER', 'HOST_RECORD_LOCKS_ACTIVE',     'History of M_RECORD_LOCKS collected',             '2147247', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  750,'STATISTICS SERVER', 'STAT_SERVER_RETENTION',        'Stat. server tables with retention < 42 days',    '2147247', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  755,'STATISTICS SERVER', 'EMBEDDED_STAT_SERVER_USED',    'Embedded statistics server used',                 '2092033', '=',        'yes',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  760,'STATISTICS SERVER', 'ESS_MIGRATION_SUCCESSFUL',     'Status of embedded statistics server migration',  '2092033', '=',        'done (okay)',   -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  765,'STATISTICS SERVER', 'STAT_SERVER_LOG_SEGMENT_SIZE', 'Log segment size of statisticsserver (MB)',       '2019148', '>=',       '1024',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  770,'STATISTICS SERVER', 'STAT_SERVER_WRONG_HOST',       'Number of stat. server tables not on master',     '2091256', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  780,'STATISTICS SERVER', 'HOST_OBJ_LOCK_UNKNOWN',        'Unknown entries in HOST_OBJECT_LOCK_STATISTICS',  '2147247', '<=',       '1000000',       -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  810,'TRANSACTIONS AND THREADS', 'VERSIONS_ROW_STORE_CURR',      'MVCC versions in row store',                      '2169283', '<=',       '5000000',       -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  811,'TRANSACTIONS AND THREADS', 'VERSIONS_ROW_STORE_DAY',       'Max. MVCC versions in row store (last day)',      '2169283', '<=',       '10000000',      -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  812,'TRANSACTIONS AND THREADS', 'MVCC_REC_VERSIONS_ROW_STORE',  'Max. versions per record in row store',           '2169283', '<=',       '30000',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  815,'TRANSACTIONS AND THREADS', 'MVCC_TRANS_START_TIME',        'Age of transaction blocking row store MVCC (s)',  '2169283', '<=',       '10800',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  830,'TRANSACTIONS AND THREADS', 'ACTIVE_COMMIT_ID_RANGE',       'Active commit ID range',                          '2169283', '<=',       '3000000',       -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  832,'TRANSACTIONS AND THREADS', 'ACTIVE_COMMIT_ID_RANGE_DAY',   'Max. active commit ID range (last day)',          '2169283', '<=',       '8000000',       -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  841,'TRANSACTIONS AND THREADS', 'ACTIVE_UPDATE_TRANS_TIME',     'Oldest active update transaction (s)',            '2169283', '<=',       '10800',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  846,'TRANSACTIONS AND THREADS', 'TABLE_MVCC_SNAPSHOT_RANGE',    'Table MVCC snapshot range',                       '2169283', '<=',       '8000000',       -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  849,'TRANSACTIONS AND THREADS', 'ORPHAN_LOBS',                  'Orphan disk LOBs',                                '2220627', '<=',       '15000000',      -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  850,'TRANSACTIONS AND THREADS', 'MAX_GC_HISTORY_COUNT',         'Persistence garbage collection history count',    '2169283', '<=',       '3000000',       -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  852,'TRANSACTIONS AND THREADS', 'GC_UNDO_FILE_COUNT',           'Undo and cleanup files',                          '2169283', '<=',       '200000',        -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  854,'TRANSACTIONS AND THREADS', 'GC_UNDO_FILE_SIZE',            'Undo and cleanup file size (GB)',                 '2169283', '<=',       '50.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  856,'TRANSACTIONS AND THREADS', 'TRANSACTIONS_LARGE_UNDO',      'Max. undo size of current transaction (MB)',      '2169283', '<=',       '500.00',        -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  857,'TRANSACTIONS AND THREADS', 'TRANSACTIONS_LARGE_REDO',      'Max. redo size of current transaction (MB)',      '2169283', '<=',       '1000.00',       -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  860,'TRANSACTIONS AND THREADS', 'PENDING_SESSIONS_CURRENT',     'Current pending sessions',                        '',        '<=',       '5',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  863,'TRANSACTIONS AND THREADS', 'PENDING_SESSIONS_RECENT',      'Avg. pending sessions (last day)',                '',        '<=',       '1.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  870,'TRANSACTIONS AND THREADS', 'HIGH_SELFWATCHDOG_ACTIVITY',   'SelfWatchDog activity time (%  last hour)',       '1999998', '<=',       '2.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  878,'TRANSACTIONS AND THREADS', 'CONNECTIONS_CANCEL_REQUESTED', 'Connections in CANCEL REQUESTED state',           '2169283', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  880,'TRANSACTIONS AND THREADS', 'OPEN_CONNECTIONS',             'Open connections (%)',                            '1910159', '<=',       '90.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  881,'TRANSACTIONS AND THREADS', 'OPEN_TRANSACTIONS',            'Number of transactions',                          '2154870', '<=',       '20000',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  882,'TRANSACTIONS AND THREADS', 'PARKED_JOBWORKERS',            'Max. parked job worker ratio',                    '2256719', '<=',       '2.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  883,'TRANSACTIONS AND THREADS', 'QUEUED_JOBWORKERS',            'Queued job workers',                              '2222250', '<=',       '200',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  884,'TRANSACTIONS AND THREADS', 'DEVIATING_MAX_CONCURRENCY',    'Deviating max_concurrency used internally',       '2222250', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  885,'TRANSACTIONS AND THREADS', 'CUR_HIGH_DURATION_THREADS',    'SqlExecutor threads with significant duration',   '2114710', '<=',       '10',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  887,'TRANSACTIONS AND THREADS', 'CUR_APP_USER_THREADS',         'Application users with significant threads',      '2114710', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  890,'TRANSACTIONS AND THREADS', 'REC_POPULAR_THREAD_METHODS',   'Unusual frequent thread methods (last hour)',     '2114710', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALl 
    ( SELECT  910,'BACKUP', 'LAST_DATA_BACKUP',             'Age of last data backup (days)',                  '2091951', '<=',       '1.20',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  911,'BACKUP', 'LAST_DATA_BACKUP_ERROR',       'Age of last data backup error (days)',            '2091951', '>=',       '1.20',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  915,'BACKUP', 'MIN_DATA_BACKUP_THROUGHPUT',   'Min. data backup throughput (GB/h  last week)',   '1999930', '>=',       '200.00',        -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  916,'BACKUP', 'AVG_DATA_BACKUP_THROUGHPUT',   'Avg. data backup throughput (GB/h  last week)',   '1999930', '>=',       '300.00',        -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  920,'BACKUP', 'LAST_LOG_BACKUP',              'Age of last log backup (hours)',                  '2091951', '<=',       '1.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  921,'BACKUP', 'LAST_LOG_BACKUP_ERROR',        'Age of last log backup error (days)',             '2091951', '>=',       '1.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  922,'BACKUP', 'MAX_LOG_BACKUP_DURATION',      'Maximum log backup duration (s last day )',       '2063454', '<=',       '300',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  923,'BACKUP', 'LOG_BACKUP_ERRORS_LAST_MONTH', 'Log backup errors (last month)',                  '2091951', '<=',       '10',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  940,'BACKUP', 'BACKUP_CATALOG_SIZE',          'Size of backup catalog (MB)',                     '2505218', '<=',       '50.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  942,'BACKUP', 'CATALOG_BACKUP_SIZE_SHARE',    'Catalog size share (last day %)',                '2505218', '<=',       '3.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  945,'BACKUP', 'OLDEST_BACKUP_IN_CATALOG',     'Age of oldest backup in catalog (days)',          '2505218', '<=',       '100',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  950,'BACKUP', 'LOG_SEGMENTS_NOT_FREE',        'Log segments not free for reuse',                 '',        '<=',       '100',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  952,'BACKUP', 'LOG_SEGMENTS_FREE',            'Log segments free for reuse',                     '',        '<=',       '250',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT  955,'BACKUP', 'SERVICE_LOG_BACKUPS',          'Max. number of log backups / service (last day)', '',        '<=',       '300',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1010,'LOCKS', 'OLDEST_LOCK_WAIT',             'Age of oldest active trans. lock wait (s)',       '1999998', '<=',       '60',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1011,'LOCKS', 'LONG_LOCK_WAITS',              'Trans. lock wait durations > 600 s (last day)',   '1999998', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1020,'LOCKS', 'LOCKED_THREADS',               'Threads currently waiting for locks',             '1999998', '<=',       '10',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1021,'LOCKS', 'LOCKED_THREADS_LAST_DAY',      'Maximum threads waiting for locks (last day)',    '1999998', '<=',       '100',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1030,'LOCKS', 'CONC_BLOCK_TRANS_HOUR',        'Concurrently blocked transactions (last hour)',   '1999998', '<=',       '20',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1031,'LOCKS', 'CONC_BLOCK_TRANS_DAY',         'Concurrently blocked transactions (last day)',    '1999998', '<=',       '20',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1040,'LOCKS', 'TRANS_LOCKS_GLOBAL',           'Total current transactional locks',               '1999998', '<=',       '10000000',      -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1045,'LOCKS', 'OLD_TRANS_LOCKS',              'Transactional locks older than 1 day',            '1999998', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1050,'LOCKS', 'INTERNAL_LOCKS_LAST_HOUR',     'Significant internal lock waits (last hour)',     '1999998', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1052,'LOCKS', 'INTERNAL_LOCKS_LAST_DAY',      'Significant internal lock waits (last day)',      '1999998', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1110,'SQL', 'TOP_SQL_SQLCACHE',             'SQL using in average > 1 connection (last day)',  '2000002', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1112,'SQL', 'TOP_SQL_THREADSAMPLES_CURR',   'SQL using in average > 1 thread (last hour)',     '2000002', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1113,'SQL', 'TOP_SQL_THREADSAMPLES_HIST',   'SQL using in average > 1 thread (last day)',      '2000002', '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1115,'SQL', 'LONGEST_CURRENT_SQL',          'Longest running current SQL statement (h)',       '2000002', '<=',       '12.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1118,'SQL', 'LONG_RUNNING_JOB',             'Longest running current job (s)',                 '2000002', '<=',       '600',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1120,'SQL', 'EXP_TRACE_LONG_RUNNING_SQL',   'Exp. stmt. trace: SQL running > 1 h (last day)',  '2000002', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1129,'SQL', 'SQL_CACHE_EVICTIONS_LAST_DAY', 'SQL cache evictions / h (last day)',              '2124112', '<=',       '1000',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1130,'SQL', 'SQL_CACHE_EVICTIONS',          'SQL cache evictions / h',                         '2124112', '<=',       '1000',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1131,'SQL', 'SQL_CACHE_HIT_RATIO',          'SQL cache hit ratio of indexserver (%)',          '2124112', '>=',       '90.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1140,'SQL', 'SQL_PREPARATION_SHARE',        'SQL preparation runtime share (%)',               '2124112', '<=',       '5.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1142,'SQL', 'SQL_CACHE_USED_BY_TABLE',      'Table(s) using > 10 % of SQL cache',              '2124112', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1145,'SQL', 'SQL_CACHE_LONG_INLIST',        'SQL cache used by IN lists >= 100 elements (%)',  '2124112', '<=',       '20.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1147,'SQL', 'SQL_CACHE_DUPLICATE_HASHES',   'Duplicate statement hashes in SQL cache (%)',     '2124112', '<=',       '20.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1148,'SQL', 'SQL_CACHE_FREQUENT_HASH',      'Statements existing > 100 times in SQL cache',    '2124112', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1149,'SQL', 'SQL_CACHE_SESSION_LOCAL',      'Statements with SESSION LOCAL sharing type (%)',  '2124112', '<=',       '1.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1150,'SQL', 'SQL_CACHE_PINNED',             'Pinned statements in SQL cache (%)',              '2124112', '<=',       '20.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1155,'SQL', 'SUSPENDED_SQL',                'Number of SQL statements in SUSPENDED state',     '2169283', '<=',       '100',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1160,'SQL', 'AVG_COMMIT_TIME',              'Average COMMIT time (ms)',                        '2000000', '<=',       '10.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1162,'SQL', 'AVG_COMMIT_IO_TIME',           'Average COMMIT I/O time (ms)',                    '2000000', '<=',       '10.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1170,'SQL', 'AVG_DB_REQUEST_TIME',          'Average database request time (ms)',              '2000002', '<=',       '2.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1180,'SQL', 'ABAP_BUFFER_LOADING',          'Avg. ABAP buffer loading sessions (last day)',    '2000002', '<=',       '0.50',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1181,'SQL', 'FDA_WRITE',                    'Avg. FDA write sessions (last day)',              '2000002', '<=',       '0.50',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1210,'APPLICATION', 'DDLOG_SEQUENCE_CACHING',       'DDLOG sequence cache size',                       '2000002', '>=',       '2',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1220,'APPLICATION', 'QCM_TABLES',                   'QCM conversion tables',                           '9385',    '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1250,'APPLICATION', 'BPC_TABLES',                   'Physical BPC tables',                             '2445363', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1252,'APPLICATION', 'ABAP_POOL_CLUSTER_TABLES',     'Physical ABAP pool and cluster tables',           '1892354', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1270,'APPLICATION', 'TWO_COLUMN_MANDT_INDEXES',     'Two-column indexes including client column',      '2160391', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1280,'APPLICATION', 'SNAP_GROWTH_LAST_DAY',         'Growth of short dump table SNAP (GB last day )',  '2399990', '<=',       '0.50',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1310,'SECURITY', 'SECURE_STORE_AVAILABLE',       'Secure store (SSFS) status',                      '1977221', '=',        'available',     -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1331,'SECURITY', 'CONNECTION_USER_EXPIRATION',   'Connection user with (password) expiration',      '',        '=',        'none',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1340,'SECURITY', 'CATALOG_READ_GRANTED',         'CATALOG READ privilege granted to current user',  '1640741', '=',        'yes',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1360,'SECURITY', 'AUDIT_LOG_SIZE',               'Size of audit log table (GB)',                    '2388483', '<=',       '10.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1362,'SECURITY', 'ACTIVE_DML_AUDIT_POLICIES',    'Active DML audit policies',                       '2159014', '<=',       '30',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1410,'LICENSE', 'LICENSE_LIMIT',                'License usage (%)',                               '1704499', '<=',       '95',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1415,'LICENSE', 'LICENSE_EXPIRATION',           'License expiration (days)',                       '1644792', '>=',       '100',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1420,'LICENSE', 'PERMANENT_LICENSE',            'Permanent license',                               '1644792', '=',        'yes',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1510,'NETWORK', 'SERVICE_SEND_INTRANODE',       'Avg. intra node send throughput (MB/s)',          '2222200', '>=',       '120',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1512,'NETWORK', 'SERVICE_SEND_INTERNODE',       'Avg. inter node send throughput (MB/s)',          '2222200', '>=',       '80',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1520,'NETWORK', 'TCP_RETRANSMITTED_SEGMENTS',   'Retransmitted TCP segments (%)',                  '2222200', '<=',       '1.00000',       -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1522,'NETWORK', 'TCP_BAD_SEGMENTS',             'Bad TCP segments (%)',                            '2222200', '<=',       '0.10000',       -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1530,'NETWORK', 'NETWORK_VOLUME_INTRANODE',     'Avg. intra node communication volume (MB/s)',     '2222200', '<=',       '30',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1532,'NETWORK', 'NETWORK_VOLUME_INTERNODE',     'Avg. inter node communication volume (MB/s)',     '2222200', '<=',       '20',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1540,'NETWORK', 'HOST_NAME_RESOLUTION',         'Host name resolution for non IP addresses',       '2222200', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1710,'NAMESERVER', 'PING_TIME_HOUR',               'Avg. indexserver ping time (ms  last hour)',      '2222110', '<=',       '100.00',        -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1712,'NAMESERVER', 'PING_TIME_DAY',                'Avg. indexserver ping time (ms last day )',       '2222110', '<=',       '80.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1720,'NAMESERVER', 'NAMESERVER_LOCKFILE_LOCATION', 'Supported nameserver lock file location',         '2100296', '=',        'yes',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1810,'SYSTEM REPLICATION', 'REPLICATION_ERROR',            'Services with replication error',                 '1999880', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1811,'SYSTEM REPLICATION', 'REPLICATION_UNKNOWN',          'Services with unknown replication state',         '1999880', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1813,'SYSTEM REPLICATION', 'REP_CONNECTION_CLOSED',        'Replication connection closed (last day)',        '1999880', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1814,'SYSTEM REPLICATION', 'OLD_LOG_POSITION',             'Log position gap (MB)',                           '2436931', '<=',       '100',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1815,'SYSTEM REPLICATION', 'LOG_SHIPPING_DELAY',           'Current log shipping delay (s)',                  '1999880', '<=',       '60',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1816,'SYSTEM REPLICATION', 'LOG_SHIPPING_ASYNC_BUFF_FILL', 'Filling level of async shipping buffer (%)',      '1999880', '<=',       '50',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1818,'SYSTEM REPLICATION', 'ASYNC_BUFFER_FULL_LAST_DAY',   'Async log shipping buffer full (last day)',       '1999880', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1820,'SYSTEM REPLICATION', 'REP_PARAMETER_DEVIATION',      'Parameter deviations primary vs. secondary site', '1999880', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1830,'SYSTEM REPLICATION', 'OLDEST_REPLICATION_SNAPSHOT',  'Age of oldest replication snapshot (h)',          '1999880', '<=',       '5.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1840,'SYSTEM REPLICATION', 'SYNC_LOG_SHIPPING_TIME_CURR',  'Avg. sync log shipping time (ms/req  last hour)', '1999880', '<=',       '2.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1843,'SYSTEM REPLICATION', 'SYNC_LOG_SHIPPING_TIME_REC',   'Avg. sync log shipping time (ms/req last day )',  '1999880', '<=',       '2.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1846,'SYSTEM REPLICATION', 'SYNC_LOG_SHIPPING_TIME_HIST',  'Max. sync log shipping time (ms/req history)',   '1999880', '<=',       '5.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1852,'SYSTEM REPLICATION', 'SR_LOGREPLAY_BACKLOG',         'Current log replay backlog (GB)',                 '2409671', '<=',       '50.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1860,'SYSTEM REPLICATION', 'DATASHIPPING_LOGRETENTION',    'Datashipping combined with log retention',        '1999880', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1865,'SYSTEM REPLICATION', 'REPLICATION_SAVEPOINT_DELAY',  'System replication savepoint delay (h)',          '1999880', '<=',       '4.00',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 1920,'OBJECTS', 'INVALID_PROCEDURES',           'Number of invalid procedures',                    '',        '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2010,'BW', 'EMPTY_TABLE_PLACEMENT',        'Empty TABLE_PLACEMENT table in BW',               '1908075', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2020,'BW', 'NUM_PARTITIONED_SID_TABLES',   'Partitioned SID tables',                          '2044468', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2022,'BW', 'SID_TABLES_WITH_MANY_RECORDS', 'SID tables > 1.5 billion rows',                   '1331403', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2025,'BW', 'NUM_PART_SPECIAL_TABLES',      'Partitioned special BW tables < 1.5 bill. rows',  '2044468', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2030,'BW', 'BW_SCALEOUT_TWO_NODES',        'BW scale-out installation on 2 nodes',            '1702409', '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2040,'BW', 'TEMPORARY_BW_TABLES',          'Temporary BW tables',                             '2388483', '<=',       '1000',          -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2050,'BW', 'INVERTED_HASH_ON_BW_TABLE',    'BW tables with inverted hash indexes',            '2109355', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2110,'CONSISTENCY', 'CTC_ERRORS_LAST_MONTH',        'CHECK_TABLE_CONSISTENCY errors (last month)',     '1977584', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2113,'CONSISTENCY', 'LAST_CTC_RUN',                 'Last global table consistency check (days)',      '2116157', '<=',       '32.00',         -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2115,'CONSISTENCY', 'CS_TABLES_OLD_CTC',            'Tables without recent consistency check',         '2116157', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2116,'CONSISTENCY', 'CS_TABLES_CTC_ERRORS',         'Tables with consistency check errors',            '2116157', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2130,'CONSISTENCY', 'TOPOLOGY_DAEMON_INCONSISTENT', 'Inconsistencies between topology and daemon',     '2222249', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2135,'CONSISTENCY', 'TOPOLOGY_ROLES_INCONSISTENT',  'Inconsistent node role definition in topology',   '',        '=',        'no',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2140,'CONSISTENCY', 'METADATA_DEP_INCONSISTENT',    'Inconsistencies of metadata and dependencies',    '2498587', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2210,'SMART DATA ACCESS / SMART DATA INTEGRATION', 'SDA_TABLES_WITHOUT_STATS',     'SDA tables without statistics',                   '2180119', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2220,'SMART DATA ACCESS / SMART DATA INTEGRATION', 'SDI_SUBSCRIPTION_EXCEPTIONS',  'SDI remote subscription exceptions',              '2400022', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2230,'SMART DATA ACCESS / SMART DATA INTEGRATION', 'DPSERVER_ON_SLAVE_NODES',      'Slave nodes with dpserver processes',             '2391341', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2310,'ADMINISTRATION', 'HDBSTUDIO_CONNECTIONS',        'SAP HANA Studio connections',                     '2073112', '<=',       '100',           -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2315,'ADMINISTRATION', 'OUTDATED_HDBSTUDIO_VERSION',   'Connections with old SAP HANA Studio versions',   '2073112', '=',        '0',             -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2320,'ADMINISTRATION', 'LAST_HDBCONS_EXECUTION',       'Time since last hdbcons execution (h)',           '2222218', '>=',       '24',            -1,    -1 FROM DUMMY ) UNION ALL 
    ( SELECT 2410,'TABLE REPLICATION', 'INACTIVE_TABLE_REPLICAS',      'Inactive table replicas',                         '2340450', '=',        '0',             -1,    -1 FROM DUMMY )

/* TMC_GENERATION_END_2 */
  ) CC
  WHERE
    C.NAME = CC.NAME AND
    ( IFNULL(C.HOST, '') = '' OR C.HOST LIKE BI.HOST ) AND	
    REL.REVISION BETWEEN CC.MIN_REV AND MAP(CC.MAX_REV, -1, 99999, CC.MAX_REV) AND
    ( BI.CHECK_ID = -1 OR CC.CHECK_ID = BI.CHECK_ID ) AND
    ( BI.CHECK_GROUP = '%' OR
      BI.CHECK_GROUP = 'GENERAL'                                    AND CC.CHECK_ID BETWEEN    0 AND  199 OR
      BI.CHECK_GROUP = 'OPERATING SYSTEM'                           AND CC.CHECK_ID BETWEEN  200 AND  299 OR
      BI.CHECK_GROUP = 'DISKS'                                      AND CC.CHECK_ID BETWEEN  300 AND  399 OR
      BI.CHECK_GROUP = 'MEMORY'                                     AND CC.CHECK_ID BETWEEN  400 AND  499 OR
      BI.CHECK_GROUP = 'TABLES'                                     AND CC.CHECK_ID BETWEEN  500 AND  599 OR
      BI.CHECK_GROUP = 'TRACES, DUMPS AND LOGS'                     AND CC.CHECK_ID BETWEEN  600 AND  699 OR
      BI.CHECK_GROUP = 'STATISTICS SERVER'                          AND CC.CHECK_ID BETWEEN  700 AND  799 OR
      BI.CHECK_GROUP = 'TRANSACTIONS AND THREADS'                   AND CC.CHECK_ID BETWEEN  800 AND  899 OR
      BI.CHECK_GROUP = 'BACKUP'                                     AND CC.CHECK_ID BETWEEN  900 AND  999 OR
      BI.CHECK_GROUP = 'LOCKS'                                      AND CC.CHECK_ID BETWEEN 1000 AND 1099 OR
      BI.CHECK_GROUP = 'SQL'                                        AND CC.CHECK_ID BETWEEN 1100 AND 1199 OR
      BI.CHECK_GROUP = 'APPLICATION'                                AND CC.CHECK_ID BETWEEN 1200 AND 1299 OR
      BI.CHECK_GROUP = 'SECURITY'                                   AND CC.CHECK_ID BETWEEN 1300 AND 1399 OR
      BI.CHECK_GROUP = 'LICENSE'                                    AND CC.CHECK_ID BETWEEN 1400 AND 1499 OR
      BI.CHECK_GROUP = 'NETWORK'                                    AND CC.CHECK_ID BETWEEN 1500 AND 1599 OR
      BI.CHECK_GROUP = 'XS ENGINE'                                  AND CC.CHECK_ID BETWEEN 1600 AND 1699 OR
      BI.CHECK_GROUP = 'NAMESERVER'                                 AND CC.CHECK_ID BETWEEN 1700 AND 1799 OR
      BI.CHECK_GROUP = 'SYSTEM REPLICATION'                         AND CC.CHECK_ID BETWEEN 1800 AND 1899 OR
      BI.CHECK_GROUP = 'OBJECTS'                                    AND CC.CHECK_ID BETWEEN 1900 AND 1999 OR
      BI.CHECK_GROUP = 'BW'                                         AND CC.CHECK_ID BETWEEN 2000 AND 2099 OR
      BI.CHECK_GROUP = 'CONSISTENCY'                                AND CC.CHECK_ID BETWEEN 2100 AND 2199 OR
      BI.CHECK_GROUP = 'SMART DATA ACCESS / SMART DATA INTEGRATION' AND CC.CHECK_ID BETWEEN 2200 AND 2299 OR
      BI.CHECK_GROUP = 'ADMINISTRATION'                             AND CC.CHECK_ID BETWEEN 2300 AND 2399 OR
      BI.CHECK_GROUP = 'TABLE REPLICATION'                          AND CC.CHECK_ID BETWEEN 2400 AND 2499
    )
) M
WHERE
  ONLY_POTENTIALLY_CRITICAL_RESULTS = ' ' OR POTENTIALLY_CRITICAL = 'X' OR M.CHECK_ID <= 10
ORDER BY
  MAP(M.ORDER_BY, 'CHECK', M.CHECK_ID),
  M.HOST,
  M.VALUE
WITH HINT (NO_SUBPLAN_SHARING)
"
			$cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
			$ds=New-Object system.Data.DataSet ;
            Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query29 CollectorType=State , Category=ConfigurationCheck"  

$ex=$null
			Try{
				$cmd.fill($ds) | out-null
			}
			Catch
			{
				$Ex=$_.Exception.MEssage;write-warning "Failed to run Query29"
			}
			      

            If(!$ex)
            {
                 $trackhost+=new-object pscustomobject -property @{
                        Host=$saphost
                        ConfigCheckRun=$true
                     }


            }
            
			[System.Collections.ArrayList]$Resultsstate=@(); 

		
			Write-Output ' CollectorType="State" ,  Category="SAPConfMiniChecks"'
        
            
			foreach ($row in $ds.Tables[0].rows)
			{
				
				$cu=$null
                    $cu=[PSCustomObject]@{
					CollectorType="State"
					Category="ConfigurationCheck"
					Database=$(IF([String]::IsNullOrEmpty($row.DATABASE_NAME)){$hanadb}Else{$row.DATABASE_NAME})
                    CHID=[int]$row.CHID
                    SubCategory=$row.Category
                    NAME=$row.NAME
                    DESCRIPTION=$row.DESCRIPTION
                    CONDITION=[String]$row.EXPECTED_VALUE 
                    HOST= $(IF([String]::IsNullOrEmpty($row.HOST)){$saphost}Else{$row.HOST})
                    RESULT=$(IF($row.c -eq 'X'){"Fail"}Else{"Pass"})
                    SAP_NOTE=$row.SAP_NOTE.Trim()
					
				}
                if( $row.Category -ne 'SAP HANA MINI CHECKS' -and $row.Value -match '^([0-9])' -and $row.Value -notmatch '([a-zA-Z])')
                {
                   $row.VALUE
                    Add-Member -InputObject $cu -MemberType NoteProperty -Name Value -Value $([Double]$row.Value)
                }


                $resultsstate.ADD($cu)|Out-Null
			}

			If($resultsstate)
			{

				$jsonlogs=$null
				$dataitem=$null
				


					$jsonlogs= ConvertTo-Json -InputObject $resultsstate
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
 #endregion

#region Hana Table Inventory
IF($runmode -eq 'daily'  -and $collecttableinv -eq $true)  #run only in daily schedule  with Table inventory switch 
 {

 IF($false)
{
    Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query22 CollectorType=Inventory - Category=Tables - Largest"	

	  $query="/* OMS -Query22*/SELECT OWNER,
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
	   $cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
		  $ds=New-Object system.Data.DataSet ;
	  $ex=$null
		  Try{
			  $cmd.fill($ds)|out-null
		  }
		  Catch
		  {
			  $Ex=$_.Exception.MEssage;write-warning "Failed to run Query22"
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
					  Category="Tables"
					  Subcategory="Largest"
					  Database=$Hanadb
					  TableName=$row.TABLE_NAME
					  StoreType=$row.S
					  Loaded=$row.L
					  POS=$row.POS
					  COLS=$row.COLS
					  RECORDS=[long]$row.RECORDS    
				  })|Out-Null
			  }
			
		  }

}

### New table query 

 Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Query44 CollectorType=Inventory - Category=Tables - Largest"	

	  $query="/* OMS -Query44*/SELECT * FROM M_CS_TABLES 
WHERE TABLE_NAME IN
(SELECT TOP 50 TABLE_NAME FROM
( SELECT TABLE_NAME, SUM(RECORD_COUNT) as TOTAL FROM M_TABLES  GROUP BY TABLE_NAME )ORDER by TOTAL DESC)"

	   $cmd=new-object Sap.Data.Hana.HanaDataAdapter($Query, $conn);
		  $ds=New-Object system.Data.DataSet ;
	  $ex=$null
		  Try{
			  $cmd.fill($ds)|out-null
		  }
		  Catch
		  {
			  $Ex=$_.Exception.MEssage;write-warning "Failed to run Query22"
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
                      PORT=$row.Port
					  Instance=$sapinstance
					  CollectorType="Inventory"
					  Category="Tables"
					  Subcategory="Largest"
					  Database=$Hanadb
					  TableName=$row.TABLE_NAME
                        PART_ID=$row.PART_ID
                        SCHEMA_NAME=$row.SCHEMA_NAME
                        MEMORY_SIZE_IN_TOTAL_MB=[math]::Round($row.MEMORY_SIZE_IN_TOTAL/1024/1024,0)
                        MEMORY_SIZE_IN_MAIN_MB=[math]::Round($row.MEMORY_SIZE_IN_MAIN/1024/1024,0)
                        MEMORY_SIZE_IN_DELTA_MB =[math]::Round($row.MEMORY_SIZE_IN_DELTA /1024/1024,0)
                        MEMORY_SIZE_IN_HISTORY_MAIN_MB=[math]::Round($row.MEMORY_SIZE_IN_HISTORY_MAIN/1024/1024,0)
                        MEMORY_SIZE_IN_HISTORY_DELTA_MB=[math]::Round($row.MEMORY_SIZE_IN_HISTORY_DELTA/1024/1024,0)
                        MEMORY_SIZE_IN_PAGE_LOADABLE_MAIN_MB=[math]::Round($row.MEMORY_SIZE_IN_PAGE_LOADABLE_MAIN /1024/1024 ,0)
                        PERSISTENT_MEMORY_SIZE_IN_TOTAL_MB  =[math]::Round($row.PERSISTENT_MEMORY_SIZE_IN_TOTAL/1024/1024,0)
                        ESTIMATED_MAX_MEMORY_SIZE_IN_TOTAL_MB=[math]::Round($row.ESTIMATED_MAX_MEMORY_SIZE_IN_TOTAL/1024/1024,0)
                        LAST_ESTIMATED_MEMORY_SIZE_MB =[math]::Round($row.LAST_ESTIMATED_MEMORY_SIZE/1024/1024,0)
                        LAST_ESTIMATED_MEMORY_SIZE_TIME  =$row.LAST_ESTIMATED_MEMORY_SIZE_TIME
                        RECORD_COUNT =[long]$row.RECORD_COUNT 
                        RAW_RECORD_COUNT_IN_MAIN   =[long]$row.RAW_RECORD_COUNT_IN_MAIN 
                        RAW_RECORD_COUNT_IN_DELTA  =[long]$row.RAW_RECORD_COUNT_IN_DELTA
                        RAW_RECORD_COUNT_IN_HISTORY_MAIN =[long]$row.RAW_RECORD_COUNT_IN_HISTORY_MAIN   
                        RAW_RECORD_COUNT_IN_HISTORY_DELTA=[long]$row.RAW_RECORD_COUNT_IN_HISTORY_DELTA  
                        LAST_COMPRESSED_RECORD_COUNT =[long]$row.LAST_COMPRESSED_RECORD_COUNT 
                        MAX_UDIV   =$row.MAX_UDIV   
                        MAX_MERGE_CID=$row.MAX_MERGE_CID
                        MAX_ROWID  =$row.MAX_ROWID  
                        IS_DELTA2_ACTIVE =$row.IS_DELTA2_ACTIVE 
                        IS_DELTA_LOADED  =$row.IS_DELTA_LOADED  
                        IS_LOG_DELTA =$row.IS_LOG_DELTA 
                        PERSISTENT_MERGE =$row.PERSISTENT_MERGE 
                        CREATE_TIME=$row.CREATE_TIME
                        MODIFY_TIME=$row.MODIFY_TIME
                        LAST_MERGE_TIME  =$row.LAST_MERGE_TIME  
                        LAST_REPLAY_LOG_TIME =$row.LAST_REPLAY_LOG_TIME   
                        LAST_TRUNCATION_TIME =$row.LAST_TRUNCATION_TIME   
                        LAST_CONSISTENCY_CHECK_TIME=$row.LAST_CONSISTENCY_CHECK_TIME  
                        LAST_CONSISTENCY_CHECK_ERROR_COUNT=$row.LAST_CONSISTENCY_CHECK_ERROR_COUNT 
                        LOADED =$row.LOADED 
                        READ_COUNT =$row.READ_COUNT 
                        WRITE_COUNT=$row.WRITE_COUNT
                        MERGE_COUNT=$row.MERGE_COUNT
                        IS_REPLICA =$row.IS_REPLICA 
                        UNUSED_RETENTION_PERIOD=$row.UNUSED_RETENTION_PERIOD
                        PERSISTENT_MEMORY=$row.PERSISTENT_MEMORY 
				  })|Out-Null
			  }
			
		  }






           Write-Output "Elapsed Time : $([math]::round($stopwatch.Elapsed.TotalSeconds,0))"
            If($resultsinv)
			{
				$jsonlogs=$null
				$dataitem=$null
				
                $jsonlogs= ConvertTo-Json -InputObject $resultsinv
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


