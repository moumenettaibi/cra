const presentation = {
    folderTitle: "RSS Feed",
    menuTitle: "RSS Feed",
    icon: "icon.svg",
    defaultRefreshInterval: 900,
    refreshIntervals: [300, 900, 1800, 3600, 7200, 14400, 28800],
    filters: [],
    optionGroups: [
        {
            id: "limit",
            title: "Item Limit",
            choices: [
                {id: "5", title: "5 items"},
                {id: "10", title: "10 items"},
                {id: "25", title: "25 items", enabledByDefault: true},
                {id: "50", title: "50 items"}
            ]
        },
        {
            id: "range",
            title: "Time Range",
            choices: [
                {id: "24h", title: "Last 24 hours"},
                {id: "7d", title: "Last 7 days"},
                {id: "30d", title: "Last 30 days"},
                {id: "all", title: "All time", enabledByDefault: true}
            ]
        }
    ],
    setup: {
        key: "feed",
        allowQuery: true,
        title: "Add an RSS Live Folder",
        message: "Enter a feed URL or any website address to auto-discover its RSS or Atom feed.",
        placeholder: "https://example.com/feed.xml",
        defaultValue: "",
        invalidTitle: "That isn’t a valid web address",
        invalidMessage: "Enter an http:// or https:// website or feed URL, like https://example.com/feed.xml."
    },
    statusMessages: {
        notSignedIn: "Feed requires sign-in or access permission",
        rateLimited: "Feed server rate limit exceeded",
        unexpectedPage: "Could not find or parse an RSS or Atom feed at that address",
        network: "Failed to update: feed can’t be reached"
    }
};

function fail(code) { throw new Error(code); }

function headerValue(headers, name) {
    if (!headers || typeof headers !== "object") return null;
    const target = name.toLowerCase();
    for (const key of Object.keys(headers)) {
        if (key.toLowerCase() === target) {
            const value = String(headers[key] ?? "").trim();
            if (value) return value;
        }
    }
    return null;
}

function decodeEntities(text) {
    if (!text) return "";
    const named = {
        lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
        mdash: "—", ndash: "–", rsquo: "’", lsquo: "‘",
        rdquo: "”", ldquo: "“", hellip: "…"
    };
    return String(text)
        .replace(/&(lt|gt|quot|apos|nbsp|mdash|ndash|rsquo|lsquo|rdquo|ldquo|hellip);/gi, (_, name) => named[name.toLowerCase()] ?? _)
        .replace(/&#(x?)([0-9a-fA-F]+);/g, (original, hex, digits) => {
            const value = parseInt(digits, hex ? 16 : 10);
            return value >= 0 && value <= 0x10ffff && !(value >= 0xd800 && value <= 0xdfff)
                ? String.fromCodePoint(value) : original;
        })
        .replace(/&amp;/gi, "&");
}

function unwrapCDATA(text) {
    return String(text ?? "").replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1");
}

function cleanText(text) {
    const raw = unwrapCDATA(text).replace(/<[^>]+>/g, " ");
    return decodeEntities(raw).replace(/\s+/g, " ").trim();
}

function parseAttributes(raw) {
    const attrs = {};
    const regex = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/g;
    let match;
    while ((match = regex.exec(raw)) !== null) {
        attrs[match[1].toLowerCase()] = decodeEntities(match[2] ?? match[3] ?? match[4] ?? "");
    }
    return attrs;
}

