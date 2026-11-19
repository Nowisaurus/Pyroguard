# Sala glass transparency update

Applied to the full Flutter project using the previous v2 build as the base.

- Shared `GlassPanel`, `GlassStyle.card`, app card surfaces, input fields, dialogs, popup menus and bottom sheets now use a lower-opacity tint so the phoenix background shows through.
- Existing solid sidebar/drawer code was left unchanged.
- Existing camera rendering and emergency alert surfaces were not converted because they require clear contrast.
- No Dart service, Supabase schema, MySQL schema or synchronization worker logic was modified.
- The 11 JavaScript MySQL worker tests passed. Flutter compilation and device/runtime testing must be performed locally.

Note: screen-specific custom decorations may still require individual visual updates; these changes primarily cover shared surfaces and the room sensor metric cards.
