param
(
[Parameter(Mandatory=$false)] [bool] $collectqueryperf=$false,
[Parameter(Mandatory=$false)] [bool] $collecttableinv=$false,
[Parameter(Mandatory=$true)] [string] $configfolder,
[Parameter(Mandatory=$true)] [string] $defaultProfileUser,
[Parameter(Mandatory=$true)] [string] $defaultProfilePassword,
[Parameter(Mandatory=$true)] [string] $hybridworkername="HANAMonitorGroup"
)


#region Login to Azure account and select the subscription.
#Authenticate to Azure with SPN section
"Logging in to Azure..."
$ArmConn = Get-AutomationConnection -Name AzureRunAsConnection 

if ($ArmConn  -eq $null)
{
	throw "Could not retrieve connection asset AzureRunAsConnection,  Ensure that runas account  exists in the Automation account."
}

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
$subscriptionid=$ArmConn.SubscriptionId
"Azure rm profile path  $((get-module -Name AzureRM.Profile).path) "
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
$certs= Get-ChildItem -Path Cert:\Currentuser\my -Recurse | Where{$_.Thumbprint -eq $ArmConn.CertificateThumbprint}
#$certs
[System.Security.Cryptography.X509Certificates.X509Certificate2]$mycert=$certs[0]


$CliCert=new-object   Microsoft.IdentityModel.Clients.ActiveDirectory.ClientAssertionCertificate($ArmConn.ApplicationId,$mycert)
$AuthContext = new-object Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext("https://login.windows.net/$($ArmConn.tenantid)")
$result = $AuthContext.AcquireToken("https://management.core.windows.net/",$CliCert)
$header = "Bearer " + $result.AccessToken
$headers = @{"Authorization"=$header;"Accept"="application/json"}
$body=$null
$HTTPVerb="GET"
$subscriptionInfoUri = "https://management.azure.com/subscriptions/"+$subscriptionid+"?api-version=2016-02-01"
$subscriptionInfo = Invoke-RestMethod -Uri $subscriptionInfoUri -Headers $headers -Method Get -UseBasicParsing
IF($subscriptionInfo)
{
	"Successfully connected to Azure ARM REST"
}

#


#endregion

$AAResourceGroup = Get-AutomationVariable -Name 'AzureSAPHanaMonitoring-AzureAutomationResourceGroup-MS-Mgmt'
$AAAccount = Get-AutomationVariable -Name 'AzureSAPHanaMonitoring-AzureAutomationAccount-MS-Mgmt'
$collectorRunbookName = "AzureSAPHanaCollector-MS"
$collectorScheduleName = "AzureSAPHanaCollector-Schedule"
$mainSchedulerName="AzureSAPHanaMonitoring-Scheduler-Hourly"

$varText= "AAResourceGroup = $AAResourceGroup , AAAccount = $AAAccount"

Write-output $varText



IF([string]::IsNullOrEmpty($AAAccount) -or [string]::IsNullOrEmpty($AAResourceGroup))
{

	Write-Error "Automation Account  or Automation Account Resource Group Variables is empty. Make sure AzureSAIngestion-AzureAutomationAccount-MS-Mgmt-SA and AzureSAIngestion-AzureAutomationResourceGroup-MS-Mgmt-SA variables exist in automation account and populated. "
	Write-Output "Script will not continue"
	Exit


}

New-AzureRmAutomationVariable -Name AzureHanaMonitorUser -Description "Hana Monitoring User for Default Profile" -Value $defaultProfileUser -Encrypted 0 -ResourceGroupName $AAResourceGroup -AutomationAccountName $AAAccount  -ea 0
New-AzureRmAutomationVariable -Name AzureHanaMonitorPwd -Description "Hana Monitoring User Password for Default Profile." -Value $defaultProfilePassword -Encrypted 1 -ResourceGroupName $AAResourceGroup -AutomationAccountName $AAAccount  -ea 0
$PlainTextPassword= [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR( (ConvertTo-SecureString $defaultProfilePassword )))

Write-Output $PlainTextPassword

# if not works 
<#
$PlainTextPassword= [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR( (ConvertTo-SecureString $defaultProfilePassword ))

#>

$min=(get-date).Minute 
if($min -in 0..10) 
{
	$RBStart1=(get-date -Minute 16 -Second 00).ToUniversalTime()
}Elseif($min -in 11..25) 
{
	$RBStart1=(get-date -Minute 31 -Second 00).ToUniversalTime()
}elseif($min -in 26..40) 
{
	$RBStart1=(get-date -Minute 46 -Second 00).ToUniversalTime()
}ElseIf($min -in 46..55) 
{
	$RBStart1=(get-date -Minute 01 -Second 00).AddHours(1).ToUniversalTime()
}Else
{
	$RBStart1=(get-date -Minute 16 -Second 00).AddHours(1).ToUniversalTime()
}

$RBStart2=$RBStart1.AddMinutes(15)
$RBStart3=$RBStart2.AddMinutes(15)
$RBStart4=$RBStart3.AddMinutes(15)


# First clean up any previous schedules to prevent any conflict 

$allSchedules=Get-AzureRmAutomationSchedule `
-AutomationAccountName $AAAccount `
-ResourceGroupName $AAResourceGroup

foreach ($sch in  $allSchedules|where{$_.Name -match $collectorScheduleName})
{

	Write-output "Removing Schedule $($sch.Name)    "
	Remove-AzureRmAutomationSchedule `
	-AutomationAccountName $AAAccount `
	-Force `
	-Name $sch.Name `
	-ResourceGroupName $AAResourceGroup `
	
} 

Write-output  "Creating schedule $collectorScheduleName for runbook $collectorRunbookName"

$i=1
Do {
	New-AzureRmAutomationSchedule `
	-AutomationAccountName $AAAccount `
	-HourInterval 1 `
	-Name $($collectorScheduleName+"-$i") `
	-ResourceGroupName $AAResourceGroup `
	-StartTime (Get-Variable -Name RBStart"$i").Value

	{

		$params = @{"collectqueryperf" = $collectqueryperf ; "collecttableinv" = $collecttableinv;"configfolder" = $configfolder;"collectfreq"=$collectfreq}
		Register-AzureRmAutomationScheduledRunbook `
		-AutomationAccountName $AAAccount `
		-ResourceGroupName  $AAResourceGroup `
		-RunbookName $collectorRunbookName `
		-ScheduleName $($collectorScheduleName+"-$i")  -Parameters $Params -RunOn $hybridworkername

	
	}

	$i++
}
While ($i -le 4)








#finally remove the schedule for the createschedules runbook as not needed if all schedules are in place

$allSchedules=Get-AzureRmAutomationSchedule `
		-AutomationAccountName $AAAccount `
		-ResourceGroupName $AAResourceGroup |where{$_.Name -match $collectorScheduleName }


If ($allSchedules.count -ge 5)
{
Write-output "Removing hourly schedule for this runbook as its not needed anymore  "
Remove-AzureRmAutomationSchedule `
		-AutomationAccountName $AAAccount `
		-Force `
		-Name $mainSchedulerName `
		-ResourceGroupName $AAResourceGroup `


}

	

