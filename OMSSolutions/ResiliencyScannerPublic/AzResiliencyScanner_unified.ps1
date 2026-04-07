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
Rules

#>

$ResiliencyRules = @(

    # ──────────────────────────────────────────────
    # STORAGE
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Storage/storageAccounts'
        ExtraProperties  = @('accessTier', 'skuname', 'skutier')
        ResiliencyLogic  = {
            param($item)
            $skuname = $item.sku.name
            $config = switch -Wildcard ($skuname) {
                '*ZRS'  { 'ZoneRedundant' }
                '*GZRS' { 'GeoZoneRedundant' }
                '*GRS'  { 'GeoRedundant' }
                '*LRS'  { 'LocallyRedundant' }
                default { 'NoInformation' }
            }
            @{
                ResiliencyConfig = $config
                skuname          = $skuname
            }
        }
    }

    # ──────────────────────────────────────────────
    # NETWORKING - Public IPs
    # ──────────────────────────  ───────────────────
    @{
        ResourceSubType  = 'Microsoft.Network/publicIPAddresses'
        ExtraProperties  = @('ipConfiguration', 'publicIPAllocationMethod', 'ipAddress')
        ResiliencyLogic  = {
            param($item)
     $zones=($zonemapping|where{$_.location -eq $item.location})
            $config = if ($item.sku -like '*tier=Global*') { 'Global' }
                      elseif ($item.zones.length -ge 2 -or $zones.count -gt 1) { 'ZoneRedundant' }
                      elseif ($item.zones.length -eq 1) { 'Zonal' }
                      else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }

    # ──────────────────────────────────────────────
    # NETWORKING - Load Balancers
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Network/loadBalancers'
        ExtraProperties  = @('frontendIPConfigurations', 'backendAddressPools')
        ResiliencyLogic  = {
            param($item)
            # Global LB override
            if ($item.sku -like '*Global*') {
                return @{
                    ResiliencyConfig = 'Global'
                    Kind             = 'Public-Global'
                }
            }

            $fe = $item.properties.frontendipconfigurations
            $kind = if ($fe[0].properties.psobject.Properties.name -contains 'privateIPAddress') { 'Internal' } else { 'Public' }

            $allZones = @()
            foreach ($fip in $fe) { $allZones += $fip.zones }
            $allZones = $allZones | Sort-Object -Unique

            $config = if ($allZones.count -gt 1) { 'ZoneRedundant' }
                      elseif ($allZones.count -eq 1) { 'Zonal' }
                      else { 'NonZonal' }

            @{
                ResiliencyConfig = $config
                Kind             = $kind
            }
        }
    }

    # ──────────────────────────────────────────────
    # NETWORKING - Azure Firewall
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Network/azureFirewalls'
        ExtraProperties  = @('ipconfigurations', 'publicIPAddress')
        ResiliencyLogic  = {
            param($item)
         $zones=($zonemapping|where{$_.location -eq $item.location})
  
            $config = if ($item.zones.length -gt 1  -or $zones.count -gt 1) { 'ZoneRedundant' }
                      elseif ($item.zones.length -eq 1) { 'Zonal' }
                      else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }

    # ─────────────   ────────────────────────────────
    # NETWORKING - Application Gateway
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Network/applicationGateways'
        ExtraProperties  = @('backendAddressPools', 'autoscaleConfigurationminCapacity', 'autoscaleConfigurationmaxCapacity')
        ResiliencyLogic  = {
            param($item)
            $zones=($zonemapping|where{$_.location -eq $item.location})
            $config = if ($item.zones.length -ge 2 -or $zones.count -gt 1) { 'ZoneRedundant' }
                      elseif ($item.zones.length -eq 1) { 'Zonal' }
                      else { 'NonZonal' }
            $backendCount = ($item.properties.backendAddressPools)[0].properties.backendIPConfigurations.id.count
            @{
                ResiliencyConfig     = $config
                BackendPoolNodeCount = $backendCount
            }
        }
    }

    # ──────────────────────────────────────────────
    # NETWORKING - VNet Gateway - FIX and Validate
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Network/virtualNetworkGateways'
        ExtraProperties  = @('ipConfigurations')
        ResiliencyLogic  = {
            param($item)
            $sku = $item.properties.sku.name
            $config = if ($sku -like '*AZ*') { 'ZoneRedundant' }
                      elseif ($sku -eq 'Basic' -or $sku -match 'Gw[1-9]') { 'LocallyRedundant' }
                      else { 'NonZonal' }
            $kind = if ($sku -like '*ErGw*') { 'ER' } else { 'VPN' }
            @{
                ResiliencyConfig = $config
                Kind             = $kind
            }
        }
    }

    # ──────────────────────────────────────────────
    # NETWORKING - NAT Gateway 
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Network/natGateways'
        ExtraProperties  = @()
        ResiliencyLogic  = {
            param($item)
                     $config = if ($item.zones.length -gt 1) { 'ZoneRedundant' }
                      elseif ($item.zones.length -eq 1) { 'Zonal' }
                      else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }

    # ──────────────────────────────────────────────
    # NETWORKING - Bastion
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Network/bastionHosts'
        ExtraProperties  = @()
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.zones.length -gt 1) { 'ZoneRedundant' }
                      elseif ($item.zones.length -eq 1) { 'Zonal' }
                      else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }

    # ──────────────────────────────────────────────
    # NETWORKING - Redundant by Default (batch rule)
    # ──────────────────────────────────────────────
    @{
        ResourceSubType    = 'Microsoft.Network/dnsZones'
        DefaultResiliency  = 'RedundantbyDefault'
    }
    @{
        ResourceSubType    = 'Microsoft.Network/dnsResolvers'
        DefaultResiliency  = 'RedundantbyDefault'
    }
    @{
        ResourceSubType    = 'Microsoft.Network/virtualNetworks'
        DefaultResiliency  = 'RedundantbyDefault'
    }
    @{
        ResourceSubType    = 'Microsoft.Network/routeTables'
        DefaultResiliency  = 'RedundantbyDefault'
    }
    @{
        ResourceSubType    = 'Microsoft.Network/virtualWans'
        DefaultResiliency  = 'RedundantbyDefault'
    }
    @{
        ResourceSubType    = 'Microsoft.Network/privateLinkServices'
        DefaultResiliency  = 'RedundantbyDefault'
    }
    @{
        ResourceSubType    = 'Microsoft.Network/privateEndpoints'
        DefaultResiliency  = 'RedundantbyDefault'
    }
    @{
        ResourceSubType    = 'Microsoft.Network/networkWatchers'
        DefaultResiliency  = 'RedundantbyDefault'
    }
    @{
        ResourceSubType    = 'Microsoft.Network/virtualRouters'
        DefaultResiliency  = 'RedundantbyDefault'
    }
    @{
        ResourceSubType    = 'Microsoft.Network/ddosProtectionPlans'
        DefaultResiliency  = 'RedundantbyDefault'
    }
    @{
        ResourceSubType    = 'Microsoft.Network/expressRouteCircuits'
        DefaultResiliency  = 'RedundantbyDefault'
    }
    @{
        ResourceSubType    = 'Microsoft.Network/expressRoutePorts'
        DefaultResiliency  = 'RedundantbyDefault'
    }

    # ──────────────────────────────────────────────
    # COMPUTE - Virtual Machines
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Compute/virtualMachines'
        ExtraProperties  = @('VMsize', 'OSDiskName', 'OSDiskId', 'networkprofile', 'ASREnabled', 'ASRConfig', 'availabilityset')
        SkipExtensions   = $true   # filter out /extensions/ sub-resources
        ResiliencyLogic  = {
            param($item)
            $osDiskSku = $item.properties.storageProfile.osDisk.managedDisk.storageAccountType
            $vmz = if ($item.zones -gt 0) { 'Zonal' } else { 'NonZonal' }

            $storageHA = switch -Wildcard ($osDiskSku) {
                '*ZRS'  { 'ZoneRedundant' }
                '*LRS'  { 'LocallyRedundant' }
                default { 'NoInformation' }
            }

            $config = if ($storageHA -eq 'ZoneRedundant') { 'ZoneRedundant' } else { $vmz }

            @{
                ResiliencyConfig  = $config
                ResiliencyDetail  = "$vmz with $storageHA disks"
                StorageResiliency = $storageHA
                OsDiskSku         = if ($osDiskSku) { $osDiskSku } else { 'VHD-Unmanaged' }
                DataDiskCount     = $item.properties.storageProfile.dataDisks.Count
            }
        }
    }

    # ──────────────────────────────────────────────
    # COMPUTE - Disks
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Compute/disks'
        ExtraProperties  = @('Disksku', 'Disktier', 'diskMBpsReadWrite', 'diskIOPSReadWrite')
        ResiliencyLogic  = {
            param($item)
            $config = switch -Wildcard ($item.sku.name) {
                '*ZRS'  { 'ZoneRedundant' }
                '*LRS'  { 'LocallyRedundant' }
                default { 'NoInformation' }
            }
            @{ ResiliencyConfig = $config }
        }
    }

    # ──────────────────────────────────────────────
    # COMPUTE - VMSS
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Compute/virtualMachineScaleSets'
        ExtraProperties  = @('orchestrationMode', 'zoneBalance')
        SkipExtensions   = $true
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.zones.length -gt 1) { 'ZoneRedundant' }
                      elseif ($item.zones.length -eq 1) { 'Zonal' }
                      else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }


    # ──────────────────────────────────────────────
    # SQL - Server
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Sql/servers'
        MatchFilter      = { $_.Resourceid -notlike '*/databases/*'}

        ResiliencyLogic  = {
            param($item,$reslist,$sqlfgreport)
					   
		$splt=$item.ResourceId.split('/')
		#check if its part of failover group
		$fg=$null
		$fg=$sqlfgreport |where{$_.ResourceGroupName -eq $splt[4] -and $_.servername -eq $splt[8] }
            $config = if ($fg -and ($fg.location -ne $fg.PartnerLocation)) { 'GeoReplica' }elseif($fg) { 'SameRegionFG' }Else{'NoFailoverGroup'}
            @{
                ResiliencyConfig  = $config
		ZonalResiliency="Notapplicable"
		GeoResiliency=$config
                ResourceSubType   = 'Microsoft.Sql/servers'
                BackupDetails     = $item.properties.currentBackupStorageRedundancy
                SecondaryLocation = $item.properties.defaultSecondaryLocation
                PreferedAZ        = $item.properties.availabilityZone
                GR_Detail  = "FailoverGroup: $($fg.PartnerLocation) , Server : $($fg.PartnerServerName), RepState=$($fg.ReplicationState)"
            }
        }
    }


    # ──────────────────────────────────────────────
    # SQL - Databases
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Sql/servers'
        MatchFilter      = { $_.Resourceid -like '*/databases/*' -and $_.Resourceid -notlike '*/databases/master' }
        ExtraProperties  = @('requestedBackupStorageRedundancy', 'currentBackupStorageRedundancy', 'currentSku', 'defaultSecondaryLocation', 'zoneRedundant', 'availabilityZone', 'secondaryType')
        ResiliencyLogic  = {
            param($item,$reslist,$sqlfgreport)
		$splt=$item.ResourceId.split('/')
		$fg=$null
		$fg=$sqlfgreport |where{$_.ResourceGroupName -eq $splt[4] -and $_.servername -eq $splt[8] }
            $zrconfig = if ($item.properties.zoneRedundant -eq $true) { 'ZoneRedundant' } else { 'NonZonal' }
	    $grconfig = if ($fg -and ($fg.location -ne $fg.PartnerLocation)) { 'GeoReplica' }elseif($fg) { 'SameRegionFG' }Else{'NoFailoverGroup'}
            @{
                ResiliencyConfig  = $zrconfig
		ZonalResiliency=$zrconfig
		GeoResiliency=$grconfig
                ResourceSubType   = 'Microsoft.Sql/databases'
                BackupDetails     = $item.properties.currentBackupStorageRedundancy
                SecondaryLocation = $item.properties.defaultSecondaryLocation
                PreferedAZ        = $item.properties.availabilityZone
                ZR_Detail  = "ZoneRedundant:$($item.properties.zoneredundant), PreferedAZ: $($item.properties.availabilityzone)"
		GR_DEtail ="FailoverGroup: $($fg.PartnerLocation) , Server : $($fg.PartnerServerName), RepState=$($fg.ReplicationState)"
            }
        }
    }

    # ──────────────────────────────────────────────
    # SQL - Managed Instances
    # ────────────────────────────────────────   ─────
    @{
        ResourceSubType  = 'Microsoft.Sql/managedInstances'
 	MatchFilter      = { $_.Resourceid -like '*/Microsoft.Sql/managedInstances*' -and $_.Resourceid -notlike '*/databases/*'}
        ExtraProperties  = @('maintenanceConfigurationId', 'zoneRedundant', 'requestedBackupStorageRedundancy')
        ResiliencyLogic  = {
           param($item,$reslist,$sqlfgreport)
            # Skip databases (sub-resources)
            if ($item.ResourceId -like '*/databases/*') {
              #  return @{ _skip = $true }
            }
	
		$splt=$item.ResourceId.split('/')
		$fg=$null
		$fg=$sqlfgreport |where{$_.ResourceGroupName -eq $splt[4] -and $_.servername -eq $splt[8] }
	 	   $grconfig = if ($fg -and ($fg.location -ne $fg.PartnerLocation)) { 'GeoReplica' }elseif($fg) { 'SameRegionFG' }Else{'NoFailoverGroup'}
          	  $zrconfig = if ($item.properties.zoneRedundant -eq $true) { 'ZoneRedundant' } else { 'NonZonal' }

            @{
                ResiliencyConfig = $zrconfig
                BackupDetails    = "Storage : $($item.properties.requestedBackupStorageRedundancy)"
                Maintenance      = $item.properties.maintenanceConfigurationId
		ZonalResiliency=$zrconfig
		GeoResiliency=$grconfig
                ResourceSubType   = 'Microsoft.Sql/managedInstances'
                SecondaryLocation = $item.properties.defaultSecondaryLocation
                PreferedAZ        = $item.properties.availabilityZone
		GR_DEtail ="FailoverGroup: $($fg.PartnerLocation) , Server : $($fg.PartnerServerName), RepState=$($fg.ReplicationState)"
            }





        }
    }

    # ──────────────────────────────────────────────
    # SQL - Managed Instances DBS
    # ────────────────────────────────────────   ─────
    @{
        ResourceSubType  = 'Microsoft.Sql/managedInstances'
        ExtraProperties  = @('maintenanceConfigurationId', 'zoneRedundant', 'requestedBackupStorageRedundancy')
        ResiliencyLogic  = {
            param($item)
            # Skip databases (sub-resources)

	$failoverGrp=$mainReport| where {$_.ResourceId -like  '*/instanceFailoverGroups/*'}
	#Write-output $failovergrp
	Break
            if ($item.ResourceId -like '*/databases/*') {
                
            
            $config = if ($item.properties.zoneRedundant -eq $true) { 'ZoneRedundant' } else { 'NonZonal' }
            @{
                ResiliencyConfig = $config
                BackupDetails    = "Storage : $($item.properties.requestedBackupStorageRedundancy)"
                Maintenance      = $item.properties.maintenanceConfigurationId
            }
	}
        }
    }

    # ──────────────────────────────────────────────
    # COSMOS DB
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.DocumentDb/databaseAccounts'
   MatchFilter      = { $_.kind   -eq "GlobalDocumentDB"}
        ExtraProperties  = @('enableMultipleWriteLocations', 'enableAutomaticFailover', 'consistencyPolicy', 'locations', 'writeLocations')


        ResiliencyLogic  = {
            param($item)
		$pri= $item.properties.writeLocations.locationName

        
  		$loc = $item.properties.locations
            $locationNames = ($loc).locationname -join ", "
            $zrCheck = IF(($loc  | where{$_.locationName -eq $pri}).isZoneRedundant -eq $true){"ZoneRedundant"}else{"NonZonal"}

            $grconfig = if ($loc.count -gt 1) { 'GeoReplica' }
		$grdetails=($loc  | where{$_.locationName -ne $pri}).locationname -join ", "
                   

            @{
     
                locations        = $locationNames
                ResiliencyConfig  = $zrCheck
                ResiliencyDetail = $zrCheck
		ZonalResiliency=$zrCheck
		GeoResiliency=$grconfig
		GR_Details=$grdetails
            }
        }
    }

    @{
        ResourceSubType  = 'Microsoft.DocumentDB/mongoclusters'
        ExtraProperties  = @('nodeGroupSpecs')
        ResiliencyLogic  = {
             param($item,$reslist,$fglist)
            $zrconfig = if ($item.properties.replica.role -eq 'GeoAyncReplica') { 'MultiRegion' }elseif(($item.properties.nodeGroupSpecs).enableHA -eq $true) { 'ZoneRedundant' } else { 'LocallyRedundant' }
       


			$list=$reslist|where {$_.ResourceSubType  -eq 'Microsoft.DocumentDB/mongoclusters'}
			
			$replica=($list| where{$_.properties.sourceServerResourceId -eq $item.resourceid})[0]
			if($replica){
			IF($replica.location -ne $item.location){$grconfig='GeoReplica'}
			$grdetails="$($replica.location),  Srv:  $($replica.name) , ReplicaHA: $($replica.properties.replicationRole) with HA $($replica.properties.highAvailability.mode)"
			}
	



            @{
                ResiliencyConfig       = $zrconfig
                ResiliencyDetail       = $item.properties.highAvailability
		ZonalResiliency=$zrconfig
		GeoResiliency=$grconfig
		GR_Details=$grdetails
                BackupDetails          = $backupDetail
                customMaintenanceWindow = ($item.properties.maintenanceWindow).customWindow
                backupRetentionDays    = ($item.properties.backup).backupRetentionDays
                geoRedundantBackup     = $backupGeo
                backupIntervalHours    = ($item.properties.backup).backupIntervalHours
            }



        
    }
}


    # ──────────────────────────────────────────────
    # POSTGRESQL - Flexible Server
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.DBforPostgreSQL/flexibleServers'
        ExtraProperties  = @('highAvailability', 'replicationRole', 'HAState', 'HAMode', 'maintenanceWindow', 'backup', 'backupredundancy')
        ResiliencyLogic  = {
              param($item,$reslist,$fglist)
            $haMode = if ($item.properties.highAvailability.mode) { $item.properties.highAvailability.mode } else { $item.properties.HAMode }

            $config = switch ($haMode) {
                { $_ -eq 'Disabled' }       { 'NonZonal' }
                { $_ -eq 'SameZone' }       { 'SameZoneHA' }
                { $_ -in @('ZoneRedundant','Enabled') } { 'ZoneRedundant' }
                default                     { 'NonZonal' }
            }

            $backupGeo = ($item.properties.backup).geoRedundantBackup
            $backupDetail = switch ($backupGeo) {
                'Enabled'  { 'GeoRedundant' }
                'Disabled' { 'LocallyRedundant' }
                default    { $null }
            }

			$list=$reslist|where {$_.ResourceSubType  -eq 'Microsoft.DBforPostgreSQL/flexibleServers'}
			
			$replica=($list| where{$_.properties.sourceServerResourceId -eq $item.resourceid})[0]
			if($replica){
			IF($replica.location -ne $item.location){$grconfig='GeoReplica'}
			$grdetails="$($replica.location),  Srv:  $($replica.name) , ReplicaHA: $($replica.properties.replicationRole) with HA $($replica.properties.highAvailability.mode)"
			}
	



            @{
                ResiliencyConfig       = $config
                ResiliencyDetail       = $item.properties.highAvailability
		ZonalResiliency=$config
		GeoResiliency=$grconfig
		GR_Details=$grdetails
                BackupDetails          = $backupDetail
                customMaintenanceWindow = ($item.properties.maintenanceWindow).customWindow
                backupRetentionDays    = ($item.properties.backup).backupRetentionDays
                geoRedundantBackup     = $backupGeo
                backupIntervalHours    = ($item.properties.backup).backupIntervalHours
            }
        }
    }

    # ──────────────────────────────────────────────
    # POSTGRESQL - Single Server (retiring)
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.DBforPostgreSQL/servers'
        ExtraProperties  = @('storageProfile', 'highAvailability')
        ResiliencyLogic  = {
            param($item)
            @{
                ResiliencyConfig = 'NonZonal'
                ResiliencyDetail = 'No Az Support for SKU'
                BackupDetails    = "GeoRedundant backup : $(($item.properties.storageProfile).geoRedundantBackup), Retention: $(($item.properties.storageProfile).backupRetentionDays) days"
            }
        }
    }

    # ──────────────────────────────────────────────
    # MYSQL - Flexible Server
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.DBforMySQL/flexibleServers'
        ExtraProperties  = @('highAvailability', 'replicationRole', 'sourceserverresourceid', 'HAState', 'HAMode', 'maintenanceWindow', 'backup')
        ResiliencyLogic  = {
            param($item,$reslist,$fglist)
            $haMode = if ($item.properties.highAvailability.mode) { $item.properties.highAvailability.mode } else { $item.properties.HAMode }

            $config = switch ($haMode) {
                { $_ -eq 'Disabled' }       { 'NonZonal' }
                { $_ -eq 'SameZone' }       { 'SameZoneHA' }
                { $_ -in @('ZoneRedundant','Enabled') } { 'ZoneRedundant' }
                default                     { 'NonZonal' }
            }

		#If($Item.properties.replicationRole -eq 'Source')
		#{
			$list=$reslist|where {$_.ResourceSubType  -eq 'Microsoft.DBforMySQL/flexibleServers'}
			$replica=($list| where{$_.properties.sourceServerResourceId -eq $item.resourceid})[0]
			if($replica)
			{
			#$replica|out-file replicalist.txt -append
			IF($replica.location -ne $item.location){$grconfig='GeoReplica'}
			$grdetails="$($replica.location) , Srv:  $($replica.name) , ReplicaHA: $($replica.properties.highAvailability.mode)"
			}

		#}		

		
	

            @{
                ResiliencyConfig        = $config
                ResiliencyDetail        = $item.properties.highAvailability
		ZonalResiliency=$config
		GeoResiliency=$grconfig
		GR_Details=$grdetails
                BackupDetails           = $backupDetail
                customMaintenanceWindow = ($item.properties.maintenanceWindow).customWindow
                backupRetentionDays     = ($item.properties.backup).backupRetentionDays
                geoRedundantBackup      = $backupGeo
                backupIntervalHours     = ($item.properties.backup).backupIntervalHours
            }
        }
    }

    # ──────────────────────────────────────────────
    # MYSQL - Single Server (retiring)
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.DBforMySQL/servers'
        ExtraProperties  = @('storageProfile', 'highAvailability')
        ResiliencyLogic  = {
            param($item)
            @{
                ResiliencyConfig = 'NonZonal'
                ResiliencyDetail = 'No Az Support for SKU'
                BackupDetails    = "GeoRedundant backup : $(($item.properties.storageProfile).geoRedundantBackup), Retention: $(($item.properties.storageProfile).backupRetentionDays) days"
            }
        }
    }

    # ──────────────────────────────────────────────
    # AKS
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.ContainerService/managedClusters'
        ExtraProperties  = @('agentPoolProfiles', 'nodeResourceGroup')
        ResiliencyLogic  = {
            param($item)
            $zonal = 0; $nonzonal = 0; $poolInfo = @()
            foreach ($pool in $item.properties.agentPoolProfiles) {
                $poolInfo += "$($pool.name),$($pool.osType),Zones:$($pool.availabilityZones)"
                if ($pool.availabilityZones.count -gt 0) { $zonal++ } else { $nonzonal++ }
            }
            $config = if ($zonal -gt 0 -and $nonzonal -eq 0) { 'ZoneRedundant' }
                      elseif ($zonal -eq 0) { 'LocallyRedundant' }
                      else { 'PartiallyAzRedundant' }
            @{
                ResiliencyConfig = $config
                ResiliencyDetail = ($poolInfo -join ';')
            }
        }
    }

        # ──────────────────────────────────────────────
    # ACR
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.ContainerRegistry/registries'
            ResiliencyLogic  = {
            param($item)
            $zones=($zonemapping|where{$_.location -eq $item.location})
            $config = if ($zones.count -gt 1) { 'ZoneRedundant' }
                      elseif ($item.zones.length -eq 1) { 'Zonal' }
                      else { 'NonZonal' }
            @{
                ResiliencyConfig = $config
                ResiliencyDetail = ($poolInfo -join ';')
            }
        }
    }


    # ──────────────────────────────────────────────
    # REDIS CACHE
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Cache/Redis'
        ExtraProperties  = @('zonalconfiguration')
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.properties.sku.name -eq 'Basic') { 'NonZonal' }
                      elseif ($item.properties.zonalAllocationPolicy -eq 'Automatic') { 'ZoneRedundant' }
                      elseif ($item.properties.zonalAllocationPolicy -eq 'NoZones') { 'NonZonal' }
                      else { 'NoInformation' }
            @{ ResiliencyConfig = $config }
        }
    }

    @{
        ResourceSubType  = 'Microsoft.Cache/redisEnterprise'
        ExtraProperties  = @()
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.zones.length -ge 2) { 'ZoneRedundant' }
                      elseif ($item.zones.length -eq 1) { 'Zonal' }
                      else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }

    # ──────────────────────────────────────────────
    # APP SERVICE - Server Farms
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Web/serverFarms'
        ExtraProperties  = @('zoneRedundant', 'numberOfWorkers', 'elasticScaleEnabled')
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.properties.zoneRedundant -eq $true) { 'ZoneRedundant' } else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }

    # ──────────────────────────────────────────────
    # SERVICE BUS
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Servicebus/namespaces'
        ExtraProperties  = @('zoneRedundant', 'status')
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.properties.zoneRedundant -eq $true) { 'ZoneRedundant' } else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }

    # ──────────────────────────────────────────────
    # EVENT HUB
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.EventHub/namespaces'
        ExtraProperties  = @('zoneRedundant')
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.properties.zoneRedundant -eq $true) { 'ZoneRedundant' } else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }

    # ──────────────────────────────────────────────
    # EVENT GRID
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.EventGrid/namespaces'
        ExtraProperties  = @('isZoneRedundant')
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.properties.isZoneRedundant -eq $true) { 'ZoneRedundant' } else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }
    @{
        ResourceSubType   = 'Microsoft.EventGrid/systemTopics'
        DefaultResiliency = 'RedundantbyDefault'
    }
    @{
        ResourceSubType   = 'Microsoft.EventGrid/Topics'
        DefaultResiliency = 'RedundantbyDefault'
    }

    # ──────────────────────────────────────────────
    # RECOVERY SERVICES
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.RecoveryServices/vaults'
        ExtraProperties  = @('standardTierStorageRedundancy', 'crossRegionRestore', 'crossSubscriptionRestoreSettings')
        ResiliencyLogic  = {
            param($item)
            @{
                ResiliencyConfig = $item.properties.redundancySettings.standardTierStorageRedundancy
                ResiliencyDetail = "crossRegionRestore: $($item.properties.redundancySettings.crossRegionRestore)"
            }
        }
    }

    # ──────────────────────────────────────────────
    # KEY VAULT
    # ──────────────────────────────────────────────
    @{
        ResourceSubType   = 'Microsoft.KeyVault/vaults'
        DefaultResiliency = 'RedundantbyDefault'
    }

    # ──────────────────────────────────────────────
    # API MANAGEMENT
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.ApiManagement/service'
        ExtraProperties  = @('outboundPublicIPAddresses', 'additionalLocations', 'gatewayRegionalUrl', 'privateIPAddresses', 'platformVersion', 'natGatewayState')
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.sku.capacity -gt 1) { 'ZoneRedundant' } else { 'Zonal' }
            @{ ResiliencyConfig = $config }
        }
    }

    # ──────────────────────────────────────────────
    # SEARCH
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.Search/searchServices'
        ExtraProperties  = @('replicaCount', 'partitionCount')
        ResiliencyLogic  = {
            param($item)
            $replicas = $item.properties.replicaCount
            $config = if ($replicas -gt 1) { 'ZoneRedundant' }
                      elseif ($replicas -eq 1) { 'Zonal' }
                      else { 'NoInformation' }
            @{
                ResiliencyConfig = $config
                ResiliencyDetail = "Replicas: $replicas"
            }
        }
    }

    # ──────────────────────────────────────────────
    # SIGNALR / WEB PUBSUB
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.SignalRService/signalR'
        ExtraProperties  = @()
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.sku.tier -eq 'Premium' -or $item.sku -like '*Premium*') { 'ZoneRedundant' } else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }
    @{
        ResourceSubType  = 'Microsoft.SignalRService/WebPubSub'
        ExtraProperties  = @()
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.sku.tier -eq 'Premium' -or $item.sku -like '*Premium*') { 'ZoneRedundant' } else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }

    # ──────────────────────────────────────────────
    # LOG ANALYTICS
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.OperationalInsights/workspaces'
        ExtraProperties  = @('availability')
        ResiliencyLogic  = {
            param($item)
            $azRegions = @('canadacentral','southcentralus','westus3','australiaeast','centralindia','southeastasia','francecentral','italynorth','northeurope','norwayeast','spaincentral','swedencentral','uksouth','israelcentral','uaenorth')
            $detail = if ($item.location -in $azRegions) { 'ZonalRedundantRegion' } else { 'LocalRedundantRegion' }
            @{
                ResiliencyConfig = 'RedundantbyDefault'
                ResiliencyDetail = $detail
            }
        }
    }

    @{
        ResourceSubType  = 'Microsoft.OperationalInsights/clusters'
        ExtraProperties  = @('isAvailabilityZonesEnabled')
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.properties.isAvailabilityZonesEnabled -eq $true) { 'ZoneRedundant' } else { 'LocallyRedundant' }
            @{ ResiliencyConfig = $config }
        }
    }

    # ──────────────────────────────────────────────
    # CONTAINER APPS
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.App/managedEnvironments'
        ExtraProperties  = @('zoneredundant')
        ResiliencyLogic  = {
            param($item)
            $config = if ($item.properties.zoneredundant -eq $true) { 'ZoneRedundant' } else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }

    # ──────────────────────────────────────────────
    # AVS
    # ──────────────────────────────────────────────
    @{
        ResourceSubType  = 'Microsoft.AVS/privateClouds'
        ExtraProperties  = @('availability')
        ResiliencyLogic  = {
            param($item)
            $avail = $item.properties.availability
            $config = if ($avail.secondaryZone) { 'ZoneRedundant' } else { 'Zonal' }
            @{
                ResiliencyConfig = $config
                ResiliencyDetail = if ($avail.secondaryZone) { "SecondaryZone: $($avail.secondaryZone)" } else { $null }
                HAStrategy       = $avail.strategy
                PrimaryZone      = $avail.zone
            }
        }
    }

    # ──────────────────────────────────────────────
    # SIMPLE DEFAULTS (services that are always redundant)
    # ──────────────────────────────────────────────
    @{ ResourceSubType = 'Microsoft.Databricks/workspaces';          DefaultResiliency = 'RedundantbyDefault' }
    #@{ ResourceSubType = 'Microsoft.ContainerRegistry/registries';   DefaultResiliency = 'RedundantbyDefault' }
    @{ ResourceSubType = 'Microsoft.Logic/workflows';                DefaultResiliency = 'RedundantbyDefault' }
    @{ ResourceSubType = 'Microsoft.StreamAnalytics/streamingjobs';  DefaultResiliency = 'RedundantbyDefault' }
    @{ ResourceSubType = 'Microsoft.Automation/automationAccounts';  DefaultResiliency = 'RedundantbyDefault' }
    @{ ResourceSubType = 'Microsoft.NotificationHubs/namespaces';    DefaultResiliency = 'RedundantbyDefault' }
    @{ ResourceSubType = 'Microsoft.DataFactory/factories';          DefaultResiliency = 'GeoRedundantbyDefault' }
    @{ ResourceSubType = 'Microsoft.Kusto/clusters';                 ExtraProperties = @()
        ResiliencyLogic = {
            param($item)
            $config = if ($item.zones.length -ge 2) { 'ZoneRedundant' }
                      elseif ($item.zones.length -eq 1) { 'Zonal' }
                      else { 'NonZonal' }
            @{ ResiliencyConfig = $config }
        }
    }
)



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

        [array]$CustomerTags = @(),
	[array]$sqlfgreport = @()


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
                    $result = & $rule.ResiliencyLogic $item $AllResources $sqlfgreport
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
#$sublist = $sublist | Where-Object { $_.name -notlike '*DEV*' -and $_.name -notlike '*UAT*' -and $_.name -notlike '*POC*' }

