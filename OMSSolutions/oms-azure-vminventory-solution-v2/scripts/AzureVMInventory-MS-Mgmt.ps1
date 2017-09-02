
param(
    [Parameter(Mandatory=$false)] [int] $apireadlimit=7500,
    [Parameter(Mandatory=$false)] [bool] $getarmvmstatus=$true,
    [Parameter(Mandatory=$false)] [bool] $getNICandNSG=$true,
    [Parameter(Mandatory=$false)] [bool] $getDiskInfo=$true
    
    )

#region Variables definition
# Variables definition
# Common  variables  accross solution 

$StartTime = [dateTime]::Now
$rbstart=get-date
$Timestampfield = "Timestamp" 

#Update customer Id to your Operational Insights workspace ID
$customerID = Get-AutomationVariable -Name  "AzureVMInventory-OPSINSIGHTS_WS_ID"

#For shared key use either the primary or seconday Connected Sources client authentication key   
$sharedKey = Get-AutomationVariable -Name  "AzureVMInventory-OPSINSIGHT_WS_KEY"

$ApiVerSaAsm = '2016-04-01'
$ApiVerSaArm = '2016-01-01'
$ApiStorage='2016-05-31'
$apiverVM='2016-02-01'

# OMS log analytics custom log name

$logname='AzureVMInventory'

# Runbook specific variables 

$VMstates = @{
"StoppedDeallocated"="Deallocated";
"ReadyRole"="Running";
"PowerState/deallocated"="Deallocated";
"PowerState/stopped" ="Stopped";
"StoppedVM" ="Stopped";
"PowerState/running" ="Running"}

#Define VMSizes - Fetch from variable but failback to hardcoded if needed 
$vmiolimits = Get-AutomationVariable -Name 'VMinfo_-IOPSLimits'  -ea 0 

IF(!$vmiolimits)
{
$vmiolimits=@{"Basic_A0"=300;
"Basic_A1"=300;
"Basic_A2"=300;
"Basic_A3"=300;
"Basic_A4"=300;
"ExtraSmall"=500;
"Small"=500;
"Medium"=500;
"Large"=500;
"ExtraLarge"=500;
"Standard_A0"=500;
"Standard_A1"=500;
"Standard_A2"=500;
"Standard_A3"=500;
"Standard_A4"=500;
"Standard_A5"=500;
"Standard_A6"=500;
"Standard_A7"=500;
"Standard_A8"=500;
"Standard_A9"=500;
"Standard_A10"=500;
"Standard_A11"=500;
"Standard_A1_v2"=500;
"Standard_A2_v2"=500;
"Standard_A4_v2"=500;
"Standard_A8_v2"=500;
"Standard_A2m_v2"=500;
"Standard_A4m_v2"=500;
"Standard_A8m_v2"=500;
"Standard_D1"=500;
"Standard_D2"=500;
"Standard_D3"=500;
"Standard_D4"=500;
"Standard_D11"=500;
"Standard_D12"=500;
"Standard_D13"=500;
"Standard_D14"=500;
"Standard_D1_v2"=500;
"Standard_D2_v2"=500;
"Standard_D3_v2"=500;
"Standard_D4_v2"=500;
"Standard_D5_v2"=500;
"Standard_D11_v2"=500;
"Standard_D12_v2"=500;
"Standard_D13_v2"=500;
"Standard_D14_v2"=500;
"Standard_D15_v2"=500;
"Standard_DS1"=3200;
"Standard_DS2"=6400;
"Standard_DS3"=12800;
"Standard_DS4"=25600;
"Standard_DS11"=6400;
"Standard_DS12"=12800;
"Standard_DS13"=25600;
"Standard_DS14"=51200;
"Standard_DS1_v2"=3200;
"Standard_DS2_v2"=6400;
"Standard_DS3_v2"=12800;
"Standard_DS4_v2"=25600;
"Standard_DS5_v2"=51200;
"Standard_DS11_v2"=6400;
"Standard_DS12_v2"=12800;
"Standard_DS13_v2"=25600;
"Standard_DS14_v2"=51200;
"Standard_DS15_v2"=64000;
"Standard_D2s_v3"=4000;
"Standard_D4s_v3"=8000;
"Standard_D8s_v3"=16000;
"Standard_D16s_v3"=32000;
"Standard_D2_v3"=3000;
"Standard_D4_v3"=6000;
"Standard_D8_v3"=12000;
"Standard_D16_v3"=24000;
"Standard_F1"=500;
"Standard_F2"=500;
"Standard_F4"=500;
"Standard_F8"=500;
"Standard_F16"=500;
"Standard_F1s"=3200;
"Standard_F2s"=6400;
"Standard_F4s"=12800;
"Standard_F8s"=25600;
"Standard_F16s"=51200;
"Standard_G1"=500;
"Standard_G2"=500;
"Standard_G3"=500;
"Standard_G4"=500;
"Standard_G5"=500;
"Standard_GS1"=5000;
"Standard_GS2"=10000;
"Standard_GS3"=20000;
"Standard_GS4"=40000;
"Standard_GS5"=80000;
"Standard_H8"=500;
"Standard_H16"=500;
"Standard_H8m"=500;
"Standard_H16m"=500;
"Standard_H16r"=500;
"Standard_H16mr"=500;
"Standard_NV6"=500;
"Standard_NV12"=500;
"Standard_NV24"=500;
"Standard_NC6"=500;
"Standard_NC12"=500;
"Standard_NC24"=500;
"Standard_NC24r"=500}


}




#endregion

#region Login to Azure Using both ARM , ASM and REST
#Authenticate to Azure with SPN section
"Logging in to Azure..."
$ArmConn = Get-AutomationConnection -Name AzureRunAsConnection 
$AsmConn = Get-AutomationConnection -Name AzureClassicRunAsConnection  


# retry
$retry = 6
$syncOk = $false
do
{ 
	try
	{  
		Add-AzureRMAccount -ServicePrincipal -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint 
		$syncOk = $true
	}
	catch
	{
		$ErrorMessage = $_.Exception.Message
		$StackTrace = $_.Exception.StackTrace
		Write-Warning "Error during sync: $ErrorMessage, stack: $StackTrace. Retry attempts left: $retry"
		$retry = $retry - 1       
		Start-Sleep -s 60        
	}
} while (-not $syncOk -and $retry -ge 0)

"Selecting Azure subscription..."
$SelectedAzureSub = Select-AzureRmSubscription -SubscriptionId $ArmConn.SubscriptionId -TenantId $ArmConn.tenantid 


#Creating headers for REST ARM Interface



#"Azure rm profile path  $((get-module -Name AzureRM.Profile).path) "

$path=(get-module -Name AzureRM.Profile).path
$path=Split-Path $path
$dlllist=Get-ChildItem -Path $path  -Filter Microsoft.IdentityModel.Clients.ActiveDirectory.dll  -Recurse
$adal =  $dlllist[0].VersionInfo.FileName



try
{
	Add-type -Path $adal
	[reflection.assembly]::LoadWithPartialName( "Microsoft.IdentityModel.Clients.ActiveDirectory" )

}
catch
{
	$ErrorMessage = $_.Exception.Message
	$StackTrace = $_.Exception.StackTrace
	Write-Warning "Error during sync: $ErrorMessage, stack: $StackTrace. "
}


#Create authentication token using the Certificate for ARM connection

$retry = 6
$syncOk = $false
do
{ 
	try
	{  
		$certs= Get-ChildItem -Path Cert:\Currentuser\my -Recurse | Where{$_.Thumbprint -eq $ArmConn.CertificateThumbprint}

		[System.Security.Cryptography.X509Certificates.X509Certificate2]$mycert=$certs[0]

		$syncOk = $true
	}
	catch
	{
		$ErrorMessage = $_.Exception.Message
		$StackTrace = $_.Exception.StackTrace
		Write-Warning "Error during certificate retrieval : $ErrorMessage, stack: $StackTrace. Retry attempts left: $retry"
		$retry = $retry - 1       
		Start-Sleep -s 60        
	}
} while (-not $syncOk -and $retry -ge 0)

IF ($mycert)
{
		$CliCert=new-object   Microsoft.IdentityModel.Clients.ActiveDirectory.ClientAssertionCertificate($ArmConn.ApplicationId,$mycert)
	$AuthContext = new-object Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext("https://login.windows.net/$($ArmConn.tenantid)")
	$result = $AuthContext.AcquireToken("https://management.core.windows.net/",$CliCert)
	$header = "Bearer " + $result.AccessToken
	$headers = @{"Authorization"=$header;"Accept"="application/json"}
    $body=$null
	$HTTPVerb="GET"
	$subscriptionInfoUri = "https://management.azure.com/subscriptions/"+$ArmConn.SubscriptionId+"?api-version=$apiverVM"
	$subscriptionInfo = Invoke-RestMethod -Uri $subscriptionInfoUri -Headers $headers -Method Get -UseBasicParsing



  
	IF($subscriptionInfo)
	{
		"Successfully connected to Azure ARM REST;"
       # $subscriptionInfo
	}
    Else
    {

        Write-warning "Unable to login to Azure ARM Rest , runbook will not continue"
        Exit

    }
}
Else
{
	Write-error "Failed to login ro Azure ARM REST  , make sure Runas account configured correctly"
	Exit
}

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
	$uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

	$OMSheaders = @{
		"Authorization" = $signature;
		"Log-Type" = $logType;
		"x-ms-date" = $rfc1123date;
		"time-generated-field" = $TimeStampField;
	}

