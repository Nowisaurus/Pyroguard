# Translucent workspace treatment

The desktop sidebar and mobile navigation drawer remain opaque maroon. Emergency alerts, live camera preview surfaces and action buttons retain their high-contrast treatment.

All screens using the existing shared `GlassPanel`, `GlassStyle.card`, and Material card/input/dialog themes inherit warmer translucent surfaces. `GlassPanel` includes actual backdrop blur; ordinary `Card`, dialogs, and input fields use translucent colors but do not perform their own blur unless placed in a blur-enabled parent.

Existing standalone custom screens that use explicitly opaque `Container` decorations can still require visual review. No application logic, data fetching, sensors, or database schema were changed.
