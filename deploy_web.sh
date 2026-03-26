#!/bin/bash

# Script to deploy web app and update version in Firestore
# Usage: ./deploy_web.sh

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== CLM Schedule Web Deployment ===${NC}"

# Get version from pubspec.yaml
VERSION=$(grep "^version:" pubspec.yaml | sed 's/version: //' | sed 's/+.*//')

echo -e "${BLUE}Current version: ${GREEN}${VERSION}${NC}"

# Step 1: Build the web app
echo -e "\n${BLUE}Step 1: Building web app...${NC}"
flutter clean
flutter pub get
dart run tools/replace_maps_key.dart
flutter build web --release

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Build successful${NC}"
else
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

# Step 2: Deploy to Firebase Hosting
echo -e "\n${BLUE}Step 2: Deploying to Firebase Hosting...${NC}"
firebase deploy --only hosting:main --project clmschedule

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Deployment successful${NC}"
else
    echo -e "${RED}✗ Deployment failed${NC}"
    exit 1
fi

# Step 3: Update version in Firestore
echo -e "\n${BLUE}Step 3: Updating version in Firestore...${NC}"
node tools/update_firestore_version.js "$VERSION"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Version updated in Firestore${NC}"
else
    echo -e "${RED}✗ Failed to update version in Firestore${NC}"
    echo -e "${RED}You may need to update it manually in Firebase Console${NC}"
fi

echo -e "\n${GREEN}=== Deployment Complete ===${NC}"
echo -e "${BLUE}Version ${GREEN}${VERSION}${BLUE} is now live!${NC}"
echo -e "${BLUE}Users will be prompted to reload to get the latest version.${NC}"
