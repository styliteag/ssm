#!/usr/bin/env sh

set -eu

# shellcheck disable=SC3040
(set -o pipefail 2> /dev/null) && set -o pipefail

command="$1"

# TODO: Read authorized_keys location from sshd config
authorized_keys_location=".ssh/authorized_keys"

# Get the location of the authorized keyfile given a username
get_authorized_keys_location() {
  user="$1"
  home=$(getent passwd "${user}" | cut -d: -f6)

  echo "${home}/${authorized_keys_location}"
}

case "${command}" in
  get_authorized_keyfile)
    user="$2"
    keyfile_location=$(get_authorized_keys_location "${user}")

    if [ ! -e "${keyfile_location}" ]; then
      echo "Couldn't find authorized_keys for this user."
      echo "Tried location: '${keyfile_location}'"
      exit 1
    fi

    cat "${keyfile_location}"
    exit 0
    ;;
  set_authorized_keyfile)
    user="$2"
    keyfile_location=$(get_authorized_keys_location "${user}")

    # TODO: check if file exists and is managed by keymanager
    # Then maybe move the old file to a backup location

    # Read new authorized_keys from stdin
    cat - > "${keyfile_location}"
    exit 0
    ;;
  get_ssh_users)
    getent passwd | while IFS=: read -r name _password _uid _gid _gecos home _shell; do
      if [ -e "${home}/${authorized_keys_location}" ]; then
        echo "${name}"
      fi
    done
    exit 0
    ;;
  update)
    new_script=$(cat -)

    echo "Updating script"
    echo "not implemented"
    exit 1
    ;;

  version)
    echo "ssh-key-manager v0.1-alpha"
    exit 0
    ;;

  *)
    echo "Command '${command}' not found."
    exit 2
    ;;
esac
