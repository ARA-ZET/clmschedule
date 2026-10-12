// letterbox/utils/letterbox_split.dart
//
// The one translation between the letterbox module's [LetterboxBreakdown] and
// the app-wide [LetterBoxSplit] stored on polygons.
//
// It lives here, on the letterbox side, because the direction of the
// dependency matters: `lib/models/custom_polygon.dart` is used by the whole
// app and must not import this module (its own doc comment says so), while
// this module already depends on app models. Every caller that needs to store
// a counted breakdown — the shareable map editor's auto-estimate, the track
// editor's Client Maps write — goes through here, so the two numbers can never
// come to mean different things in different places.
import '../../models/custom_polygon.dart';
import 'letterbox_clusters.dart';

extension LetterboxBreakdownSplit on LetterboxBreakdown {
  /// This breakdown as the type a [CustomPolygon] stores.
  LetterBoxSplit toLetterBoxSplit() => LetterBoxSplit(
        houses: houses,
        apartmentBoxes: apartmentBoxes,
        apartmentBlocks: apartmentBlocks,
      );
}
