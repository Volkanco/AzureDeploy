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

- **Azure Monitor should be enabled for VMs**

Data is pulled from log analtics workspace and  all azure VMs  needs to be configured to report to one or many workspaces. 
VM Insights solution should be enabled to be able to provide Azure size history and size optimization recommendations.


## Solution Views 



## Template Deployment

[![Deploy to Azure](http://azuredeploy.net/deploybutton.png)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fazure-cost-analytics%2Fazuredeploy.json) 
<a href="http://armviz.io/#/?load=https%3A%2F%2raw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fazure-cost-analytics%2Fazuredeploy.json" target="_blank">
    <img src="http://armviz.io/visualizebutton.png"/>
</a>

Once deployed workbook can be accessed under Azure Portal/Monitoring/Workbooks

![alt text](images/wbimage6.PNG "Workbook")