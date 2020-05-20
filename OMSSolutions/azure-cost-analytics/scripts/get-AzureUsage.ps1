param
(
[Parameter(Mandatory=$false)] [datetime] $startdate,
[Parameter(Mandatory=$false)] [datetime] $enddate
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


$context = Get-AzureRmContext
$SubscriptionId = $context.Subscription

Write-Output "with ADAL"



$subs=Get-AzSubscription

foreach ($sub in $subs)
{

    Set-AzContext -SubscriptionObject $sub
    

    $AzLAUploadsuccess=0
    $AzLAUploaderror=0


    $content=@()
    $dt=get-date



    IF ($startdate -ne $null -and $enddate -ne $null)
    {
            $billperiod=$startdate.ToString('yyyyMM')
        $content+=get-AzConsumptionUsageDetail -BillingPeriodName $billperiod -Expand MeterDetails -IncludeAdditionalProperties -StartDate $startdate -EndDate $enddate
    }Else
    {
        $billperiod=$dt.ToString('yyyyMM')
        $start=(get-date).AddDays(-1).Date
        $end=$start.Date.AddHours(23).AddMinutes(59).AddSeconds(59);
        $content+=get-AzConsumptionUsageDetail -BillingPeriodName $billperiod  -Expand MeterDetails -IncludeAdditionalProperties -StartDate $start -EndDate $end

    }



[System.Collections.ArrayList]$usage=@()


foreach ($item in $content)
{
    
    $usage.add([PSCustomObject]@{            
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
If($usage)
{

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
        $Index
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
Write-output "Successfull upload job count : $AzLAUploadsuccess"
write-output  "Failed Upload Job count : $AzLAUploaderror "




