# Azure Cost Analytics Solution 

[![Deploy to Azure](http://azuredeploy.net/deploybutton.png)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fazure-cost-analytics%2Fazuredeploy.json) 
<a href="http://armviz.io/#/?load=https%3A%2F%2raw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fazure-cost-analytics%2Fazuredeploy.json" target="_blank">
    <img src="http://armviz.io/visualizebutton.png"/>
</a>

>[AZURE.NOTE]This is preliminary documentation for Azure Cost Analytics solution which helps vizualizing Azure Usage using Azure Automation and Azure Monitor cusotm logs.




## Steps to deploy the solution 

* Deploy the Arm Template
* Create Runas Account for Automation Account
* Import Az.Accounts and Az.Billing   Module to Automation Account

**Runbook is scheduled to run at 15.00  every day. If you need to ingest historical data start the runbook manually by specifying stratdate and enddate parameters.**


## Pre-reqs

- **Azure Automatation RunAS Account should be created**
- **Azure Automatation RunAS Account should have Reader / Billing Reader or Contributor access to customers subscriptions**
- **Az.Accounts and Az.Billing modules should be imported from gallery manually**


## Template Deployment using PowerShell

New-AzResourceGroupDeployment -Name azcostanalytics -ResourceGroupName <yourRG> -Mode Incremental -TemplateUri https://raw.githubusercontent.com/Volkanco/AzureDeploy/master/OMSSolutions/azure-cost-analytics/azuredeploy.json  -logAnalyticsWorkspaceName <your LA WS> -logAnalyticsRegion "West Europe" -automationAccountName <your automation account> -automationRegion "West Europe"

Make sure you select regions from  allowed values !

### Log Analytics:
 "allowedValues": [
               "East US",
                "West Europe",
                "Southeast Asia",
                "Australia Southeast",
                "West Central US",
                "Japan East",
                "UK South",
                "Central India",
                "Canada Central",
                "East US 2 EUAP",
                "West US 2",
                "Australia Central",
                "Australia East",
                "France Central",
                "Korea Central",
                "North Europe",
                "Central US",
                "East Asia",
                "East US 2",
                "South Central US",
                "North Central US",
                "West US",
                "UK West",
                "South Africa North",
                "Brazil South",
                "Switzerland North",
                "Switzerland West"
            ],            

### Automaton:
         "allowedValues": [
                "Japan East",
                "East US 2",
                "West Europe",
                "South Africa North",
                "UK West",
                "Switzerland North",
                "Southeast Asia",
                "South Central US",
                "North Central US",
                "East Asia",
                "Central US",
                "West US",
                "Australia Central",
                "Australia East",
                "Korea Central",
                "East US",
                "West US 2",
                "Brazil South",
                "Central US EUAP",
                "UK South",
                "West Central US",
                "North Europe",
                "Canada Central",
                "Australia Southeast",
                "Central India",
                "France Central"
            ],





## Template Deployment

[![Deploy to Azure](http://azuredeploy.net/deploybutton.png)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fazure-cost-analytics%2Fazuredeploy.json) 
<a href="http://armviz.io/#/?load=https%3A%2F%2raw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fazure-cost-analytics%2Fazuredeploy.json" target="_blank">
    <img src="http://armviz.io/visualizebutton.png"/>
</a>

Once deployed workbook can be accessed under Azure Portal/Monitoring/Workbooks

To deploy individual workbooks only ; 
[![Deploy WB v5](http://azuredeploy.net/deploybutton.png)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fazure-cost-analytics%2FAzureConsumptionWBv5.json) 
