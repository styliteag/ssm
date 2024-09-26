#!/usr/bin/env sh

command="$1"

case "${command}" in
  get_authorized_keyfile)
    user="$2"

    echo "Getting authorized keyfile for user ${user}"
    echo "not implemented"
    exit 1
    ;;
  set_authorized_keyfile)
    user="$2"
    new_keyfile=$(cat -)

    echo "Setting authorized keyfile for user ${user}"
    echo "not implemented"
    exit 1
    ;;
  get_ssh_users)
    echo "Getting all ssh users"
    echo "not implemented"
    exit 1
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
