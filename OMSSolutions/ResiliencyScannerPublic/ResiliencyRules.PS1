# Each rule defines:
#   ResourceSubType    - the Azure resource subtype to match (supports wildcards)
#   ExtraProperties    - additional ARM properties to include as columns
#   ResiliencyLogic    - scriptblock that receives $_ (the resource) and must return a hashtable
#                        with at minimum: @{ ResiliencyConfig = "..." }
#                        Optionally: ResiliencyDetail, BackupDetails, Kind, etc.
#   DefaultResiliency  - (optional) if set, skip the scriptblock and assign this value to all matches

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
