 param(
    [Parameter(Mandatory=$false)] [string] $filterTenantID,
        [bool] $useazmodule=$false
) 


#region Variables definition
# Common  variables  accross solution 


#Update customer Id to your Operational Insights workspace ID
$customerID = Get-AutomationVariable -Name "AzureRBACMonitoring-AZMON_WS_ID" 

#For shared key use either the primary or seconday Connected Sources client authentication key   
$sharedKey = Get-AutomationVariable -Name "AzureRBACMonitoring-AZMON_WS_KEY" 



#For shared key use either the primary or seconday Connected Sources client authentication key   

#define API Versions for REST API  Calls

# Azure log analytics custom log name
$logname='RBACReport'
$Timestampfield="TimeStamp"


$AzureEnvironment = 'AzureCloud'

#endregion

#region Define Required Functions

# Create the function to create the authorization signature
Function Build-OMSSignature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
{
	$xHeaders = "x-ms-date:" + $date
	$stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
	$bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
	$keyBytes = [Convert]::FromBase64String($sharedKey)
	$sha256 =New-Object System.Security.Cryptography.HMACSHA256
	$sha256.Key = $keyBytes
	$calculatedHash = $sha256.ComputeHash($bytesToHash)
	$encodedHash = [Convert]::ToBase64String($calculatedHash)
	$authorization = 'SharedKey {0}:{1}' -f $customerId,$encodedHash
	return $authorization
}
# Create the function to create and post the request
Function Post-OMSData($customerId, $sharedKey, $body, $logType)
{


	#usage     $post=$null; $post=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
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
	
    [string]$uriadr = "https://{0}.ods.opinsights.azure.com{1}?api-version=2016-04-01" -f [string]$customerId,[string]$resource 
    $uri1=[System.Uri]$uriadr

	$OMSheaders = @{
		"Authorization" = $signature;
		"Log-Type" = $logType;
		"x-ms-date" = $rfc1123date;
		"time-generated-field" = $TimeStampField;
	}

	Try{
		$response = Invoke-WebRequest -Uri $uri1 -Method POST  -ContentType $contentType -Headers $OMSheaders -Body $body -UseBasicParsing
	}catch [Net.WebException] 
	{
		$ex=$_.Exception
		If ($_.Exception.Response.StatusCode.value__) {
			$exrespcode = ($_.Exception.Response.StatusCode.value__ ).ToString().Trim();
			#Write-Output $crap;
		}
		If  ($_.Exception.Message) {
			$exMessage = ($_.Exception.Message).ToString().Trim();
			#Write-Output $crapMessage;
		}
		$errmsg= "$exrespcode : $exMessage"
	}

	if ($errmsg){return $errmsg }
	Else{	return $response.StatusCode }
	#write-output $response.StatusCode
	Write-error $error[0]
}

# Use the Run As connection to login to Azure
function Login-AzureAutomation([bool] $AzModuleOnly) {
    try {
        $RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
        Write-Output "Logging in to Azure ($AzureEnvironment)..."

        if ($AzModuleOnly) {
            Add-AzAccount `
                -ServicePrincipal `
                -TenantId $RunAsConnection.TenantId `
                -ApplicationId $RunAsConnection.ApplicationId `
                -CertificateThumbprint $RunAsConnection.CertificateThumbprint `
                -Environment $AzureEnvironment

            Select-AzSubscription -SubscriptionId $RunAsConnection.SubscriptionID  | Write-Verbose
        } else {
            Add-AzureRmAccount `
                -ServicePrincipal `
                -TenantId $RunAsConnection.TenantId `
                -ApplicationId $RunAsConnection.ApplicationId `
                -CertificateThumbprint $RunAsConnection.CertificateThumbprint #`
              #  -Environment $AzureEnvironment

            Select-AzureRmSubscription -SubscriptionId $RunAsConnection.SubscriptionID  | Write-Verbose
        }
    } catch {
        if (!$RunAsConnection) {
            Write-Output $servicePrincipalConnection
            Write-Output $_.Exception
            $ErrorMessage = "Connection $connectionName not found."
            throw $ErrorMessage
        }

        throw $_.Exception
    }
}