#write-output "OMS parameters"
#$OMSheaders
	Try
    {

		$response = Invoke-WebRequest -Uri $uri -Method POST  -ContentType $contentType -Headers $OMSheaders -Body $body -UseBasicParsing
	}
	Catch
	{
		$_.MEssage
	}
	return $response.StatusCode
	write-output $response.StatusCode
	Write-error $error[0]
}

#endregion



$timestamp=(get-date).ToUniversalTime().ToString("yyyy-MM-ddT$($hour):$($min):00.000Z")

"Starting $(get-date),Memory Usage    $([System.gc]::gettotalmemory('forcefullcollection') /1MB)"
#################


 $SubscriptionsURI="https://management.azure.com/subscriptions?api-version=2016-06-01" 
 $Subscriptions = Invoke-WebRequest -Uri  $SubscriptionsURI -Method GET  -Headers $headers -UseBasicParsing 
 $Subscriptions =  @((ConvertFrom-Json -InputObject $Subscriptions.Content).value)
 Write-Output "$($Subscriptions.count)  subscrptions found"


#Variable to sync between runspaces

$hash = [hashtable]::New(@{})
$hash['Host']=$host
$hash['subscriptionInfo']=$subscriptionInfo
$hash['ArmConn']=$ArmConn
$hash['AsmConn']=$AsmConn
$hash['headers']=$headers
$hash['headerasm']=$headers
$hash['AzureCert']=$AzureCert
$hash['Timestampfield']=$Timestampfield

$hash['customerID'] =$customerID
$hash['syncInterval']=$syncInterval
$hash['sharedKey']=$sharedKey 
$hash['Logname']=$logname

$hash['ApiVerSaAsm']=$ApiVerSaAsm
$hash['ApiVerSaArm']=$ApiVerSaArm
$hash['ApiStorage']=$ApiStorage
$hash['apiverVM']=$apiverVM

$hash['AAAccount']=$AAAccount
$hash['AAResourceGroup']=$AAResourceGroup

$hash['debuglog']=$true

$hash['apireadlimit']=$apireadlimit
$hash['getarmvmstatus']=$getarmvmstatus
$hash['getNICandNSG']=$getNICandNSG
$hash['getDiskInfo']=$getDiskInfo
$hash['VMstates']=$VMstates
$hash['vmiolimits']=$vmiolimits
$hash['SubscriptionCount']=$Subscriptions.Count
$hash['TotalVMCount']=0
$hash['TotalVHDCount']=0
$hash['TotalNSGCount']=0
$hash['TotalEndPointCount']=0
$hash['TotalExtensionCount']=0
$hash['TotalVMScaleSetCount']=0


$SAInfo=@()
$hash.'SAInfo'=$sainfo



$Throttle = [int][System.Environment]::ProcessorCount+1  #threads
 
$sessionstate = [system.management.automation.runspaces.initialsessionstate]::CreateDefault()
$runspacepool = [runspacefactory]::CreateRunspacePool(1, $Throttle, $sessionstate, $Host)
$runspacepool.Open() 
[System.Collections.ArrayList]$Jobs = @()

$scriptBlock={

Param ($hash,$rsid,$subscriptionID,$subscriptionname)


$ArmConn=$hash.ArmConn
$headers=$hash.headers
$AsmConn=$hash.AsmConn
$headerasm=$hash.headerasm
$AzureCert=$hash.AzureCert

$Timestampfield = $hash.Timestampfield

$Currency=$hash.Currency
$Locale=$hash.Locale
$RegionInfo=$hash.RegionInfo
$OfferDurableId=$hash.OfferDurableId
$syncInterval=$Hash.syncInterval
$customerID =$hash.customerID 
$sharedKey = $hash.sharedKey
$logname=$hash.Logname
$StartTime = [dateTime]::Now
$ApiVerSaAsm = $hash.ApiVerSaAsm
$ApiVerSaArm = $hash.ApiVerSaArm
$ApiStorage=$hash.ApiStorage
$apiverVM=$hash.apiverVM
$AAAccount = $hash.AAAccount
$AAResourceGroup = $hash.AAResourceGroup
$debuglog=$hash.deguglog
$apireadlimit=$hash.'apireadlimit'
$getarmvmstatus=$hash.'getarmvmstatus'
$getNICandNSG=$hash.'getNICandNSG'
$getDiskInfo=$hash.'getDiskInfo'
$VMstates=$hash.VMstates
$vmiolimits=$hash.vmiolimits



#endregion



#region Define Required Functions

Function Build-tableSignature ($customerId, $sharedKey, $date,  $method,  $resource,$uri)
{
	$stringToHash = $method + "`n" + "`n" + "`n"+$date+"`n"+"/"+$resource+$uri.AbsolutePath
	Add-Type -AssemblyName System.Web
	$query = [System.Web.HttpUtility]::ParseQueryString($uri.query)  
	$querystr=''
	$bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
	$keyBytes = [Convert]::FromBase64String($sharedKey)
	$sha256 = New-Object System.Security.Cryptography.HMACSHA256
	$sha256.Key = $keyBytes
	$calculatedHash = $sha256.ComputeHash($bytesToHash)
	$encodedHash = [Convert]::ToBase64String($calculatedHash)
	$authorization = 'SharedKey {0}:{1}' -f $resource,$encodedHash
	return $authorization
	
}
# Create the function to create the authorization signature
Function Build-StorageSignature ($sharedKey, $date,  $method, $bodylength, $resource,$uri ,$service)
{
	Add-Type -AssemblyName System.Web
	$str=  New-Object -TypeName "System.Text.StringBuilder";
	$builder=  [System.Text.StringBuilder]::new("/")
	$builder.Append($resource) |out-null
	$builder.Append($uri.AbsolutePath) | out-null
	$str.Append($builder.ToString()) | out-null
	$values2=@{}
	IF($service -eq 'Table')
	{
		$values= [System.Web.HttpUtility]::ParseQueryString($uri.query)  
		#    NameValueCollection values = HttpUtility.ParseQueryString(address.Query);
		foreach ($str2 in $values.Keys)
		{
			[System.Collections.ArrayList]$list=$values.GetValues($str2)
			$list.sort()
			$builder2=  [System.Text.StringBuilder]::new()
			
			foreach ($obj2 in $list)
			{
				if ($builder2.Length -gt 0)
				{
					$builder2.Append(",");
				}
				$builder2.Append($obj2.ToString()) |Out-Null
			}
			IF ($str2 -ne $null)
			{
				$values2.add($str2.ToLowerInvariant(),$builder2.ToString())
			} 
		}
		
		$list2=[System.Collections.ArrayList]::new($values2.Keys)
		$list2.sort()
		foreach ($str3 in $list2)
		{
			IF($str3 -eq 'comp')
			{
				$builder3=[System.Text.StringBuilder]::new()
				$builder3.Append($str3) |out-null
				$builder3.Append("=") |out-null
				$builder3.Append($values2[$str3]) |out-null
				$str.Append("?") |out-null
				$str.Append($builder3.ToString())|out-null
			}
		}
	}
	Else
	{
		$values= [System.Web.HttpUtility]::ParseQueryString($uri.query)  
		#    NameValueCollection values = HttpUtility.ParseQueryString(address.Query);
		foreach ($str2 in $values.Keys)
		{
			[System.Collections.ArrayList]$list=$values.GetValues($str2)
			$list.sort()
			$builder2=  [System.Text.StringBuilder]::new()
			
			foreach ($obj2 in $list)
			{
				if ($builder2.Length -gt 0)
				{
					$builder2.Append(",");
				}
				$builder2.Append($obj2.ToString()) |Out-Null
			}
			IF ($str2 -ne $null)
			{
				$values2.add($str2.ToLowerInvariant(),$builder2.ToString())
			} 
		}
		
		$list2=[System.Collections.ArrayList]::new($values2.Keys)
		$list2.sort()
		foreach ($str3 in $list2)
		{
			
			$builder3=[System.Text.StringBuilder]::new()
			$builder3.Append($str3) |out-null
			$builder3.Append(":") |out-null
			$builder3.Append($values2[$str3]) |out-null
			$str.Append("`n") |out-null
			$str.Append($builder3.ToString())|out-null
		}
	} 
	#    $stringToHash+= $str.ToString();
	#$str.ToString()
	############
	$xHeaders = "x-ms-date:" + $date+ "`n" +"x-ms-version:$ApiStorage"
	if ($service -eq 'Table')
	{
		$stringToHash= $method + "`n" + "`n" + "`n"+$date+"`n"+$str.ToString()
	}
	Else
	{
		IF ($method -eq 'GET' -or $method -eq 'HEAD')
		{
			$stringToHash = $method + "`n" + "`n" + "`n" + "`n" + "`n"+"application/xml"+ "`n"+ "`n"+ "`n"+ "`n"+ "`n"+ "`n"+ "`n"+$xHeaders+"`n"+$str.ToString()
		}
		Else
		{
			$stringToHash = $method + "`n" + "`n" + "`n" +$bodylength+ "`n" + "`n"+"application/xml"+ "`n"+ "`n"+ "`n"+ "`n"+ "`n"+ "`n"+ "`n"+$xHeaders+"`n"+$str.ToString()
		}     
	}
	##############
	

	$bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
	$keyBytes = [Convert]::FromBase64String($sharedKey)
	$sha256 = New-Object System.Security.Cryptography.HMACSHA256
	$sha256.Key = $keyBytes
	$calculatedHash = $sha256.ComputeHash($bytesToHash)
	$encodedHash = [Convert]::ToBase64String($calculatedHash)
	$authorization = 'SharedKey {0}:{1}' -f $resource,$encodedHash
	return $authorization
	
}
# Create the function to create and post the request
Function invoke-StorageREST($sharedKey, $method, $msgbody, $resource,$uri,$svc,$download)
{

	$rfc1123date = [DateTime]::UtcNow.ToString("r")

	
	If ($method -eq 'PUT')
	{$signature = Build-StorageSignature `
		-sharedKey $sharedKey `
		-date  $rfc1123date `
		-method $method -resource $resource -uri $uri -bodylength $msgbody.length -service $svc
	}Else
	{

		$signature = Build-StorageSignature `
		-sharedKey $sharedKey `
		-date  $rfc1123date `
		-method $method -resource $resource -uri $uri -body $body -service $svc
	} 

	If($svc -eq 'Table')
	{
		$headersforsa=  @{
			'Authorization'= "$signature"
			'x-ms-version'="$apistorage"
			'x-ms-date'=" $rfc1123date"
			'Accept-Charset'='UTF-8'
			'MaxDataServiceVersion'='3.0;NetFx'
			#      'Accept'='application/atom+xml,application/json;odata=nometadata'
			'Accept'='application/json;odata=nometadata'
		}
	}
	Else
	{ 
		$headersforSA=  @{
			'x-ms-date'="$rfc1123date"
			'Content-Type'='application\xml'
			'Authorization'= "$signature"
			'x-ms-version'="$ApiStorage"
		}
	}
	




IF($download)
{
      $resp1= Invoke-WebRequest -Uri $uri -Headers $headersforsa -Method $method -ContentType application/xml -UseBasicParsing -Body $msgbody  -OutFile "$($env:TEMP)\$resource.$($uri.LocalPath.Replace('/','.').Substring(7,$uri.LocalPath.Length-7))"

      
    #$xresp=Get-Content "$($env:TEMP)\$resource.$($uri.LocalPath.Replace('/','.').Substring(7,$uri.LocalPath.Length-7))"
    return "$($env:TEMP)\$resource.$($uri.LocalPath.Replace('/','.').Substring(7,$uri.LocalPath.Length-7))"


}Else{
	If ($svc -eq 'Table')
	{
		IF ($method -eq 'PUT'){  
			$resp1= Invoke-WebRequest -Uri $uri -Headers $headersforsa -Method $method  -UseBasicParsing -Body $msgbody  
			return $resp1
		}Else
		{  $resp1=Invoke-WebRequest -Uri $uri -Headers $headersforsa -Method $method   -UseBasicParsing -Body $msgbody 

			$xresp=$resp1.Content.Substring($resp1.Content.IndexOf("<")) 
		} 
		return $xresp

	}Else
	{
		IF ($method -eq 'PUT'){  
			$resp1= Invoke-WebRequest -Uri $uri -Headers $headersforsa -Method $method -ContentType application/xml -UseBasicParsing -Body $msgbody 
			return $resp1
		}Elseif($method -eq 'GET')
		{
			$resp1= Invoke-WebRequest -Uri $uri -Headers $headersforsa -Method $method -ContentType application/xml -UseBasicParsing -Body $msgbody -ea 0

			$xresp=$resp1.Content.Substring($resp1.Content.IndexOf("<")) 
			return $xresp
		}Elseif($method -eq 'HEAD')
        {
            $resp1= Invoke-WebRequest -Uri $uri -Headers $headersforsa -Method $method -ContentType application/xml -UseBasicParsing -Body $msgbody 

			
			return $resp1
        }
	}
}
}
#get blob file size in gb 

function Get-BlobSize ($bloburi,$storageaccount,$rg,$type)
{

	If($type -eq 'ARM')
	{
		$Uri="https://management.azure.com/subscriptions/{3}/resourceGroups/{2}/providers/Microsoft.Storage/storageAccounts/{1}/listKeys?api-version={0}"   -f  $ApiVerSaArm, $storageaccount,$rg,$SubscriptionId 
		$keyresp=Invoke-WebRequest -Uri $uri -Method POST  -Headers $headers -UseBasicParsing
		$keys=ConvertFrom-Json -InputObject $keyresp.Content
		$prikey=$keys.keys[0].value
	}Elseif($type -eq 'Classic')
	{
		$Uri="https://management.azure.com/subscriptions/{3}/resourceGroups/{2}/providers/Microsoft.ClassicStorage/storageAccounts/{1}/listKeys?api-version={0}"   -f  $ApiVerSaAsm,$storageaccount,$rg,$SubscriptionId 
		$keyresp=Invoke-WebRequest -Uri $uri -Method POST  -Headers $headers -UseBasicParsing
		$keys=ConvertFrom-Json -InputObject $keyresp.Content
		$prikey=$keys.primaryKey
	}Else
	{
		"Could not detect storage account type, $storageaccount will not be processed"
		Continue
	}





$vhdblob=invoke-StorageREST -sharedKey $prikey -method HEAD -resource $storageaccount -uri $bloburi
	
Return [math]::round($vhdblob.Headers.'Content-Length'/1024/1024/1024,0)



}		
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
	$uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
	$OMSheaders = @{
		"Authorization" = $signature;
		"Log-Type" = $logType;
		"x-ms-date" = $rfc1123date;
		"time-generated-field" = $TimeStampField;
	}
#write-output "OMS parameters"
#$OMSheaders
	Try{
		$response = Invoke-WebRequest -Uri $uri -Method POST  -ContentType $contentType -Headers $OMSheaders -Body $body -UseBasicParsing
	}
	Catch
	{
		$_.MEssage
	}
	return $response.StatusCode
	#write-output $response.StatusCode
	Write-error $error[0]
}

