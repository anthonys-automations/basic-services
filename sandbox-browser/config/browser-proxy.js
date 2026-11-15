// Firefox ignores the first line of an autoconfig file; this one is always first.
// Shared by the Firefox and Tor Browser autoconfig files: parses the container's
// proxy variables, which PAM loads into every desktop session.
function sandboxBrowserProxy(value) {
  if (!value) return null;
  var match = value.match(/^(?:(https?):\/\/)?(?:[^@\/]+@)?(\[[0-9a-f:.]+\]|[^\s:\/?#@]+)(?::([0-9]+))?\/?$/i);
  if (!match) return null;
  return {
    host: match[2].replace(/^\[|\]$/g, ""),
    port: match[3] ? parseInt(match[3], 10) : (match[1] && match[1].toLowerCase() == "https" ? 443 : 80),
  };
}
var httpProxy = sandboxBrowserProxy(getenv("http_proxy") || getenv("HTTP_PROXY"));
var httpsProxy = sandboxBrowserProxy(getenv("https_proxy") || getenv("HTTPS_PROXY")) || httpProxy;