#endregion


Login-AzureAutomation $useazmodule



#get all SPNs

Write-Output "account id : $accountId"
$RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"


If($useazmodule){ Write-Output "Az Module swill be used"; $subs=Get-AzSubscription}else{ Write-Output "AzureRM Modules  will be used"; $subs=Get-AzureRmSubscription}

 If($filterTenantID)
 {
    $subs=$subs|where{$_.TenantId -eq $filterTenantID }  #collect from  specific tenants only 
    Connect-AzureAD `
        -TenantId $filterTenantID `
        -CertificateThumbprint  $RunAsConnection.CertificateThumbprint `
         -ApplicationId $RunAsConnection.ApplicationId
 }Else
 {
 
 Connect-AzureAD `
        -TenantId $RunAsConnection.TenantId `
        -CertificateThumbprint  $RunAsConnection.CertificateThumbprint `
         -ApplicationId $RunAsConnection.ApplicationId

#$objectList|select appid,displayname 
 }

 $objectList=@()
$objectList+=Get-AzureADServicePrincipal | select ObjectId,Displayname
$objectList+=Get-AzureADGroup | select ObjectId,Displayname
 $report=@()

Write-Output $subs |ft


#get Management Groups
$MGs=@(Get-AzureRmManagementGroup)
IF($false) # not needed as subs  also has the information 
{
$MGAssignmentReport=@()  

    foreach ($mg in $MGs)
    {
        Write-Output "Check RBAC for MG"
        Write-Output $mg
        Write-Output $mg.Children
        Get-AzureRmManagementGroup  -GroupName $mg.id.split('/')[4]  -Expand -Recurse
        Get-AzureRmManagementGroup  -GroupName $mg.Children[0]  -Expand -Recurse


        $assignments=$null
        $assignments=Get-AzureRmRoleAssignment -Scope $mg.id

        Foreach ($item in $assignments)
        {
    
            $def=$null
            $actions=$null

            If($useazmodule)
            {
                $def=Get-AzRoleDefinition -Id $item.RoleDefinitionId
            }Else
            {
                $def=Get-AzureRmRoleDefinition -Id $item.RoleDefinitionId
            }
        
            $displayname=$null

            IF([string]::isnullorempty($item.DisplayName))
            {
                $displayname=@($objectList|where{$_.ObjectId  -eq $item.SignInName})[0]
            }Else
            {
                $displayname=$item.DisplayName
            }


            $MGAssignmentReport+=new-object pscustomobject -Property @{
                    Category="RBAC Assignment"
                    Subscription=$sub.Name
                    SignInName=$item.SignInName
                    SignInDisplayName=$displayname
                    RoleDefinitionName=$item.RoleDefinitionName
                    Scope=$item.Scope
                    ScopedTo="ManagementGroup"
                    ManagementGroup=$mg.id.split('/')[4]
                    SubscriptionId="*"
                    ResourceGroup="*"
                    Resource="*"
                    ObjectType=$item.ObjectType
                    ObjectId=$item.ObjectId
                    RoleDefinitionId=$item.RoleDefinitionId
                    RoleDescription=$def.Description
                    CanDelegate=$item.CanDelegate
                }     

         }

    

}

$jsonlogs= ConvertTo-Json -InputObject $MGAssignmentReport
$post=$null; 
#$post=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
if ($post -in (200..299))
{
    $AzLAUploadsuccess++
}Else
{
    $AzLAUploaderror++
} 

}

