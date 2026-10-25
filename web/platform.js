// Shortcuts follow this browser's keyboard, independently of the workspace and window style.
(function () {
  var query = new URLSearchParams(location.search);
  var platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
  var visitor = /mac|iphone|ipad/i.test(platform) ? "Mac" : /win/i.test(platform) ? "Windows" : "Linux";
  var environment = query.getAll("env").filter(function (entry) { return entry.indexOf("RAYDE_VISITOR=") !== 0; });
  environment.push("RAYDE_VISITOR=" + visitor);
  if (window.matchMedia("(display-mode: standalone), (display-mode: window-controls-overlay), (display-mode: fullscreen)").matches && window.top === window && !environment.some(function (entry) { return entry.indexOf("RAYDE_STANDALONE=") === 0; })) environment.push("RAYDE_STANDALONE=1");
  query.delete("env");
  environment.forEach(function (entry) { query.append("env", entry); });
  history.replaceState(null, "", location.pathname + "?" + query.toString() + location.hash);
})();