Function Post-OMSIntData($customerId, $sharedKey, $body, $logType)
{
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
	$uri = "https://" + $customerId + ".ods.int2.microsoftatlanta-int.com" + $resource + "?api-version=2016-04-01"
	$OMSheaders = @{
		"Authorization" = $signature;
		"Log-Type" = $logType;
		"x-ms-date" = $rfc1123date;
		"time-generated-field" = $TimeStampField;
	}
#write-output "OMS parameters"
#$OMSheaders
	Try{
		$response = Invoke-WebRequest -Uri $uri -Method POST  -ContentType $contentType -Headers $OMSheaders -Body $body -UseBasicParsing
	}
	Catch
	{
		$_.MEssage
	}
	return $response.StatusCode
	#write-output $response.StatusCode
	Write-error $error[0]
}



#endregion





#"$(GEt-date)  Get ARM storage Accounts "

$Uri="https://management.azure.com{1}/providers/Microsoft.Storage/storageAccounts?api-version={0}"   -f  $ApiVerSaArm,$subscriptionID
$armresp=Invoke-WebRequest -Uri $uri -Method GET  -Headers $headers -UseBasicParsing
$saArmList=(ConvertFrom-Json -InputObject $armresp.Content).Value

#"$(GEt-date)  $($saArmList.count) storage accounts found"
#get Classic SA
#"$(GEt-date)  Get Classic storage Accounts "

$Uri="https://management.azure.com{1}/providers/Microsoft.ClassicStorage/storageAccounts?api-version={0}"   -f  $ApiVerSaAsm,$subscriptionID

$sresp=Invoke-WebRequest -Uri $uri -Method GET  -Headers $headers -UseBasicParsing
$saAsmList=(ConvertFrom-Json -InputObject $sresp.Content).value

#"$(GEt-date)  $($saAsmList.count) storage accounts found"
#endregion



#region Cache Storage Account Name , RG name and Build paramter array

$colParamsforChild=@()

foreach($sa in $saArmList|where {$_.Sku.tier -ne 'Premium'})
{

	$rg=$sku=$null

	$rg=$sa.id.Split('/')[4]

	$colParamsforChild+="$($sa.name);$($sa.id.Split('/')[4]);ARM;$($sa.sku.tier)"
	
}

#Add Classic SA
$sa=$rg=$null

foreach($sa in $saAsmList|where{$_.properties.accounttype -notmatch 'Premium'})
{

	$rg=$sa.id.Split('/')[4]
	$tier=$null

# array  wth SAName,ReouceGroup,Prikey,Tier 

	If( $sa.properties.accountType -notmatch 'premium')
	{
		$tier='Standard'
		$colParamsforChild+="$($sa.name);$($sa.id.Split('/')[4]);Classic;$tier"
	}

	

}