Foreach ($sub in $subs)
{
      $AssignmentsReport=@()    
    Write-output " Checking subscription : $($sub.Name) "
 

  $assignments=$null
 IF($useazmodule)
 {
    Set-AzContext -Subscription $sub.id
    $assignments=Get-AzRoleAssignment -IncludeClassicAdministrators
 }Else{
     $assignments=Get-AzureRmRoleAssignment  -IncludeClassicAdministrators
   Set-AzureRmContext -SubscriptionId $sub.id

 }


    
      Foreach ($item in $assignments)
    {

    $def=$null
    $actions=$null

    IF($item.RoleDefinitionId)
    {

        If($useazmodule)
        {
            $def=Get-AzRoleDefinition -Id $item.RoleDefinitionId
        }Else
        {
            $def=Get-AzureRmRoleDefinition -Id $item.RoleDefinitionId
        }

        $displayname=$null

        IF([string]::isnullorempty($item.DisplayName))
        {
            $displayname=@($objectList|where{$_.ObjectId  -eq $item.SignInName})[0]

            if ([string]::isnullorempty($displayname)){ $displayname=(Get-AzureADObjectByObjectId -ObjectIds $item.ObjectId -ErrorAction SilentlyContinue )[0].Displayname }
           
        }Else
        {
            $displayname=$item.DisplayName
        }

            
    If($item.Scope -match '/providers/Microsoft.Management/managementGroups')
    {
          $scope="ManagementGroup"
              $AssignmentsReport+=new-object pscustomobject -Property @{
                Category="RBAC Assignment"
                Subscription=$sub.Name
                ManagementGroup=[string]$item.Scope.Split('/')[4]
                SignInName=$item.SignInName
                SignInDisplayName=$displayname
                RoleDefinitionName=$item.RoleDefinitionName
                Scope=$item.Scope
                ScopedTo=$scope
                SubscriptionId=$sub.Id
                ResourceGroup="*"
                Resource="*"
                ObjectType=$item.ObjectType
                ObjectId=$item.ObjectId
                RoleDefinitionId=$item.RoleDefinitionId
                RoleDescription=$def.Description
                CanDelegate=$item.CanDelegate
                RoleAssignmentId=$item.RoleAssignmentId
                }
    
    }else
    {

      $scopelev=$item.Scope.Split('/').count
      if($scopelev -eq 3)
      {
        $scope="Subscription"
              $AssignmentsReport+=new-object pscustomobject -Property @{
                Category="RBAC Assignment"
                Subscription=$sub.Name
                SignInName=$item.SignInName
                SignInDisplayName=$displayname
                RoleDefinitionName=$item.RoleDefinitionName
                Scope=$item.Scope
                ScopedTo=$scope
                SubscriptionId=$item.Scope.Split('/')[2]
                ResourceGroup="*"
                Resource="*"
                ObjectType=$item.ObjectType
                ObjectId=$item.ObjectId
                RoleDefinitionId=$item.RoleDefinitionId
                RoleDescription=$def.Description
                CanDelegate=$item.CanDelegate
                RoleAssignmentId=$item.RoleAssignmentId
            }
        
      }elseif($scopelev -eq 5)
      {
        $scope="ResourceGroup"
            $AssignmentsReport+=new-object pscustomobject -Property @{
                Category="RBAC Assignment"
                Subscription=$sub.Name
                SignInName=$item.SignInName
                SignInDisplayName=$displayname
                RoleDefinitionName=$item.RoleDefinitionName
                Scope=$item.Scope
                ScopedTo=$scope
                SubscriptionId=$item.Scope.Split('/')[2]
                ResourceGroup=$item.Scope.Split('/')[4]
                Resource="*"
                ObjectType=$item.ObjectType
                ObjectId=$item.ObjectId
                RoleDefinitionId=$item.RoleDefinitionId
                RoleDescription=$def.Description
                CanDelegate=$item.CanDelegate
                RoleAssignmentId=$item.RoleAssignmentId
            }
      }else
      {
        $scope="Resource"
         $AssignmentsReport+=new-object pscustomobject -Property @{
                Category="RBAC Assignment"
                Subscription=$sub.Name
                SignInName=$item.SignInName
                SignInDisplayName=$displayname
                RoleDefinitionName=$item.RoleDefinitionName
                Scope=$item.Scope
                ScopedTo=$scope
                SubscriptionId=$item.Scope.Split('/')[2]
                ResourceGroup=$item.Scope.Split('/')[4]
                Resource=$item.Scope.Split('/')[6]
                ObjectType=$item.ObjectType
                ObjectId=$item.ObjectId
                RoleDefinitionId=$item.RoleDefinitionId
                RoleDescription=$def.Description
                CanDelegate=$item.CanDelegate
                RoleAssignmentId=$item.RoleAssignmentId
            }
      }
      
     }
         
      $def.Actions|?{

    $report+=new-object pscustomobject -Property @{
                Category="RBAC Definition"
                Subscription=$sub.Name
                SignInName=$item.SignInName
                SignInDisplayName=$displayname
                RoleDefinitionName=$item.RoleDefinitionName
                Scope=$item.Scope
                ObjectType=$item.ObjectType
                ObjectId=$item.ObjectId
                RoleDefinitionId=$item.RoleDefinitionId
                IsCustom=$def.IsCustom
                Action=$_
                RBACType="Action"
            }

    }

      $def.NotActions|?{

    $report+=new-object pscustomobject -Property @{
                Category="RBAC Definition"
                Subscription=$sub.Name
                SignInName=$item.SignInName
                SignInDisplayName=$displayname
                RoleDefinitionName=$item.RoleDefinitionName
                Scope=$item.Scope
                ObjectType=$item.ObjectType
                ObjectId=$item.ObjectId
                RoleDefinitionId=$item.RoleDefinitionId
                IsCustom=$def.IsCustom
                NotAction=$_
                RBACType="NotAction"
            }

    }

        $def.DataActions|?{

    $report+=new-object pscustomobject -Property @{
                Category="RBAC Definition"
                Subscription=$sub.Name
                SignInName=$item.SignInName
                SignInDisplayName=$displayname
                RoleDefinitionName=$item.RoleDefinitionName
                Scope=$item.Scope
                ObjectType=$item.ObjectType
                ObjectId=$item.ObjectId
                RoleDefinitionId=$item.RoleDefinitionId
                IsCustom=$def.IsCustom
                NotAction=$_
                RBACType="DataAction"
            }

    }

        $def.NotDataActions|?{

    $report+=new-object pscustomobject -Property @{
                Category="RBAC Definition"
                Subscription=$sub.Name
                SignInName=$item.SignInName
                SignInDisplayName=$displayname
                RoleDefinitionName=$item.RoleDefinitionName
                Scope=$item.Scope
                ObjectType=$item.ObjectType
                ObjectId=$item.ObjectId
                RoleDefinitionId=$item.RoleDefinitionId
                IsCustom=$def.IsCustom
                NotDataAction=$_
                RBACType="NotDataAction"
            }

    }
     }Else
     {
        #classic admin
        foreach($classicrole in $item.RoleDefinitionName.Split(';'))
        {
         $AssignmentsReport+=new-object pscustomobject -Property @{
                Category="RBAC Assignment Classic"
                Subscription=$sub.Name
                SignInName=$item.SignInName
                SignInDisplayName=$item.DisplayName
                RoleDefinitionName=$classicrole
                Scope=$item.Scope
                ScopedTo="Subscription"
                ObjectType=$item.ObjectType
                ObjectId=$item.ObjectId
                CanDelegate=$item.CanDelegate
            }
        }
     }
    }

    #upload data if exist 
    		If($AssignmentsReport)
		{

			$jsonlogs=$null
			$dataitem=$null
			

			foreach( $dataitem in $AssignmentsReport)
			{

				#if more than 5000 items in array split and upload them to Azure Monitor
				
				If ($dataitem.count -gt $splitSize) {
					$spltlist = @()
					$spltlist += for ($Index = 0; $Index -lt $dataitem.count; $Index += $splitSize) {
						, ($dataitem[$index..($index + $splitSize - 1)])
					}
					
				
					$spltlist|foreach {
						$splitLogs = $null
						$splitLogs = $_
						$post=$null;
						$jsonlogs = ConvertTo-Json -InputObject $splitLogs
						$post=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
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
					$jsonlogs= ConvertTo-Json -InputObject $dataitem
					$post=$null; 
					$post=Post-OMSData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonlogs)) -logType $logname
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

}


Write-output "Successfull upload job count : $AzLAUploadsuccess"
write-output  "Failed Upload Job count : $AzLAUploaderror "