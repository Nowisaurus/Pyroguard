{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
  onEntrypointLoaded: async function(engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine({
      // Use html renderer to avoid WebGL CanvasKit context loss crash on Chrome
      renderer: "html",
    });
    await appRunner.runApp();
  }
});