function parseURLParts(url) {
    const m = /^(https?):\/\/([^\/:?#]+)(?::(\d+))?([^?#]*)(\?[^#]*)?(?:#.*)?$/i.exec(String(url ?? "").trim());
    if (!m) return null;
    const scheme = m[1].toLowerCase();
    const host = m[2].toLowerCase();
    if (!host || host.includes("@")) return null;
    const port = m[3] ? Number(m[3]) : null;
    const defaultPort = scheme === "https" ? 443 : 80;
    const effectivePort = port ?? defaultPort;
    const origin = scheme + "://" + host + (effectivePort === defaultPort ? "" : ":" + effectivePort);
    return {scheme, host, port: effectivePort, origin, path: m[4] || "/", query: m[5] || ""};
}

function normalizeDotSegments(path) {
    const out = [];
    for (const seg of path.split("/")) {
        if (seg === "" || seg === ".") continue;
        if (seg === "..") { if (out.length) out.pop(); continue; }
        out.push(seg);
    }
    return "/" + out.join("/") + (path.endsWith("/") && out.length ? "/" : "");
}

function resolveURL(raw, base) {
    const input = decodeEntities(String(raw ?? "")).trim().replace(/#.*$/, "");
    if (!input) return null;
    if (/^https?:\/\//i.test(input)) {
        const parsed = parseURLParts(input);
        return parsed ? input : null;
    }
    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(input)) return null;
    const baseParts = parseURLParts(base);
    if (!baseParts) return null;
    if (input.startsWith("//")) {
        const candidate = baseParts.scheme + ":" + input;
        return parseURLParts(candidate) ? candidate : null;
    }
    if (input.startsWith("?")) return baseParts.origin + baseParts.path + input;
    const queryIdx = input.indexOf("?");
    const relPath = queryIdx >= 0 ? input.slice(0, queryIdx) : input;
    const relQuery = queryIdx >= 0 ? input.slice(queryIdx) : "";
    let resolvedPath;
    if (relPath.startsWith("/")) {
        resolvedPath = normalizeDotSegments(relPath);
    } else if (!relPath) {
        resolvedPath = baseParts.path;
    } else {
        const dir = baseParts.path.slice(0, baseParts.path.lastIndexOf("/") + 1);
        resolvedPath = normalizeDotSegments(dir + relPath);
    }
    return baseParts.origin + resolvedPath + relQuery;
}

function parseDate(raw) {
    if (!raw) return null;
    const text = cleanText(raw);
    if (!text) return null;
    const isoNormalized = text.replace(/([+-]\d{2})(\d{2})$/, "$1:$2");
    let ms = Date.parse(isoNormalized);
    if (Number.isFinite(ms)) return ms / 1000;
    const zones = {
        GMT: "+00:00", UTC: "+00:00", UT: "+00:00", Z: "+00:00",
        EST: "-05:00", EDT: "-04:00", CST: "-06:00", CDT: "-05:00",
        MST: "-07:00", MDT: "-06:00", PST: "-08:00", PDT: "-07:00"
    };
    const rfc = text.replace(/\b(GMT|UTC|UT|EST|EDT|CST|CDT|MST|MDT|PST|PDT|Z)\b/i, z => zones[z.toUpperCase()] ?? z);
    ms = Date.parse(rfc);
    return Number.isFinite(ms) ? ms / 1000 : null;
}

function tagText(block, names) {
    for (const name of names) {
        const re = new RegExp("<" + name + "\\b[^>]*>([\\s\\S]*?)<\\/" + name + ">", "i");
        const m = re.exec(block);
        if (m) return m[1];
    }
    return null;
}

function parseRSS(xml, baseURL) {
    const isRSS = /<(?:rss|rdf:RDF)\b/i.test(xml) && /<channel\b/i.test(xml);
    if (!isRSS) return null;
    const firstItem = xml.search(/<item\b/i);
    const channelHead = firstItem >= 0 ? xml.slice(0, firstItem) : xml;
    const channelMatch = /<channel\b[^>]*>([\s\S]*)/i.exec(channelHead);
    const feedTitle = channelMatch ? cleanText(tagText(channelMatch[1], ["title"]) ?? "") : "";

    const items = [];
    const itemRegex = /<item\b[^>]*>([\s\S]*?)<\/item>/gi;
    let match;
    while ((match = itemRegex.exec(xml)) !== null) {
        const block = match[1];
        const rawLink = unwrapCDATA(tagText(block, ["link"]) ?? "").trim();
        const guidTag = /<guid\b([^>]*)>([\s\S]*?)<\/guid>/i.exec(block);
        const guidAttrs = guidTag ? parseAttributes(guidTag[1]) : {};
        const rawGuid = guidTag ? unwrapCDATA(guidTag[2]).trim() : "";
        const permalinkCandidate = guidAttrs.ispermalink !== "false" ? rawGuid : "";
        const url = resolveURL(rawLink || permalinkCandidate, baseURL);
        if (!url) continue;
        const title = cleanText(tagText(block, ["title"]) ?? "") || url;
        const author = cleanText(tagText(block, ["dc:creator", "author"]) ?? "") || null;
        const createdAt = parseDate(tagText(block, ["pubDate", "dc:date"]));
        items.push({id: rawGuid || url, url, title, subtitle: author, createdAt});
    }
    return {title: feedTitle || null, items};
}

function parseAtom(xml, baseURL) {
    if (!/<feed\b/i.test(xml)) return null;
    const firstEntry = xml.search(/<entry\b/i);
    const feedHead = firstEntry >= 0 ? xml.slice(0, firstEntry) : xml;
    const feedTitle = cleanText(tagText(feedHead, ["title"]) ?? "");

    const items = [];
    const entryRegex = /<entry\b[^>]*>([\s\S]*?)<\/entry>/gi;
    let match;
    while ((match = entryRegex.exec(xml)) !== null) {
        const block = match[1];
        let alternateHref = null;
        let fallbackHref = null;
        const linkRegex = /<link\b([^>]*)\/?\s*>/gi;
        let linkMatch;
        while ((linkMatch = linkRegex.exec(block)) !== null) {
            const attrs = parseAttributes(linkMatch[1]);
            if (!attrs.href) continue;
            const rel = (attrs.rel ?? "alternate").toLowerCase();
            if (rel === "alternate" && !alternateHref) {
                alternateHref = attrs.href;
            } else if (rel !== "enclosure" && rel !== "self" && !fallbackHref) {
                fallbackHref = attrs.href;
            }
        }
        const rawId = unwrapCDATA(tagText(block, ["id"]) ?? "").trim();
        const url = resolveURL(alternateHref ?? fallbackHref ?? rawId, baseURL);
        if (!url) continue;
        const title = cleanText(tagText(block, ["title"]) ?? "") || url;
        const authorBlock = tagText(block, ["author"]);
        const author = cleanText((authorBlock ? tagText(authorBlock, ["name"]) : null) ?? authorBlock ?? "") || null;
        const createdAt = parseDate(tagText(block, ["published"]) ?? tagText(block, ["updated"]));
        items.push({id: rawId || url, url, title, subtitle: author, createdAt});
    }
    return {title: feedTitle || null, items};
}

function parseFeed(xml, baseURL) {
    return parseRSS(xml, baseURL) ?? parseAtom(xml, baseURL);
}

function discoverFeedURLs(html, baseURL) {
    const cleaned = String(html ?? "").replace(/<!--[\s\S]*?-->/g, "");
    const linkRegex = /<link\b([^>]*)>/gi;
    const primary = [];
    const secondary = [];
    const seen = new Set();
    let match;
    while ((match = linkRegex.exec(cleaned)) !== null) {
        const attrs = parseAttributes(match[1]);
        const relTokens = (attrs.rel ?? "").toLowerCase().split(/\s+/).filter(Boolean);
        if (!relTokens.includes("alternate") || !attrs.href) continue;
        const mediaType = (attrs.type ?? "").split(";")[0].trim().toLowerCase();
        let isPrimary = false;
        if (mediaType === "application/rss+xml" || mediaType === "application/atom+xml") {
            isPrimary = true;
        } else if (mediaType === "application/xml" || mediaType === "text/xml" || mediaType === "application/rdf+xml") {
            const hint = (attrs.href + " " + (attrs.title ?? "")).toLowerCase();
            if (!hint.includes("rss") && !hint.includes("atom") && !hint.includes("feed")) continue;
        } else {
            continue;
        }
        const resolved = resolveURL(attrs.href, baseURL);
        if (!resolved || seen.has(resolved.toLowerCase())) continue;
        seen.add(resolved.toLowerCase());
        (isPrimary ? primary : secondary).push(resolved);
    }
    return primary.concat(secondary);
}

function finalizeItems(rawItems, limit, range, nowSeconds) {
    const seen = new Set();
    const deduped = [];
    const windows = {"24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400};
    const cutoff = windows[range] != null ? nowSeconds - windows[range] : null;
    for (const item of rawItems) {
        if (cutoff != null && (item.createdAt == null || item.createdAt < cutoff)) continue;
        const key = item.url.toLowerCase();
        if (seen.has(key)) continue;
        seen.add(key);
        deduped.push(item);
    }
    const indexed = deduped.map((item, idx) => ({item, idx}));
    indexed.sort((a, b) => {
        const la = a.item.createdAt, lb = b.item.createdAt;
        if (la != null && lb != null && la !== lb) return lb - la;
        if (la != null && lb == null) return -1;
        if (la == null && lb != null) return 1;
        return a.idx - b.idx;
    });
    return indexed.slice(0, limit).map(entry => entry.item);
}

function fetchFeed(url, conditionalHeaders) {
    const headers = {
        Accept: "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, text/html;q=0.8, */*;q=0.5",
        ...conditionalHeaders
    };
    const response = cra.session.fetch(url, {headers});
    if (response.status === 0) fail("network");
    if (response.status === 304) return {notModified: true, response};
    if (response.status === 401 || response.status === 403) fail("notSignedIn");
    if (response.status === 429) fail("rateLimited");
    if (response.status < 200 || response.status >= 300) fail("unexpectedPage");
    return {notModified: false, response};
}

function refresh(input) {
    const state = input.state ?? {};
    const target = state.feedURL || input.settings?.feed;
    if (!target) fail("unexpectedPage");

    const rawLimit = Number(input.settings?.limit ?? 25);
    const limit = [5, 10, 25, 50].includes(rawLimit) ? rawLimit : 25;
    const range = ["24h", "7d", "30d", "all"].includes(input.settings?.range) ? input.settings.range : "all";
    const nowSeconds = typeof input.now === "number" ? input.now : Date.now() / 1000;
    const filterKey = limit + ":" + range;
    const canConditional = Boolean(state.feedURL) && state.lastFilterKey === filterKey;

    const conditional = {};
    if (canConditional && state.etag) conditional["If-None-Match"] = state.etag;
    if (canConditional && state.lastModified) conditional["If-Modified-Since"] = state.lastModified;

    let result = fetchFeed(target, conditional);
    if (result.notModified) {
        return {
            items: [],
            actions: [],
            preservedGroups: [],
            notModified: true,
            folderTitle: state.feedTitle || undefined,
            state: {
                feedURL: target,
                feedTitle: state.feedTitle ?? "",
                etag: headerValue(result.response.headers, "etag") ?? state.etag ?? "",
                lastModified: headerValue(result.response.headers, "last-modified") ?? state.lastModified ?? "",
                lastFilterKey: filterKey
            }
        };
    }

    let response = result.response;
    let finalURL = response.url || target;
    let parsed = parseFeed(response.body, finalURL);

    if (!parsed) {
        const candidates = discoverFeedURLs(response.body, finalURL);
        const currentOrigin = parseURLParts(finalURL)?.origin;
        for (const candidate of candidates) {
            if (parseURLParts(candidate)?.origin !== currentOrigin) continue;
            const retryConditional = {};
            if (canConditional && candidate === state.feedURL) {
                if (state.etag) retryConditional["If-None-Match"] = state.etag;
                if (state.lastModified) retryConditional["If-Modified-Since"] = state.lastModified;
            }
            result = fetchFeed(candidate, retryConditional);
            if (result.notModified) {
                return {
                    items: [],
                    actions: [],
                    preservedGroups: [],
                    notModified: true,
                    folderTitle: state.feedTitle || undefined,
                    state: {
                        feedURL: candidate,
                        feedTitle: state.feedTitle ?? "",
                        etag: headerValue(result.response.headers, "etag") ?? state.etag ?? "",
                        lastModified: headerValue(result.response.headers, "last-modified") ?? state.lastModified ?? "",
                        lastFilterKey: filterKey
                    }
                };
            }
            response = result.response;
            finalURL = response.url || candidate;
            parsed = parseFeed(response.body, finalURL);
            if (parsed) break;
        }
    }

    if (!parsed) fail("unexpectedPage");

    const etag = headerValue(response.headers, "etag") ?? "";
    const lastModified = headerValue(response.headers, "last-modified") ?? "";
    const feedTitle = parsed.title ?? state.feedTitle ?? "";
    const nextState = {
        feedURL: finalURL,
        feedTitle,
        lastFilterKey: filterKey
    };
    if (etag) nextState.etag = etag;
    if (lastModified) nextState.lastModified = lastModified;

    return {
        items: finalizeItems(parsed.items, limit, range, nowSeconds),
        actions: [],
        preservedGroups: [],
        folderTitle: feedTitle || undefined,
        state: nextState
    };
}

function hostOf(url) {
    return parseURLParts(url)?.host ?? String(url ?? "").replace(/^https?:\/\//, "").split(/[/?#]/)[0];
}

return {
    describe() { return presentation; },
    refresh,
    signIn(input) {
        const feedURL = input.state?.feedURL || input.settings?.feed || "";
        const feedTitle = input.state?.feedTitle || "";
        const host = hostOf(feedURL);
        return {
            title: "Open Feed…",
            url: feedURL || "https://example.com",
            warning: "Sign in to access this feed.",
            emptyText: "New articles from this feed will show up here automatically",
            failureText: "We’re having trouble loading this feed; click here to open it in a tab.",
            failureURL: feedURL || undefined,
            instanceLabel: feedTitle ? feedTitle : "RSS (" + host + ")",
            detailLabel: feedURL || host
        };
    },
    pageChanged(input) {
        return {state: input.state ?? {}, refreshAfter: [], checkSignIn: false};
    }
};
