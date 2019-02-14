param
(
[Parameter(Mandatory=$false)] [bool] $collectqueryperf=$false,
[Parameter(Mandatory=$false)] [bool] $collecttableinv=$false,
[Parameter(Mandatory=$true)] [string] $configfolder="C:\HanaMonitor",
[Parameter(Mandatory=$true)] [string] $hybridWorkerGroup,
[Parameter(Mandatory=$true)] [int] $frequency=15
)


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



# if not works 
<#
New-AzureRmAutomationVariable -Name AzureHanaMonitorUser -Description "Hana Monitoring User for Default Profile" -Value $defaultProfileUser -Encrypted 0 -ResourceGroupName $AAResourceGroup -AutomationAccountName $AAAccount  -ea 0
New-AzureRmAutomationVariable -Name AzureHanaMonitorPwd -Description "Hana Monitoring User Password for Default Profile." -Value $defaultProfilePassword -Encrypted 1 -ResourceGroupName $AAResourceGroup -AutomationAccountName $AAAccount  -ea 0
$PlainTextPassword= [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR( (ConvertTo-SecureString $defaultProfilePassword )))
Write-Output $PlainTextPassword
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


$schcount=60/$frequency

For($i=2;$I -le $schcount; $I++)
{
    New-Variable -Name RBStart$i -Value $RBStart1.AddMinutes($frequency*($i-1))
}

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


		$params = @{"collecttableinv" = $collecttableinv;"configfolder" = $configfolder;"debuglog"=$false;"useManagedIdentity"=$false;"runmode"="default"}
		Register-AzureRmAutomationScheduledRunbook `
		-AutomationAccountName $AAAccount `
		-ResourceGroupName  $AAResourceGroup `
		-RunbookName $collectorRunbookName  `
		-ScheduleName $($collectorScheduleName+"-$i")  -Parameters $Params -RunOn $hybridworkergroup


	$i++
}
While ($i -le $schcount)

#finally create a daily schedule for Configuration Checks
if($(get-date).Hour -lt 4 )
{
    $dailyschedule=Get-Date -Hour 4 -Minute 0 -Second 0
}Else
{
    $dailyschedule=(Get-Date -Hour 4 -Minute 0 -Second 0).adddays(1)
}


New-AzureRmAutomationSchedule  `
	-AutomationAccountName $AAAccount `
	-DayInterval 1  `
	-Name "$collectorScheduleName-Daily"
	-ResourceGroupName $AAResourceGroup `
	-StartTime $dailyschedule

		$params = @{"collecttableinv" = $collecttableinv;"configfolder" = $configfolder;"debuglog"=$false;"useManagedIdentity"=$false;"runmode"="daily"}
		Register-AzureRmAutomationScheduledRunbook `
		-AutomationAccountName $AAAccount `
		-ResourceGroupName  $AAResourceGroup `
		-RunbookName $collectorRunbookName  `
		-ScheduleName "$collectorScheduleName-Daily"  -Parameters $Params -RunOn $hybridworkergroup






#finally remove the schedule for the createschedules runbook as not needed if all schedules are in place

$allSchedules=Get-AzureRmAutomationSchedule `
		-AutomationAccountName $AAAccount `
		-ResourceGroupName $AAResourceGroup |where{$_.Name -match $mainSchedulerName}



foreach ($sch in  $allSchedules)
{

	Write-output "Removing Schedule $($sch.Name)    "
	Remove-AzureRmAutomationSchedule `
	-AutomationAccountName $AAAccount `
	-Force `
	-Name $sch.Name `
	-ResourceGroupName $AAResourceGroup `
	
} 


