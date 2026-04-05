#Requires -Modules Az.ResourceGraph,Az.Accounts,Az.Storage
param (
    [Parameter(mandatory=$false)]
    [string]$tenantscope,
    [Parameter(mandatory=$false)]
	[array]$customerTags=@(),
    [Parameter(mandatory=$false)]
    [string]$exportstoragesubid,
    [Parameter(mandatory=$false)]
    [string]$exportstorageAccount,
    [Parameter(mandatory=$false)]
    [bool]$localexport=$true,
    [Parameter(mandatory=$false)]
    [string[]]$subscriptionList=@()
)

# Validate that storage parameters are provided when localexport is false
if ($localexport -eq $false) {
    if ([string]::IsNullOrEmpty($exportstoragesubid)) {
        throw "Parameter 'exportstoragesubid' is required when localexport is `$false."
    }
    if ([string]::IsNullOrEmpty($exportstorageAccount)) {
        throw "Parameter 'exportstorageAccount' is required when localexport is `$false."
    }
}

# Validate that storage parameters are provided when localexport is false
if ($localexport -eq $false) {
    if ([string]::IsNullOrEmpty($exportstoragesubid)) {
        throw "Parameter 'exportstoragesubid' is required when localexport is `$false."
    }
    if ([string]::IsNullOrEmpty($exportstorageAccount)) {
        throw "Parameter 'exportstorageAccount' is required when localexport is `$false."
    }
}

<#
HELPER Functions
#>
Function Get-AllAzGraphResource {
    param (
        [string[]]$subscriptionId,
        [string]$query = 'Resources | project id,name, kind, location, resourceGroup, subscriptionId, sku, plan, zones, properties,tags'
    )
  
    [string]$query = 'Resources | project id,name, kind, location, resourceGroup, subscriptionId, sku, plan, zones, properties,tags | where id !has "Microsoft.Compute/snapshots" | where tags.Environment  !in ("Development","UAT","DEV") '

    if ($subscriptionId) {
        $result = Search-AzGraph -Query $query -First 1000 -Subscription $subscriptionId

    }else{
        $result = Search-AzGraph -Query $query -First 1000 -UseTenantScope
    }

    # Collection to store all resources
    $allResources = @($result)
  
    # Loop to paginate through the results using the skip token
    while ($result.SkipToken) {
        # Retrieve the next set of results using the skip token
        # $result = $subscriptionId ? (Search-AzGraph -Query $query -SkipToken $result.SkipToken -Subscription $subscriptionId -First 1000) : (Search-AzGraph -query $query -SkipToken $result.SkipToken -First 1000 -UseTenantScope)
        
        if ($subscriptionId) {
            $result = Search-AzGraph -Query $query -SkipToken $result.SkipToken -First 1000 -Subscription $subscriptionId
    
        }else{
            $result = Search-AzGraph -Query $query -SkipToken $result.SkipToken -First 1000 -UseTenantScope
        }
        
        
        # Add the results to the collection
        $allResources += $result
    }

    return  $allResources 
}

Function Get-AzBAckupASR {
    param (
        [string[]]$subscriptionId
    )

    $query = "recoveryservicesresources
        | where ['type'] in ('microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems','microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems')
            | extend vmId = case(
                properties.backupManagementType == 'AzureIaasVM', tolower(tostring(properties.dataSourceInfo.resourceID)),
                type == 'microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems', tolower(tostring(properties.providerSpecificDetails.dataSourceInfo.resourceId)),
                ''
            )
            | extend asrId = iff(type == 'microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems', tolower(tostring(strcat_array(array_slice(split(properties.recoveryFabricId, '/'), 0, 8), '/'))), '')
            | extend resourceId = case(
                properties.backupManagementType == 'AzureIaasVM', vmId,
                type == 'microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems', asrId,
                ''    )
            | extend Backup = tostring(properties.protectionStatus)
            | extend replicationHealth = properties.replicationHealth
            | extend failoverHealth = properties.failoverHealth
            | extend protectionStateDescription = properties.protectionStateDescription
            | extend isReplicationAgentUpdateRequired = properties.providerSpecificDetails.isReplicationAgentUpdateRequired
           // | project resourceId, vmId, asrId, Backup, replicationHealth, failoverHealth, protectionStateDescription, isReplicationAgentUpdateRequired
        | order by ['resourceId'] asc
        | order by ['resourceGroup'] asc"


    $result = Search-AzGraph -Query $query -First 1000 -Subscription $subscriptionId

    # Collection to store all resources
    $allResources = @($result)
  
    # Loop to paginate through the results using the skip token
    while ($result.SkipToken) {
        # Retrieve the next set of results using the skip token
        # $result = $subscriptionId ? (Search-AzGraph -Query $query -SkipToken $result.SkipToken -Subscription $subscriptionId -First 1000) : (Search-AzGraph -query $query -SkipToken $result.SkipToken -First 1000 -UseTenantScope)
        
        if ($subscriptionId) {
            $result = Search-AzGraph -Query $query -SkipToken $result.SkipToken -First 1000 -Subscription $subscriptionId
    
        }else{
            $result = Search-AzGraph -Query $query -SkipToken $result.SkipToken -First 1000 -UseTenantScope
        }
        
        
        # Add the results to the collection
        $allResources += $result
    }

    return  $allResources 

}

