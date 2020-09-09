# Azure VM Size Optimization Wokbook

[![Deploy to Azure](http://azuredeploy.net/deploybutton.png)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fvm-size-optimization%2Fazuredeploy.json) 
<a href="http://armviz.io/#/?load=https%3A%2F%2raw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fvm-size-optimization%2Fazuredeploy.json" target="_blank">
    <img src="http://armviz.io/visualizebutton.png"/>
</a>

>[AZURE.NOTE]This is preliminary documentation for Azure VM Optimization Workbook which helps vizualizing the  VM usage indicators fetched from Azure Monitor/Log Analytics.


Azure Size Optimizations Workbook  correlates  the following data per Azure VM ;

* RDP or SSH logins
* Reboots
* CPU Utilization 
* Memory Utilization
* Disk IOPs
* Disk Latency
* NW Sent / Receive
* Inbound Connections
* NW Traffic Sent Total
* NW Traffic Received Total

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

You can select a libe from 
table and see the size history and storage profile for the selected VM ; 

![alt text](images/wbimage7.PNG "Part2")

![alt text](images/wbimage8.PNG "Part2")

# Performance History of a VM 
This view vizualize  performance metrics on   timecharts  for detailed analysis. Data behind all views can be exported to excel . 


![alt text](images/wbimage9.PNG "Part2")


# Size Optimization 
Workbook compares the actual usage for CPU/Memory/Iops and compares them to the threshol set by customer  and decides if CPU/Memory/IOPs can be resized. If all 3 can be resized  if checks which VM sizes on Azure will be able to accomodate the load.  

![alt text](images/wbimage3.PNG "Part3")
![alt text](images/wbimage10.PNG "Part4")

# Unused Disks

This part displays all the managed disk which is not unattached or reserved by a deallocated VMs . These can be cleaned up or converted to VHD blobs to save cost.

![alt text](images/wbimage4.PNG "Part5")

# Unused Public IPs

This part displays all public IP addresses that is not associcated  to a NIC.

![alt text](images/wbimage11.PNG "Part6")

## Template Deployment

[![Deploy to Azure](http://azuredeploy.net/deploybutton.png)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fvm-size-optimization%2Fazuredeploy.json) 
<a href="http://armviz.io/#/?load=https%3A%2F%2raw.githubusercontent.com%2FVolkanco%2FAzureDeploy%2Fmaster%2FOMSSolutions%2Fvm-size-optimization%2Fazuredeploy.json" target="_blank">
    <img src="http://armviz.io/visualizebutton.png"/>
</a>

Once deployed workbook can be accessed under Azure Portal/Monitoring/Workbooks

![alt text](images/wbimage6.PNG "Workbook")