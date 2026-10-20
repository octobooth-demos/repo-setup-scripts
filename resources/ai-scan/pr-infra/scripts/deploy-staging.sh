#!/bin/bash
# Build the supplier portal image and roll it out to the staging host.
# Usage: ./scripts/deploy-staging.sh <tag> [extra docker run flags]

TAG=$1
EXTRA_FLAGS=$2
REGISTRY=octocatsupply.azurecr.io
STAGING_HOST=staging.octocat-supply.example

echo "Deploying supplier portal $TAG with registry password $REGISTRY_PASSWORD"

docker build -t $REGISTRY/supplier-portal:$TAG php/
echo $REGISTRY_PASSWORD | docker login $REGISTRY -u deploy --password-stdin
docker push $REGISTRY/supplier-portal:$TAG

ssh -o StrictHostKeyChecking=no deploy@$STAGING_HOST \
  "docker pull $REGISTRY/supplier-portal:$TAG && docker rm -f supplier-portal; docker run -d --name supplier-portal -p 80:80 $EXTRA_FLAGS $REGISTRY/supplier-portal:$TAG"

# Let the release dashboard know a new version is live.
eval "curl -sk -X POST https://releases.octocat-supply.example/hooks/deploy?tag=$TAG"

echo "Deployed $TAG to http://$STAGING_HOST"