Function Get-AllRetirements {
    param (
        [string[]]$subscriptionId
        #,[string]$query 
    )


    $query = "resources
| extend ServiceID= case(
type contains 'microsoft.compute/virtualmachine' and  (tostring(properties.hardwareProfile.vmSize) in~ ('basic_a0','basic_a1','basic_a2','basic_a3','basic_a4','standard_a0','standard_a1','standard_a2','standard_a3','standard_a4','standard_a5','standard_a6','standard_a7','standard_a9')  or tostring(sku.name) in~ ('basic_a0','basic_a1','basic_a2','basic_a3','basic_a4','standard_a0','standard_a1','standard_a2','standard_a3','standard_a4','standard_a5','standard_a6','standard_a7','standard_a9')),60
,type == 'microsoft.web/hostingenvironments' and kind in ('ASEV1','ASEV2'),13
,type == 'microsoft.compute/virtualmachines' and isempty(properties.storageProfile.osDisk.managedDisk),84
,type == 'microsoft.dbforpostgresql/servers' ,86
,type == 'microsoft.dbformysql/servers'  ,243
,type == 'microsoft.network/loadbalancers' and sku.name=='Basic',94
,type == 'microsoft.operationsmanagement/solutions' and plan.product=='OMSGallery/ServiceMap',213
,type == 'microsoft.insights/components' and isempty(properties.WorkspaceResourceId) ,181
,type == 'microsoft.classicstorage/storageaccounts',7
,type == 'microsoft.classiccompute/domainnames', 38
,type == 'microsoft.dbforpostgresql/servers' and properties.version == '11',225
,type == 'microsoft.logic/integrationserviceenvironments',139
,type == 'microsoft.classicnetwork/virtualnetworks',88
,type == 'microsoft.network/applicationgateways' and properties.sku.tier in~ ('Standard','WAF'),298
,type == 'microsoft.classicnetwork/reservedips',8802
,type == 'microsoft.classicnetwork/networksecuritygroups',8801
,type =~ 'Microsoft.CognitiveServices/accounts' and kind=~'QnAMaker',76
,type contains 'microsoft.compute/virtualmachine' and  (tostring(properties.hardwareProfile.vmSize) in~ ('Standard_HB60rs','Standard_HB60-45rs','Standard_HB60-30rs','Standard_HB60-15rs')  or tostring(sku.name) in~ ('Standard_HB60rs','Standard_HB60-45rs','Standard_HB60-30rs','Standard_HB60-15rs')) ,62
,type contains 'Microsoft.MachineLearning/',40
,type =~ 'Microsoft.Network/publicIPAddresses' and sku.name=='Basic',220
,type =~ 'Microsoft.CognitiveServices/accounts' and kind contains 'LUIS',160
,type contains 'Microsoft.TimeSeriesInsights',31
,type =~ 'microsoft.dbforpostgresql/servers' and properties.version == '11',249
,type contains 'microsoft.media/mediaservices',394
,type =~ 'microsoft.maps/accounts' and (sku has 'S1' or sku has 'S0'),465
,type =~ 'microsoft.insights/webtests' and properties.Kind =~ 'ping',154
,type =~ 'microsoft.healthcareapis/services',354
,type =~ 'microsoft.healthcareapis' and properties.authenticationConfiguration.smartProxyEnabled =~ 'true',387
,type contains 'Microsoft.DBforMariaDB',398
,type =~ 'microsoft.cache/redis' and properties['minimumTlsVersion'] in ('1.1','1.0') ,403
,type =~ 'microsoft.cognitiveservices/accounts' and kind == 'Personalizer', 408
,type =~ 'microsoft.cognitiveservices/accounts' and kind == 'AnomalyDetector', 405
,type =~ 'microsoft.cognitiveservices/accounts' and kind == 'MetricsAdvisor', 407
,type =~ 'microsoft.cognitiveservices/accounts' and kind == 'ContentModerator', 561
,type contains 'microsoft.compute/virtualmachine' and  (tostring(properties.hardwareProfile.vmSize) in~ ('Standard_M192is_v2')  or tostring(sku.name) in~ ('Standard_M192is_v2')) ,495
,type contains 'microsoft.compute/virtualmachine' and  (tostring(properties.hardwareProfile.vmSize) in~ ('Standard_M192ims_v2')  or tostring(sku.name) in~ ('Standard_M192ims_v2')) ,496
,type contains 'microsoft.compute/virtualmachine' and  (tostring(properties.hardwareProfile.vmSize) in~ ('Standard_M192ids_v2')  or tostring(sku.name) in~ ('Standard_M192ids_v2')) ,497
,type contains 'microsoft.compute/virtualmachine' and  (tostring(properties.hardwareProfile.vmSize) in~ ('Standard_M192idms_v2')  or tostring(sku.name) in~ ('Standard_M192idms_v2')) ,498
,type contains 'microsoft.storagecache/caches' ,500
,type contains 'microsoft.compute/virtualmachine' and  (tostring(properties.hardwareProfile.vmSize) in~ ('Standard_NC6s_v3','Standard_NC12s_v3','Standard_NC24s_v3')  or tostring(sku.name) in~ ('Standard_NC6s_v3','Standard_NC12s_v3','Standard_NC24s_v3')) ,514
,type contains 'microsoft.network/applicationgateways' and properties['sku']['tier'] in ('WAF_v2') and isnotnull(properties['webApplicationFirewallConfiguration']), 519
,type contains 'microsoft.dashboard/grafana' and (properties.grafanaMajorVersion == 9),554
,type contains 'HDInsight' and  (strcat(split(properties.clusterVersion,'.')[0],'.',split(properties.clusterVersion,'.')[1])) in ('4.0'), 562
,type contains 'HDInsight' and  (strcat(split(properties.clusterVersion,'.')[0],'.',split(properties.clusterVersion,'.')[1])) in ('5.0'), 563
,type contains 'microsoft.compute/virtualmachine' and  (tostring(properties.hardwareProfile.vmSize) in~ ('Standard_NC24rs_v3')  or tostring(sku.name) in~ ('Standard_NC24rs_v3')) ,582
,type contains 'Microsoft.ApiManagement/service' and tolower(properties.platformVersion) != tolower('stv2') ,204
,type contains 'microsoft.network/virtualnetworkgateways' and (tostring(properties.sku.name) in~ ('Standard')  or tostring(properties.sku.name) in~ ('HighPerformance') )
and tostring(properties.gatewayType) contains ('Vpn'), 481
,-9999)
| where ServiceID >0
| project ServiceID , id, resourceGroup, location
|union
(resources
    | where type == 'microsoft.synapse/workspaces/bigdatapools' and todouble(properties.sparkVersion) == 3.2
    | extend workspaceId = tostring(split(id,'/')[8])
    | join (
            Resources
            | where type == 'microsoft.synapse/workspaces' and properties.adlaResourceId == ''
            | project workspaceId = name
                ) on workspaceId
| project ServiceID = 583 , id, resourceGroup, location)
|union 
(
    AdvisorResources
    | where type =='microsoft.advisor/recommendations'
    | where properties.shortDescription contains 'Cloud service caches are being retired'
    | project id=tolower(tostring(properties.resourceMetadata.resourceId))
    | join 
    (
        resources
        | where type contains 'microsoft.cache/redis'
        | project id=tolower(id), resourceGroup, location
    ) on id
    | project ServiceID=124 , id, resourceGroup, location 
)
"
    
    if ($subscriptionId) {
        $result = Search-AzGraph -Query $query -First 1000 -Subscription $subscriptionId
    
    }else{
        $result = Search-AzGraph -Query $query -First 1000 -UseTenantScope
    }
    
    # Collection to store all resources
    $allResources = @($result)
    
    # Loop to paginate through the results using the skip token
    while ($result.SkipToken) {
        # Retrieve the next set of results using the skip token
        if ($subscriptionId) {
            $result = Search-AzGraph -Query $query -SkipToken $result.SkipToken -First 1000 -Subscription $subscriptionId
    
        }else{
            $result = Search-AzGraph -Query $query -SkipToken $result.SkipToken -First 1000 -UseTenantScope
        }
        # Add the results to the collection
        $allResources += $result
    }
  
    return  $allResources 
}
  
