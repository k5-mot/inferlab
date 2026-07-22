#!/bin/bash
set -e

if [ "$container" == "podman" ]; then
  export NAMESERVER
  NAMESERVER="$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf)"
else
  export NAMESERVER
  NAMESERVER="$(awk '/nameserver/ {print $2}' /etc/resolv.conf | tr '\n' ' ')"
fi

envsubst '$NAMESERVER' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

for file in /etc/nginx/pulp/*.conf; do
  [ -e "$file" ] || continue
  sed -i 's/pulp-api/$pulp_api:24817/g' "$file"
  sed -i 's/pulp-content/$pulp_content:24816/g' "$file"
done

exec nginx -g "daemon off;"