#region collect Storage account inventory 
$SAInventory=@()
foreach($sa in $saArmList)
{
	$rg=$sa.id.Split('/')[4]
	$cu=$null
	$cu = New-Object PSObject -Property @{
		Timestamp = $timestamp
		MetricName = 'Inventory';
		InventoryType='StorageAccount'
		StorageAccount=$sa.name
		Uri="https://management.azure.com"+$sa.id
		DeploymentType='ARM'
		Location=$sa.location
		Kind=$sa.kind
		ResourceGroup=$rg
		Sku=$sa.sku.name
		Tier=$sa.sku.tier
		
		SubscriptionId = $subscriptionID
        AzureSubscription = $subscriptionname
		ShowinDesigner=1
	}
	
	IF ($sa.properties.creationTime){$cu|Add-Member -MemberType NoteProperty -Name CreationTime -Value $sa.properties.creationTime}
	IF ($sa.properties.primaryLocation){$cu|Add-Member -MemberType NoteProperty -Name PrimaryLocation -Value $sa.properties.primaryLocation}
	IF ($sa.properties.secondaryLocation){$cu|Add-Member -MemberType NoteProperty -Name secondaryLocation-Value $sa.properties.secondaryLocation}
	IF ($sa.properties.statusOfPrimary){$cu|Add-Member -MemberType NoteProperty -Name statusOfPrimary -Value $sa.properties.statusOfPrimary}
	IF ($sa.properties.statusOfSecondary){$cu|Add-Member -MemberType NoteProperty -Name statusOfSecondary -Value $sa.properties.statusOfSecondary}
	IF ($sa.kind -eq 'BlobStorage'){$cu|Add-Member -MemberType NoteProperty -Name accessTier -Value $sa.properties.accessTier}
	$SAInventory+=$cu
}
#Add Classic SA
foreach($sa in $saAsmList)
{
	$rg=$sa.id.Split('/')[4]
	$cu=$iotype=$null
	IF($sa.properties.accountType -like 'Standard*')
	{$iotype='Standard'}Else{{$iotype='Premium'}}
	$cu = New-Object PSObject -Property @{
		Timestamp = $timestamp
		MetricName = 'Inventory'
		InventoryType='StorageAccount'
		StorageAccount=$sa.name
		Uri="https://management.azure.com"+$sa.id
		DeploymentType='Classic'
		Location=$sa.location
		Kind='Storage'
		ResourceGroup=$rg
		Sku=$sa.properties.accountType
		Tier=$iotype
			SubscriptionId = $subscriptionID
        AzureSubscription = $subscriptionname
		ShowinDesigner=1
	}
	
	IF ($sa.properties.creationTime){$cu|Add-Member -MemberType NoteProperty -Name CreationTime -Value $sa.properties.creationTime}
	IF ($sa.properties.geoPrimaryRegion){$cu|Add-Member -MemberType NoteProperty -Name PrimaryLocation -Value $sa.properties.geoPrimaryRegion.Replace(' ','')}
	IF ($sa.properties.geoSecondaryRegion ){$cu|Add-Member -MemberType NoteProperty -Name SecondaryLocation-Value $sa.properties.geoSecondaryRegion.Replace(' ','')}
	IF ($sa.properties.statusOfPrimaryRegion){$cu|Add-Member -MemberType NoteProperty -Name statusOfPrimary -Value $sa.properties.statusOfPrimaryRegion}
	IF ($sa.properties.statusOfSecondaryRegion){$cu|Add-Member -MemberType NoteProperty -Name statusOfSecondary -Value $sa.properties.statusOfSecondaryRegion}
	
	$SAInventory+=$cu
}


#endregion




#Check if  API Ream limits reached

#Write-output "Starting API Limits collection "


$apiuri = Invoke-WebRequest -Uri "https://management.azure.com$($subscriptionID)/resourcegroups?api-version=2016-09-01" -Method GET -Headers $Headers -UseBasicParsing
 
$remaining=$apiuri.Headers["x-ms-ratelimit-remaining-subscription-reads"]


 $apidatafirst = New-Object PSObject -Property @{
                             MetricName = 'ARMAPILimits';
                            APIReadsRemaining=$apiuri.Headers["x-ms-ratelimit-remaining-subscription-reads"]
                            SubscriptionID = $subscriptionID
                            AzureSubscription = $subscriptionname
      
                            }


#"$(get-date)   -  $($apidatafirst.APIReadsRemaining)  request available , collection will continue " 


$uri="https://management.azure.com$($subscriptionID)/resourceGroups?api-version=$apiverVM"

#$uri


$resultarm = Invoke-WebRequest -Method Get -Uri $uri -Headers $headers -UseBasicParsing

$content=$resultarm.Content
$content= ConvertFrom-Json -InputObject $resultarm.Content


$rglist=$content.value

$uri="https://management.azure.com"+$subscriptionID+"/providers?api-version=$apiverVM"

$resultarm = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -UseBasicParsing

$content=$resultarm.Content
$content= ConvertFrom-Json -InputObject $resultarm.Content




$providers=@()

Foreach($item in $content.value)
{

foreach ($rgobj in $item.resourceTypes)
{

$properties = @{'ID'=$item.id;
                'namespace'=$item.namespace;
                'Resourcetype'=$rgobj.resourceType;
                'Apiversion'=$rgobj.apiVersions[0]}
$object = New-Object –TypeName PSObject –Prop $properties
#Write-Output $object
$providers+=$object
}


}



Write-output "$(get-date) - Starting inventory for VMs for subscription $subscriptionID "



$vmlist=@()


Foreach ($prvitem in $providers|where{$_.resourcetype -eq 'virtualMachines'})
{

$uri="https://management.azure.com"+$prvitem.id+"/$($prvitem.Resourcetype)?api-version=$($prvitem.apiversion)"

$resultarm = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -UseBasicParsing
$content=$resultarm.Content
$content= ConvertFrom-Json -InputObject $resultarm.Content
$vmlist+=$content.value


    IF(![string]::IsNullOrEmpty($content.nextLink))
    {
        do 
        {
            $uri2=$content.nextLink
            $content=$null
             $resultarm = Invoke-WebRequest -Method GET -Uri $uri2 -Headers $headers -UseBasicParsing
	            $content=$resultarm.Content
	            $content= ConvertFrom-Json -InputObject $resultarm.Content
	            $vmlist+=$content.value

        $uri2=$null
        }While (![string]::IsNullOrEmpty($content.nextLink))
    }




}

$vmsclassic=$vmlist|where {$_.type -eq 'Microsoft.ClassicCompute/virtualMachines'}
$vmsarm=$vmlist|where {$_.type -eq 'Microsoft.Compute/virtualMachines'}


$vm=$cu=$cuvm=$cudisk=$null

$invVMs=@()
$invTags=@()
$invVHDs=@()
$invEndpoints=@()
$invNSGs=@()
$invNics=@() 
$invExtensions=@()
$colltime=get-date


#"{0}  VM found " -f $vmlist.count



Foreach ($vm in $vmsclassic)
{

#vm inventory
#extensions 
$extlist=$null
$vm.properties.extensions|?{$extlist+=$_.extension+";"}

  $cuvm = New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'VMInventory';
                            ResourceGroup=$vm.id.Split('/')[4]
                            HWProfile=$vm.properties.hardwareProfile.size.ToString()
                            Deploymentname=$vm.properties.hardwareProfile.deploymentName.ToString()
                            Status=$VMstates.get_item($vm.properties.instanceView.status.ToString())
                            fqdn=$vm.properties.instanceView.fullyQualifiedDomainName
                            DeploymentType='Classic'
                            Location=$vm.location
                            VmName=$vm.Name
                            ID=$vm.id
                            OperatingSystem=$vm.properties.storageProfile.operatingSystemDisk.operatingSystem
                            privateIpAddress=$vm.properties.instanceView.privateIpAddress
                            SubscriptionId = $subscriptionID
                             AzureSubscription = $subscriptionname
							 ShowinDesigner=1
      
                                   }

                if($vm.properties.networkProfile.virtualNetwork)
                    {
                    $cuvm|Add-Member -MemberType NoteProperty -Name VNETName -Value $vm.properties.networkProfile.virtualNetwork.name -Force
                    $cuvm|Add-Member -MemberType NoteProperty -Name Subnet -Value  $vm.properties.networkProfile.virtualNetwork.subnetNames[0] -Force
                                  
                    }

                 if( $vm.properties.instanceView.publicIpAddresses)
                    {
                    $cuvm|Add-Member -MemberType NoteProperty -Name PublicIP -Value $vm.properties.instanceView.publicIpAddresses[0].tostring()
                    }
                              
                $invVMs+=$cuvm

    #inv extensions
    IF(![string]::IsNullOrEmpty($vm.properties.extensions))
    {
    Foreach ($extobj in $vm.properties.extensions)
        {

        $invExtensions+=New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'VMExtensions';
                           VmName=$vm.Name
                          Extension=$extobj.Extension
                          publisher=$extobj.publisher
                        version=$extobj.version
                        state=$extobj.state
                        referenceName=$extobj.referenceName
                        ID=$vm.id+"/extensions/"+$extobj.Extension
                        SubscriptionId = $subscriptionID
                             AzureSubscription = $subscriptionname
							 ShowinDesigner=1
                          
                                   }

        }


    }
    

    #inv endpoints

    
    $ep=$null
    IF(![string]::IsNullOrEmpty($vm.properties.networkProfile.inputEndpoints)  -and $getNICandNSG)
    {
        Foreach($ep in $vm.properties.networkProfile.inputEndpoints)
        {
            
             $invEndpoints+= New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'VMEndpoint';
                           VmName=$vm.Name
                           endpointName=$ep.endpointName
                             publicIpAddress=$ep.publicIpAddress
                               privatePort=$ep.privatePort
                            publicPort=$ep.publicPort
                            protocol=$ep.protocol
                            enableDirectServerReturn=$ep.enableDirectServerReturn
                            SubscriptionId = $subscriptionID
                             AzureSubscription = $subscriptionname
							 ShowinDesigner=1
      
                                   }

        }

    }









    If($getDiskInfo)
    {
#first get os disk then iterate data disks 



   IF(![string]::IsNullOrEmpty($vm.properties.storageProfile.operatingSystemDisk.storageAccount.Name))
    {	


        $safordisk=$SAInventory|where {$_.StorageAccount -eq $vm.properties.storageProfile.operatingSystemDisk.storageAccount.Name}
        $IOtype=$safordisk.Tier

	    $sizeingb=$null
        #$sizeingb=Get-BlobSize -bloburi $([uri]$vm.properties.storageProfile.operatingSystemDisk.vhdUri) -storageaccount $safordisk.StorageAccount -rg $safordisk.ResourceGroup -type Classic



	         $cudisk = New-Object PSObject -Property @{
		Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
		MetricName = 'VMDisk';
        DiskType='Unmanaged'
		Deploymentname=$vm.properties.hardwareProfile.deploymentName.ToString()
		DeploymentType='Classic'

		Location=$vm.location
		VmName=$vm.Name
		VHDUri=$vm.properties.storageProfile.operatingSystemDisk.vhdUri
		DiskIOType=$IOtype
		StorageAccount=$vm.properties.storageProfile.operatingSystemDisk.storageAccount.Name
			SubscriptionId = $subscriptionID
        AzureSubscription = $subscriptionname
		SizeinGB=$sizeingb
		ShowinDesigner=1
		
	}
	

         IF ($IOtype -eq 'Standard' -and $vm.properties.hardwareProfile.size.ToString() -like  'Basic*')
	    {
		    $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 300
	    }ElseIf  ($IOtype -eq 'Standard' )
	    {
		    $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 500
        }Elseif($IOtype -eq 'Premium')
        {
            $cudisk|Add-Member -MemberType NoteProperty -Name MaxVMIO -Value $vmiolimits.Item($vm.properties.hardwareProfile.size)

              
           if ($cudisk.SizeinGB -le 128 )
           {
                $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 500
           }Elseif ($cudisk.SizeinGB -in  129..512 )
           {
                $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 2300
           }Elseif ($cudisk.SizeinGB -in  513..1024 )
           {
                $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 5000
           }
        }
        
        $invVHDs+=$cudisk
    }

#check data disks 
	IF($vm.properties.storageProfile.dataDisks)
	{
		$ddisks=$null
		$ddisks=@($vm.properties.storageProfile.dataDisks)

		Foreach($disk in $ddisks)
		{
            IF(![string]::IsNullOrEmpty($disk.storageAccount.Name))
            {	
			        $safordisk=$null
			        $safordisk=$SAInventory|where {$_ -match $disk.storageAccount.Name}
			        $IOtype=$safordisk.Tier

			        $cudisk = New-Object PSObject -Property @{
				        Timestamp = $timestamp
				        MetricName = 'VMDisk';
                        DiskType='Unmanaged'
				        Deploymentname=$vm.properties.hardwareProfile.deploymentName.ToString()
				        DeploymentType='Classic'
				        Location=$vm.location
				        VmName=$vm.Name
				        VHDUri=$disk.vhdUri
				        DiskIOType=$IOtype
				        StorageAccount=$disk.storageAccount.Name
				        	SubscriptionId = $subscriptionID
        AzureSubscription = $subscriptionname
				        SizeinGB=$disk.diskSize
						ShowinDesigner=1
				
			        }
			

  
                 IF ($IOtype -eq 'Standard' -and $vm.properties.hardwareProfile.size.ToString() -like  'Basic*')
	            {
		            $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 300
	            }ElseIf  ($IOtype -eq 'Standard' )
	            {
		            $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 500
                }Elseif($IOtype -eq 'Premium')
                {
                   if ($cudisk.SizeinGB -le 128 )
                   {
                        $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 500
                   }Elseif ($cudisk.SizeinGB -in  129..512 )
                   {
                        $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 2300
                   }Elseif ($cudisk.SizeinGB -in  513..1024 )
                   {
                        $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 5000
                   }
                }

			    $invVHDs+=$cudisk    
		      }
		   }
	}
    }

	
}


