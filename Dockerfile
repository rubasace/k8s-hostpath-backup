FROM alpine

RUN apk add --no-cache curl bash tar && \
    curl -LO https://storage.googleapis.com/kubernetes-release/release/`curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt`/bin/linux/amd64/kubectl && \
    chmod +x ./kubectl && \
    mv ./kubectl /usr/local/bin/kubectl

COPY entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/entrypoint.sh

ENV BACKUP_UID 1000
ENV BACKUP_GID 999
ENV SLEEP_SECONDS 30
ENV BACKUP_NAME_PREFIX volumes-backup
ENV BACKUPS_TO_KEEP 3
ENV BACKUP_DIRECTORY /backup
ENV PERSISTENT_VOLUMES_ROOT /persistentVolumes
ENV BACKUP_IGNORE_CONFIG_FILE /config/dont-backup.txt

VOLUME ["/backup", "/persistentVolumes", "/config"]

ENTRYPOINT ["/app/entrypoint.sh"]