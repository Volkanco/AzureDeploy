AppName="App1Crm"

busunit="cb"

location = "uaenorth"

#Spoke Subnet names and ip ranges
spoke_subnet_names=["dev","test","uat","sim"]
spoke_subnet_prefixes=["10.200.2.0/26", "10.200.2.64/26","10.200.2.128/26","10.200.2.192/26"]

# FW IP for the HUB Vnet , used in UDR as next hop
hubfwip = "10.1.2.4"
onprem_address_prefix ="10.0.0.0/16"


 