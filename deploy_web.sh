#!/bin/bash

# Script to deploy web app and update version in Firestore
# Usage: ./deploy_web.sh
# 
# Before first deployment:
# 1. Download Firebase service account key:
#    - Go to: https://console.firebase.google.com/project/clmschedule/settings/serviceaccounts/adminsdk
#    - Click "Generate New Private Key"
#    - Save as: ~/.firebase/clmschedule-key.json
# 2. Set environment variable:
#    export GOOGLE_APPLICATION_CREDENTIALS=~/.firebase/clmschedule-key.json

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== CLM Schedule Web Deployment ===${NC}"
echo -e "${BLUE}Deployment started at $(date)${NC}\n"

# Get version from pubspec.yaml
VERSION=$(grep "^version:" pubspec.yaml | sed 's/version: //' | sed 's/+.*//')

echo -e "${BLUE}Current version: ${GREEN}${VERSION}${NC}"

# Check if credentials are available
if [ -z "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
  echo -e "${YELLOW}⚠️  WARNING: GOOGLE_APPLICATION_CREDENTIALS not set${NC}"
  echo -e "${YELLOW}   Version update to Firestore may fail${NC}"
  echo -e "${YELLOW}   Setup: export GOOGLE_APPLICATION_CREDENTIALS=~/.firebase/clmschedule-key.json${NC}\n"
fi

# Step 1: Build the web app
echo -e "\n${BLUE}Step 1: Building web app...${NC}"
flutter clean
flutter pub get
dart run tools/replace_maps_key.dart
flutter build web --wasm --release

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
echo -e "${BLUE}This notifies users that version ${GREEN}${VERSION}${BLUE} is available${NC}"
node tools/update_firestore_version.js "$VERSION"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Version updated in Firestore${NC}"
    echo -e "${GREEN}  Users will see update notification dialog${NC}"
else
    echo -e "${RED}✗ Failed to update version in Firestore${NC}"
    echo -e "${YELLOW}   If this is your first deployment, set up credentials:${NC}"
    echo -e "${YELLOW}   1. Download key from Firebase Console (Settings > Service Accounts)${NC}"
    echo -e "${YELLOW}   2. Save as: ~/.firebase/clmschedule-key.json${NC}"
    echo -e "${YELLOW}   3. Run: export GOOGLE_APPLICATION_CREDENTIALS=~/.firebase/clmschedule-key.json${NC}"
    echo -e "${YELLOW}   4. Try deployment again${NC}"
    echo -e "${RED}   Manual update: Set appConfig/version document in Firebase Console${NC}\n"
fi

echo -e "\n${GREEN}=== Deployment Complete ===${NC}"
echo -e "${BLUE}Version ${GREEN}${VERSION}${BLUE} deployment completed at $(date)${NC}"
if [ $? -eq 0 ]; then
  echo -e "${GREEN}📱 Users using old version will see: 'Update Available' dialog${NC}"
  echo -e "${GREEN}   They can click 'Refresh Now' to load the new version${NC}"
fi