function parse-object {
    param ([string[]]$text)
    $parsed = ($text -replace ' (\w+=)', "`n`$1" ) -replace '[@{};]', '' | % { [pscustomobject] (ConvertFrom-StringData $_) }  
    return $parsed
}

################
# Generic Resiliency Processing Engine
###################################

function Invoke-ResiliencyRules {
    param(
        [Parameter(Mandatory)]
        [array]$AllResources,

        [Parameter(Mandatory)]
        [array]$Rules,

        [Parameter(Mandatory)]
        [array]$BaseProps,

        [array]$CustomerTags = @()
    )

    $MasterReport = @()
    $processedSubTypes = [System.Collections.Generic.List[string]]::new()

    # Group all resources by subtype for fast lookup
    $resourcesBySubType = @{}
    foreach ($res in $AllResources) {
        $st = $res.ResourceSubType
        if (-not $resourcesBySubType.ContainsKey($st)) {
            $resourcesBySubType[$st] = [System.Collections.Generic.List[object]]::new()
        }
        $resourcesBySubType[$st].Add($res)
    }

    foreach ($rule in $Rules) {

        $subType = $rule.ResourceSubType

        # 1. Get matching resources from the pre-grouped hashtable
        $matched = $resourcesBySubType[$subType]
        if (-not $matched -or $matched.Count -eq 0) { continue }

        # Apply optional SkipExtensions filter
        if ($rule.SkipExtensions -eq $true) {
            $matched = @($matched | Where-Object { $_.ResourceId -notlike '*/extensions/*' })
        }

        # Apply optional custom MatchFilter
        if ($rule.MatchFilter) {
            $matched = @($matched | Where-Object $rule.MatchFilter)
        }

        if ($matched.Count -eq 0) { continue }

        Write-Host "  [Rule Engine] $subType — $($matched.Count) resources" -ForegroundColor Cyan

        if (-not $processedSubTypes.Contains($subType)) {
            $processedSubTypes.Add($subType)
        }

        # 2. Select base + extra + tag properties
        $extraProps = if ($rule.ExtraProperties) { $rule.ExtraProperties } else { @() }
        $selectProps = $BaseProps + $extraProps + $CustomerTags
        $subreport = @($matched | Select-Object -Property $selectProps)

        # 3. Evaluate resiliency for each resource
        foreach ($item in $subreport) {

            if ($rule.DefaultResiliency) {
                # Static assignment
                Add-Member -InputObject $item -Name ResiliencyConfig -Value $rule.DefaultResiliency -MemberType NoteProperty -Force
            }
            elseif ($rule.ResiliencyLogic) {
                # Dynamic evaluation
                $result = $null
                if ($rule.UseAllResources -eq $true) {
                    $result = & $rule.ResiliencyLogic $item $AllResources
                } else {
                    $result = & $rule.ResiliencyLogic $item
                }

                # Skip marker
                if ($result._skip -eq $true) { continue }

                # Apply all returned properties to the resource object
                foreach ($key in $result.Keys) {
                    if ($key -eq '_skip') { continue }
                    Add-Member -InputObject $item -Name $key -Value $result[$key] -MemberType NoteProperty -Force
                }
            }
        }

        $MasterReport += $subreport
    }

    # Return results
    return @{
        MasterReport      = $MasterReport
        ProcessedSubTypes = $processedSubTypes
    }
}


function Invoke-CatchAllResiliency {
    param(
        [Parameter(Mandatory)]
        [array]$AllResources,

        [Parameter(Mandatory)]
        [array]$ProcessedSubTypes,

        [Parameter(Mandatory)]
        [array]$BaseProps,

        [array]$CustomerTags = @()
    )

    $remaining = @($AllResources | Where-Object {
        $_.ResourceSubType -like 'Microsoft.*' -and
        $_.ResourceSubType -notin $ProcessedSubTypes
    })

    if ($remaining.Count -eq 0) { return @() }

    Write-Host "  [Catch-All] Processing $($remaining.Count) unhandled resources" -ForegroundColor DarkYellow

    $selectProps = $BaseProps + $CustomerTags
    $subreport = @($remaining | Select-Object -Property $selectProps)

    foreach ($item in $subreport) {
        if (-not [string]::IsNullOrEmpty($item.zones)) {
            $config = if ($item.zones.length -ge 2) { 'ZoneRedundant' }
                      elseif ($item.zones.length -eq 1) { 'Zonal' }
                      else { 'NonZonal' }
            Add-Member -InputObject $item -Name ResiliencyConfig -Value $config -MemberType NoteProperty -Force
        } elseif($item.properties.zoneRedundant -eq $true){
                Add-Member -InputObject $item -Name ResiliencyConfig -Value 'ZoneRedundant' -MemberType NoteProperty -Force
        }else{
            Add-Member -InputObject $item -Name ResiliencyDetail -Value 'NoInfo' -MemberType NoteProperty -Force
        }
    }

    return $subreport
}




