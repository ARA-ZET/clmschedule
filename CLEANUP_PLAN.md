# 🧹 CLM Schedule - Detailed Cleanup Plan

**Generated**: February 5, 2026  
**Total Unused Files**: 45 (29.6% of codebase)  
**Estimated Cleanup Impact**: Reduce lib/ directory by ~30%

---

## 📋 TABLE OF CONTENTS

1. [Priority 1: Safe to Delete Immediately](#priority-1-safe-to-delete-immediately)
2. [Priority 2: Review & Confirm Before Deleting](#priority-2-review--confirm-before-deleting)
3. [Priority 3: Requires Investigation](#priority-3-requires-investigation)
4. [Execution Steps](#execution-steps)
5. [Rollback Plan](#rollback-plan)

---

## ✅ PRIORITY 1: Safe to Delete Immediately

### Total: 15 files - **RECOMMENDED ACTION: DELETE NOW**

These files are clearly obsolete, empty, or debug-only with no risk to production.

#### 🗑️ Backup/Old Files (2 files)

| File | Reason | Risk Level |
|------|--------|------------|
| `lib/services/chat_service_backup_old.dart` | Old backup with `_old` suffix | 🟢 ZERO |
| `lib/services/firestore_service_old.dart` | Old backup with `_old` suffix | 🟢 ZERO |

**Action**: Delete both files immediately.

---

#### 🧪 Debug/Test Widgets (4 files)

| File | Purpose | Risk Level |
|------|---------|------------|
| `lib/widgets/cache_debug_widget.dart` | Debug UI for cache inspection | 🟢 ZERO |
| `lib/widgets/scale_test_widget.dart` | Scale testing utility | 🟢 ZERO |
| `lib/widgets/kml_download_demo.dart` | KML demo/testing | 🟢 ZERO |
| `lib/widgets/kml_map_demo.dart` | KML map demo/testing | 🟢 ZERO |

**Action**: Delete all debug widgets.

---

#### 📄 Empty/Placeholder Files (1 file)

| File | Content | Risk Level |
|------|---------|------------|
| `lib/theme.dart` | Empty (whitespace only) | 🟢 ZERO |

**Action**: Delete empty file.

---

#### 🔧 Unused Utilities (6 files)

| File | Purpose | Risk Level |
|------|---------|------------|
| `lib/utils/color_utils.dart` | Color helper functions | 🟢 ZERO |
| `lib/utils/google_maps_utils.dart` | Google Maps helpers | 🟢 ZERO |
| `lib/utils/maps_util.dart` | Map utilities | 🟢 ZERO |
| `lib/utils/work_area_converter.dart` | Work area conversion | 🟢 ZERO |
| `lib/utils/seed_job_list_data.dart` | Seed data generation | 🟢 ZERO |
| `lib/utils/collection_job_integration_helper.dart` | Integration helper | 🟢 ZERO |

**Action**: Delete all unused utility files.

---

#### 🔐 Unused Auth Implementations (2 files)

| File | Purpose | Risk Level |
|------|---------|------------|
| `lib/services/mock_auth_service.dart` | Mock authentication | 🟢 ZERO* |
| `lib/providers/mock_auth_provider.dart` | Mock auth provider | 🟢 ZERO* |

**Note**: *Safe to delete IF not used in tests. Check `test/` directory first.

**Action**: Verify no test dependencies, then delete.

---

## 🟡 PRIORITY 2: Review & Confirm Before Deleting

### Total: 18 files - **RECOMMENDED ACTION: VERIFY THEN DELETE**

These files appear unused but may have been part of incomplete features or future plans.

#### 🎯 Command Pattern Files (3 files)

| File | Classes Defined | Status |
|------|----------------|--------|
| `lib/commands/job_list_commands.dart` | `AddJobListItemCommand`, `UpdateJobListItemCommand`, `DeleteJobListItemCommand` | ⚠️ Architecture pattern not implemented |
| `lib/commands/map_commands.dart` | Map-related commands | ⚠️ Architecture pattern not implemented |
| `lib/commands/schedule_commands.dart` | `AddJobCommand`, `UpdateJobCommand`, etc. | ⚠️ Architecture pattern not implemented |

**Finding**: Code comments in `schedule_provider.dart` indicate the Command pattern was bypassed in favor of direct Firestore calls.

**Recommendation**:
- ✅ DELETE if Command pattern refactoring is abandoned
- ⏸️ KEEP if you plan to implement proper undo/redo architecture

**Action Required**: Decision from lead developer on architectural direction.

---

#### 🗺️ Map View Variations (2 files)

| File | Purpose | Likely Status |
|------|---------|---------------|
| `lib/widgets/map_view.dart` | Original map view implementation | 🔄 Replaced by `updated_map_view.dart` |
| `lib/widgets/updated_map_view.dart` | Updated map view | ❓ Which is canonical? |

**Finding**: Two map view implementations exist. Need to determine which is actively used.

**Recommendation**:
- Check import usage in main app screens
- Keep the one that's actively rendered
- Delete the obsolete version

**Action Required**: 
```bash
# Search for usage
grep -r "import.*map_view.dart" lib/
grep -r "import.*updated_map_view.dart" lib/
```

---

#### 📅 Date Filter Widgets (2 files)

| File | Likely Purpose |
|------|----------------|
| `lib/widgets/date_filter_widget.dart` | Date filtering UI |
| `lib/widgets/compact_date_filter.dart` | Compact date filter variant |

**Finding**: Multiple date filter implementations suggest UI iteration.

**Recommendation**: Identify which filter is currently in use and delete others.

**Action Required**: Check which is imported in active screens.

---

#### 📊 Alternative Widget Implementations (4 files)

| File | Purpose | Status |
|------|---------|--------|
| `lib/widgets/fast_job_list_view.dart` | Performance-optimized job list | ❓ Replaced by `job_list_grid.dart`? |
| `lib/widgets/job_list_card.dart` | Card layout for job list | ❓ Not used in current grid |
| `lib/widgets/job_list_row_widget.dart` | Row layout for job list | ❓ Not used in current grid |
| `lib/widgets/editable_text_field.dart` | Custom editable field | ❓ Replaced by `editable_table_cell.dart`? |

**Recommendation**: These appear to be alternative implementations. Delete if superseded.

**Action Required**: Verify current job list implementation uses none of these.

---

#### 🌞 Happy Sun Unused Widgets (4 files)

| File | Purpose | Imported By |
|------|---------|-------------|
| `lib/widgets/happy_sun_jobs_screen.dart` | Jobs screen | ❌ None |
| `lib/widgets/happy_sun_project_card.dart` | Project card widget | ❌ None |
| `lib/widgets/happy_sun_projects_screen.dart` | Projects screen | ❌ None |
| `lib/widgets/happy_sun_tools_needed_dialog.dart` | Tools dialog | ❌ None |

**Finding**: These Happy Sun widgets exist but are not imported. Current implementation uses `happy_sun_job_projects_screen.dart`.

**Recommendation**: 
- ✅ DELETE if the new combined screen (`happy_sun_job_projects_screen.dart`) replaces these
- ⏸️ KEEP if these are part of an upcoming UI refactor

**Action Required**: Verify `happy_sun_job_projects_screen.dart` provides all needed functionality.

---

#### 📈 Tracking & Version Widgets (2 files)

| File | Purpose | Risk Level |
|------|---------|------------|
| `lib/widgets/schedule_tracking_view.dart` | Schedule tracking UI | 🟡 LOW |
| `lib/widgets/new_version_dialog.dart` | Version update dialog | 🟡 LOW |

**Recommendation**: 
- `schedule_tracking_view.dart`: Delete if tracking feature is not implemented
- `new_version_dialog.dart`: Keep if you have app update notifications, otherwise delete

**Action Required**: Check if version checking is active in `app_version_provider.dart`.

---

#### 🔄 Undo/Redo Widgets (1 file)

| File | Purpose | Risk Level |
|------|---------|------------|
| `lib/widgets/undo_redo_widgets.dart` | Undo/redo UI controls | 🟡 LOW |

**Finding**: Undo/redo UI exists but not shown anywhere.

**Recommendation**: Delete if undo/redo feature is not user-facing, or integrate into UI.

**Action Required**: Decide if undo/redo should be visible to users.

---

## 🔴 PRIORITY 3: Requires Investigation

### Total: 12 files - **RECOMMENDED ACTION: INVESTIGATE FIRST**

These files may have dependencies or be planned features.

#### 🔐 Authentication Alternatives (2 files)

| File | Purpose | Keep/Delete |
|------|---------|-------------|
| `lib/services/auth_service.dart` | Abstract auth interface | ⚠️ May be needed for abstraction |
| `lib/services/platform_auth_service.dart` | Platform-specific auth | ⚠️ May be needed for multi-platform |

**Recommendation**: Keep if planning multi-platform support (iOS/Android/Web with different auth).

**Action Required**: Review auth architecture plans.

---

#### 🔐 Simple Auth (1 file)

| File | Purpose | Keep/Delete |
|------|---------|-------------|
| `lib/services/simple_auth_service.dart` | Simplified auth implementation | ⚠️ May be fallback |

**Recommendation**: Delete if current auth (Firebase) is the only implementation.

**Action Required**: Confirm no need for simple/demo auth mode.

---

#### 📊 Tracking & Cache Services (2 files)

| File | Purpose | Keep/Delete |
|------|---------|-------------|
| `lib/services/schedule_tracking_service.dart` | Schedule tracking logic | ⚠️ May be planned feature |
| `lib/services/job_cache_service.dart` | Job caching for offline | ⚠️ May be needed for performance |

**Recommendation**: 
- Keep if offline support is planned
- Delete if all data is real-time from Firestore

**Action Required**: Review offline/caching strategy.

---

#### 🗺️ Parser Services (2 files)

| File | Purpose | Keep/Delete |
|------|---------|-------------|
| `lib/services/gpx_parser_service.dart` | Parse GPX track files | ⚠️ May be planned import feature |
| `lib/services/kml_parser_service.dart` | Parse KML map files | ⚠️ Already have KML in project |

**Finding**: KML parser exists but KML features appear to be present in the app.

**Recommendation**:
- Delete `gpx_parser_service.dart` if GPX import is not planned
- Investigate if `kml_parser_service.dart` is used indirectly (check imports more carefully)

**Action Required**: Verify KML functionality doesn't use this service.

---

#### ⌨️ Keyboard Shortcuts (1 file)

| File | Purpose | Keep/Delete |
|------|---------|-------------|
| `lib/services/keyboard_shortcuts_service.dart` | Keyboard shortcut handling | ⚠️ Desktop feature |

**Recommendation**: Keep if targeting desktop (Windows/Mac/Linux), delete if web/mobile only.

**Action Required**: Check platform targets in `pubspec.yaml`.

---

#### 📦 Models (2 files)

| File | Purpose | Keep/Delete |
|------|---------|-------------|
| `lib/models/gpx_track.dart` | GPX track data model | ⚠️ Matches GPX parser |
| `lib/models/happy_sun_job.dart` | Happy Sun job model | ⚠️ Check if used differently than project model |

**Recommendation**: Delete if features are not implemented.

**Action Required**: Confirm no hidden references.

---

#### 🔄 Providers (1 file)

| File | Purpose | Keep/Delete |
|------|---------|-------------|
| `lib/providers/job_provider.dart` | Job state management | ⚠️ May be replaced by schedule_provider |

**Recommendation**: Delete if `schedule_provider.dart` handles all job state.

**Action Required**: Verify schedule provider is the sole source of truth.

---

#### 📊 Google Sheets Integration (1 file)

| File | Purpose | Keep/Delete |
|------|---------|-------------|
| `lib/widgets/google_sheets_tracking_view.dart` | Google Sheets export/view | ⚠️ May be planned feature |

**Recommendation**: Keep if planning Google Sheets integration, delete otherwise.

**Action Required**: Check if Sheets export is a requirement.

---

## 🚀 EXECUTION STEPS

### Phase 1: Safe Deletions (15 files)
**Time**: 10 minutes  
**Risk**: ZERO

```bash
# Backup first
git checkout -b cleanup/remove-unused-files

# Delete Priority 1 files
rm lib/theme.dart
rm lib/services/chat_service_backup_old.dart
rm lib/services/firestore_service_old.dart
rm lib/services/mock_auth_service.dart
rm lib/providers/mock_auth_provider.dart
rm lib/widgets/cache_debug_widget.dart
rm lib/widgets/scale_test_widget.dart
rm lib/widgets/kml_download_demo.dart
rm lib/widgets/kml_map_demo.dart
rm lib/utils/color_utils.dart
rm lib/utils/google_maps_utils.dart
rm lib/utils/maps_util.dart
rm lib/utils/work_area_converter.dart
rm lib/utils/seed_job_list_data.dart
rm lib/utils/collection_job_integration_helper.dart

# Verify app still works
flutter pub get
flutter analyze
flutter run --release
```

### Phase 2: Verified Deletions (18 files)
**Time**: 30 minutes  
**Risk**: LOW (after verification)

```bash
# First verify which map view is used
grep -r "MapView" lib/main.dart lib/widgets/*.dart

# Delete confirmed unused widgets
# (Adjust based on verification results)

# Test thoroughly
flutter test
```

### Phase 3: Investigation Required (12 files)
**Time**: 1-2 hours  
**Risk**: MEDIUM

- Review each file individually
- Check for indirect references
- Confirm with team on planned features
- Delete in small batches with testing

---

## 🔄 ROLLBACK PLAN

If issues arise after deletion:

```bash
# Restore all deleted files
git checkout main -- lib/

# Or restore specific file
git checkout main -- lib/path/to/file.dart

# Or revert entire commit
git revert HEAD
```

---

## 📊 EXPECTED OUTCOMES

### Before Cleanup
- Total lib/ files: 152
- Active files: 101
- Unused files: 45

### After Cleanup (Aggressive)
- Total lib/ files: 107 (-45)
- Active files: 101
- Unused files: 0

### After Cleanup (Conservative - Priority 1 only)
- Total lib/ files: 137 (-15)
- Active files: 101  
- Unused files: 30

---

## ✅ VERIFICATION CHECKLIST

Before deleting each file, verify:

- [ ] Not imported anywhere in lib/
- [ ] Not used in test files
- [ ] Not referenced in documentation that matters
- [ ] No dynamic imports (String-based imports)
- [ ] Not used by reflection/code generation
- [ ] Run `flutter analyze` after deletion
- [ ] Run `flutter test` after deletion
- [ ] Manually test affected features

---

## 📝 NOTES

1. **Command Pattern**: Decision needed on whether to implement or abandon
2. **Map Views**: Clarify which implementation is canonical
3. **Happy Sun**: New combined screen may supersede individual screens
4. **Auth Alternatives**: Only needed for multi-platform auth strategies
5. **Parser Services**: Keep only if import features are planned

---

## 🎯 RECOMMENDATION

**Immediate Action**: Execute Phase 1 (15 files) - Zero risk, immediate benefit

**Short Term**: Complete Phase 2 (18 files) after verification - Low risk, high benefit

**Long Term**: Review Phase 3 (12 files) with team - Requires architectural decisions

**Total Cleanup Potential**: 45 files (29.6% reduction)

---

**Generated by**: Unused Files Analysis Script  
**Last Updated**: February 5, 2026
