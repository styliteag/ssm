#!/usr/bin/env sh

set -eu

# shellcheck disable=SC3040
(set -o pipefail 2> /dev/null) && set -o pipefail

authorized_keys_location=".ssh/authorized_keys"
version="Secure SSH Manager script v0.3-alpha"
keyfile_head="# Auto-generated by Secure SSH Manager. DO NOT EDIT!"

cleanup() {
    rm -f "${TMP}/homedirs.$$"
}
trap cleanup EXIT INT TERM

TMP="${TMPDIR:-/tmp}"

have_getent() {
  command -v getent >/dev/null 2>&1
}

do_getent_passwd_all() {
  if have_getent; then
    getent passwd
  else
    cat /etc/passwd
  fi
}

do_getent_passwd() {
  login="$1"
  if have_getent; then
    getent passwd "${login}"
  else
    grep "^${login}:" /etc/passwd
  fi
}

# TODO: Read authorized_keys location from sshd config
# Get the location of the authorized keyfile given a login
get_authorized_keys_location() {
  login="$1"
  home=$(do_getent_passwd "${login}" | cut -d: -f6)
  
  echo "${home}/${authorized_keys_location}"
}

# Check if the system has any condition that make the keyfile externally
# managed or readonly. Returns only the first met condition
check_keyfile_condition() {
    login="$1"

    # Check for global override
    system_readonly="${HOME}/.ssh/system_readonly"
    if [ -f "${system_readonly}" ]; then
        content=$(cat "${system_readonly}")
        if [ -n "${content}" ]; then
            printf "%s" "${content}"
        else
            printf "Global overrride '%s' exists" "${system_readonly}"
        fi
        return 0
    fi
    
    # Check for user override
    home=$(do_getent_passwd "${login}" | cut -d: -f6)
    user_readonly="${home}/.ssh/user_readonly"
    if [ -f "${user_readonly}" ]; then
        content=$(cat "${user_readonly}")
        if [ -n "${content}" ]; then
            printf "%s" "${content}"
        else
            printf "Local override '%s' exists" "${user_readonly}"
        fi
        return 0
    fi
    
    # Check for specific systems:
    # PfSense
    if grep -qs "pfSense" "/etc/platform"; then
        echo "Product is pfSense"
        return 0
    fi

    # Truenas core
    if uname -a | grep -qs "TRUENAS"; then
        echo "Product is Truenas Core"
        return 0
    fi

    # Truenas Scale
    if uname -a | grep -qs "+truenas "; then
        echo "Product is Truenas Scale"
        return 0
    fi

    # Sophos
    if [ -f "/etc/product" ] && grep -qs "Sophos UTM" "/etc/product"; then
        echo "Product is Sophos UTM"
        return 0
    fi
}

get_authorized_keyfile_for() {
    login="$1"
    keyfile_location=$(get_authorized_keys_location "${login}")

    if [ ! -e "${keyfile_location}" ]; then
        echo "Couldn't find authorized_keys for this login."
        echo "Tried location: ${keyfile_location}"
        exit 1
    fi

    cat "${keyfile_location}"
    echo ""
    exit 0
}

handle_set_authorized_keyfile() {
    login="$1"
    keyfile_location=$(get_authorized_keys_location "${login}")

    readonly_condition=$(check_keyfile_condition "${login}")
    if [ -n "${readonly_condition}" ]; then
        echo "Keyfile is readonly, aborting."
        exit 1
    fi

    if [ -e "${keyfile_location}" ]; then
        file_head=$(head -n1 < "${keyfile_location}")

        if [ "${file_head}" != "${keyfile_head}" ]; then
            mv "${keyfile_location}" "${keyfile_location}.backup"
        fi
    fi

    printf "%s\n" "${keyfile_head}" > "${keyfile_location}"
    cat - >> "${keyfile_location}"
    exit 0
}

get_ssh_users() {
    printf "" > "${TMP}/homedirs.$$"
    
    do_getent_passwd_all | while IFS=: read -r name _password _uid _gid _gecos home _shell; do
            if [ -e "${home}/${authorized_keys_location}" ]; then
                grep "^${home}\$" "${TMP}/homedirs.$$" >/dev/null 2>&1 || echo "${name}"
                echo "${home}" >> "${TMP}/homedirs.$$"
            fi
        done
    rm -f "${TMP}/homedirs.$$"
    exit 0
}

handle_get_ssh_keyfiles() {
    isFirst=true
    printf "["
      get_ssh_users | while read -r login; do
            keyfile=$(get_authorized_keyfile_for "${login}")
            if [ "${isFirst}" = true ]; then
                isFirst=false
            else
                printf ','
            fi

            has_pragma="false"
            readonly_condition=$(check_keyfile_condition "${login}")

            # When file is readonly there is no point in checking the pragma
            if [ -n "${readonly_condition}" ]; then
                has_pragma="true"
            else
                head=$(printf "%s" "${keyfile}" | head -n1)
                [ "${head}" = "${keyfile_head}" ] && has_pragma="true"
            fi

            printf '{"login":"%s", "has_pragma": %s, "readonly_condition": "%s",' "${login}" "${has_pragma}" "${readonly_condition}"

            # Remove carriage returns
            # Escape double quotes and newlines
            printf '"keyfile":"%s"}' "$(printf "%s" "${keyfile}" | tr -d '\r' | sed 's/\"/\\\"/g' | awk 1 ORS='\\n' )"
      done
    printf "]"
}

handle_update() {
    newfile="${0}.new"
    cat - > "${newfile}"
    # Can we check if the new file is valid?
    mv "${newfile}" "${0}"
    exit 0
}

handle_version() {
    sha256=$(sha256sum "${0}" | awk '{ print $1 }')
    printf '{"version":"%s","sha256":"%s"}' "${version}" "${sha256}"
    exit 0
}

#####################################
# Script starts here
#####################################

# Modify the command handling section
if [ $# -eq 0 ]; then
    printf "No command argument found"
    exit 2
fi

command="$1"
shift
case "${command}" in
    set_authorized_keyfile)  handle_set_authorized_keyfile "$@" ;;
    get_ssh_keyfiles)        handle_get_ssh_keyfiles ;;
    update)                  handle_update ;;
    version)                 handle_version ;;
    *)
        printf "Command '%s' not found.\n" "${command}"
        exit 2
        ;;
esac
