param
(
[Parameter(Mandatory=$false)] [string] $configfolder="C:\HanaMonitor",
[Parameter(Mandatory=$true)] [string] $query
)


#Runmode  options :
#   "default  - Regulat checks every 15 min"
#   "daily - Long running checks  ( Hana Config Cheks and Hana Table Inventory"
#   With Daily switch Long Running  collections can be scheduled seperately 
#


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
		
    
		
        #region Connect to Hana DB
        $ex=$null

		Try
		{
			$conn.open()
		}
		Catch
		{
			$Ex=$_.Exception.MEssage;write-warning $Ex
		}
		
	
        #end region
		IF ($conn.State -eq 'open')
		{	    
			
            Write-Output "$((get-date).ToString('dd-MM-yyyy hh:mm:ss')) Succesfully connected to $hanadb on  $($ins.HanaServer):$($ins.Port)"
            $stopwatch=[system.diagnostics.stopwatch]::StartNew()

   


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
					
			Write-output "Query run time: 	$([Math]::Round($stopwatch.Elapsed.TotalSeconds,0)) seconds "
            
            $ds.Tables[0].rows|select |select -First 10|ft
1

   		
		$Omsupload=$null
		$omsupload=@()
		$conn.Close()
        $i++
      
      }Else
      {
         Write-output  "Connection to database is not in open state"
      }
      {

        Write-output "$($rule.Database)  is not enabled for data collection in config file"
      }

	}


	$colend=Get-date
	write-output "Collected all data in  $(($colend-$colstart).Totalseconds)  seconds"
	
}


}