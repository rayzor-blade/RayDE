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
  var environment = stored.concat(query.getAll("env")).filter(function (entry) { return !/^RAYDE_(VISITOR|STANDALONE)=/.test(entry); });
  environment.push("RAYDE_VISITOR=" + visitor);
  environment.push("RAYDE_STANDALONE=" + (window.top === window ? "1" : "0"));
  globalThis.ashuiEnvironment = environment;
})();
