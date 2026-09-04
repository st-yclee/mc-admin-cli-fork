#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly JENKINS_CONTAINER="${MCMP_JENKINS_CONTAINER_NAME:-mc-workflow-manager-jenkins}"
readonly ENCRYPTED_CREDENTIALS_FILE="${MCMP_CREDENTIALS_FILE:-$HOME/.cloud-barista/credentials.yaml.enc}"
readonly DECRYPT_KEY_FILE="${MCMP_CREDENTIALS_KEY_FILE:-$HOME/.cloud-barista/.tmp_enc_key}"
readonly GROOVY_SCRIPT="$SCRIPT_DIR/jenkins-credentials.groovy"
readonly REGISTRATION_MARKER="/var/jenkins_home/.mcmp-object-storage-credentials-initialized"
readonly MAX_PASSWORD_ATTEMPTS=3

MCMP_JENKINS_COOKIE_FILE=""

cleanup_jenkins_cookie() {
    if [ -n "$MCMP_JENKINS_COOKIE_FILE" ]; then
        rm -f -- "$MCMP_JENKINS_COOKIE_FILE"
    fi
}

run_inside_container() {
    : "${JENKINS_USERNAME:?JENKINS_USERNAME must not be empty}"
    : "${JENKINS_PASSWORD:?JENKINS_PASSWORD must not be empty}"

    local jenkins_url="http://localhost:8080"
    local crumb_header

    MCMP_JENKINS_COOKIE_FILE=$(mktemp /tmp/mcmp-jenkins-cookie.XXXXXX)
    trap cleanup_jenkins_cookie EXIT

    crumb_header=$(curl -fsS \
        --user "$JENKINS_USERNAME:$JENKINS_PASSWORD" \
        --cookie-jar "$MCMP_JENKINS_COOKIE_FILE" \
        "$jenkins_url/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")

    if [ -z "$crumb_header" ]; then
        echo "Error: Jenkins returned an empty CSRF crumb." >&2
        return 1
    fi

    curl -fsS \
        --user "$JENKINS_USERNAME:$JENKINS_PASSWORD" \
        --cookie "$MCMP_JENKINS_COOKIE_FILE" \
        --header "$crumb_header" \
        --data-urlencode "script@-" \
        "$jenkins_url/scriptText"
}

if [ "${1:-}" = "--inside-container" ]; then
    if [ "$#" -ne 1 ]; then
        echo "Error: --inside-container does not accept additional arguments." >&2
        exit 1
    fi
    run_inside_container
    exit $?
fi

force_registration=false
case "${1:-}" in
    "")
        ;;
    --force)
        force_registration=true
        ;;
    *)
        echo "Usage: $0 [--force]" >&2
        exit 1
        ;;
esac

for command_name in docker openssl; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: $command_name is required to register Jenkins credentials." >&2
        exit 1
    fi
done

if [ ! -f "$GROOVY_SCRIPT" ]; then
    echo "Error: Jenkins credential script not found: $GROOVY_SCRIPT" >&2
    exit 1
fi

container_running=$(docker inspect --format '{{.State.Running}}' "$JENKINS_CONTAINER" 2>/dev/null || true)
if [ "$container_running" != "true" ]; then
    echo "Error: Jenkins container is not running: $JENKINS_CONTAINER" >&2
    exit 1
fi