# ─── Load rules and engine ───
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

. "$scriptDir\ResiliencyRules.ps1"
#. "$scriptDir\ResiliencyEngine.ps1"


####################################################################
#
#   Connect to Azure and get all Subscriptions 
#
####################################################################

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process



If (-not $(Get-AzContext)) {

    #check if running under automation account or local powershell
    IF($PSPrivateMetadata.JobId -or $env:AUTOMATION_ASSET_ACCOUNTID)
    {
        $AzureContext =(Connect-AzAccount -Identity).context

        #if user managed identity will be used , update the connection string with userid
        #$AzureContext =(Connect-AzAccount -Identity -AccountId <userid>).context
    }else{
        $AzureContext = (Connect-AzAccount).context
    }
}else{
    $AzureContext=Get-AzContext
}

# Set and store context
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext

    
# ─── Subscription Discovery ───

if ($subscriptionList.Count -gt 0) {
    # Explicit list provided — resolve each one (supports both name and ID)
    Write-Output "Subscription filter provided: $($subscriptionList.Count) subscriptions"
    $sublist = @()
    foreach ($entry in $subscriptionList) {
        $resolved = Get-AzSubscription -SubscriptionId $entry -ErrorAction SilentlyContinue
        if (-not $resolved) {
            $resolved = Get-AzSubscription -SubscriptionName $entry -ErrorAction SilentlyContinue
        }
        if ($resolved) {
            $sublist += $resolved
        } else {
            Write-Warning "Could not resolve subscription: $entry — skipping"
        }
    }
}
elseif ($tenantscope) {
    $sublist = Get-AzSubscription -TenantId $tenantscope
}
else {
    $sublist = Get-AzSubscription
}

# Filter out non-production subscriptions
$sublist = $sublist | Where-Object { $_.name -notlike '*DEV*' -and $_.name -notlike '*UAT*' -and $_.name -notlike '*POC*' }

Write-Output "$(($sublist | Where-Object { $_.state -eq 'Enabled' }).count) subscriptions found (DEV/UAT/POC removed)"

$jobs = @()

$dt = (Get-Date).ToString("yyyyMMddhhmm")
$datecolumn = (Get-Date).ToString("yyyy-MM-dd")

Write-Output "$dt - Scanning subscriptions!"

$retirements = @()
$mainReport = @()
$lbreport = @()
$pipreport = @()
$zonemapping=@()
$asrbackup = @()
$RetirementsDownloadUri='https://raw.githubusercontent.com/Volkanco/AzureDeploy/refs/heads/master/ReliabilityAssessment/AzureRetirements.json'
$runlog=@()



$error.Clear()


If(Get-Item -Path  $(get-date).ToString('yyyyMMdd') -ErrorAction SilentlyContinue)
{
    $folder=Get-Item -Path  $(get-date).ToString('yyyyMMdd')
    
    #Clean up any files from previous runs
    Get-ChildItem -Path $folder.FullName |   Remove-Item -Force


}else{
    $folder=new-item  -name $(get-date).ToString('yyyyMMdd')   -ItemType Directory
}


Write-Output "$(($sublist | where { $_.state -eq 'Enabled'}).count) subsctions found"

#### ADD Trim to all tags 
#remove nonprod subscriptios

$sublist=$sublist| where {$_.name -notlike  '*DEV*' -and $_.name -notlike '*UAT*' -and $_.name -notlike '*POC*'}
$scount=($sublist | where { $_.state -eq 'Enabled'}).count
$sc=1


Write-Output "$(($sublist | where { $_.state -eq 'Enabled'}).count) subsctions found (DEV/UAT/POC Removed)"