#forarm
$vm=$cuvm=$cudisk=$osdisk=$nic=$nsg=$null
Foreach ($vm in $vmsarm)
{



 #vm inv
 
        
        $cuvm = New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'VMInventory';
                            ResourceGroup=$vm.id.split('/')[4]
                            HWProfile=$vm.properties.hardwareProfile.vmSize.ToString()
                            DeploymentType='ARM'
                            Location=$vm.location
                            VmName=$vm.Name
                            OperatingSystem=$vm.properties.storageProfile.osDisk.osType
                            ID=$vm.id
                            
                       
                           	SubscriptionId = $subscriptionID
        AzureSubscription = $subscriptionname
		ShowinDesigner=1
      
                            }

              If([int]$remaining -gt [int]$apireadlimit -and $getarmvmstatus)
                {
        $uriinsview="https://management.azure.com"+$vm.id+"/InstanceView?api-version=2015-06-15"

        $resiview = Invoke-WebRequest -Method Get -Uri $uriinsview -Headers $headers -UseBasicParsing
      
        $ivcontent=$resiview.Content
        $ivcontent= ConvertFrom-Json -InputObject $resiview.Content

        $cuvm|Add-Member -MemberType NoteProperty -Name Status  -Value $VMstates.get_item(($ivcontent.statuses|select -Last 1).Code)
                }

                $invVMs+=$cuVM 

                If($getNICandNSG)
                {
#inventory network interfaces

Foreach ($nicobj in $vm.properties.networkProfile.networkInterfaces)
{
  $urinic="https://management.azure.com"+$nicobj.id+"?api-version=2015-06-15"

        $nicresult = Invoke-WebRequest -Method Get -Uri $urinic -Headers $headers -UseBasicParsing
      
        
        $Nic= ConvertFrom-Json -InputObject $nicresult.Content
        
        $cunic=$null
     
       $cuNic= New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'VMNIC';
                            VmName=$vm.Name
                            ID=$nic.id
                            NetworkInterface=$nic.name
                            VNetName=$nic.properties.ipConfigurations[0].properties.subnet.id.split('/')[8]
                            ResourceGroup=$nic.id.split('/')[4]
                            Location=$nic.location
                            Primary=$nic.properties.primary
                            enableIPForwarding=$nic.properties.enableIPForwarding
                            macAddress=$nic.properties.macAddress
                            privateIPAddress=$nic.properties.ipConfigurations[0].properties.privateIPAddress
                            privateIPAllocationMethod=$nic.properties.ipConfigurations[0].properties.privateIPAllocationMethod
                            subnet=$nic.properties.ipConfigurations[0].properties.subnet.id.split('/')[10]
                           	SubscriptionId = $subscriptionID
                            AzureSubscription = $subscriptionname
							ShowinDesigner=1
      
                            } 

            IF (![string]::IsNullOrEmpty($cunic.publicIPAddress))
            {
                  $uripip="https://management.azure.com"+$cunic.publicIPAddress+"?api-version=2015-06-15"
                  $pipresult = Invoke-WebRequest -Method Get -Uri $uripip -Headers $headers -UseBasicParsing
                $pip= ConvertFrom-Json -InputObject $pipresult.Content
                If($pip)
                {
                $cuNic|Add-Member -MemberType NoteProperty -Name PublicIp -Value $pip.properties.ipAddress -Force
                $cuNic|Add-Member -MemberType NoteProperty -Name publicIPAllocationMethod -Value $pip.properties.publicIPAllocationMethod -Force
                $cuNic|Add-Member -MemberType NoteProperty -Name fqdn -Value $pip.properties.dnsSettings.fqdn -Force

                }


            }

            $invNics+=$cuNic

        #inventory NSG
        
        IF($nic.properties.networkSecurityGroup)
        {
            Foreach($nsgobj in $nic.properties.networkSecurityGroup)
            {
                 $urinsg="https://management.azure.com"+$nsgobj.id+"?api-version=2015-06-15"
                  $nsgresult = Invoke-WebRequest -Method Get -Uri $urinsg -Headers $headers -UseBasicParsing
                $nsg= ConvertFrom-Json -InputObject $nsgresult.Content
             

                 If($Nsg.properties.securityRules)
                 {
                    foreach($rule in $Nsg.properties.securityRules)
                    {

                      $invNSGs+= New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'VMNSGrule';
                            VmName=$vm.Name
                            ID=$nsg.id
                            NSGName=$nsg.id
                            NetworkInterface=$nic.name
                            ResourceGroup=$nsg.id.split('/')[4]
                            Location=$nsg.location
                            RuleName=$rule.name
                            protocol=$rule.properties.protocol
                            sourcePortRange=$rule.properties.sourcePortRange
                            destinationPortRange=$rule.properties.destinationPortRange
                            sourceAddressPrefix=$rule.properties.sourceAddressPrefix
                            destinationAddressPrefix=$rule.properties.destinationAddressPrefix
                            access=$rule.properties.access
                            priority=$rule.properties.priority
                            direction=$rule.properties.direction
                             	SubscriptionId = $subscriptionID
                             AzureSubscription = $subscriptionname
							 ShowinDesigner=1
      
                            } 
                    }
                 }
             }
        }

}

                }
                
