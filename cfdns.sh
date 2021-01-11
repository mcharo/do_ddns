#!/bin/bash

set -eo pipefail

function usage {
    echo "usage: $(basename $0) [-h] [domain] [record]"
    echo "  -h       display help"
    echo "  domain   specify domain for the record. Can be set using DO_DDNS_DOMAIN"
    echo "  record   specify the record hostname, defaults to @. Can be set using DO_DDNS_RECORD"
    exit 0
}

function get_zone_id {
    local DOMAIN=$1
    local TOKEN=$2
    zone_lookup=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN&status=active" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")
    lookup_result=$(echo $zone_lookup | jq -r '.success' | tr -d "\n")
    if [[ "$lookup_result" == "true" ]]; then
        zone_id=$(echo $zone_lookup | jq -r '.result[].id' | tr -d "\n")
        echo "$zone_id"
        return 0
    else
        return 1
    fi
}

function get_zone_record {
    local ZONE_ID=$1
    local RECORD_NAME=$2
    local TOKEN=$3
    local RECORD_TYPE=${4:-A}
    records_lookup=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$RECORD_TYPE&name=$RECORD_NAME" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json")
    lookup_result=$(echo $records_lookup | jq -r '.success' | tr -d "\n")
    if [[ "$lookup_result" == "true" ]]; then
        record=$(echo $records_lookup | jq -c '.result[]')
        echo "$record"
        return 0
    else
        return 1
    fi
}

function create_zone_record {
    local ZONE_ID=$1
    local RECORD_NAME=$2
    local RECORD_CONTENT=$3
    local TOKEN=$4
    local RECORD_TYPE=${5:-A}
    local RECORD_TTL=${6:-1}
    local RECORD_PROXIED=${7:-true}
    record_creation=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$RECORD_NAME\",\"content\":\"$RECORD_CONTENT\",\"ttl\":$RECORD_TTL,\"proxied\":$RECORD_PROXIED}")
    creation_result=$(echo $record_creation | jq -r '.success' | tr -d "\n")
    if [[ "$creation_result" == "true" ]]; then
        record=$(echo $record_creation | jq -c '.result')
        echo "$record"
        return 0
    else
        return 1
    fi
}

function update_zone_record {
    local RECORD=$1
    local RECORD_CONTENT=$2
    local TOKEN=$3
    local ZONE_ID=$(echo $RECORD | jq -r '.zone_id')
    local RECORD_ID=$(echo $RECORD | jq -r '.id')
    local RECORD_TYPE=$(echo $RECORD | jq -r '.type')
    local RECORD_NAME=$(echo $RECORD | jq -r '.name')
    local RECORD_TTL=$(echo $RECORD | jq -r '.ttl')
    record_update=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$RECORD_NAME\",\"content\":\"$RECORD_CONTENT\",\"ttl\":$RECORD_TTL}")
    update_result=$(echo $record_update | jq -r '.success' | tr -d "\n")
    if [[ "$update_result" == "true" ]]; then
        record=$(echo $record_update | jq -c '.result')
        echo "$record"
        return 0
    else
        return 1
    fi
}

[[ "$1" == "-h" ]] && { usage; }

# get token from envvar (or keychain if on macOS and its configured)
TOKEN=$CF_API_KEY
if [[ -z "$TOKEN" ]]; then
    if command -v security &> /dev/null; then
        TOKEN=$(security find-generic-password -wl ${CF_DDNS_KEYCHAIN_TOKEN:-cf_api} | tr -d "\n")
    fi
fi
if [[ -z "$TOKEN" ]]; then
    echo "Unable to retrieve API token"
    exit 1
fi

# if DDNS_DEBUG envvar is set to True, print commands
DDNS_DEBUG="${CF_DDNS_DEBUG:-False}"
if [[ "$CF_DDNS_DEBUG" =~ ^[Tt]rue$ ]]; then
    set -x
fi

# TODO: Sort out zone from record name
DOMAIN=${1:-$CF_DDNS_DOMAIN}
RECORD=${CF_DDNS_RECORD:-@}
RECORD=${2:-$RECORD}
PUBLIC_IP=$(curl -s http://bot.whatismyipaddress.com/)

echo "Domain: $DOMAIN"
echo "Record: $RECORD"
echo "Token: ${TOKEN:0:3}..."
echo "Public IP: $PUBLIC_IP"

if [[ -z "$PUBLIC_IP" ]]; then
    echo "Unable to detect public IP"
    exit 1
fi

zone_id=$(get_zone_id $DOMAIN $TOKEN)
existing_record=$(get_zone_record $zone_id $DOMAIN $TOKEN)
if [[ -z "$existing_record" ]]; then
    # create new record
    echo "Didn't find an existing record, creating a new record..."
    create_zone_record $zone_id $DOMAIN $PUBLIC_IP $TOKEN
else
    # update existing record if public IP has changed
    existing_ip=$(echo $existing_record | jq -r '.content')
    if [[ $existing_ip == $PUBLIC_IP ]]; then
        echo "The existing record ($existing_ip) matches the current public IP ($PUBLIC_IP)"
        exit 0
    fi
    echo "Updating the existing record..."
    update_zone_record $existing_record $PUBLIC_IP $TOKEN
fi
exit $?