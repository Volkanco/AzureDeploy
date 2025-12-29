# Azure VM Size Optimization Wokbook

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fvirtualnetwork-insights%2Fazuredeploy.json) 
<a href="http://armviz.io/#/?load=https%3A%2F%2raw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fvirtualnetwork-insights%2Fazuredeploy.json" target="_blank">
</a>

>[AZURE.NOTE]This is preliminary documentation for Azure Virtual Netwotk Insights  Workbook which helps vizualizing the  Virtual Networks, UDRS, NSGs and related settings. 


Azure Virtual Network Insights  Workbook  pulls information about 

* Azure Virtual Netwotks and their DDOS protection setting
* Subnets
* User Defines Routes
* Network Secuirty Groups 
* Internet Egress Configuration for each subnet


![alt text](images/dummary.png "DDOS")

Using these views you can identfy the egress path of each subnet. You can check which subnets are sending internet to speicific firewall appliances and which ones has direc internet egress without firewall. 




## Pre-reqs

You need at least reader permission on the subscriptions where virtual networks are deployed. 


## Solution Views 

### DDOS 

![alt text](images/ddos.png "DDOS")


DDOS tab displays DDOS protection coverage accross virtual networks. 

### NSG

![alt text](images/nsgview.png "NSG")


NSG tab displays all network secuirty rules  across all subnets. You can filter the view by source/destination/directian and action to identify the applicable rules for the given virtaul netwirks. 

### Internet Eggress

![alt text](images/egress.png "EGRESS")


Egress tab visuzlizes the internet egress configuration across virtual networks & subnets. By using this view you can identify which subnets has direct internet access and which ones are forced to any firewall appliance.

## Template Deployment

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fvirtualnetwork-insights%2Fazuredeploy.json) 
<a href="http://armviz.io/#/?load=https%3A%2F%2raw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fvirtualnetwork-insights%2Fazuredeploy.json" target="_blank">
    <img src="http://armviz.io/visualizebutton.png"/>
</a>

Once deployed workbook can be accessed under Azure Portal/Monitoring/Workbooks