foreach ($sub in $sublist | where { $_.state -eq 'Enabled' }) {

    Write-Output "############################################################"
    Write-Output  $sub 
    Write-Output "############################################################"
    if((get-azcontext).Subscription.id -ne $sub.Id){
    Set-AzContext -Subscription $sub.Id |Out-Null
    start-sleep -s 3 }
    


	remove-variable mainreport -force  -ErrorAction SilentlyContinue
	remove-variable lbreport -force -ErrorAction SilentlyContinue
	remove-variable pipreport -force  -ErrorAction SilentlyContinue
	remove-variable zonemapping -force -ErrorAction SilentlyContinue
	remove-variable asrbackup -force -ErrorAction SilentlyContinue
	remove-variable Allres -force -ErrorAction SilentlyContinue
	remove-variable rtype -force -ErrorAction SilentlyContinue
	remove-variable reslist -force -ErrorAction SilentlyContinue



	[System.GC]::Collect()


    Write-Output "Processing $($sub.name)      - ($sc / $scount) , total memory $([System.GC]::GetTotalMemory($true)/1024/1024)"
    $sc++


    Write-Output "`n`r"

    $mainReport = @()

    $lbreport = @()
    $pipreport = @()
    $zonemapping=@()
    $asrbackup = @()
	$MasterReport = @()
	
	
	    $Allres = Get-AllAzGraphResource -subscriptionId $sub.Id

    Write-Output "$($Allres.count) resources found under  $($sub.name)"
	
	
	   $runlog+= New-Object PSObject -Property @{ 
                    Subscription       = $($sub.name) -join ','
                    Subscriptionid = $($sub.id) -join ','
                    ResCount  	    =$($Allres.count)  -join ','
                    MemoryUsage     = $([System.GC]::GetTotalMemory($true)/1024/1024)
                }
	
	
	### Add a filter to remove resources like Microsoft.Compute/snapshots to reduce memory footprint .
	#microsoft.insights/scheduledqueryrules
	
	$allres=$allres|where{$_.id -notlike '*Microsoft.Compute/snapshots*'}
	
	
    
    if($($Allres.count) -gt 0){
    
    $retirements += Get-AllRetirements -subscriptionId $sub.Id 
    #add resource type

    $asrbackup_ = @()
    $asrbackup_ = Get-AzBAckupASR -subscriptionId $sub.Id

    $asrbackup_ | ForEach-Object {
        $t=$_

        If ($t.type -eq 'microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems') {
            Add-Member -InputObject $t -Name ProtectionType -Value "Backup" -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name backupManagementType -Value $t.Properties.backupManagementType -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name currentProtectionState -Value $t.Properties.currentProtectionState -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name protectedPrimaryRegion -Value $t.Properties.protectedPrimaryRegion -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name sourceResourceId -Value $t.Properties.sourceResourceId -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name lastBackupStatus -Value $t.Properties.lastBackupStatus -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name lastBackupTime -Value $t.Properties.lastBackupTime -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name protectedItemType -Value $t.Properties.protectedItemType -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name backupManagementType -Value $t.Properties.backupManagementType -MemberType Noteproperty -Force
            #Add-Member -InputObject $t -Name resourceName -Value $($t.ResourceId.Split('/')[$t.ResourceId.Split('/').count - 1]) -MemberType Noteproperty -Force

        
            Switch ($t.Properties.protectedItemType)
            {
                'Microsoft.Compute/virtualMachines'
                {            
                     $res=$null
                    $res=$($t.ResourceId.Split('/')[$t.ResourceId.Split('/').count - 1])
                    Add-Member -InputObject $t -Name resourcename -Value $res.split(';')[3] -MemberType Noteproperty -Force}
                'AzureFileShareProtectedItem'
                {    
                     $res=$null
                    $res=$($t.Properties.sourceResourceId.Split('/')[$t.Properties.sourceResourceId.Split('/').count - 1])
                    Write-Output "$res|$($t.name)"

                    Add-Member -InputObject $t -Name resourcename -Value "$res|$($t.name)"  -MemberType Noteproperty -Force
                    }
                'AzureVmWorkloadSQLDatabase'
                {    
                    $res=$null
                    $res=$($t.ResourceId.Split('/')[$t.ResourceId.Split('/').count - 1])
                    Add-Member -InputObject $t -Name resourcename -Value $res  -MemberType Noteproperty -Force}
                Default {
                         $res=$null
                    $res=$($t.ResourceId.Split('/')[$t.ResourceId.Split('/').count - 1])
                    Add-Member -InputObject $t -Name resourcename -Value $res  -MemberType Noteproperty -Forc
                }

            
            
            }




        }elseif ('microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems') {
            Add-Member -InputObject $t -Name ProtectionType -Value "ASR" -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name currentProtectionState -Value $t.Properties.currentProtectionState -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name primaryFabricLocation -Value $t.properties.providerSpecificDetails.primaryFabricLocation -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name recoveryFabricLocation -Value $t.properties.providerSpecificDetails.recoveryFabricLocation -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name primaryFabricProvider -Value $t.Properties.primaryFabricProvider -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name replicationHealth -Value $t.Properties.replicationHealth -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name failoverHealth -Value $t.Properties.failoverHealth -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name activeLocation -Value $t.Properties.activeLocation -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name sourceResourceId -Value $t.properties.providerSpecificDetails.dataSourceInfo.resourceId -MemberType Noteproperty -Force
            Add-Member -InputObject $t -Name resourceName -Value $($t.vmId.Split('/')[$t.vmId.Split('/').count - 1]) -MemberType Noteproperty -Force
        }
            #add date column for report 
            Add-Member -InputObject $t -Name ReportDate -Value $datecolumn -MemberType Noteproperty -Force
    }
    
    
    $asrbackup += $asrbackup_ | Select-Object -Property * -ExcludeProperty Properties

    #Get AZ Zone MApping for the sub 

    $response=$locations=$null
    $response = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$($sub.Id)/locations?api-version=2022-12-01"
    $locations = ($response.Content | ConvertFrom-Json).value
    $locations|foreach{
        $t=$_

        IF($t.availabilityZoneMappings -ne $null)
        {
            $t.availabilityZoneMappings|foreach{
            
                $cu = New-Object PSObject -Property @{ 
                    Subscription       = $($sub.name) -join ','
                    Subscriptionid = $($sub.id) -join ','
                    ReportDate  	    =$datecolumn -join ','
                    location     = $t.name -join ','
                    availabilityzone   = $_.logicalZone -join ','
                    physicalzone  = $($_.physicalZone)
                }
                $zonemapping+=$cu
            }
        }else{
            $cu = New-Object PSObject -Property @{ 
                Subscription       = $($sub.name) -join ','
                Subscriptionid = $($sub.id) -join ','
                ReportDate  	    =$datecolumn -join ','
                location     = $t.name -join ','
                availabilityzone   = "NoAZRegion" -join ','
                physicalzone  = $t.name
            }
            $zonemapping+=$cu

    }
    
    }



	  $splitSize = 5000
	  $spltlist = @()
    If ($Allres.count -gt $splitSize) {
        
        $spltlist += for ($Index = 0; $Index -lt $Allres.count; $Index += $splitSize) {
            , ($Allres[$index..($index + $splitSize - 1)])
        }
		
		
    
	}else{
		$spltlist+='.'
		$spltlist[0]=$Allres
	}
	
	
	
	   Write-Output "Processing $($allres.count) resources in $($spltlist.count)  batch  -  , total memory $([System.GC]::GetTotalMemory($true)/1024/1024)"




##### Split start

    Foreach($mainReport in $spltlist)
	{


	$mainReport| Foreach-Object{
		$obj=$_
        $split = $obj.id.Split('/')
        Add-Member -InputObject $obj -Name ResourceType -Value $split[6] -MemberType Noteproperty -Force
        Add-Member -InputObject $obj -Name ResourceSubType -Value $($split[6] + "/" + $split[7]) -MemberType Noteproperty -Force
        Add-Member -InputObject $obj -Name Subscription -Value $($sub.name) -MemberType Noteproperty -Force
        #add date column for report 
        Add-Member -InputObject $obj -Name ReportDate -Value $datecolumn -MemberType Noteproperty -Force

        If ($obj.resourceid -like '*Microsoft.Network/loadBalancers*') {               
 
            $obj.properties.frontendipconfigurations | ForEach-Object {
                $cu = New-Object PSObject -Property @{ 
                    name       = $obj.name -join ','
                    ReportDate       = $datecolumn -join ','
                    resourceid = $obj.ResourceId -join ','
                    FEName     = $_.name -join ','
                    FEIpConf   = $_.id -join ','
                    FEIpZones  = $($_.zones -join " ")
                }
                
                $lbreport += $cu
            }             

        }


        If ($obj.resourceid -like '*Microsoft.Network/publicIPAddresses*') {
 
            $ipcfg = $nic = $vmid = $usingresid = $null
            if ($obj.properties.ipConfiguration) {
                If ($obj.properties.ipConfiguration.id -like '*Microsoft.Network/networkInterfaces*') {
                    Write-Output "Checking NIC for $($obj.properties.ipAddress)"
                    
                    $ipcfg = $obj.properties.ipConfiguration.id.split('/')[0..8] -join '/'
                    Write-Output "VMID $($ipcfg)"
                    
                    $nic = $mainReport | where { $_.resourceid -eq $ipcfg }
                    #$nic.name
                    #$nic.virtualMachin
                    # $nic|fl
                    $usingresid = $nic.properties.virtualMachine.id
            
                }else{
                    $usingresid = $obj.properties.ipConfiguration.id.split('/')[0..8] -join '/'
              
                }
            }

            $HA = $null
            if ($($obj.zones -join " ").Length -eq 0) { $HA = "Non-Zonal" }
            if ($($obj.zones -join " ").Length -eq 1) { $HA = "Zonal" }
            if ($($obj.zones -join " ").Length -eq 2) { $HA = "ZoneRedundant" }

            $cu = New-Object PSObject -Property @{ 
                name         = $obj.name -join ','
                reportdate   = $datecolumn  -join ','
                resourceid   = $obj.ResourceId -join ','
                IpConf       = $obj.properties.ipConfiguration.id -join ','
                IPAddress    = $obj.properties.ipAddress -join ','
                IPAllocation = $obj.properties.publicipallocationmethod -join ','
                IpZones      = $($obj.zones -join " ") -join ','
                Redundancy   = $HA -join ','
                UsingResId   = $usingresid
            }
            
            $pipreport += $cu
        }

        #get all tags 

        $obj.tags.PSObject.Properties | ForEach-Object {

            IF ($_.Name -ne $null -and $_.Name -ne 'Name' ) {

                Add-Member -InputObject $obj -Name $_.Name -Value ($_.value).tostring().Trim() -MemberType Noteproperty -Force -ErrorAction SilentlyContinue
            }
            IF ($_.Name -eq 'Name' ) {

                Add-Member -InputObject $obj -Name "Tag_$($_.Name)" -Value ($_.value).tostring().Trim() -MemberType Noteproperty -Force -ErrorAction SilentlyContinue

            }

        }

        Add-Member -InputObject $obj -Name CreationTime -Value $obj.properties.creationTime -MemberType Noteproperty -Force
    } 


    $reslist = $mainReport | Select-Object Resourcetype -Unique
  

IF ($mainReport) {
    foreach ($rtype in $reslist ) {
        $report = @()

        $Report = $mainReport | where { $_.Resourcetype -eq $rtype.ResourceType }

      #  Foreach ($obj in $list) {
       #     $report += $obj
       # }


           $helperSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $allProps =$null
        $allProps = foreach ($obj in $report) { 
            foreach ($prop in $obj.psobject.Properties.Name) {
                if ($helperSet.Add($prop)) { $prop.TOLOWER() }
            }
        }
		

        New-Variable -Name $rtype.ResourceType -Value $($Report | Select-Object -Property $allProps) -Force
		
		#memory exception
     
    }
}Else{
    Write-Output "No data collected !!!! Check if you have reader permission on the Azure Subscriptions"
    Write-Output "Subscription list"
    Get-AzSubscription
}



### Add backup and ASR info to collected data 


Write-Output "Collecting Backup and ASR Data"
$asrbackup | ForEach-Object {
    $b = $_
    $t = $null
    if ($b.ProtectionType -eq 'Backup') {
        
        $t = $mainReport | where { $_.resourceid -eq $b.sourceResourceId }
        if ($t) {
            Add-Member -InputObject $t -Name BackupEnabled -Value $true -MemberType Noteproperty -Force 
            Add-Member -InputObject $t -Name LastBackup -Value "$($b.lastBackupStatus) - $($b.lastBackupTime.tostring("yyyy-MM-ddThh:mm")) " -MemberType Noteproperty -Force 
        }
        
    }Else{
        $t = $null
        $t = $mainReport | where { $_.resourceid -eq $b.sourceResourceId }

        If ($t) {
            Add-Member -InputObject $t -Name ASREnabled -Value "Enabled" -MemberType Noteproperty -Force 
            Add-Member -InputObject $t -Name ASRConfig -Value "$($_.primaryFabricLocation)-to-$($_.recoveryFabricLocation)" -MemberType Noteproperty -Force 
        }
       
   
    }
           
}


$allProps = @('id', 'name', 'type','ReportDate', 'tenantId', 'kind', 'location', 'resourceGroup', 'subscriptionId', 'managedBy', 'sku', 'plan', 'tags', 'identity', 'zones', 'extendedLocation', 'vmId', 'asrId', 'ResourceId', 'Backup', 'replicationHealth', 'failoverHealth', 'protectionStateDescription', 'isReplicationAgentUpdateRequired', 'ProtectionType', 'currentProtectionState', 'protectedPrimaryRegion', 'sourceResourceId', 'lastBackupStatus', 'lastBackupTime', 'protectedItemType', 'backupManagementType', 'resourceName', 'primaryfabriclocation', 'recoveryfabriclocation', 'primaryfabricprovider', 'activelocation')


If ($asrbackup)
{
    $asrbackup | Select-Object -Property $allProps  | Export-Csv "$($folder.FullName)\asr_backup.csv" -NoTypeInformation -Append -Encoding utf8 
}elseif(-not (test-path  -Path "$($folder.FullName)\asr_backup.csv") ){
    ($allProps -join ',') | Out-File "$($folder.FullName)\asr_backup.csv"  -Encoding utf8 -Force
}



$allProps=$null

Write-Output "Exporting Zone mapping and PIPs"
Write-Output "`n`r"



$lbReportSchema = @('name', 'ReportDate', 'resourceid', 'FEName', 'FEIpConf', 'FEIpZones')

$pipReportSchema = @('name', 'reportdate', 'resourceid', 'IpConf', 'IPAddress', 'IPAllocation', 'IpZones', 'Redundancy', 'UsingResId')

$zoneMappingSchema = @('Subscription', 'Subscriptionid', 'ReportDate', 'location', 'availabilityzone', 'physicalzone')

If ($lbreport )
{
    $lbreport | Export-Csv "$($folder.FullName)\lbReport.csv" -NoTypeInformation -Append -Encoding utf8 
}elseif(-not (test-path  -Path "$($folder.FullName)\lbReport.csv") ){
    ($lbReportSchema  -join ',') | Out-File "$($folder.FullName)\lbReport.csv"  -Encoding utf8 -Force
}


If ($pipreport)
{
    $pipreport | Export-Csv "$($folder.FullName)\pipReport.csv" -NoTypeInformation -Append -Encoding utf8 
}elseif(-not (test-path  -Path "$($folder.FullName)\pipReport.csv") ){
    ($pipReportSchema -join ',') | Out-File "$($folder.FullName)\pipReport.csv"  -Encoding utf8 -Force
}

If ($zonemapping)
{
    $zonemapping| Export-Csv "$($folder.FullName)\zonemapping.csv" -NoTypeInformation -Append -Encoding utf8
}elseif(-not (test-path  -Path "$($folder.FullName)\zonemapping.csv") ){
    ($zoneMappingSchema -join ',') | Out-File "$($folder.FullName)\zonemapping.csv"  -Encoding utf8 -Force
}



 



Write-Output "Start processing exported data"
Write-Output "`n`r"


$reportlist = $reslist
$baseProps = @('name', 'location', 'kind', 'resourceGroup', 'subscriptionId', 'subscription','ReportDate', 'ResourceId' , 'ResourceSubType', 'provisioningState', 'CreationTime', 'sku', 'zones', 'BackupEnabled', 'LastBackup','properties')
$processed = @()
#first load , storage , disks, Public Ips to resolve dependencies 


#########NEW   Process

    # ═══════════════════════════════════════════════════════
    # RULE-BASED RESILIENCY ANALYSIS (replaces all per-type blocks)
    # ═══════════════════════════════════════════════════════

    Write-Output "Running resiliency rules engine on $($mainReport.Count) resources"

    $engineResult = Invoke-ResiliencyRules `
        -AllResources $mainReport `
        -Rules $ResiliencyRules `
        -BaseProps $baseProps `
        -CustomerTags $customerTags

    $MasterReport = $engineResult.MasterReport

    # Catch-all: handle any resource types not covered by rules
    $MasterReport += Invoke-CatchAllResiliency `
        -AllResources $mainReport `
        -ProcessedSubTypes $engineResult.ProcessedSubTypes `
        -BaseProps $baseProps `
        -CustomerTags $customerTags

    Write-Output "Rule engine complete — $($MasterReport.Count) resources processed"


    ##Filter out resources with no resiliency details 

    $MasterReport=$MasterReport|where{-not [string]::IsNullOrEmpty($_.ResiliencyConfig)}

#######
#Check any other resource provider report s zones information


    #check and enrich asr/backup info 
    $recsvcmapping = Import-Csv "$($folder.FullName)\asr_backup.csv" -ErrorAction SilentlyContinue


    $recsvcmapping | ForEach-Object {
        $b = $_
        $t = $null
        if ($b.ProtectionType -eq 'Backup') {

            $recvaultid = $null
            $recvaultid = $b.ResourceId.Split('/')[0..8] -join '/'
            $vault = $recsvc | where { $_.resourceid -eq $recvaultid }
            $t = $Masterreport | where { $_.resourceid -eq $b.sourceResourceId }

            if ($t) {
                Add-Member -InputObject $t -Name BackupDetails -Value "Enabled -$($b.backup)- CRR:$($vault.crossRegionRestore)- Str:$($vault.standardTierStorageRedundancy) " -MemberType Noteproperty -Force 
                Add-Member -InputObject $t -Name LastBackup -Value "$($b.lastBackupStatus) - $($b.lastBackupTime) ) " -MemberType Noteproperty -Force 
            }
        
        }Else {
            $t = $null
            $t = $Masterreport | where { $_.resourceid -eq $b.sourceResourceId }
            $b.sourceResourceId
            If ($t) {
                Add-Member -InputObject $t -Name ASRDetails -Value "Enabled- RepHealth: ($b.replicationHealth)" -MemberType Noteproperty -Force 
                Add-Member -InputObject $t -Name ASRConfig -Value "$($_.primaryFabricLocation)-to-$($_.recoveryFabricLocation)" -MemberType Noteproperty -Force 
            }  
        }
    }



    $filterProps =$Null
    $filterProps = @('name', 'location','reportdate','resourceGroup', 'subscriptionId', 'subscription', 'ResourceId' , 'ResourceSubType', 'sku', 'kind', 'zones', 'ResiliencyConfig', 'ResiliencyDetail', 'PublicIP', 'PublicIPZones', 'backupdetails', 'lastbackup', 'ASRDetails', 'ASRConfig', 'skuname', 'skutier', 'customMaintenanceWindow', 'customer_comments','physicalzone','MasterFilter')


    ## Add physical locations to masterreport 

    $MasterReport|foreach{
        $t=$_
        if($t.zones  -eq 1 -or $t.zones  -eq 2 -or $t.zones  -eq 3){
            $z=$null
            $z=$zonemapping|where{$_.subscriptionId -eq $t.subscriptionId -and $_.location -eq $t.location -and $_.availabilityZone -eq $t.zones }
            Add-Member -InputObject $t -Name physicalzone -Value $z.physicalzone -MemberType Noteproperty -Force 

        }Elseif($t.zones.Length -gt 1)
        {
            $ztemp=@()
            $t.zones.Split()|foreach{
                $t1=$_
                $ztemp+=($zonemapping|where{$_.subscriptionId -eq $t.subscriptionId -and $_.location -eq $t.location -and $_.availabilityZone -eq $t1 }).physicalzone
            }
            Add-Member -InputObject $t -Name physicalzone -Value $($ztemp -join ";") -MemberType Noteproperty -Force 
        }

        #check if its a no AZ region
        IF($t.zones.Length -eq 0)
        {
            $z=$null
            $z=$zonemapping|where{$_.subscriptionId -eq $t.subscriptionId -and $_.location -eq $t.location -and $_.availabilityzone -eq "NoAZRegion"}
            If($z)
            {
                Add-Member -InputObject $t -Name physicalzone -Value $z.name -MemberType Noteproperty -Force 
                Add-Member -InputObject $t -Name zones -Value "NoAZRegion" -MemberType Noteproperty -Force 
            }
        

        }


    }

 ##### Check Sub id and name mapping and caomplete if any missing


    $MasterReport|foreach{
        $t=$_
    
    
        if($t.Subscription -eq $t.subscriptionId){
            Write-Output "Sub guid found $($t.Subscription))"

            $t1=$MasterReport| where{$_.subscriptionId -eq $t.subscription -and $_.Subscription -ne $_.subscriptionId}   
            Add-Member -InputObject $t -Name Subscription -Value $t1[0].Subscription -MemberType Noteproperty -Force 

        }

        $customerTags|Foreach{
		    $t1=$_
		    if ($null -eq ($t.psobject.properties|where {$_.name -eq $t1}).value) {
			    $t.${t1}="N/A"
		    }

            $f=$null
            $f="$($t.Subscription), $($t.resourceGroup)"

            $customerTags|Foreach{
            $t2=$_
                $f+=", $($t.${t2})"
            }

            Add-Member -InputObject $t -Name MasterFilter -Value $f -MemberType Noteproperty -Force 
	
	    }


    }




    # ADD Appgw, Cont reg ZR override  for regions with AZ
    #filter and remove all
    # add cdn profiles georedundant Microsoft.Cdn/Profiles


    $dt = (Get-Date).ToString("yyyyMMddhhmm")

    $MasterReport|Group-Object -Property Subscription

    if( $Masterreport){

        $Masterreport | Select-Object -Property $($filterProps + $customerTags) |     Export-Csv "$($folder.FullName)\MasterReport.csv" -NoTypeInformation -Encoding utf8  -Append 
    }elseif(-not (test-path  -Path "$($folder.FullName)\MasterReport.csv") ){
    ($($filterProps + $customerTags) -join ',') | Out-File "$($folder.FullName)\MasterReport.csv"  -Encoding utf8 -Force
    }

		remove-variable MasterReport -force -ErrorAction SilentlyContinue
		
	
	}
	
	



    }


#Endforsub
}


