#! /bin/sh
# shellcheck disable=SC2181

data_dir=/etc/reverse_proxy
acme_dir="$data_dir/.acme.sh"
config_file="$data_dir/config.json"
acme="$acme_dir/acme.sh"

if [ ! -f "$config_file" ]; then
  echo "Missing $config_file. Did you forget to mount the data volume?"
  exit 1
fi

config=$(cat "$config_file")
alias jqc='echo "$config" | jq'

if [ ! -d "$acme_dir" ]; then
  email=$(jqc -e -r '.email')
  if [ $? -ne 0 ]; then
    echo "$config_file is missing the email to use when registering the SSL certificates"
    exit 1
  fi
  echo "Installing acme.sh"
  (cd /opt/acme.sh && ./acme.sh --install --home "$acme_dir" --accountemail "$email") || exit 1
fi

if ! jqc -e '.account_thumbprint' >/dev/null; then
  echo "Registering account with LetsEncrypt"
  le_response=$("$acme" --home "$acme_dir" --server letsencrypt --register-account)
  if [ $? -ne 0 ]; then
    echo "Failed to register the acme account"
    echo "$le_response"
    exit 1
  fi
  account_thumbprint=$(echo "$le_response" | grep ACCOUNT_THUMBPRINT | sed "s/.*ACCOUNT_THUMBPRINT='\(.*\)'/\1/")
  # shellcheck disable=SC2016
  config=$(jqc -e --arg x "$account_thumbprint" '.account_thumbprint=$x')
  if [ $? -ne 0 ]; then
    echo "Failed to register the account thumbprint"
    exit 1
  fi
  echo "$config" > "$config_file"
fi
