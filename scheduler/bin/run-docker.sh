#!/usr/bin/env bash

# Usage: ./bin/run-docker.sh [OPTIONS...]
# Runs the cook scheduler inside a docker container.
#   --auth={http-basic,one-user}    Use the specified authentication scheme. Default is one-user.
#   --executor={cook,mesos}         Use the specified job executor. Default is cook.

set -e

# Defaults (overridable via environment)
: ${COOK_PORT:=12321}
: ${COOK_NREPL_PORT:=8888}
: ${COOK_FRAMEWORK_ID:=cook-framework-$(date +%s)}
: ${COOK_AUTH:=one-user}
: ${COOK_EXECUTOR:=cook}

while (( $# > 0 )); do
  case "$1" in
    --auth=*)
      COOK_AUTH="${1#--auth=}"
      shift
      ;;
    --executor=*)
      COOK_EXECUTOR="${1#--executor=}"
      shift
      ;;
    *)
      echo "Unrecognized option: $1"
      exit 1
  esac
done

case "$COOK_AUTH" in
  http-basic)
    export COOK_HTTP_BASIC_AUTH=true
    export COOK_EXECUTOR_PORTION=0
    ;;
  one-user)
    export COOK_EXECUTOR_PORTION=1
    ;;
  *)
    echo "Unrecognized auth scheme: $COOK_AUTH"
    exit 1
esac

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NAME=cook-scheduler-${COOK_PORT}

if [ "$(docker ps -aq -f name=${NAME})" ]; then
    # Cleanup
    docker rm ${NAME}
fi

$(minimesos info | grep MINIMESOS)
EXIT_CODE=$?
if [ ${EXIT_CODE} -eq 0 ]
then
    ZK=${MINIMESOS_ZOOKEEPER%;}
    echo "ZK = ${ZK}"
    echo "MINIMESOS_MASTER_IP = ${MINIMESOS_MASTER_IP}"
else
    echo "Could not get ZK URI from minimesos; you may need to restart minimesos"
    exit ${EXIT_CODE}
fi

SCHEDULER_DIR="$( dirname ${DIR} )"
SCHEDULER_EXECUTOR_DIR=${SCHEDULER_DIR}/resources/public
EXECUTOR_NAME=cook-executor

case "$COOK_EXECUTOR" in
  cook)
    echo "$(date +%H:%M:%S) Cook executor has been enabled"
    COOK_EXECUTOR_COMMAND="./${EXECUTOR_NAME}/${EXECUTOR_NAME}"
    ;;
  mesos)
    COOK_EXECUTOR_COMMAND=""
    ;;
  *)
    echo "Unrecognized executor: $EXECUTOR"
    exit 1
esac

if [ -z "$(docker network ls -q -f name=cook_nw)" ];
then
    # Using a separate network allows us to access hosts by name (cook-scheduler-12321)
    # instead of IP address which simplifies configuration
    echo "Creating cook_nw network"
    docker network create -d bridge --subnet 172.25.0.0/16 cook_nw
fi

if [ -z "${COOK_DATOMIC_URI}" ];
then
    COOK_DATOMIC_URI="datomic:mem://cook-jobs"
fi

if [ "${COOK_ZOOKEEPER_LOCAL}" = false ] ; then
    COOK_ZOOKEEPER="${MINIMESOS_ZOOKEEPER_IP}:2181"
else
    COOK_ZOOKEEPER=""
    COOK_ZOOKEEPER_LOCAL=true
fi

echo "Starting cook..."

# NOTE: since the cook scheduler directory is mounted as a volume
# by the minimesos agents, they have access to the cook-executor binary
# using the absolute file path URI given for COOK_EXECUTOR below.
docker create \
    -i \
    -t \
    --rm \
    --name=${NAME} \
    --publish=${COOK_NREPL_PORT}:${COOK_NREPL_PORT} \
    --publish=${COOK_PORT}:${COOK_PORT} \
    -e "COOK_EXECUTOR=file://${SCHEDULER_EXECUTOR_DIR}/${EXECUTOR_NAME}.tar.gz" \
    -e "COOK_EXECUTOR_COMMAND=${COOK_EXECUTOR_COMMAND}" \
    -e "COOK_PORT=${COOK_PORT}" \
    -e "COOK_NREPL_PORT=${COOK_NREPL_PORT}" \
    -e "COOK_FRAMEWORK_ID=${COOK_FRAMEWORK_ID}" \
    -e "MESOS_MASTER=${ZK}" \
    -e "MESOS_MASTER_HOST=${MINIMESOS_MASTER_IP}" \
    -e "COOK_ZOOKEEPER=${COOK_ZOOKEEPER}" \
    -e "COOK_ZOOKEEPER_LOCAL=${COOK_ZOOKEEPER_LOCAL}" \
    -e "COOK_HOSTNAME=${NAME}" \
    -e "COOK_DATOMIC_URI=${COOK_DATOMIC_URI}" \
    -e "COOK_LOG_FILE=log/cook-${COOK_PORT}.log" \
    -e "COOK_HTTP_BASIC_AUTH=${COOK_HTTP_BASIC_AUTH:-false}" \
    -e "COOK_ONE_USER_AUTH=root" \
    -e "COOK_EXECUTOR_PORTION=${COOK_EXECUTOR_PORTION:-0}" \
    -v ${DIR}/../log:/opt/cook/log \
    cook-scheduler:latest ${COOK_CONFIG:-}

docker network connect bridge ${NAME}
docker network connect cook_nw ${NAME}
docker start -ai ${NAME}

# If Cook is not starting, you may be able to troubleshoot by
# adding the following line right after the `docker run` line:
#
#    --entrypoint=/bin/bash \
#
# This will override the ENTRYPOINT baked into the Dockerfile
# and instead give you an interactive bash shell.
