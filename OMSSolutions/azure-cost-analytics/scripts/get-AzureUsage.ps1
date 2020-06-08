param
(
    [Parameter(Mandatory=$false)] [int] $ingestpastndays
)




#region Variables definition
# Common  variables  accross solution 


#Update customer Id to your Operational Insights workspace ID
$customerID = Get-AutomationVariable -Name "AzureCostAnalytics-AZMON_WS_ID" 

#For shared key use either the primary or seconday Connected Sources client authentication key   
$sharedKey = Get-AutomationVariable -Name "AzureCostAnalytics-AZMON_WS_KEY" 



$azResourceID="Az REsource group id "
# Azure log analytics custom log name
$logname='AzureUsage'


# You can use an optional field to specify the timestamp from the data. If the time field is not specified, Azure Monitor assumes the time is the message ingestion time

$Timestampfield="usageEnd"

#endregion

#region Define Required Functions

# Create the function to create the authorization signature
Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
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
Function Post-LogAnalyticsData($customerId, $sharedKey, $body, $logType)
{
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Build-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

    $headers = @{
        "Authorization" = $signature;
        "Log-Type" = $logType;
        "x-ms-date" = $rfc1123date;
        "time-generated-field" = $TimeStampField;
        "x-ms-AzureResourceId" = $azResourceID;
    }

    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode

}


function get-arm ($localuri, $Headers)
{

$all=@()
write-host $localuri 

$content=Invoke-RestMethod -Uri $localuri -Method GET  -Headers $headers -UseBasicParsing
$all+=$content.value

IF (![string]::IsNullOrEmpty($content.nextLink)) {
    do {
        [uri]$uri=$content.nextLink
        $content = $null

        $content=Invoke-RestMethod -Uri $uri -Method GET  -Headers $headers -UseBasicParsing

        $all+=$content.value


    }While (![string]::IsNullOrEmpty($content.NextMarker))
}

return($all)
}



#endregion


### MAIN Data Collection Logic 
#Connect to azure 
Enable-AzureRmAlias

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


$context = Get-AzContext
$SubscriptionId = $context.Subscription


$subs=Get-AzSubscription
$dt=get-date

$AzLAUploadsuccess=0
$AzLAUploaderror=0

