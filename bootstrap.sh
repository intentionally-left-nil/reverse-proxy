#! /bin/sh
# shellcheck disable=SC2181

data_dir=/etc/reverse_proxy
acme_dir="$data_dir/.acme.sh"
config_file="$data_dir/config.json"

if [ ! -f "$config_file" ]; then
  echo "Missing $config_file. Did you forget to mount the data volume?"
  exit 1
fi

config=$(cat "$config_file")

if [ ! -d "$acme_dir" ]; then
  email=$(echo "$config" | jq -e '.email')
  if [ $? -ne 0 ]; then
    echo "$config_file is missing the email to use when registering the SSL certificates"
    exit 1
  fi
  echo "Installing acme.sh"
  (cd /opt/acme.sh && ./acme.sh --install --home "$acme_dir" --accountemail "$email") || exit 1
fi
