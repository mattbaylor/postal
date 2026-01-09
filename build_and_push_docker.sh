#!/bin/bash
# Build and push Docker image for AMD64 architecture to Docker Hub
# This script builds the multi-hash cache enhancement and pushes it to mattbaylor/postalserver

set -e

echo "==== Building and Pushing Postal Docker Image ===="
echo ""

# Version info
NEW_VERSION="3.3.4-edify.6"
echo "Building version: $NEW_VERSION"
echo ""

# Step 1: Ensure Docker login
echo "Step 1: Checking Docker Hub login..."
# Check if we can access Docker Hub repos (better test than 'docker info')
if ! docker pull mattbaylor/postalserver:3.3.4-edify.5 > /dev/null 2>&1; then
    echo "Docker Hub access check failed. Please ensure you're logged in:"
    echo "  docker login"
    exit 1
fi

echo "✓ Docker login confirmed"
echo ""

# Step 2: Build for AMD64 and push
echo "Step 2: Building Docker image for AMD64 architecture..."
echo "This will take approximately 10-15 minutes..."
echo ""

docker buildx build \
  --platform linux/amd64 \
  --builder multiarch \
  --target full \
  -t mattbaylor/postalserver:${NEW_VERSION} \
  --push \
  .

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Build and push completed successfully!"
    echo ""
    echo "Images pushed to Docker Hub:"
    echo "  - mattbaylor/postalserver:${NEW_VERSION}"
    echo ""
else
    echo ""
    echo "✗ Build failed!"
    exit 1
fi

# Step 3: Tag the git commit
echo "Step 3: Creating git tag..."
if git rev-parse "${NEW_VERSION}" >/dev/null 2>&1; then
    echo "Note: Git tag ${NEW_VERSION} already exists, skipping"
else
    if git tag -a "${NEW_VERSION}" -m "Fix multi-line DKIM header normalization in scan cache"; then
        echo "✓ Git tag created: ${NEW_VERSION}"
        echo ""
        echo "To push the tag to GitHub, run:"
        echo "  git push origin ${NEW_VERSION}"
    else
        echo "Warning: Could not create git tag"
    fi
fi

echo ""
echo "==== Next Steps ===="
echo ""
echo "1. Pull the new image on e1.edify.press:"
echo "   ssh root@e1.edify.press"
echo "   docker compose pull"
echo "   docker compose down && docker compose up -d"
echo ""
echo "2. Run the migration on e1:"
echo "   WORKER=\$(docker ps --filter 'name=worker' --format '{{.Names}}' | head -1)"
echo "   docker exec \$WORKER rails db:migrate"
echo "   docker restart \$(docker ps --filter 'name=worker' --format '{{.Names}}')"
echo ""
echo "3. Repeat steps 1-2 on e2.edify.press"
echo ""
echo "4. Monitor logs:"
echo "   docker logs -f \$WORKER | grep -i cache"
echo ""
echo "5. Test with personalized emails"
echo ""
