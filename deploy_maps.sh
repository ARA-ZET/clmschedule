#!/bin/bash

# Script to build and deploy the standalone CLM Maps app
# Deploys to: https://clm-maps.web.app
# Usage: ./deploy_maps.sh

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== CLM Maps Web Deployment ===${NC}"
echo -e "${BLUE}Target: https://clm-maps.web.app${NC}"

# Step 1: Build the maps flavor
echo -e "\n${BLUE}Step 1: Building maps flavor...${NC}"
flutter pub get
dart run tools/replace_maps_key.dart
flutter build web --release --target lib/main_maps.dart --dart-define=FLAVOR=maps

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Build successful${NC}"
else
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

# Step 2: Deploy to Firebase Hosting (maps target → clm-maps site)
echo -e "\n${BLUE}Step 2: Deploying to Firebase Hosting (maps target)...${NC}"
firebase deploy --only hosting:maps --project clmschedule

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Deployment successful${NC}"
else
    echo -e "${RED}✗ Deployment failed${NC}"
    exit 1
fi

echo -e "\n${GREEN}=== CLM Maps Deployment Complete ===${NC}"
echo -e "${BLUE}Live at: ${GREEN}https://clm-maps.web.app${NC}"