# inv  extensions

            IF(![string]::IsNullOrEmpty($vm.resources.id))
            {	
                  Foreach ($extobj in $vm.resources)
                    {
                        if($extobj.id.Split('/')[9] -eq 'extensions')
                        {
                            $invExtensions+=New-Object PSObject -Property @{
                                        Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                                        MetricName = 'VMExtensions';
                           VmName=$vm.Name
                          Extension=$extobj.Extension
                         ID=$extobj.id
                                                     SubscriptionId = $subscriptionID
                             AzureSubscription = $subscriptionname
							 ShowinDesigner=1
                          
                                   }
                        }
        }

                

            }
        


        If($vm.tags)
         {

         $tags=$null
         $tags=$vm.tags

            foreach ($tag in $tags)
            {
                $tag.PSObject.Properties | foreach-object {
                
                    #exclude devteslabsUID 
                    $name = $_.Name 
                    $value = $_.value
                
                    IF ($name -match '-LabUId'){Continue}
                
                    Write-Verbose     "Adding tag $name : $value to $($VM.name)"
                    $cutag=$null
                    $cutag=New-Object PSObject
                    $cuVM.psobject.Properties|foreach-object  {
                      $cutag|Add-Member -MemberType NoteProperty -Name  $_.Name   -Value $_.value -Force
                }
                   $cutag|Add-Member -MemberType NoteProperty -Name Tag  -Value "$name : $value"


                }
                $invTags+=$cutag
                        
                        #End tag processing 
           }

         }
      


      IF($getDiskInfo)
      {

    #INVENTORY DISKS
 
   
    $osdisk=$saforVm=$IOtype=$null
   IF(![string]::IsNullOrEmpty($vm.properties.storageProfile.osDisk.vhd.uri))
    {	

        $osdisk=[uri]$vm.properties.storageProfile.osDisk.vhd.uri

        $saforVm=$SAInventory|where {$_.StorageAccount -eq $osdisk.host.Substring(0,$osdisk.host.IndexOf('.')) } 
	    IF($saforvm)
	            {
		$IOtype=$saforvm.tier
	}
	    $sizeingb=$null
       # $sizeingb=Get-BlobSize -bloburi $([uri]$vm.properties.storageProfile.osDisk.vhd.uri) -storageaccount $saforvm.StorageAccount -rg $saforVm.ResourceGroup -type ARM

	     $cudisk = New-Object PSObject -Property @{
		        Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
		        MetricName = 'VMDisk';
		        DiskType='Unmanaged'
		        Deploymentname=$vm.id.split('/')[4]   # !!! consider chnaging this to ResourceGroup here or in query
		        DeploymentType='ARM'
		        Location=$vm.location
		        VmName=$vm.Name
		        VHDUri=$vm.properties.storageProfile.osDisk.vhd.uri
		        #arm does not expose this need to queri it from $colParamsforChild
		        DiskIOType=$IOtype
		        StorageAccount=$saforVM.StorageAccount
		        	SubscriptionId = $subscriptionID
        AzureSubscription = $subscriptionname
		        SizeinGB=$sizeingb
				ShowinDesigner=1
                } -ea 0

	    IF ($cudisk.DiskIOType -eq 'Standard' -and $vm.properties.hardwareProfile.vmSize.ToString() -like  'BAsic*')
	            {
		$cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 300
	}ElseIf  ($cudisk.DiskIOType -eq 'Standard' -and $vm.properties.hardwareProfile.vmSize.ToString() -like 'Standard*')
	            {
		$cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 500
	}Elseif($IOtype -eq 'Premium')
        {
            $cudisk|Add-Member -MemberType NoteProperty -Name MaxVMIO -Value $vmiolimits.Item($vm.properties.hardwareProfile.vmSize)
              
           if ($cudisk.SizeinGB -le 128 )
           {
                $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 500
                 
           }Elseif ($cudisk.SizeinGB -in  129..512 )
           {
                $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 2300
           }Elseif ($cudisk.SizeinGB -in  513..1024 )
           {
                $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 5000
           }
        }
        $invVHDs+=$cudisk    
    
    }
    Else
    {
    $cudisk=$null

        $cudisk = New-Object PSObject -Property @{
		    Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
		    MetricName = 'VMDisk';
		    DiskType='Unmanaged'
		    Deploymentname=$vm.id.split('/')[4]   # !!! consider chnaging this to ResourceGroup here or in query
		    DeploymentType='ARM'
		    Location=$vm.location
		    VmName=$vm.Name
		    Uri="https://management.azure.com/{0}" -f $vm.properties.storageProfile.osDisk.managedDisk.id
		    StorageAccount=$vm.properties.storageProfile.osDisk.managedDisk.id
		    	SubscriptionId = $subscriptionID
        AzureSubscription = $subscriptionname
		    SizeinGB=128
			ShowinDesigner=1
                } -ea 0

	    IF ($vm.properties.storageProfile.osDisk.managedDisk.storageAccountType -match 'Standard')
	    {
		    $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 500
            $cudisk|Add-Member -MemberType NoteProperty -Name DiskIOType -Value 'Standard'

	    }Elseif($vm.properties.storageProfile.osDisk.managedDisk.storageAccountType -match  'Premium')
        {
            $cudisk|Add-Member -MemberType NoteProperty -Name MaxVMIO -Value $vmiolimits.Item($vm.properties.hardwareProfile.vmSize)
                 $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 500
                  $cudisk|Add-Member -MemberType NoteProperty -Name DiskIOType -Value 'Premium'

           }
           $invVHDs+=$cudisk
     }

               
	#check for Data disks 
	iF ($vm.properties.storageProfile.dataDisks)
	{
		$ddisks=$null
		$ddisks=@($vm.properties.storageProfile.dataDisks)
		Foreach($disk in $ddisks)
		{



               IF(![string]::IsNullOrEmpty($disk.vhd.uri))
            {	
			        $diskuri=$safordisk=$IOtype=$null
			        $diskuri=[uri]$disk.vhd.uri
			        $safordisk=$SAInventory|where {$_ -match $diskuri.host.Substring(0,$diskuri.host.IndexOf('.')) }
			        $IOtype=$safordisk.Tier
			        $cudisk = New-Object PSObject -Property @{
				        Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
				        MetricName = 'VMDisk';
				        DiskType='Unmanaged'
				        Deploymentname=$vm.id.split('/')[4] 
				        DeploymentType='ARM'
				        Location=$vm.location
				        VmName=$vm.Name
				        VHDUri=$disk.vhd.uri
				        DiskIOType=$IOtype
				        StorageAccount=$safordisk.StorageAccount
				        	SubscriptionId = $subscriptionID
        AzureSubscription = $subscriptionname
				        SizeinGB=$disk.diskSizeGB
						ShowinDesigner=1
				
			        } -ea 0 
			
			IF ($cudisk.DiskIOType -eq 'Standard' -and $vm.properties.hardwareProfile.vmSize.ToString() -like  'BAsic*')
			{
				$cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 300
			}ElseIf  ($cudisk.DiskIOType -eq 'Standard' -and $vm.properties.hardwareProfile.vmSize.ToString() -like 'Standard*')
			{
				$cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 500
			}Elseif($IOtype -eq 'Premium')
            {
                $cudisk|Add-Member -MemberType NoteProperty -Name MaxVMIO -Value $vmiolimits.Item($vm.properties.hardwareProfile.vmSize)
              
               if ($cudisk.SizeinGB -le 128 )
               {
                    $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 500
               }Elseif ($cudisk.SizeinGB -in  129..512 )
               {
                    $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 2300
               }Elseif ($cudisk.SizeinGB -in  513..1024 )
               {
                    $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 5000
               }
           }
                       
			$invVHDs+=$cudisk
    		}
            Else
            {
                 $cudisk = New-Object PSObject -Property @{
		            Timestamp = $timestamp
		            MetricName = 'Inventory';
		            DiskType='Managed'
		            Deploymentname=$vm.id.split('/')[4]   # !!! consider chnaging this to ResourceGroup here or in query
		            DeploymentType='ARM'
		            Location=$vm.location
		            VmName=$vm.Name
		            Uri="https://management.azure.com/{0}" -f $disk.manageddisk.id
		            StorageAccount=$disk.managedDisk.id
		            	SubscriptionId = $subscriptionID
        AzureSubscription = $subscriptionnamee
		            SizeinGB=$disk.diskSizeGB
					ShowinDesigner=1
                        } -ea 0

               IF ($vm.properties.storageProfile.osDisk.managedDisk.storageAccountType -match 'Standard')
	            {
		            $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 500
                    $cudisk|Add-Member -MemberType NoteProperty -Name DiskIOType -Value 'Standard'

	            }Elseif($vm.properties.storageProfile.osDisk.managedDisk.storageAccountType -match  'Premium')
                {
                    $cudisk|Add-Member -MemberType NoteProperty -Name MaxVMIO -Value $vmiolimits.Item($vm.properties.hardwareProfile.vmSize)
                    $cudisk|Add-Member -MemberType NoteProperty -Name DiskIOType -Value 'Premium'

                     if ($disk.diskSizeGB -le 128 )
               {
                    $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 500
               }Elseif ($disk.diskSizeGB -in  129..512 )
               {
                    $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 2300
               }Elseif ($disk.diskSizeGB -in  513..1024 )
               {
                    $cudisk|Add-Member -MemberType NoteProperty -Name MaxDiskIO -Value 5000
               }
           }
                $invVHDs+=$cudisk
            }


        }
	}

    }


}

# Collect Subscription limits


#Write-output "$(get-date) - Starting inventory of Usage data "

$locations=$loclistcontent=$cu=$null

$invServiceQuota=@()


$loclisturi="https://management.azure.com/"+$subscriptionID+"/locations?api-version=2016-09-01"


$loclist = Invoke-WebRequest -Uri $loclisturi -Method GET -Headers $Headers -UseBasicParsing

$loclistcontent= ConvertFrom-Json -InputObject $loclist.Content

$locations =$loclistcontent

Foreach($loc in $loclistcontent.value.name)
{

$usgdata=$cu=$usagecontent=$null
$usageuri="https://management.azure.com/"+$subscriptionID+"/providers/Microsoft.Compute/locations/"+$loc+"/usages?api-version=2015-06-15"

$usageapi = Invoke-WebRequest -Uri $usageuri -Method GET -Headers $Headers  -UseBasicParsing

$usagecontent= ConvertFrom-Json -InputObject $usageapi.Content



Foreach($usgdata in $usagecontent.value)
{


 $cu= New-Object PSObject -Property @{
                              Timestamp = $timestamp
                             MetricName = 'ARMVMUsageStats';
                            Location = $loc
                            currentValue=$usgdata.currentValue
                            limit=$usgdata.limit
                            Usagemetric = $usgdata.name[0].value.ToString()
                            SubscriptionID = $subscriptionID
                            AzureSubscription = $subscriptionname
							ShowinDesigner=1
      
                            }


$invServiceQuota+=$cu


}

}





#add scale sets 