echo "Waiting for Jenkins initialization to complete..."
jenkins_ready=false
for ((attempt = 1; attempt <= 120; attempt++)); do
    health_status=$(docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$JENKINS_CONTAINER" 2>/dev/null || true)
    if [ "$health_status" = "healthy" ]; then
        jenkins_ready=true
        break
    fi
    sleep 5
done

if [ "$jenkins_ready" != "true" ]; then
    echo "Error: Jenkins did not become healthy within 10 minutes." >&2
    exit 1
fi

if [ "$force_registration" != "true" ] && \
    docker exec "$JENKINS_CONTAINER" test -f "$REGISTRATION_MARKER"; then
    echo "Jenkins credentials are already initialized; skipping registration."
    exit 0
fi

if [ ! -f "$ENCRYPTED_CREDENTIALS_FILE" ] || [ ! -s "$ENCRYPTED_CREDENTIALS_FILE" ]; then
    echo "Encrypted CSP credentials not found or empty; skipping Jenkins credential registration:"
    echo "  $ENCRYPTED_CREDENTIALS_FILE"
    echo "Register the credentials manually in the Jenkins UI."
    exit 0
fi

encoded_credentials_yaml=""
credentials_decrypted=false
if [ -s "$DECRYPT_KEY_FILE" ]; then
    echo "Using the host key file for this one-time registration: $DECRYPT_KEY_FILE"
    if encoded_credentials_yaml=$(
        openssl enc -aes-256-cbc -d -pbkdf2 \
            -in "$ENCRYPTED_CREDENTIALS_FILE" \
            -pass "file:$DECRYPT_KEY_FILE" 2>/dev/null |
            openssl base64 -A
    ); then
        credentials_decrypted=true
    else
        encoded_credentials_yaml=""
        echo "Warning: failed to decrypt credentials.yaml.enc with .tmp_enc_key." >&2
    fi
fi

if [ "$credentials_decrypted" != "true" ] && [ -t 0 ]; then
    for ((attempt = 1; attempt <= MAX_PASSWORD_ATTEMPTS; attempt++)); do
        credential_password=""
        IFS= read -r -s -p "Enter the credentials.yaml.enc password ($attempt/$MAX_PASSWORD_ATTEMPTS): " credential_password || credential_password=""
        printf '\n'

        if [ -z "$credential_password" ]; then
            echo "Warning: a decryption password is required ($attempt/$MAX_PASSWORD_ATTEMPTS)." >&2
            continue
        fi

        if encoded_credentials_yaml=$(
            printf '%s\n' "$credential_password" |
                openssl enc -aes-256-cbc -d -pbkdf2 \
                    -in "$ENCRYPTED_CREDENTIALS_FILE" \
                    -pass stdin 2>/dev/null |
                openssl base64 -A
        ); then
            credentials_decrypted=true
            unset credential_password
            break
        fi

        encoded_credentials_yaml=""
        unset credential_password
        echo "Warning: failed to decrypt credentials.yaml.enc with the entered password ($attempt/$MAX_PASSWORD_ATTEMPTS)." >&2
    done
fi

if [ "$credentials_decrypted" != "true" ]; then
    echo "Unable to decrypt credentials.yaml.enc; skipping Jenkins credential registration."
    echo "Register the credentials manually in the Jenkins UI."
    exit 0
fi

if [ -z "$encoded_credentials_yaml" ]; then
    echo "Error: decrypted CSP credentials are empty." >&2
    exit 1
fi

if ! registration_output=$(
    {
        printf 'encodedCredentialsYaml = "%s"\n' "$encoded_credentials_yaml"
        sed -n '1,$p' "$GROOVY_SCRIPT"
    } | docker exec -i "$JENKINS_CONTAINER" \
        /opt/mcmp/jenkins-credentials/register-credentials.sh --inside-container
); then
    unset encoded_credentials_yaml
    echo "Error: failed to send credentials to Jenkins." >&2
    exit 1
fi
unset encoded_credentials_yaml

registration_complete=false
while IFS= read -r output_line; do
    case "$output_line" in
        MCMP_OBJECT_STORAGE_CREDENTIAL_REGISTERED\ *|MCMP_OBJECT_STORAGE_CREDENTIAL_SKIPPED\ *)
            printf '%s\n' "$output_line"
            ;;
        MCMP_OBJECT_STORAGE_CREDENTIALS_COMPLETE)
            registration_complete=true
            ;;
    esac
done <<< "$registration_output"

if [ "$registration_complete" != "true" ]; then
    echo "Error: Jenkins did not confirm credential registration." >&2
    exit 1
fi

echo "Jenkins credential registration is complete."
