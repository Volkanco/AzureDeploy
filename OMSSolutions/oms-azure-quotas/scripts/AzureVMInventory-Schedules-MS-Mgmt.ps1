param (
[Parameter (Mandatory= $false)]
[int] $frequency=30,
[Parameter(Mandatory=$false)] [bool] $getNICandNSG=$true,
[Parameter(Mandatory=$false)] [bool] $getDiskInfo=$true,
[Parameter(Mandatory=$false)] [bool] $getarmvmstatus=$true
)

#region Login to Azure account and select the subscription.
#Authenticate to Azure with SPN section
Write-Verbose "Logging in to Azure..."
$Conn = Get-AutomationConnection -Name AzureRunAsConnection 
# retry
$retry = 6
$syncOk = $false
do
{ 
	try
	{  
		Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationId $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint
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
Write-Verbose "Selecting Azure subscription..."
Select-AzureRmSubscription -SubscriptionId $Conn.SubscriptionID -TenantId $Conn.tenantid 
#endregion

#define variables 
$AAResourceGroup = Get-AutomationVariable -Name 'AzureVMInventory-AzureAutomationResourceGroup-MS-Mgmt'
$AAAccount = Get-AutomationVariable -Name 'AzureVMInventory-AzureAutomationAccount-MS-Mgmt'
$RunbookName = "AzureVMInventory-MS-Mgmt-v2"
$ScheduleName = "AzureVMInventory-Scheduler-Hourly"
$schedulerrunbookname="AzureVMInventory-Schedules-MS-Mgmt"
$varVMIopsList="AzureVMInventory-VM-IOPSLimits"
$mainSchedulerName="AzureVMInventory-Scheduler"

#create new variales and schedules
$iopslist=Get-AzureRmAutomationVariable -Name $varVMIopsList -ResourceGroupName $AAResourceGroup -AutomationAccountName $AAAccount
If (!$iopslist)
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
	New-AzureRmAutomationVariable -Name $varVMIopsList -Description "Variable to store IOPS limits for Azure VM Sizes." -Value $vmiolimits -Encrypted 0 -ResourceGroupName $AAResourceGroup -AutomationAccountName $AAAccount  -ea 0
}

IF([string]::IsNullOrEmpty($AAAccount) -or [string]::IsNullOrEmpty($AAResourceGroup))
{
	Write-Error "Automation Account  or Automation Account Resource Group Variables is empty. Make sure AzureVMInventory-AzureAutomationResourceGroup-MS-Mgmt and AzureVMInventory-AzureAutomationAccount-MS-Mgmt variables exist in automation account and populated. "
	Write-Output "Script will not continue"
	Exit
}
#schedules

# First clean up any previous schedules to prevent any conflict 
$allSchedules=Get-AzureRmAutomationSchedule `
-AutomationAccountName $AAAccount `
-ResourceGroupName $AAResourceGroup
foreach ($sch in  $allSchedules|where{$_.Name -match $ScheduleName})
{
	Write-output "Removing Schedule $($sch.Name)    "
	Remove-AzureRmAutomationSchedule `
	-AutomationAccountName $AAAccount `
	-Force `
	-Name $sch.Name `
	-ResourceGroupName $AAResourceGroup `
	
} 

# Create required schedules 

$schcount=60/$frequency
Write-output  "Creating schedule $ScheduleName for runbook $RunbookName"

$RunbookStartTime = $Date = $([DateTime]::Now.AddMinutes(10))
$params = @{"getNICandNSG"=$getNICandNSG;"getDiskInfo" = $getDiskInfo;"getarmvmstatus"=$getarmvmstatus}
$i=1
Do {
	New-AzureRmAutomationSchedule `
	-AutomationAccountName $AAAccount `
	-HourInterval 1 `
	-Name $($ScheduleName+"-$i") `
	-ResourceGroupName $AAResourceGroup `
	-StartTime $RunbookStartTime
	Register-AzureRmAutomationScheduledRunbook `
	-AutomationAccountName $AAAccount `
	-ResourceGroupName  $AAResourceGroup `
	-RunbookName $RunbookName `
	-ScheduleName $($ScheduleName+"-$i") -Parameters $params
	$i++
	$RunbookStartTime=$RunbookStartTime.AddMinutes($frequency)
}
While ($i -le $schcount)

#finally remove the schedule for the createschedules runbook as not needed if all schedules are in place

$allSchedules=Get-AzureRmAutomationSchedule `
-AutomationAccountName $AAAccount `
-ResourceGroupName $AAResourceGroup |where{$_.Name -match $ScheduleName -or $_.Name -match $schedulerrunbookname}
If ($allSchedules.count -ge $schcount+1)
{
	Write-output "Removing hourly schedule for scheduler runbook as its not needed anymore, you may rerun this runbook anytime to fix schedules  "
	Remove-AzureRmAutomationSchedule `
	-AutomationAccountName $AAAccount `
	-Force `
	-Name $mainSchedulerName `
	-ResourceGroupName $AAResourceGroup `
}

