#!/usr/bin/env sh

set -eu

# shellcheck disable=SC3040
(set -o pipefail 2> /dev/null) && set -o pipefail

authorized_keys_location=".ssh/authorized_keys"
version="Secure SSH Manager script v0.1-alpha"
keyfile_head="# Auto-generated by Secure SSH Manager. DO NOT EDIT!"

# TODO: Read authorized_keys location from sshd config
# Get the location of the authorized keyfile given a username
get_authorized_keys_location() {
  user="$1"
  home=$(getent passwd "${user}" | cut -d: -f6)

  printf "%s/%s" "${home}" "${authorized_keys_location}"
}

command="$1"
case "${command}" in
  get_authorized_keyfile)
    user="$2"
    keyfile_location=$(get_authorized_keys_location "${user}")

    if [ ! -e "${keyfile_location}" ]; then
      printf "Couldn't find authorized_keys for this user.\n"
      printf "Tried location: '%s'\n" "${keyfile_location}"
      exit 1
    fi

    cat "${keyfile_location}"
    exit 0
    ;;
  set_authorized_keyfile)
    user="$2"
    keyfile_location=$(get_authorized_keys_location "${user}")

    if [ -e "${keyfile_location}" ]; then
      file_head=$(head -n1 < "${keyfile_location}")

      if [ "${file_head}" != "${keyfile_head}" ]; then
        # Move keyfile to backup
        mv "${keyfile_location}" "${keyfile_location}.backup"
      fi
    fi

    # Read new authorized_keys from stdin
    printf "%s\n" "${keyfile_head}" > "${keyfile_location}"
    cat - >> "${keyfile_location}"
    exit 0
    ;;
  get_ssh_users)
    getent passwd | while IFS=: read -r name _password _uid _gid _gecos home _shell; do
      if [ -e "${home}/${authorized_keys_location}" ]; then
        printf "%s\n" "${name}"
      fi
    done
    exit 0
    ;;
  update)
    newfile="${0}.new"
    cat - > "${newfile}"

    mv "${newfile}" "${0}"
    exit 0
    ;;

  version)
    printf "%s\n" "${version}"
    exit 0
    ;;

  *)
    printf "Command '%s' not found.\n" "${command}"
    exit 2
    ;;
esac