$vmSSList=@()
$invvmSS=@()
$vmSS=@()

$vmScaleSetPrv=$providers|where {$_.resourcetype -eq 'virtualMachineScaleSets'}

Foreach ($prvitem in $vmScaleSetPrv)
{

$uri="https://management.azure.com"+$prvitem.id+"/$($prvitem.Resourcetype)?api-version=$($prvitem.apiversion)"

$resultarm = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -UseBasicParsing
$content=$resultarm.Content
$content= ConvertFrom-Json -InputObject $resultarm.Content
$vmSSList+=$content.value


    IF(![string]::IsNullOrEmpty($content.nextLink))
    {
        do 
        {
            $uri2=$content.nextLink
            $content=$null
             $resultarm = Invoke-WebRequest -Method GET -Uri $uri2 -Headers $headers -UseBasicParsing
	            $content=$resultarm.Content
	            $content= ConvertFrom-Json -InputObject $resultarm.Content
	           $vmSSList+=$content.value

        $uri2=$null
        }While (![string]::IsNullOrEmpty($content.nextLink))
    }




}

Foreach ($ss in $vmsslist)
{


        $cuss = New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'ScaleSetInventory';
                            ResourceGroup=$ss.id.split('/')[4]
                            Location=$ss.location
                            Name=$ss.Name
                            Sku=$ss.sku.name
                            Tier=$ss.sku.tier
                            Capacity=$ss.sku.capacity
                            upgradePolicy=$ss.properties.upgradePolicy.mode
                            overprovision=$ss.properties.overprovision
                            uniqueId=$ss.properties.uniqueId
                            computerNamePrefix=$ss.properties.virtualMachineProfile.osProfile.computerNamePrefix
                            imageReference=$ss.properties.virtualMachineProfile.storageProfile.imageReference.offer+ "/"+$ss.properties.virtualMachineProfile.storageProfile.imageReference.sku
                            diskname=$ss.properties.virtualMachineProfile.storageProfile.osDisk.name
                            networkInterfaceConfigurations=$ss.properties.virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].name
                            VNet=$ss.properties.virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].properties.ipConfigurations.properties.subnet.id.split('/')[8]
                            subnetid=$ss.properties.virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].properties.ipConfigurations.properties.subnet.id
                            ID=$ss.id
                            DeploymentType='ARM'                                       
                           	SubscriptionId = $subscriptionID
                            AzureSubscription = $subscriptionname
		                    ShowinDesigner=1
      
                            }

                         


 
#GET VMs

$uri="https://management.azure.com"+$ss.id+"/virtualMachines?api-version=$($prvitem.apiversion)"
$resultarm = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -UseBasicParsing
$content=$resultarm.Content
$content= ConvertFrom-Json -InputObject $resultarm.Content
$vmSS+=$content.value


    IF(![string]::IsNullOrEmpty($content.nextLink))
    {
        do 
        {
            $uri2=$content.nextLink
            $content=$null
             $resultarm = Invoke-WebRequest -Method GET -Uri $uri2 -Headers $headers -UseBasicParsing
	            $content=$resultarm.Content
	            $content= ConvertFrom-Json -InputObject $resultarm.Content
	            $vmss+=$content.value

        $uri2=$null
        }While (![string]::IsNullOrEmpty($content.nextLink))
    }


$cuss|Add-Member -MemberType NoteProperty -Name RunningVMs -Value $vmSS.count

#subnets

$prvforresource=$providers|where {$_.namespace -match $cuss.subnetid.split('/')[6] -and $_.resourcetype -match $cuss.subnetid.split('/')[7]}


$uri="https://management.azure.com"+$cuss.subnetid+"?api-version=$($prvforresource.Apiversion)"
$resultarm = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -UseBasicParsing 
$content=$resultarm.Content
$content= ConvertFrom-Json -InputObject $resultarm.Content


$cuss|Add-Member -MemberType NoteProperty -Name SubnetAddressSpace -Value $content.properties.addressPrefix -force


#get load balancer 

$lb=$ss.properties.virtualMachineProfile.networkProfile.networkInterfaceConfigurations.properties.ipConfigurations.properties.loadBalancerBackendAddressPools.id

$cuss|Add-Member -MemberType NoteProperty -Name LoadBalancer -Value $lb.split('/')[8] -force

#/subscriptions/2de20a16-20c6-41af-82cd-bceb39195d1c/resourceGroups/VMScaleRG/providers/Microsoft.Network/loadBalancers/scaledemo1Lb

$lbprv=$providers|where {$_.resourcetype -match 'loadbalancers'}


$uri="https://management.azure.com/"+$subscriptionId+"/resourceGroups/"+$cuss.ResourceGroup+"/providers/Microsoft.Network/loadBalancers/"+$cuss.loadbalancer+"?api-version=$($lbprv.Apiversion)"
$resultarm = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -UseBasicParsing 
$content=$resultarm.Content
$content= ConvertFrom-Json -InputObject $resultarm.Content

$pipid=$content.properties.frontendIPConfigurations.properties.publicIPAddress.id


$uri="https://management.azure.com/"+$pipid+"?api-version=$($lbprv.Apiversion)"
$resultarm = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -UseBasicParsing 
$pipcontent= ConvertFrom-Json -InputObject $resultarm.Content


$publicIP=$pipcontent.properties.ipAddress
$ipallocation=$pipcontent.properties.publicIPAllocationMethod
$fqdn=$pipcontent.properties.dnsSettings.fqdn


$cuss|Add-Member -MemberType NoteProperty -Name publicIP -Value $publicip -force
$cuss|Add-Member -MemberType NoteProperty -Name IPAllocationType -Value $ipallocation -force
$cuss|Add-Member -MemberType NoteProperty -Name fqdn -Value $fqdn -force


#get NEtworkinterfaces


$prvforresource=$uri=$resultarm=$content=$null

$pipprv=$providers|where {$_.resourcetype -match 'virtualMachineScaleSets/publicIPAddresses'}

$uri="https://management.azure.com"+$ss.id+"/publicIPAddresses?api-version=$($pipprv.Apiversion)"
$resultarm = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -UseBasicParsing
$content=$resultarm.Content
$content= ConvertFrom-Json -InputObject $resultarm.Content



    IF(![string]::IsNullOrEmpty($content.nextLink))
    {
        do 
        {
            $uri2=$content.nextLink
            $content=$null
             $resultarm = Invoke-WebRequest -Method GET -Uri $uri2 -Headers $headers -UseBasicParsing
	            $content=$resultarm.Content
	            $content= ConvertFrom-Json -InputObject $resultarm.Content
	            $vmss+=$content.value

        $uri2=$null
        }While (![string]::IsNullOrEmpty($content.nextLink))
    }




$prvforresource=$uri=$resultarm=$content=$null

$nwprv=$providers|where {$_.resourcetype -match 'virtualMachineScaleSets/networkInterfaces'}

$uri="https://management.azure.com"+$ss.id+"/networkInterfaces?api-version=$($nwprv.Apiversion)"
$resultarm = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -UseBasicParsing
$content=$resultarm.Content
$content= ConvertFrom-Json -InputObject $resultarm.Content



    IF(![string]::IsNullOrEmpty($content.nextLink))
    {
        do 
        {
            $uri2=$content.nextLink
            $content=$null
             $resultarm = Invoke-WebRequest -Method GET -Uri $uri2 -Headers $headers -UseBasicParsing
	            $content=$resultarm.Content
	            $content= ConvertFrom-Json -InputObject $resultarm.Content
	            $vmss+=$content.value

        $uri2=$null
        }While (![string]::IsNullOrEmpty($content.nextLink))
    }





    

$prvforresource=$uri=$resultarm=$content=$null

$pipprv=$providers|where {$_.resourcetype -match 'virtualMachineScaleSets/publicIPAddresses'}

$uri="https://management.azure.com"+$ss.id+"/publicIPAddresses?api-version=$($pipprv.Apiversion)"
$resultarm = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -UseBasicParsing
$content=$resultarm.Content
$content= ConvertFrom-Json -InputObject $resultarm.Content



    IF(![string]::IsNullOrEmpty($content.nextLink))
    {
        do 
        {
            $uri2=$content.nextLink
            $content=$null
             $resultarm = Invoke-WebRequest -Method GET -Uri $uri2 -Headers $headers -UseBasicParsing
	            $content=$resultarm.Content
	            $content= ConvertFrom-Json -InputObject $resultarm.Content
	            $vmss+=$content.value

        $uri2=$null
        }While (![string]::IsNullOrEmpty($content.nextLink))
    }




      $invvmSS+=$cuSS 
}





#populate  No resource found messages  for empty collections so OMS views does not generate erro msg 

 $hash['TotalVMCount']+=$invVMs.count
    $hash['TotalVHDCount']+=$invVHDs.count
     $hash['TotalNSGCount']+=$invNSGs.count
      $hash['TotalEndPointCount']+=$invEndpoints.count
       $hash['TotalExtensionCount']+=$invExtensions.count
       $hash['TotalVMScaleSetCount']+=$invvmSS.count


if($invVMs.count -eq 0)
{

$invVMs+=New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'VMInventory';
                            ResourceGroup="NO RESOURCE FOUND"
                            HWProfile="NO RESOURCE FOUND"
                            SubscriptionId = $subscriptionID
                            AzureSubscription = $subscriptionname
                            ShowinDesigner=0
                            }



}

if($invTags.count -eq 0)
{

$invVMs+=New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'VMInventory';
                            Tag="NO RESOURCE FOUND"
                            SubscriptionId = $subscriptionID
                            AzureSubscription = $subscriptionname
                            ShowinDesigner=0
                            }



}

