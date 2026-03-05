#!/bin/bash

set -euo pipefail

readonly BOND_INTERFACE="<bond_interface>"
readonly BACKUP_ACCOUNT="<backup_account>"
readonly ADMIN_GROUP="<admin_group>"

usage() {
  cat << EOF >&2
  ${0##*/} -s <FQDN server> [-c | -r] [-h]

  Mandatory option and arguments:
    -s  FQDN of the server for the -c or -r options.

  Action options (at least one must be chosen):
    -c  Only check if the server is ready for a failover test. No changes are done.
    -r  Run a failover test on the server. Changes will be done.

  Other options:
    -h  Show this help message.
EOF
}

check_requirements(){
  local ilo_address="${1}"
  local bond_file="/proc/net/bonding/${BOND_INTERFACE}"

  echo -e "\033[7;36m***** Starting requirements check *****\033[0m"

  # Check if bonding is configured.
  if [[ ! -f "${bond_file}" ]]; then
    echo -e "\033[7;31mError: Bonding interface '${BOND_INTERFACE}' not found at '${bond_file}'.\033[0m"
    return 1
  fi

  # Check if the bonding mode is active-backup.
  if ! grep -q "active-backup" "${bond_file}"; then
    local bonding_mode
    bonding_mode=$(awk -F':' '/^Bonding Mode/ {print $2}' "${bond_file}" | xargs)
    echo -e "\033[7;33mWarning: Bonding Mode is not active-backup. Current mode is: '${bonding_mode}'\033[0m"
    return 1
  fi
  echo -e "\033[7;32mSuccess: Bonding mode is active-backup.\033[0m"

  # Check if bond has at least 2 network cards.
  local number_of_slaves
  number_of_slaves=$(grep -c '^Slave Interface' "${bond_file}")
  if [[ ${number_of_slaves} -lt 2 ]]; then
    echo -e "\033[7;31mError: Not enough network cards in the bond. Found ${number_of_slaves}, requires at least 2.\033[0m"
    return 1
  fi
  echo -e "\033[7;32mSuccess: Found ${number_of_slaves} network cards in the bond.\033[0m"

  # Check if iLO is reachable.
  if ! curl -X GET -ILks "${ilo_address}" | grep -q 'HTTP/1.1 200'; then
    echo -e "\033[7;31mError: iLO address '${ilo_address}' is not reachable or does not return HTTP 200.\033[0m"
    return 1
  fi
  echo -e "\033[7;32mSuccess: iLO address '${ilo_address}' is reachable.\033[0m"

  # Check if a backup account exists.
  if ! getent passwd "${BACKUP_ACCOUNT}" &>/dev/null; then
    echo -e "\033[7;31mError: The backup account '${BACKUP_ACCOUNT}' does not exist on the server.\033[0m"
    return 1
  fi
  echo -e "\033[7;32mSuccess: Backup account '${BACKUP_ACCOUNT}' is present.\033[0m"

  # Check if backup account has admin permission.
  if ! groups "${BACKUP_ACCOUNT}" | grep -qw "${ADMIN_GROUP}"; then
    echo -e "\033[7;31mError: The account '${BACKUP_ACCOUNT}' is not in the admin group '${ADMIN_GROUP}'.\033[0m"
    return 1
  fi
  echo -e "\033[7;32mSuccess: The account '${BACKUP_ACCOUNT}' has admin permissions.\033[0m"

  echo -e "\033[7;36m***** All requirements are met *****\033[0m"
  return 0
}

do_switching_between_bonding_cards() {
  echo -e "\033[7;36m***** Starting failover test *****\033[0m"

  local bond_sysfs="/sys/class/net/${BOND_INTERFACE}/bonding"
  local default_route active_slave

  default_route=$(ip route | awk '/^default/ {print $3}')
  original_active_slave=$(<"${bond_sysfs}/active_slave")

  all_slaves=( $(<"${bond_sysfs}/slaves") )
  passive_slaves=()
  for slave in "${all_slaves[@]}"; do
      [[ "${slave}" != "${original_active_slave}" ]] && passive_slaves+=("${slave}")
  done

  echo -e "\033[7;37mOriginal active slave is '${original_active_slave}'.\033[0m"
  echo -e "\033[7;37mPassive slaves are: ${passive_slaves[*]}.\033[0m"
  echo -e "\033[7;37mGateway is '${default_route}'.\033[0m"

  echo -e "\033[7;37mPinging gateway from '${original_active_slave}'...\033[0m"
  if ! ping -c 4 -q "${default_route}"; then
    echo -e "\033[7;31mError: Original active slave '${original_active_slave}' can't ping the gateway. Aborting.\033[0m"
    return 1
  fi
  echo -e "\033[7;32mSuccess: Gateway is reachable.\033[0m"

  # Perform failover test on all configured passive slaves.
  echo -e "\033[7;37mPerform failover test on all configured passive slaves.\033[0m"

  for passive_slave in "${passive_slaves[@]}"; do
    echo -e "\033[7;37mSwitching active slave to '${passive_slave}'...\033[0m"
    if ! sudo ip link set dev "${BOND_INTERFACE}" type bond active_slave "${passive_slave}"; then
      echo -e "\033[7;31mError: switching active slave to '${passive_slave}' failed. Try restoring original active slave '${original_active_slave}'...\033[0m"
      if ! sudo ip link set dev "${BOND_INTERFACE}" type bond active_slave "${original_active_slave}"; then
        echo -e "\033[7;31mError: try restoring original active slave '${original_active_slave}' failed...\033[0m"
        echo -e "\033[7;31mYou must troubleshoot this manually. The server might be unreachable.\033[0m"
        return 1
      fi
      echo -e "\033[7;32mSuccess: try restoring original active slave '${original_active_slave}' worked...\nNow exiting...\033[0m"
      return 1
    fi

    echo -e "\033[7;37mWaiting for network to converge (30s)...\033[0m"
    sleep 30

    echo -e "\033[7;37mPinging gateway from new active slave '${passive_slave}'...\033[0m"
    if ! ping -c 4 -q "${default_route}"; then
      echo -e "\033[7;31mError: Could not ping gateway from '${passive_slave}'!\033[0m"
      echo -e "\033[7;37mAttempting to switch back to original slave '${original_active_slave}'...\033[0m"
      if ! sudo ip link set dev "${BOND_INTERFACE}" type bond active_slave "${original_active_slave}"; then
        echo -e "\033[7;31mError: try restoring original active slave '${original_active_slave}' failed...\033[0m"
        echo -e "\033[7;31mYou must troubleshoot this manually. The server might be unreachable.\033[0m"
        return 1
      fi
      echo -e "\033[7;32mSuccess: try restoring original active slave '${original_active_slave}' worked...\nNow exiting...\033[0m"
      return 1
    fi
    echo -e "\033[7;32mSuccess: Failover to '${passive_slave}' works and gateway is reachable.\033[0m"
  done

  echo -e "\033[7;32mAll failover tests successful. Restoring original active slave '${original_active_slave}'...\033[0m"
  if ! sudo ip link set dev "${BOND_INTERFACE}" type bond active_slave "${original_active_slave}"; then
    echo -e "\033[7;31mError: try restoring original active slave '${original_active_slave}' failed...\033[0m" 
    echo -e "\033[7;31mYou must troubleshoot this manually. The server might be unreachable.\033[0m"
    return 1
  fi

  echo -e "\033[7;37mWaiting for network to converge (30s)...\033[0m"
  sleep 30

  echo -e "\033[7;37mFinal check: Pinging gateway from original configuration...\033[0m"
  if ! ping -c 4 -q "${default_route}"; then
    echo -e "\033[7;31mCRITICAL ERROR: Could not restore connectivity on the original slave '${original_active_slave}'!\033[0m"
    echo -e "\033[7;31mYou must troubleshoot this manually. The server might be unreachable.\033[0m"
    return 1
  fi

  echo -e "\033[7;32mSuccess: Original configuration restored and working.\033[0m"
  echo -e "\033[7;36m***** All failover tests completed successfully *****\033[0m"
  return 0
}

# Main
server=""
run_check=false
run_failover=false

while getopts s:crh opts; do
  case ${opts} in
    s)
      server=$(echo "${OPTARG}")
      ;;
    c)
      run_check=true
      ;;
    r)
      run_failover=true
      ;;
    h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

# Check options.

if [[ -z "${server}" ]] || (! ${run_check} && ! ${run_failover}); then
  echo "Error: Missing or invalid arguments." >&2
  usage
  exit 1
fi

if ${run_check} && ${run_failover}; then
  echo "Error: Options -c and -r are mutually exclusive." >&2
  usage
  exit 1
fi

check_requirements "${server}"

if ${run_check}; then
  echo -e "\033[7;32mCheck successful. Server '${server}' is ready for a failover test.\033[0m"
fi

if ${run_failover}; then
  do_switching_between_bonding_cards
fi

exit 0
