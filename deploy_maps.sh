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
flutter build web --wasm --release --target lib/main_maps.dart --dart-define=FLAVOR=maps

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Build successful${NC}"
else
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

# Step 1b: Rebrand built index.html + manifest.json for CLM Maps
echo -e "\n${BLUE}Step 1b: Rebranding build output for CLM Maps...${NC}"

MAPS_TITLE="CLM Maps"
MAPS_DESC="CLM Maps - Interactive distribution maps and shareable layers"

INDEX_FILE="build/web/index.html"
MANIFEST_FILE="build/web/manifest.json"

if [ -f "$INDEX_FILE" ]; then
    # macOS/BSD sed requires -i ''
    sed -i '' \
        -e "s|<title>CLM Schedule</title>|<title>${MAPS_TITLE}</title>|g" \
        -e "s|<meta name=\"description\" content=\"CLM Schedule - Enterprise scheduling application\">|<meta name=\"description\" content=\"${MAPS_DESC}\">|g" \
        -e "s|<meta name=\"apple-mobile-web-app-title\" content=\"CLM Schedule\">|<meta name=\"apple-mobile-web-app-title\" content=\"${MAPS_TITLE}\">|g" \
        -e "s|<meta property=\"og:title\" content=\"CLM Schedule\">|<meta property=\"og:title\" content=\"${MAPS_TITLE}\">|g" \
        -e "s|<meta property=\"og:description\" content=\"CLM Schedule - Enterprise scheduling application\">|<meta property=\"og:description\" content=\"${MAPS_DESC}\">|g" \
        -e "s|<meta name=\"twitter:title\" content=\"CLM Schedule\">|<meta name=\"twitter:title\" content=\"${MAPS_TITLE}\">|g" \
        -e "s|<meta name=\"twitter:description\" content=\"CLM Schedule - Enterprise scheduling application\">|<meta name=\"twitter:description\" content=\"${MAPS_DESC}\">|g" \
        "$INDEX_FILE"
    echo -e "${GREEN}✓ Rebranded $INDEX_FILE${NC}"
else
    echo -e "${RED}✗ $INDEX_FILE not found${NC}"
    exit 1
fi

if [ -f "$MANIFEST_FILE" ]; then
    sed -i '' \
        -e "s|\"name\": \"CLM Schedule\"|\"name\": \"${MAPS_TITLE}\"|g" \
        -e "s|\"short_name\": \"CLM Schedule\"|\"short_name\": \"${MAPS_TITLE}\"|g" \
        -e "s|\"description\": \"CLM Schedule - Enterprise scheduling application for distributor job management\"|\"description\": \"${MAPS_DESC}\"|g" \
        "$MANIFEST_FILE"
    echo -e "${GREEN}✓ Rebranded $MANIFEST_FILE${NC}"
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
