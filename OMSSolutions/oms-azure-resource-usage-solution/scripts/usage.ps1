$allres=@()

Foreach ($subscriptionID  in $Subscriptions.id)
{
$locations=$loclistcontent=$cu=$null

$allvmusage=@()


$loclisturi="https://management.azure.com/"+$subscriptionID+"/locations?api-version=2016-09-01"
$loclist = Invoke-WebRequest -Uri $loclisturi -Method GET -Headers $Headers -UseBasicParsing
$loclistcontent= ConvertFrom-Json -InputObject $loclist.Content
$locations =$loclistcontent


$providersUri="https://management.azure.com"+$subscriptionID+'/providers?api-version=2017-05-10&$top&$expand={$top&$expand}'
$providers = Invoke-WebRequest -Uri $providersUri -Method GET -Headers $Headers -UseBasicParsing
$providerslist= (ConvertFrom-Json -InputObject $providers.Content).value |where{$_.registrationState -eq 'registered'}



foreach ($prv in $providerslist)
{

$allres+=$prv

$prv.id

$apiverforprv=$prv.resourcetypes[0].apiversions[0]

$locations=$prv.resourceTypes.locations|select -Unique



Foreach ($loc in $locations[0].replace(' ','').tolower())
{

$usgdata=$cu=$usagecontent=$null
$usageuri="https://management.azure.com"+$prv.id+"/locations/"+$loc+"/usages?api-version=$apiverforprv"
$usageuri

$usageapi=$null
$usageapi = Invoke-WebRequest -Uri $usageuri -Method GET -Headers $Headers  -UseBasicParsing -ea 0

If($usageapi.Content)
{
$usagecontent= ConvertFrom-Json -InputObject $usageapi.Content

Foreach($usgdata in $usagecontent.value)
{


 $cu= New-Object PSObject -Property @{
                              Timestamp = $timestamp
                             MetricName = 'ARMQuotas';
                            Location = $loc
                            currentValue=$usgdata.currentValue
                            limit=$usgdata.limit
                            Namespace=$prv.namespace
                            Usagemetric = $usgdata.name[0].value.ToString()
                            SubscriptionID = $subscriptionID
                            AzureSubscription = $subscriptionname
							ShowinDesigner=1
      
                            }


$allvmusage+=$cu
}
}
}





#>
}

}