#Write-Output "$(($sublist | Where-Object { $_.state -eq 'Enabled' }).count) subscriptions found (DEV/UAT/POC removed)"

$jobs = @()

$dt = (Get-Date).ToString("yyyyMMddhhmm")
$datecolumn = (Get-Date).ToString("yyyy-MM-dd")

Write-Output "$dt - Scanning subscriptions!"


$mainReport = @()
$lbreport = @()
$pipreport = @()
$zonemapping=@()
$asrbackup = @()
$sqlfgreport=@()
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

    ## Add sql Failover groups 
    $server=$null
     $servers = Get-AzSqlServer

    foreach ($server in $servers) {
        $groups = Get-AzSqlDatabaseFailoverGroup    -ResourceGroupName $server.ResourceGroupName             -ServerName $server.ServerName
         $sqlfgreport+=$groups
       
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

# Same add SQL Failover Groups Data 
$sqlfgreport|ForEach-Object {
    $b = $_
    $t = $null
    $t = $mainReport | where { $_.resourceid -match $b.servername  -and $_.resourceId -match  $b.resourcegroupname }
    if ($t) {
Write-output "SQL failover group found"
$t

        $detail=$null
        $detail= "$($b.PartnerLocation) - $($b.ReplicationState) - $($b.partnerservername)"
$detail
        Add-Member -InputObject $t -Name ResiliencyDetail -Value $detail  -MemberType Noteproperty -Force 
        if($b.PartnerLocation -ne $b.location){
            Add-Member -InputObject $t -Name GeoResiliency  -Value $b.PartnerLocation  -MemberType Noteproperty -Force 
            Add-Member -InputObject $t -Name ResiliencyDetail  -Value 'GeoRedundant'  -MemberType Noteproperty -Force 
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
        -CustomerTags $customerTags -sqlfgreport $sqlfgreport

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
    $filterProps = @('name', 'location','reportdate','resourceGroup', 'subscriptionId', 'subscription', 'ResourceId' , 'ResourceSubType', 'sku', 'kind', 'zones', 'ResiliencyConfig', 'ResiliencyDetail','ZonalResiliency', 'GeoResiliency','ZR_Details','GR_Details','PublicIP', 'PublicIPZones', 'backupdetails', 'lastbackup', 'ASRDetails', 'ASRConfig', 'skuname', 'skutier', 'customMaintenanceWindow', 'customer_comments','physicalzone','MasterFilter')


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




#####################################################
#######################################################
######################################################


#Endforsub
}


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
