foreach ($sub in $subs)
{

    Write-Output " Processing $($sub.Name)  : $($sub.id)"
    Set-AzContext -Subscription $sub.id 
    $context = Get-AzContext
    IF($context.Subscription.Id -ne $sub.Id)
    {
        Continue
    }
    
    $dt=get-date
      
      IF($ingestpastndays -eq $null){$ingestpastndays=2}
           
                IF ($ingestpastndays)
                {
                       #UsageAggregate
                    $i=$ingestpastndays
    
                    do
                    {
    
                    $dt=(Get-Date).AddDays(-1*($i-1)).ToString("yyyy-MM-dd")
                    $dt1=(Get-Date).AddDays(-1*$i).ToString("yyyy-MM-dd")
                    
                    $ua=@()
                    $us=Get-UsageAggregates   -ReportedStartTime $dt1   -ReportedEndTime $dt -AggregationGranularity Daily -ShowDetails 1
                    $ua+=$us.UsageAggregations

                    do
                    {
                        $us=Get-UsageAggregates -ContinuationToken $us.ContinuationToken -ReportedStartTime $dt1  -ReportedEndTime  $dt  -ShowDetails 1
                        $ua+=$us.UsageAggregations

                    } while($us.ContinuationToken  -ne $null) 

                        $i--
                    [System.Collections.ArrayList]$usage=@()

                    foreach ($item in $ua)
                    {
    
                        $instancedata=$null
                        $instancedata=(convertfrom-json -InputObject $item.Properties.InstanceData).'Microsoft.Resources'
        
                        $usage.add([PSCustomObject]@{            
                                    Id=$item.Id
                                    Type=$item.Type
                                    MeterCategory=$item.Properties.MeterCategory
                                    MeterId=$item.Properties.MeterId
                                    MeterName=$item.Properties.MeterName
                                    MeterRegion=$item.Properties.MeterRegion
                                    MeterSubCategory=$item.Properties.MeterSubCategory
                                    Quantity=[double]$item.Properties.Quantity
                                    Unit=$item.Properties.Unit
                                    UsageEndTime=$item.Properties.UsageEndTime.AddSeconds(-1)
                                    UsageStartTime=$item.Properties.UsageStartTime
                                    SubscriptionGuid=$sub.Id
                                    SubscriptionName=$sub.Name
                                    ResourceId=$instancedata.resourceUri
                                    Location=$instancedata.location
                                    ver=1
                                    })|Out-Null
                    }


                    #upload data if exist 
                    If($usage)
                    {
                    
                        $Timestampfield="UsageEndTime"

                        $jsonlogs=$null
                        $dataitem=$null
	                    $splitSize=5000	

                        #if more than 5000 items in array split and upload them to Azure Monitor
				
                           If ($usage.count -gt $splitSize) {
     
                            for ($Index = 0; $Index -lt $usage.count; $Index += $splitSize) {
    
                            $jsonlogs = ConvertTo-Json -InputObject $usage[$index..($index + $splitSize - 1)]
                            $post=Post-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
                            Write-Output $index
                                if ($post -in (200..299))
                                {
	                                $AzLAUploadsuccess++
                                }Else
                                {
	                                $AzLAUploaderror++
                                }
                        
                            }
                        }Else
                        {
                            $jsonlogs= ConvertTo-Json -InputObject $usage
                            $post=$null; 
                            $post=Post-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
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
                    While ($i -gt 0 )
                    
                    #usageDetails

                     $i=$ingestpastndays
    
                    do
                    {
                     $dt=get-date
                    $billperiod=$dt.AddDays(-1*$i).Date.ToString('yyyyMM')
                    
                    $content=@()
                    $content+=get-AzConsumptionUsageDetail -Expand MeterDetails -IncludeAdditionalProperties -StartDate $dt.AddDays(-1*$i).Date -EndDate $dt.AddDays(-1*($i-1)).Date.AddSeconds(-1)

                    $i--

                    [System.Collections.ArrayList]$usagedetail=@()

                    foreach ($item in $content)
                    {
                         $usagedetail.add([PSCustomObject]@{            
                                    AccountName=$item.AccountName
                                    AdditionalInfo=$item.AdditionalInfo
                                    AdditionalProperties=$item.AdditionalProperties
                                    BillableQuantity=$item.BillableQuantity
                                    BillingPeriodId=$item.BillingPeriodId
                                    BillingPeriodName=$item.BillingPeriodName
                                    ConsumedService=$item.ConsumedService
                                    CostCenter=$item.CostCenter
                                    Currency=$item.Currency
                                    DepartmentName=$item.DepartmentName
                                    Id=$item.Id
                                    InstanceId=$item.InstanceId
                                    InstanceLocation=$item.InstanceLocation
                                    InstanceName=$item.InstanceName
                                    InvoiceId=$item.InvoiceId
                                    InvoiceName=$item.InvoiceName
                                    IsEstimated=$item.IsEstimated
                                    MeterDetails=$item.MeterDetails
                                    MeterId=$item.MeterId
                                    Name=$item.Name
                                    PretaxCost=$item.PretaxCost
                                    Product=$item.Product
                                    SubscriptionGuid=$item.SubscriptionGuid
                                    SubscriptionName=$item.SubscriptionName
                                    Tags=$(convertto-json -InputObject $item.Tags)
                                    Type=$item.Type
                                    UsageEnd=$item.UsageEnd
                                    UsageQuantity=$item.UsageQuantity
                                    UsageStart=$item.UsageStart
                                    ver=1
                                    })|Out-Null
                            }

                    #upload data if exist 
                    If($usagedetail)
                    {
                       $Timestampfield="usageEnd"
                        $jsonlogs=$null
                        $dataitem=$null
	                    $splitSize=5000	

                        #if more than 5000 items in array split and upload them to Azure Monitor
				
                           If ($usagedetail.count -gt $splitSize) {
     
                            for ($Index = 0; $Index -lt $usagedetail.count; $Index += $splitSize) {
    
                            $jsonlogs = ConvertTo-Json -InputObject $usagedetail[$index..($index + $splitSize - 1)]
                            $post=Post-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
                            Write-Output $index
                                if ($post -in (200..299))
                                {
	                                $AzLAUploadsuccess++
                                }Else
                                {
	                                $AzLAUploaderror++
                                }
                        
                            }
                        }Else
                        {
                            $jsonlogs= ConvertTo-Json -InputObject $usagedetail
                            $post=$null; 
                            $post=Post-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
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
                    While ($i -gt 0 )
    

                }

}


Write-output "Successfull upload job count : $AzLAUploadsuccess"
write-output  "Failed Upload Job count : $AzLAUploaderror "




