#!/bin/bash
#set -x
set -e

#Variables
BACKUP_TEMP_DIRECTORY="${BACKUP_DIRECTORY}/temp"
BACKUP_FILENAME="${BACKUP_TEMP_DIRECTORY}/${BACKUP_NAME_PREFIX}_$(date +%F_%H-%M-%S).tar"
created=false
directories=()
notFound=0

#TODO improve to get from the volumeclaim using jsonpath filters??
get_directories(){
  dir_names=("${PERSISTENT_VOLUMES_ROOT}"/*)
  for ((i=0; i<${#dir_names[@]}; i++)); do
    foundPath="${dir_names[$i]}"
    if [[ -d "$foundPath" ]]; then
      directories+=("$foundPath")
    else
      echo "${foundPath} is not a directory, ignoring"
    fi
  done
}

get_namespace(){
  kubectl get deployment -A --field-selector metadata.name="$1" -o=jsonpath="{..metadata.namespace}"
}

get_replicas(){
    {
      deployment=$1
      namespace=$2
      selfLink=$(kubectl get deployment.apps "${deployment}" -n "${namespace}" -o jsonpath={.metadata.selfLink})
      selector=$(kubectl get --raw "${selfLink}/scale" | jq -r .status.selector)
      kubectl get pods -n "${namespace}" --selector "${selector}" --no-headers  | wc -l | xargs
    } || echo -n 0

}

wait_till_scaled_down(){
  deployment=$1
  namespace=$2
  attempts=0
  echo -n "Waiting for $deployment to scale to 0"
  while [[ $(get_replicas "$deployment" "$namespace") -gt 0 ]]
  do
    (( attempts++ ))
    if [[ attempts -gt "$MAX_WAIT_SECONDS" ]]; then
      echo ""
      echo "Deployment $deployment didn't scale down in $MAX_WAIT_SECONDS seconds, aborting"
      return 2
    fi
    echo -n "."
    sleep 1
  done
  printf "\n%s succesfully scaled to 0\n" $deployment
}

#Scale deployment to 0
stop_deployment(){
  deployment=$1
  namespace=$2
  echo "###### Scaling down deployment $deployment ######"
  kubectl scale deployment "$deployment" -n "$namespace" --replicas=0 || return 1
}

#TODO stop hardcoding 1 replica and use previous number
#Scale deployment back up
restart_deployment(){
    deployment=$1
    namespace=$2
    echo "###### Scaling deployment $deployment back up ######"
    kubectl scale deployment "$deployment" -n "$namespace" --replicas=1 || true
}

backup_directory(){
  directory=$1
  echo "###### Backing up persistent volumes ######"
  if test -f "${BACKUP_IGNORE_CONFIG_FILE}"; then
      echo "### Files that will not be backed up: ###"
      cat "${BACKUP_IGNORE_CONFIG_FILE}"
      EXCLUSION_ARGUMENT="--exclude-from=${BACKUP_IGNORE_CONFIG_FILE}"
  fi
  if [ $created = true ]; then
    TAR_ARGUMENTS=-uf
  else
    TAR_ARGUMENTS=-cf
    created=true
  fi
  mkdir -p "${BACKUP_TEMP_DIRECTORY}"
  tar "$TAR_ARGUMENTS" "${BACKUP_FILENAME}" "${EXCLUSION_ARGUMENT}" "${directory}"
}

compress_backup (){
  echo "###### Compressing tar file ######"
  gzip -9 "${BACKUP_FILENAME}"
  echo "###### Finished compressing tar file ######"
}

remove_old_backups(){
    echo "###### Removing old backups. Keeping last ${BACKUPS_TO_KEEP} ######"
    #TODO change for find??
    rm -f $(ls -1td ${BACKUP_DIRECTORY}/${BACKUP_NAME_PREFIX}* | tail -n +$((BACKUPS_TO_KEEP+1)))
    echo "###### Finished removing old backups ######"
}

try_backup(){
  get_directories

  for ((i=0; i<${#directories[@]}; i++)); do
      directory="${directories[$i]}"
      deployment=$(basename "${directory}")
      namespace=$(get_namespace "$deployment")

      if stop_deployment "$deployment" "$namespace"; then
        wait_till_scaled_down "$deployment" "$namespace" || return 29
        backup_directory "$directory"
        restart_deployment "$deployment" "$namespace"
      else
        (( notFound++ ))
        backup_directory "$directory"
      fi

  done

  compress_backup
  compressedFile="${BACKUP_FILENAME}.gz"
  chown $BACKUP_UID:$BACKUP_GID "${compressedFile}"
  mv "$compressedFile" "$BACKUP_DIRECTORY/"

  echo "###### Finished Backing up persistent volumes ######"

  remove_old_backups

  if [ "$notFound" -eq "0" ]; then
     echo "Finished without warnings";
  else
     echo "Finished!! But there were $notFound directories without a deployment. Maybe they can be removed?"
  fi
}

fallback() {
  echo "Backup exited with error, will try to scale up directories and delete temporary file"
  for ((i=0; i<${#directories[@]}; i++)); do
        deployment=$(basename "${directories[$i]}")
        namespace=$(get_namespace "$deployment")
        restart_deployment "$deployment" "$namespace"
    done
    rm -f "$BACKUP_FILENAME"
    exit 29
}

try_backup || fallback