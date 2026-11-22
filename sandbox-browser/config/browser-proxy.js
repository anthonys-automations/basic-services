// Firefox ignores the first line of an autoconfig file; this one is always first.
// Parses the container's proxy variables, which PAM loads into every desktop
// session, for the Firefox autoconfig file.
function sandboxBrowserProxy(value) {
  if (!value) return null;
  var match = value.match(/^(?:(https?|socks5h?):\/\/)?(?:[^@\/]+@)?(\[[0-9a-f:.]+\]|[^\s:\/?#@]+)(?::([0-9]+))?\/?$/i);
  if (!match) return null;
  var scheme = (match[1] || "http").toLowerCase();
  return {
    socks: scheme.indexOf("socks") == 0,
    host: match[2].replace(/^\[|\]$/g, ""),
    port: match[3] ? parseInt(match[3], 10) : ({ http: 80, https: 443 })[scheme] || 1080,
  };
}
function sandboxBrowserHttpProxy(value) {
  var proxy = sandboxBrowserProxy(value);
  return proxy && !proxy.socks ? proxy : null;
}
// all_proxy wins over the per-scheme variables, as it does in Chrome.
var allProxy = sandboxBrowserProxy(getenv("all_proxy") || getenv("ALL_PROXY"));
var socksProxy = allProxy && allProxy.socks ? allProxy : null;
var httpProxy = allProxy ? (socksProxy ? null : allProxy) : sandboxBrowserHttpProxy(getenv("http_proxy") || getenv("HTTP_PROXY"));
var httpsProxy = allProxy ? httpProxy : sandboxBrowserHttpProxy(getenv("https_proxy") || getenv("HTTPS_PROXY")) || httpProxy;
