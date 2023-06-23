#!/usr/bin/env bash
# written by Kyle Butler
# tested on ubuntu
# usage: sudo bash <script_name>.sh
# deploys a previous version of the container defender to a host/vm
# requres docker, jq, and outbound access to the prisma cloud console and the twistlock cdn

# USER CONFIG VARS BELOW

source ./secrets/secrets
source ./func/func.sh

# KEEP IN MIND. WE HAVE A N-2 support policy for defenders and console. Please don't deploy a defender older than the last two major releases 
TL_IMAGE_VERSION="22_12_694"


######################NO USER CONFIG NEEDED ########

AUTH_PAYLOAD=$(cat <<EOF
{"username": "$TL_USER", "password": "$TL_PASSWORD"}
EOF
)
command_exists() {
 command -v "$@" >/dev/null 2>&1
}

# authenticates to the prisma compute console using the access key and secret key. If using a self-signed cert with a compute on-prem version, add -k to the curl command.·
PRISMA_COMPUTE_API_AUTH_RESPONSE=$(curl --header "Content-Type: application/json" \
                                        --request POST \
                                        --data-raw "$AUTH_PAYLOAD" \
                                        --url $TL_CONSOLE/api/v1/authenticate )


TL_JWT=$(printf %s $PRISMA_COMPUTE_API_AUTH_RESPONSE | jq -r '.token')



PC_JWT_RESPONSE=$(curl --request POST \
                       --url "$PC_APIURL/login" \
                       --header 'Accept: application/json; charset=UTF-8' \
                       --header 'Content-Type: application/json; charset=UTF-8' \
                       --data "${AUTH_PAYLOAD}")

PC_JWT=$(printf '%s' "$PC_JWT_RESPONSE" | jq -r '.token' )



# only necessary if pulling defender image from the twistlock cdn. Note the prisma compute api endpoint does not have an n-1 image available.

LICENSE_ACCESS_KEY=$(curl --header "authorization: Bearer $TL_JWT" \
                          --header 'Content-Type: application/json' \
                          --request GET \
                          --url "$TL_CONSOLE/api/v1/defenders/image-name" | sed "s|\"registry\-auth\.twistlock\.com\/||g" | sed "s|\/twistlock.*||g" | sed "s|tw_||g")

# could replace with internal defender images which are checked into the organizations internal container registry
docker pull registry-auth.twistlock.com/tw_$LICENSE_ACCESS_KEY/twistlock/defender:defender_$TL_IMAGE_VERSION
docker save registry-auth.twistlock.com/tw_$LICENSE_ACCESS_KEY/twistlock/defender:defender_$TL_IMAGE_VERSION | gzip > ./temp/twistlock_defender.tar.gz
docker load -i ./temp/twistlock_defender.tar.gz
docker tag registry-auth.twistlock.com/tw_$LICENSE_ACCESS_KEY/twistlock/defender:defender_$TL_IMAGE_VERSION  twistlock/private:defender_$TL_IMAGE_VERSION

HOSTNAME_FOR_CONSOLE=$(printf %s $TL_CONSOLE | awk -F / '{print $3}' | sed  s/':\S*'//g)


curl -sSL \
     --header "authorization: Bearer $TL_JWT" \
     --request POST \
     --url "$TL_CONSOLE/api/v1/scripts/defender.sh" > ./defender.sh

HELM_REQUEST_BODY=$(cat <<EOF
{
  "consoleAddr": "$HOSTNAME_FOR_CONSOLE",
  "namespace": "twistlock",
  "orchestration": "kubernetes",
  "selinux": false,
  "cri": true,
  "privileged": false,
  "serviceAccounts": true,
  "istio": false,
  "collectPodLabels": false,
  "proxy": null,
  "taskName": null,
  "gkeAutopilot": false
}
EOF
)

curl --header "authorization: Bearer $TL_JWT" \
     --header 'Content-Type: application/json' \
     --request POST \
     -o ./temp/twistlock-defender-helm.tar.gz \
     --data "$HELM_REQUEST_BODY" \
     --url "$TL_CONSOLE/api/v1/defenders/helm/twistlock-defender-helm.tar.gz"


tar -xvzf ./temp/twistlock-defender-helm.tar.gz
sleep 2


TL_API_KEY_DEFENDER=$(cat ./temp/twistlock-defender/values.yaml | grep "install_bundle" | sed 's|install_bundle\: ||g' | base64 -d | jq -r '.apiKey')

tput_silent() {
  tput "$@" 2>/dev/null
}

print_info() {
  info=$1
  echo "$(tput_silent setaf 2)${info}.$(tput_silent sgr0)"
}

get_local_ip() {
  ip=""
# In some distributions, grep is not compiled with -P support.
# grep: support for the -P option is not compiled into this --disable-perl-regexp binary
# For those cases, use pcregrep
  if command_exists pcregrep; then
    ip=$(ip -f inet addr show | pcregrep -o 'inet \K[\d.]+')
  else
    ip=$(ip -f inet addr show | grep -Po 'inet \K[\d.]+')
  fi
  ip_result="IP:"
  ip_result+=$(echo ${ip} | sed 's/ /,IP:/g')
  echo ${ip_result}
}

download_certs() {
  local ip=${san:-$(get_local_ip)}
  local hostname=$(hostname --fqdn 2>/dev/null)
    if [[ $? == 1 ]]; then
     #Fallback to hostname without domain
     hostname=$(hostname)
    fi
    if [[ ${hostname} == *" "* ]]; then
      hostname=$(hostname)
    fi
print_info "Generating certs for ${hostname} ${ip}"
curl --header "x-redlock-auth: $PC_JWT" "$TL_CONSOLE/api/v1/certs/server-certs.sh?hostname=${hostname}&ip=${ip}" -o ./temp/certs.sh
bash ./temp/certs.sh
}

download_certs

curl --header "authorization: Bearer $TL_JWT" \
     --url $TL_CONSOLE/api/v1/scripts/twistlock.sh \
     -o ./temp/twistlock.sh

curl --header "authorization: Bearer $TL_JWT" \
     --url "$TL_CONSOLE/api/v1/scripts/twistlock.cfg" \
     -o ./temp/twistlock.cfg

sed -i "s|DOCKER_TWISTLOCK_TAG\=.*|DOCKER_TWISTLOCK_TAG\=_$TL_IMAGE_VERSION|g" ./temp/twistlock.cfg

curl --header "authorization: Bearer $TL_JWT" \
     --url "$TL_CONSOLE/api/v1/certs/service-parameter" \
     -o ./temp/service-parameter


TL_CUSTOMER_ID=$(printf '%s' "$TL_CONSOLE" | sed 's|https\:\/\/||g' |grep "/" | cut -d/ -f2- )

TL_INSTALL_BUNDLE=$(cat <<EOF
{
  "secrets": {},
  "globalProxyOpt": {
    "httpProxy": "",
    "noProxy": "",
    "ca": "",
    "user": "",
    "password": {
      "encrypted": ""
    }
  },
  "customerID": "$TL_CUSTOMER_ID",
  "apiKey": "$TL_API_KEY_DEFENDER",
  "microsegCompatible": false
}
EOF
)

ENCODED_TL_INSTALL_BUNDLE=$(printf '%s' "$TL_INSTALL_BUNDLE" | base64 | tr -d '\n')



source ./temp/twistlock.cfg
sudo bash ./temp/twistlock.sh -s --ws-port 443 -a "$HOSTNAME_FOR_CONSOLE" -b "$ENCODED_TL_INSTALL_BUNDLE" "defender"


## Remove to keep temp
{
rm -rf ./temp/*
}


exit