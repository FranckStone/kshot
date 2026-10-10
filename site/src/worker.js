// /download 跳转到 Mac App Store（APP_STORE_URL 在 wrangler.jsonc 的 vars 里配置），其余请求交给静态资源。
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.hostname === "www.kshot.org") {
      url.hostname = "kshot.org";
      return Response.redirect(url.toString(), 301);
    }

    if (url.pathname === "/download") {
      return Response.redirect(env.APP_STORE_URL || new URL("/#download", url).toString(), 302);
    }

    return env.ASSETS.fetch(request);
  },
};
