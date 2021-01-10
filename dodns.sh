#!/bin/bash

set -eo pipefail

function usage {
    echo "usage: $(basename $0) [-h] [domain] [record]"
    echo "  -h       display help"
    echo "  domain   specify domain for the record. Can be set using DO_DDNS_DOMAIN"
    echo "  record   specify the record hostname, defaults to @. Can be set using DO_DDNS_RECORD"
    exit 0
}

[[ "$1" == "-h" ]] && { usage; }

# get token from envvar (or keychain if on macOS and its configured)
TOKEN=$DO_API_KEY
if [[ -z "$TOKEN" ]]; then
    if command -v security &> /dev/null; then
        TOKEN=$(security find-generic-password -wl ${DO_DDNS_KEYCHAIN_TOKEN:-do_api} | tr -d "\n")
    fi
fi
if [[ -z "$TOKEN" ]]; then
    echo "Unable to retrieve API token"
    exit 1
fi

# if DDNS_DEBUG envvar is set to True, print commands
DDNS_DEBUG="${DO_DDNS_DEBUG:-False}"
if [[ "$DO_DDNS_DEBUG" =~ ^[Tt]rue$ ]]; then
    set -x
fi

DOMAIN=${1:-$DO_DDNS_DOMAIN}
RECORD=${DO_DDNS_RECORD:-@}
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

# look up existing record so we can get it's ID
existing_record=$(curl -s -X GET -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    "https://api.digitalocean.com/v2/domains/$DOMAIN/records")
existing_record=$(echo $existing_record | jq ".domain_records[] | select((.type==\"A\") and (.name==\"$RECORD\"))")

if [[ -z "$existing_record" ]]; then
    # create new record
    echo "Didn't find an existing record, creating a new record..."
    curl -s -X POST -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d "{\"type\":\"A\",\"name\":\"$RECORD\",\"data\":\"$PUBLIC_IP\",\"priority\":null,\"port\":null,\"ttl\":1800,\"weight\":null,\"flags\":null,\"tag\":null}" \
        "https://api.digitalocean.com/v2/domains/$DOMAIN/records"
else
    # update existing record if public IP has changed
    record_id=$(echo $existing_record | jq -r '.id')
    existing_ip=$(echo $existing_record | jq -r '.data')
    if [[ $existing_ip == $PUBLIC_IP ]]; then
        echo "The existing record ($existing_ip) matches the current public IP ($PUBLIC_IP)"
        exit 0
    fi
    if [[ -z "$record_id" ]]; then
        echo "Unable to determine ID of existing record"
        exit 1
    fi
    echo "Updating the existing record..."
    curl -s -X PUT -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d "{\"name\":\"$RECORD\",\"data\":\"$PUBLIC_IP\"}" \
        "https://api.digitalocean.com/v2/domains/$DOMAIN/records/$record_id"
fi