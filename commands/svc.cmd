#!/usr/bin/env bash
[[ ! ${WARDEN_DIR} ]] && >&2 echo -e "\033[31mThis script is not intended to be run directly!\033[0m" && exit 1

source "${WARDEN_DIR}/utils/install.sh"
assertWardenInstall
assertDockerRunning

if (( ${#WARDEN_PARAMS[@]} == 0 )) || [[ "${WARDEN_PARAMS[0]}" == "help" ]]; then
  warden svc --help || exit $? && exit $?
fi

## allow return codes from sub-process to bubble up normally
trap '' ERR

## configure docker compose files
DOCKER_COMPOSE_ARGS=()

DOCKER_COMPOSE_ARGS+=("-f")
DOCKER_COMPOSE_ARGS+=("${WARDEN_DIR}/docker/docker compose.yml")

## special handling when 'svc up' is run
if [[ "${WARDEN_PARAMS[0]}" == "up" ]]; then

    ## sign certificate used by global services (by default warden.test)
    if [[ -f "${WARDEN_HOME_DIR}/.env" ]]; then
        eval "$(grep "^WARDEN_SERVICE_DOMAIN" "${WARDEN_HOME_DIR}/.env")"
    fi

    WARDEN_SERVICE_DOMAIN="${WARDEN_SERVICE_DOMAIN:-warden.test}"
    if [[ ! -f "${WARDEN_SSL_DIR}/certs/${WARDEN_SERVICE_DOMAIN}.crt.pem" ]]; then
        "${WARDEN_DIR}/bin/warden" sign-certificate "${WARDEN_SERVICE_DOMAIN}"
    fi

    ## copy configuration files into location where they'll be mounted into containers from
    mkdir -p "${WARDEN_HOME_DIR}/etc/traefik"
    cp "${WARDEN_DIR}/config/traefik/traefik.yml" "${WARDEN_HOME_DIR}/etc/traefik/traefik.yml"

    ## generate dynamic traefik ssl termination configuration
    cat > "${WARDEN_HOME_DIR}/etc/traefik/dynamic.yml" <<-EOT
		tls:
		  stores:
		    default:
		    defaultCertificate:
		      certFile: /etc/ssl/certs/${WARDEN_SERVICE_DOMAIN}.crt.pem
		      keyFile: /etc/ssl/certs/${WARDEN_SERVICE_DOMAIN}.key.pem
		  certificates:
	EOT

    for cert in $(find "${WARDEN_SSL_DIR}/certs" -type f -name "*.crt.pem" | sed -E 's#^.*/ssl/certs/(.*)\.crt\.pem$#\1#'); do
        cat >> "${WARDEN_HOME_DIR}/etc/traefik/dynamic.yml" <<-EOF
		    - certFile: /etc/ssl/certs/${cert}.crt.pem
		      keyFile: /etc/ssl/certs/${cert}.key.pem
		EOF
    done

    ## always execute svc up using --detach mode
    if ! (containsElement "-d" "$@" || containsElement "--detach" "$@"); then
        WARDEN_PARAMS=("${WARDEN_PARAMS[@]:1}")
        WARDEN_PARAMS=(up -d "${WARDEN_PARAMS[@]}")
    fi
fi

## pass ochestration through to docker compose
docker compose \
    --project-directory "${WARDEN_HOME_DIR}" -p warden \
    "${DOCKER_COMPOSE_ARGS[@]}" "${WARDEN_PARAMS[@]}" "$@"

## connect peered service containers to environment networks when 'svc up' is run
if [[ "${WARDEN_PARAMS[0]}" == "up" ]]; then
    for network in $(docker network ls -f label=dev.warden.environment.name --format {{.Name}}); do
        connectPeeredServices "${network}"
    done
fi
