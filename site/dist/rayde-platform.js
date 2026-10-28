// Shortcuts follow this browser's keyboard, independently of the workspace and window style.
(function () {
  if (window.top !== window) document.documentElement.setAttribute("data-embedded", "");
  var query = new URLSearchParams(location.search);
  var platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
  var visitor = /mac|iphone|ipad/i.test(platform) ? "Mac" : /win/i.test(platform) ? "Windows" : "Linux";
  var stored = [];
  try {
    var connection = JSON.parse(globalThis.localStorage.getItem("rayde.workspaceConnection.v1"));
    if (connection && connection.version === 1 && Array.isArray(connection.environment)) stored = connection.environment.filter(function (entry) { return typeof entry === "string"; });
  } catch (_) {}
  var environment = stored.concat(query.getAll("env")).filter(function (entry) { return entry.indexOf("RAYDE_VISITOR=") !== 0; });
  environment.push("RAYDE_VISITOR=" + visitor);
  if (window.matchMedia("(display-mode: standalone), (display-mode: window-controls-overlay), (display-mode: fullscreen)").matches && window.top === window && !environment.some(function (entry) { return entry.indexOf("RAYDE_STANDALONE=") === 0; })) environment.push("RAYDE_STANDALONE=1");
  globalThis.ashuiEnvironment = environment;
})();
