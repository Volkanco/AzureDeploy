#!/bin/bash

function check_deps() {
  test -f $(which jq) || error_exit "jq command not detected in path, please install it"
}


function parse_input() {
  # jq reads from stdin so we don't have to set up any inputs, but let's validate the outputs
  eval "$(jq -r '@sh "export RG=\(.rg) VNETNAME=\(.vnetname)"')"
  if [[ -z "${RG}" ]]; then export RG=none; fi
  if [[ -z "${VNETNAME}" ]]; then export VNETNAME=none; fi
}




check_deps
parse_input


#check if vnet apready deployed

vnet=$(az network  vnet show  --resource-group $RG --name $VNETNAME  --query addressSpace.addressPrefixes -o tsv  2>/dev/null )

#vnet=$(az network  vnet show  --resource-group tf-uae-vnet-hub  --name tf-uae-vnet-hub  --query addressSpace.addressPrefixes -o tsv )

if [[ -z "${vnet}" ]]; then



IPsUsed=$(az network  vnet list   --query [].addressSpace.addressPrefixes -o table)

# echo ${IPsUsed[2]}
#echo "starting checking used subnets"
IpArray=()

searchip='^10.0.*(\/(3[0-2]|1[7-9]||[2][0-9]))$'

for  item in  $(az network  vnet list   --query [].addressSpace.addressPrefixes -o tsv)
do
   #echo $item
   if [[ $item =~ $searchip  ]]; then


        if [[ ! " ${IpArray[@]} " =~ " ${item} " ]]; then
            IpArray+=("$item")
#               echo "Adding $item to subnet list"
        fi



   fi
done

if [ ${#IpArray[@]} -eq 0 ]; then
    newCIDR="10.0.1.0/24"
else


IFS=$'\n' sorted=($(sort <<<"${IpArray[*]}"))
unset IFS
#echo   "${sorted[@]}"

#echo "${sorted[${#sorted[@]}-1]}"
LastSetIP="${sorted[${#sorted[@]}-1]}"


 IFS='.' read -r -a ip <<< $LastSetIP
unset IFS
#echo $ip

# we want to increase the 3rd octed and check if octed available  again
        if [[ ! " ${IpArray[@]} " =~ " ${item} " ]]; then
            IpArray+=("$item")
#               echo "Adding $item to subnet list"
        fi
newoct="${ip[2]}"


newoct="$((newoct+1))"
newCIDR="${ip[0]}.${ip[1]}.$newoct.${ip[3]}"
fi

else

newCIDR=$vnet

fi

echo  "{\"CIDR\":\"${newCIDR}\"}"