if($invVHDs.count -eq 0)
{

$invVHDs+=New-Object PSObject -Property @{
		            Timestamp = $timestamp
		            MetricName = 'Inventory';
		             StorageAccount="NO RESOURCE FOUND"
		            	SubscriptionId = $subscriptionID
                      AzureSubscription = $subscriptionname
                      ShowinDesigner=0
                        }

}

if($invNics.count -eq 0)
{

 $invNics+=New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'VMNIC';
                            subnet="NO RESOURCE FOUND"
                           	SubscriptionId = $subscriptionID
                            AzureSubscription = $subscriptionname
                            ShowinDesigner=0
      
                            } 

}

if($invNSGs.count -eq 0)
{

$invNSGs+= New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'VMNSGrule';
                            RuleName="NO RESOURCE FOUND"
                            sourcePortRange="NO RESOURCE FOUND"
                            SubscriptionId = $subscriptionID
                             AzureSubscription = $subscriptionname
                             ShowinDesigner=0
      
                            } 


}
if($invEndpoints.count -eq 0)
{

 $invEndpoints+= New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'VMEndpoint';
                           endpointName="NO RESOURCE FOUND"
                            SubscriptionId = $subscriptionID
                             AzureSubscription = $subscriptionname
                             ShowinDesigner=0
      
                                   }

}

if($invExtensions.count -eq 0)
{

  $invExtensions+=New-Object PSObject -Property @{
                                        Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                                        MetricName = 'VMExtensions';
                                         Extension="NO RESOURCE FOUND"
                                         SubscriptionId = $subscriptionID
                             AzureSubscription = $subscriptionname
                             ShowinDesigner=0
                          
                                   }
}



IF($invvmSS.count -eq 0)
{

     $invvmSS+= New-Object PSObject -Property @{
                            Timestamp = $colltime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                            MetricName = 'ScaleSetInventory';
                             Name="NO RESOURCE FOUND"
                                         SubscriptionId = $subscriptionID
                             AzureSubscription = $subscriptionname
                             ShowinDesigner=0
      
                            }


}






### Send data to OMS




$jsonvmpool = ConvertTo-Json -InputObject $invVMs
$jsonvmtags = ConvertTo-Json -InputObject $invTags
$jsonVHDData= ConvertTo-Json -InputObject $invVHDs
$jsonallvmusage = ConvertTo-Json -InputObject $invServiceQuota
$jsoninvnic = ConvertTo-Json -InputObject $invNics
$jsoninvnsg = ConvertTo-Json -InputObject $invNSGs
$jsoninvendpoint = ConvertTo-Json -InputObject $invEndpoints
$jsoninveextensions = ConvertTo-Json -InputObject $invExtensions
$jsoninvvmSS = ConvertTo-Json -InputObject $invvmSS



 Write-output "$(get-date) - Uploading all data to OMS , Final memory  $([System.gc]::gettotalmemory('forcefullcollection') /1MB) "


If($jsonvmpool){$postres1=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonvmpool)) -logType $logname}


	If ($postres1 -ge 200 -and $postres1 -lt 300)
	{
		#Write-Output " Succesfully uploaded $($invVMs.count) vm inventory   to OMS"
	}
	Else
	{
		Write-Warning " Failed to upload  $($invVMs.count) vm inventory   to OMS"
	}

If($jsonvmtags){$postres2=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonvmtags)) -logType $logname}

	If ($postres2 -ge 200 -and $postres2 -lt 300)
	{
	#	Write-Output " Succesfully uploaded $($invTags.count) vm tags  to OMS"
	}
	Else
	{
		Write-Warning " Failed to upload  $($invTags.count) vm tags   to OMS"
	}

If($jsonallvmusage){$postres3=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonallvmusage)) -logType $logname}
	If ($postres3 -ge 200 -and $postres3 -lt 300)
	{
	#	Write-Output " Succesfully uploaded $($invServiceQuota.count) vm core usage  metrics to OMS"
	}
	Else
	{
		Write-Warning " Failed to upload  $($invServiceQuota.count) vm core usage  metrics to OMS"
	}

If($jsonVHDData){$postres4=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonVHDData)) -logType $logname}

	If ($postres4 -ge 200 -and $postres4 -lt 300)
	{
	#	Write-Output " Succesfully uploaded $($invVHDs.count) disk usage metrics to OMS"
	}
	Else
	{
		Write-Warning " Failed to upload  $($invVHDs.count) Disk metrics to OMS"
	}


If($jsoninvnic){$postres5=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsoninvnic)) -logType $logname}

	If ($postres5 -ge 200 -and $postres5 -lt 300)
	{
	#	Write-Output " Succesfully uploaded $($invNics.count) NICs to OMS"
	}
	Else
	{
		Write-Warning " Failed to upload  $($invNics.count) NICs to OMS"
	}


If($jsoninvnsg){$postres6=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsoninvnsg)) -logType $logname}

	If ($postres6 -ge 200 -and $postres6 -lt 300)
	{
	#	Write-Output " Succesfully uploaded $($invNSGs.count) NSG metrics to OMS"
	}
	Else
	{
		Write-Warning " Failed to upload  $($invNSGs.count) NSG metrics to OMS"
	}


If($jsoninvendpoint){$postres7=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsoninvendpoint)) -logType $logname}

	If ($postres7 -ge 200 -and $postres7 -lt 300)
	{
	#	Write-Output " Succesfully uploaded $($invEndpoints.count) input endpoint metrics to OMS"
	}
	Else
	{
		Write-Warning " Failed to upload  $($invEndpoints.count) input endpoint metrics to OMS"
	}


If($jsoninveextensions){$postres8=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsoninveextensions)) -logType $logname}

	If ($postres8 -ge 200 -and $postres8 -lt 300)
	{
	#	Write-Output " Succesfully uploaded $($invEndpoints.count) extensionsto OMS"
	}
	Else
	{
		Write-Warning " Failed to upload  $($invEndpoints.count) extensions  to OMS"
	}


If($jsoninvvmSS){$postres9=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonvmpool)) -logType $logname}


	If ($postres9 -ge 200 -and $postres9 -lt 300)
	{
		#Write-Output " Succesfully uploaded $($invVMs.count) vm inventory   to OMS"
	}
	Else
	{
		Write-Warning " Failed to upload  $($jsoninvvmSS.count) vm inventory   to OMS"
	}


}


#endregion



Write-Output "After Runspace creation  $([System.gc]::gettotalmemory('forcefullcollection') /1MB) MB"
write-output "$($Subscriptions.count) objects will be processed "

$i=1 

$Starttimer=get-date



    $Subscriptions|foreach{
 
        $Subscription =$null
         $Subscription=$_
        $Job = [powershell]::Create().AddScript($ScriptBlock).AddArgument($hash).Addargument($i).AddArgument($Subscription.id).AddArgument($Subscription.Displayname)
        $Job.RunspacePool = $RunspacePool
        $Jobs += New-Object PSObject -Property @{
          RunNum = $i
          subscriptionId=$_.subscriptionId
          Pipe = $Job
          Result = $Job.BeginInvoke()
            }
           
        $i++
    }

write-output  "$(get-date)  , started $i Runspaces "
Write-Output "After dispatching runspaces $([System.gc]::gettotalmemory('forcefullcollection') /1MB) MB"
$jobsClone=$jobs.clone()
Write-Output "Waiting.."

#create variables to collect any errors warnings from runspaces

$errorarray=@()
$warningarray=@()


$s=1
Do {

  Write-Output "  $(@($jobs.result.iscompleted|where{$_  -match 'False'}).count)  jobs remaining"

foreach ($jobobj in $JobsClone)
{

    if ($Jobobj.result.IsCompleted -eq $true)
    {


		   $errorarray+=New-Object PSObject -Property @{
          subscriptionId=$Jobobj.subscriptionId
          errortext=$Jobobj.pipe.Streams.Error
            }


    $warningarray+=New-Object PSObject -Property @{
          subscriptionId=$Jobobj.subscriptionId
          Warningtext=$Jobobj.pipe.Streams.Warning
 
            }


        $jobobj.Pipe.Endinvoke($jobobj.Result)
        $jobobj.pipe.dispose()
        $jobs.Remove($jobobj)
    }
}


IF($([System.gc]::gettotalmemory('forcefullcollection') /1MB) -gt 200)
{
    [gc]::Collect()
}
 

    IF($s%10 -eq 0) 
   {
       Write-Output "Job $s - Mem: $([System.gc]::gettotalmemory('forcefullcollection') /1MB) MB"
   }  
$s++
    
   Start-Sleep -Seconds 15


} While ( @($jobs.result.iscompleted|where{$_  -match 'False'}).count -gt 0)

$msg= "All jobs completed! {6} subscriptions scanned. VMCount = {5}, VHD Count= {4} , NSG={3} ,Endpoints ={2} , Extensions ={1} , VMScaleSets ={0}  " -f $hash['TotalVMScaleSetCount'],$hash['TotalExtensionCount'],$hash['TotalEndPointCount'],$hash['TotalNSGCount'],$hash['TotalVHDCount'],$hash['TotalVMCount'],$hash['SubscriptionCount']
Write-output $msg
$rbend=get-date
Write-Output "Runbook total run time  $([math]::Round(($rbend-$rbstart).TotalMinutes,0)) minutes "
Write-Output "##############################################################################"
IF($errorarray.count -gt 0)
{
	Write-Output "########### ERRORS #############"
	Write-Output -InputObject $errorarray
}

IF($warningarray.count -gt 0)
{
	Write-Output "########### WARNINGS #############"
	Write-Output -InputObject $warningarray
}









