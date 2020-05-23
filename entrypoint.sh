#!/bin/bash
#set -x
set -e

#Variables
BACKUP_FILENAME="${BACKUP_DIRECTORY}/${BACKUP_NAME_PREFIX}_$(date +%F_%R).tar.gz"
TEMP_BACKUP_FILENAME="${BACKUP_FILENAME}.tmp"
deployments=()
notFound=0

#TODO improve to get from the volumeclaim using jsonpath filters??
get_deployment_names(){

  dir_names=("${PERSISTENT_VOLUMES_ROOT}"/*)
  for ((i=0; i<${#dir_names[@]}; i++)); do
    foundPath="${dir_names[$i]}"
    if [[ -d "$foundPath" ]]; then
      deployment=$(basename "${foundPath}")
      deployments+=("$deployment")
    else
      echo "${foundPath} is not a directory, ignoring"
    fi
  done
}

get_namespace(){
  kubectl get deployment -A --field-selector metadata.name="$1" -o=jsonpath="{..metadata.namespace}"
}

#Scale deployments to 0
stop_deployments(){
    echo "###### Scaling down deployments ######"
    for ((i=0; i<${#deployments[@]}; i++)); do
        deployment="${deployments[$i]}"
        namespace=$(get_namespace "$deployment")
        kubectl scale deployment "$deployment" -n "$namespace" --replicas=0 || ((notFound++)) || true
    done
    echo "###### Finished scaling down deployments ######"
}

#TODO stop hardcoding 1 replica and use previous number
#Scale deployments back up
start_stopped_deployments(){
    echo "###### Scaling deployments back up ######"
    for ((i=0; i<${#deployments[@]}; i++)); do
        deployment="${deployments[$i]}"
        namespace=$(get_namespace "$deployment")
        kubectl scale deployment "$deployment" -n "$namespace" --replicas=1 || true
    done
    echo "###### Finished scaling up deployments ######"
}


backup(){
    echo "###### Backing up persistent volumes ######"
    if test -f "${BACKUP_IGNORE_CONFIG_FILE}"; then
        echo "### Files that will not be backed up: ###"
        cat "${BACKUP_IGNORE_CONFIG_FILE}"
        EXCLUSION_ARGUMENT="--exclude-from=${BACKUP_IGNORE_CONFIG_FILE}"
    fi
    mkdir -p "${BACKUP_DIRECTORY}"
    tar -cpzf "${TEMP_BACKUP_FILENAME}" "${EXCLUSION_ARGUMENT}" "${PERSISTENT_VOLUMES_ROOT}"

    mv "${TEMP_BACKUP_FILENAME}" "${BACKUP_FILENAME}"
    chown $BACKUP_UID:$BACKUP_GID "${BACKUP_FILENAME}"
    echo "###### Finished Backing up persistent volumes ######"
}

remove_old_backups(){
    echo "###### Removing old backups. Keeping last ${BACKUPS_TO_KEEP} ######"
    #TODO change for find??
    rm -f $(ls -1td ${BACKUP_DIRECTORY}/${BACKUP_NAME_PREFIX}* | tail -n +$((BACKUPS_TO_KEEP+1)))
    echo "###### Finished removing old backups ######"
}

try_backup(){
  touch "$TEMP_BACKUP_FILENAME"
  get_deployment_names
  stop_deployments
  echo "Giving ${SLEEP_SECONDS} seconds to deployments to scale down"
  sleep $SLEEP_SECONDS
  backup
  start_stopped_deployments
  remove_old_backups
  if [ "$notFound" -eq "0" ]; then
     echo "Finished without warnings";
  else
     echo "Finished!! But there were $notFound directories without a deployment. Maybe they can be removed?"
  fi
}

fallback() {
  echo "Backup exited with error, will try to scale up deployments and delete temporary file"
  start_stopped_deployments
  rm -f "$TEMP_BACKUP_FILENAME"
}

try_backup || fallback

#TODO try to do incremental, so we can minimize time down per application