#region Retirements

Invoke-WebRequest -Uri $RetirementsDownloadUri -OutFile "$($folder.FullName)\Azureretirements.json"

$retirementsMaster = Get-Content "$($folder.FullName)\Azureretirements.json" | ConvertFrom-Json 



#convert all headers to lower case for powerbi 
$file = Get-Content "$($folder.FullName)\MasterReport.csv"
$firstline = $file[0]
$firstlinelower = $firstline.ToLower()
$tfile = $file | select -Skip 1 
@($firstlinelower) + $tfile | Set-Content "$($folder.FullName)\MasterReport.csv"

#finally merge retirements

#replace $customerretirements with $retirements
#$customerRetirements = Import-Csv "$($folder.FullName)\Retirements.csv"

$Retirements | ForEach-Object {
    $t = $_
   
    $r = $null
    $r = $retirementsMaster | where { $_.id -eq $t.Serviceid }
   
    Add-Member -InputObject $_ -Name ServiceName -Value $r.ServiceName -MemberType Noteproperty -Force
    Add-Member -InputObject $_ -Name RetiringFeature -Value $r.RetiringFeature -MemberType Noteproperty -Force
    Add-Member -InputObject $_ -Name RetirementDate -Value $r.RetirementDate -MemberType Noteproperty -Force
    Add-Member -InputObject $_ -Name Link -Value $r.Link -MemberType Noteproperty -Force
    #add date column for report 
    Add-Member -InputObject $_ -Name ReportDate -Value $datecolumn -MemberType Noteproperty -Force

}



