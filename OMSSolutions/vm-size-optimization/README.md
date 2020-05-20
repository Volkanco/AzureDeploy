# Azure VM Size Optimization Wokbook

[![Deploy to Azure](http://azuredeploy.net/deploybutton.png)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fvm-size-optimization%2Fazuredeploy.json) 
<a href="http://armviz.io/#/?load=https%3A%2F%2raw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fvm-size-optimization%2Fazuredeploy.json" target="_blank">
    <img src="http://armviz.io/visualizebutton.png"/>
</a>

>[AZURE.NOTE]This is preliminary documentation for Azure VM Optimization Workbook which helps vizualizing the  VM usage indicators fetched from Azure Monitor/Log Analytics.


Azure Size Optimizations Workbook  corrlates  the following data per Azure VM ;

* RDP or SSH logins
* Reboots
* CPU Utilization 
* Memory Utilization
* Disk IOPs
* NW Sent / Receive
* Inbound Connections

![alt text](images/wbimage2.PNG "VM Usage")

Using these metrics  you can detect the VMs  that are idle ,  not in use anymore .  
Performance counters will be used to  check if optimal size is selected for the VM and gives you recommendations for smaller sizes. 
CPU metric is measured  based on peak hours setting  to analyze the real CPU  demand.


![alt text](images/wbimage5.PNG "Parameters")


You can filter subscriptions , log analytics workspaces, resurce groups and set Peak hour Start End times. 

## Pre-reqs

- **Azure Monitor should be enabled for VMs**

Data is pulled from log analtics workspace and  all azure VMs  needs to be configured to report to one or many workspaces. 
VM Insights solution should be enabled to be able to provide Azure size history and size optimization recommendations.


## Solution Views 

![alt text](images/wbimage1.PNG "part1")
![alt text](images/wbimage2.PNG "Part2")
![alt text](images/wbimage3.PNG "Part3")
![alt text](images/wbimage4.PNG "Part4")
