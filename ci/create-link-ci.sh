#!/bin/bash
set -e
set -x

cd ci/
ssh-keygen -t ed25519 -f ./gateway-sim-key -N ""

docker network create gateway || true   # create docker network if not exists
docker compose up -d --build
eval $(ssh-agent -s)
ssh-add ./gateway-sim-key


testLinkFile=""   # Define the variable in a scope outside the cleanup function

# Function to catch and cleanup containers/files if the script fails or is terminated prematurely.
# Good for local testing, eliminates the need to manually remove docker containers.
function cleanup {
    if [[ -n "$testLinkFile" ]]; then  # Check if the variable is non-empty
        echo "\n******* Cleanup function: \ncleaning up $testLinkFile..."
        docker compose -f "$testLinkFile" down --remove-orphans || true
        docker rm -f app-example-com || true

        rm "$testLinkFile" || true
    fi
}
trap cleanup EXIT


# Default Link test
normal_test_proceed=true
if [ "$normal_test_proceed" = true ]; then
    echo "******************* Test Default Link *******************"
    $testLinkFile="test-link.yaml"

    # generate a docker compose using templates + output
    cat test-link.template.yaml > $testLinkFile
    docker run --network gateway -e SSH_AGENT_PID=$SSH_AGENT_PID -e SSH_AUTH_SOCK=$SSH_AUTH_SOCK -v $SSH_AUTH_SOCK:$SSH_AUTH_SOCK --rm fractalnetworks/gateway-cli:latest $1 $2 $3 >> $testLinkFile
    cat network.yaml >> $testLinkFile
    # set the gateway endpoint to the gateway link container
    sed -i 's/^\(\s*GATEWAY_ENDPOINT:\).*/\1 app-example-com:18521/' $testLinkFile

    docker compose -f $testLinkFile up -d
    docker compose -f $testLinkFile exec link ping 10.0.0.1 -c 2
    # assert http response code was 200
    # asserts basic auth is working with user: admin, password: admin

    if ! docker compose exec gateway curl -k -H "Authorization: Basic YWRtaW46YWRtaW4=" --resolve app.example.com:443:127.0.0.1 https://app.example.com -I |grep "HTTP/2 200"; then
        FAILED="true"
    fi

    # cleanup
    cleanup
    # docker compose -f $testLinkFile down
    # docker rm -f app-example-com
    # rm $testLinkFile
else
    echo "******************* Skipping normal link test... \n(normal_test_greenlight was false)"
fi

# Caddy + TLS Link test
caddy_greenlight=true               # andrew's sentinel thing
if [ "$caddy_greenlight" = true ]; then
    echo "******************* Testing Caddy TLS Proxy Link *******************"
    # Test the link using  CADDY_TLS_PROXY: true
    testLinkFile="test-link-caddyTLS.yaml"

    # build new docker compose using template + output + template
    cat test-link-caddyTLS.template.yaml > $testLinkFile
    docker run --network gateway -e SSH_AGENT_PID=$SSH_AGENT_PID -e SSH_AUTH_SOCK=$SSH_AUTH_SOCK -v $SSH_AUTH_SOCK:$SSH_AUTH_SOCK --rm fractalnetworks/gateway-cli:latest $1 $2 $3 >> $testLinkFile
    cat network.yaml >> $testLinkFile

    # Go inside $testLinkFile and change... (requires the commented options to be there! Can change later)
    # 1. gateway endpoint to the gateway link container
    sed -i 's/^\(\s*GATEWAY_ENDPOINT:\).*/\1 app-example-com:18521/' $testLinkFile

    # 2. CADDY_TLS_PROXY to ------------------------------------- true
    sed -i 's/^\(\s*\)#\s*CADDY_TLS_PROXY: true/\1CADDY_TLS_PROXY: true/' $testLinkFile

    # 3. For self-signed certificates, `CADDY_TLS_INSECURE` can be used to 
    #    deactivate the certificate check.
    sed -i 's/^\(\s*\)#\s*CADDY_TLS_INSECURE: true/\1CADDY_TLS_INSECURE: true/' $testLinkFile
        # for #2 & #3, the comments from the template could be removed and instead appended in the "build new docker compose..." step from a template

    # 4. In the event you already have a reverse proxy which performs SSL termination for your 
    # apps/services you can enable FORWARD_ONLY mode. Suppose you are using Traefik for SSL 
    # termination... refer to the readme

    # docker compose -f $testLinkFile up > "$testLinkFile"-compose-up.log 2>&1
    docker compose -f $testLinkFile up -d
    docker compose -f $testLinkFile exec link ping 10.0.0.1 -c 2
    # assert http response code was 200
    # asserts basic auth is working with user: admin, password: admin

    if ! docker compose exec gateway curl -v -k -H "Authorization: Basic YWRtaW46YWRtaW4=" --resolve app.example.com:443:127.0.0.1 https://app.example.com -I 2>&1 | tee curl-output.log |grep "HTTP/2 200"; then
        FAILED="true"
    fi

    # cleanup
    cleanup
    # docker compose -f $testLinkFile down --remove-orphans
    # docker rm -f app-example-com
    # rm $testLinkFile
fi


# stop and remove gateway and sshd containers
docker compose down || echo "'docker compose down' at end of 'create-link-ci.sh' had an issue"

# if FAILED is true return 1 else 0
if [ ! -z ${FAILED+x} ]; then
    exit 1
fi