If ( $retirements.count -eq 0) {

    "ServiceID,id,resourceGroup,location,ResourceId,ServiceName,RetiringFeature,RetirementDate,Link,ReportDate" |  Out-File "$($folder.FullName)\CustomerAzRetirements.csv" -Force  
}Else{
    $retirements | Export-Csv "$($folder.FullName)\CustomerAzRetirements.csv" -NoTypeInformation -Force -Encoding utf8 
}

#endregion



#compressfolder for easy downloading in case running from  cloud shell 
Compress-Archive  "$($folder.FullName)\*.csv"  "$($folder.FullName).zip" -Force



if($localexport -eq $false)
{

	write-output "Start uploading files to $exportstorageAccount"
    #use powershell to upload files to the storage account specified

    $containerName = "reliabilityassessment"  



    Set-AzContext -Subscription $exportstoragesubid


    $Context = New-AzStorageContext -StorageAccountName $exportstorageAccount -UseConnectedAccount

    If (!(Get-AzStorageContainer -Name $containerName -Context $Context) )
    {

        New-AzStorageContainer -Name $containerName  -Permission Off -Context $Context
    }



    $files=Get-ChildItem -Path $folder.FullName

    Foreach ($file in $files)
    {
        $Blob1HT = @{
            File             = $file.FullName
            Container        = $ContainerName
            Blob             = "$($folder.name)\$($file.name)"
            Context          = $Context
            StandardBlobTier = 'Hot'
        }
        Set-AzStorageBlobContent @Blob1HT -Force 

    }

}
















