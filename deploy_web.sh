#!/bin/bash

# Script to deploy web app and update version in Firestore
# Usage: ./deploy_web.sh
# 
# Step 4 (version bump in Firestore) needs credentials with access to the
# clmschedule project. Either:
#   - a gcloud login for richardatclm@gmail.com (used automatically, even if
#     another account is gcloud's active one):  gcloud auth login richardatclm@gmail.com
#   - or pick another account:  CLM_GCLOUD_ACCOUNT=you@example.com ./deploy_web.sh
#   - or a service account key at ~/.firebase/clmschedule-key.json
#     (or GOOGLE_APPLICATION_CREDENTIALS pointing at one)

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

# Check credentials for Step 4 BEFORE building, so a missing login is caught
# before the new build goes live rather than after.
GCLOUD_ACCOUNT="${CLM_GCLOUD_ACCOUNT:-richardatclm@gmail.com}"
if [ -z "$GOOGLE_APPLICATION_CREDENTIALS" ] && [ ! -f ~/.firebase/clmschedule-key.json ]; then
  if ! gcloud auth print-access-token "$GCLOUD_ACCOUNT" >/dev/null 2>&1; then
    echo -e "${RED}✗ No credentials for the Firestore version update${NC}"
    echo -e "${YELLOW}   Run: gcloud auth login ${GCLOUD_ACCOUNT}${NC}"
    echo -e "${YELLOW}   (or set CLM_GCLOUD_ACCOUNT to an account with access to clmschedule)${NC}"
    exit 1
  fi
  echo -e "${BLUE}Firestore version update will use: ${GREEN}${GCLOUD_ACCOUNT}${NC}"
fi

# Deploy as the account that owns clmschedule, whatever the Firebase CLI's
# default login happens to be. One-time setup:
#   firebase login:add richardatclm@gmail.com
# Override with CLM_FIREBASE_ACCOUNT=you@example.com ./deploy_web.sh
FIREBASE_ACCOUNT="${CLM_FIREBASE_ACCOUNT:-richardatclm@gmail.com}"
if ! firebase login:list 2>/dev/null | grep -qF "$FIREBASE_ACCOUNT"; then
  echo -e "${RED}✗ Firebase CLI is not logged in as ${FIREBASE_ACCOUNT}${NC}"
  echo -e "${YELLOW}   Run once: firebase login:add ${FIREBASE_ACCOUNT}${NC}"
  echo -e "${YELLOW}   (your other logins stay as they are)${NC}"
  exit 1
fi
echo -e "${BLUE}Firebase deploys will use: ${GREEN}${FIREBASE_ACCOUNT}${NC}"

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

# Step 2: Deploy Firestore security rules
echo -e "\n${BLUE}Step 2: Deploying Firestore rules...${NC}"
firebase deploy --only firestore:rules --project clmschedule --account "$FIREBASE_ACCOUNT"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Firestore rules deployed${NC}"
else
    echo -e "${RED}✗ Firestore rules deployment failed${NC}"
    exit 1
fi

# Step 3: Deploy to Firebase Hosting
echo -e "\n${BLUE}Step 3: Deploying to Firebase Hosting...${NC}"
firebase deploy --only hosting:main --project clmschedule --account "$FIREBASE_ACCOUNT"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Deployment successful${NC}"
else
    echo -e "${RED}✗ Deployment failed${NC}"
    exit 1
fi

# Step 4: Update version in Firestore
# This is what tells everyone already using the app that a new build exists.
# The clients compare the deploy timestamp written here, not just the version
# string, so a second deploy on the same day still notifies them — but if this
# step fails, nobody is told anything, which is why it is a hard failure.
echo -e "\n${BLUE}Step 4: Updating version in Firestore...${NC}"
echo -e "${BLUE}This notifies users that version ${GREEN}${VERSION}${BLUE} is available${NC}"
node tools/update_firestore_version.js "$VERSION"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Version updated in Firestore${NC}"
    echo -e "${GREEN}  Users will see update notification dialog${NC}"
else
    echo -e "${RED}✗ Failed to update version in Firestore${NC}"
    echo -e "${RED}   THE NEW BUILD IS LIVE BUT NOBODY WILL BE NOTIFIED.${NC}"
    echo -e "${RED}   Open users keep running the old version until they reload.${NC}"
    echo -e "${YELLOW}   Check the error above, then re-run just this step:${NC}"
    echo -e "${YELLOW}   node tools/update_firestore_version.js ${VERSION}${NC}"
    echo -e "${RED}   Manual update: Set appConfig/version document in Firebase Console${NC}\n"
    exit 1
fi

echo -e "\n${GREEN}=== Deployment Complete ===${NC}"
echo -e "${BLUE}Version ${GREEN}${VERSION}${BLUE} deployment completed at $(date)${NC}"
echo -e "${GREEN}📱 Users with the app open will see: 'Update Available' dialog${NC}"
echo -e "${GREEN}   They can click 'Refresh Now' to load the new version${NC}"
