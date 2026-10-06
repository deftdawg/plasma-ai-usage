// Helper to create buckets JSON string for ListModel storage
function makeBucketsJson(buckets) {
    return JSON.stringify(buckets || []);
}

function parseClaudeCredentials(stdout) {
    if (stdout.length < 10) return null;
    try {
        var creds = JSON.parse(stdout);
        var oauth = creds.claudeAiOauth || {};
        if (!oauth.accessToken) return null;
        
        var tier = oauth.rateLimitTier || "default_claude_pro";
        var planMap = {
            "default_claude_pro": "Pro",
            "default_claude_max_5x": "Max 5x",
            "default_claude_max_20x": "Max 20x"
        };
        
        return {
            provider: "claude",
            name: "Claude",
            icon: "claude.svg",
            token: oauth.accessToken,
            plan: planMap[tier] || tier,
            isRemaining: false,
            valid: true,
            bucketsJson: makeBucketsJson([])
        };
    } catch (e) {
        console.log("Claude Usage: Failed to parse credentials:", e);
        return null;
    }
}

function parseAntigravityConfig(stdout) {
    if (stdout.length < 5) return null;
    try {
        var data = JSON.parse(stdout);
        
        // Handle error from antigravity.py
        if (data.error) {
            return {
                provider: "antigravity",
                name: "Antigravity",
                icon: "antigravity.svg",
                error: data.error,
                valid: true,
                isRemaining: true,
                lastCacheTime: "", // Will be set by main.qml if cached data is used
                bucketsJson: makeBucketsJson([
                    { name: "Claude / OpenAI", percent: -1, used: "N/A", limit: "N/A", reset: "" },
                    { name: "Gemini Pro", percent: -1, used: "N/A", limit: "N/A", reset: "" },
                    { name: "Gemini Flash", percent: -1, used: "N/A", limit: "N/A", reset: "" }
                ])
            };
        }

        // Handle new format from antigravity.py
        if (data.models) {
            var models = data.models || [];
            console.log("Antigravity Models found:", models.length);
            for (var m = 0; m < models.length; m++) {
                console.log(" - " + models[m].name + ": " + models[m].remaining + "%");
            }
            
            function findModel(substring) {
                var lowerSub = substring.toLowerCase();
                for (var i = 0; i < models.length; i++) {
                    if (models[i].name && models[i].name.toLowerCase().indexOf(lowerSub) !== -1) {
                        return models[i];
                    }
                }
                return null;
            }

            // Match by pattern: find a model whose name contains ALL given keywords (case-insensitive)
            function findModelByPattern(keywords) {
                for (var i = 0; i < models.length; i++) {
                    var name = (models[i].name || "").toLowerCase();
                    var allMatch = true;
                    for (var k = 0; k < keywords.length; k++) {
                        if (name.indexOf(keywords[k].toLowerCase()) === -1) {
                            allMatch = false;
                            break;
                        }
                    }
                    if (allMatch) return models[i];
                }
                return null;
            }
            
            // 1. Claude / OpenAI Models (use Opus status)
            var opus = findModel("Opus") || findModel("Sonnet") || findModel("GPT-OSS") || {};
            
            // 2. Gemini Pro (High) - match any version containing both "gemini" and "pro"
            var geminiPro = findModelByPattern(["gemini", "pro"]) || {};
            
            // 3. Gemini Flash - match any version containing both "gemini" and "flash"
            var geminiFlash = findModelByPattern(["gemini", "flash"]) || {};
            
            return {
                provider: "antigravity",
                name: "Antigravity",
                icon: "antigravity.svg",
                
                bucketsJson: makeBucketsJson([
                    {
                        name: opus.name || "Claude / OpenAI",
                        percent: opus.remaining !== undefined ? opus.remaining : 0,
                        used: "N/A",
                        limit: "N/A",
                        reset: opus.reset || ""
                    },
                    {
                        name: geminiPro.name || "Gemini Pro",
                        percent: geminiPro.remaining !== undefined ? geminiPro.remaining : 0,
                        used: "N/A",
                        limit: "N/A",
                        reset: geminiPro.reset || ""
                    },
                    {
                        name: geminiFlash.name || "Gemini Flash",
                        percent: geminiFlash.remaining !== undefined ? geminiFlash.remaining : 0,
                        used: "N/A",
                        limit: "N/A",
                        reset: geminiFlash.reset || ""
                    }
                ]),
                
                isRemaining: true, // Signal to UI to treat as remaining
                valid: true,
                // These must always be defined for ListModel role consistency
                error: "",
                lastCacheTime: ""
            };
        }

        // No valid format found
        return null;
    } catch (e) {
        console.log("Antigravity: Failed to parse config:", e);
        return null;
    }
}

function makeAmpProviderBase() {
    return {
        provider: "amp",
        name: "Amp",
        icon: "amp.svg",
        // Legacy free-quota fields (mirrored from Free plan when present)
        freeUsed: 0,
        freeLimit: 0,
        freePercent: 0,
        freeResets: "",
        freeIsPercent: false,
        rechargeRate: 0,
        creditBalance: 0,
        creditCurrency: "USD",
        isRemaining: true,
        valid: true,
        // Active plan (first plan with remaining > 0; plans consume top-to-bottom)
        activePlanName: "",
        activePlanShort: "",
        activeRemaining: 0,
        activeIsPercent: true,
        activeIsCredits: false,
        // Percent of agent quota (for color/bar) even when remaining is a $ amount
        activeRemainingPercent: -1,
        // Display reset for tray (active plan, or soonest sub when on credits)
        hasActiveCountdown: false,
        resetMsLeft: -1,
        resetCountdown: "",
        resetCompact: "",
        resetLabel: "",
        // Free plan upcoming reset hint (when Free is not active but resets within 6h)
        // Tray form: "MW 44% 19d (2¼h)" — green parenthetical
        freeUpcomingCompact: "",
        freeUpcomingMsLeft: -1,
        showFreeUpcoming: false,
        plansJson: makeBucketsJson([]),
        bucketsJson: makeBucketsJson([])
    };
}

/** Short tray label for a plan: free / MW / GW / "" for credits */
function ampPlanShortLabel(name, kind) {
    if (kind === "credits") return "";
    var n = (name || "").toLowerCase();
    if (n === "free" || n.indexOf("free") !== -1) return "free";
    if (n.indexOf("gigawatt") !== -1 || n === "gw") return "GW";
    if (n.indexOf("megawatt") !== -1 || n === "mw") return "MW";
    // Fallback: up to 3-letter uppercase of first word
    var word = (name || "").split(/\s+/)[0] || "?";
    return word.substring(0, 3).toUpperCase();
}

/**
 * Milliseconds until the next midnight GMT/UTC.
 * Amp Free "resets daily" is a calendar day in GMT, not a rolling 24h from last burn.
 */
function msUntilNextMidnightGMT(nowMs) {
    var now = (nowMs !== undefined && nowMs !== null) ? nowMs : new Date().getTime();
    var d = new Date(now);
    var nextMidnight = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1, 0, 0, 0, 0);
    var ms = nextMidnight - now;
    // Exactly on midnight → full next day
    if (ms <= 0) {
        nextMidnight = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 2, 0, 0, 0, 0);
        ms = nextMidnight - now;
    }
    return ms;
}

function isAmpDailyResetLabel(phrase) {
    if (!phrase) return false;
    var p = String(phrase).trim().toLowerCase();
    p = p.replace(/^upon\s+renewal\s+in\s+/, "").replace(/^in\s+/, "");
    return p === "daily" || p === "today";
}

/**
 * Compact form of a human reset phrase from amp usage text.
 * "daily"/"today" → live hours-to-midnight-GMT (via formatAmpCountdownCompact)
 * "1 month" → "1mo", "15 days" → "15d", "2 weeks" → "2w"
 */
function formatAmpResetPhraseCompact(phrase) {
    if (!phrase) return "";
    var p = String(phrase).trim().toLowerCase();
    // Strip leading "upon renewal in " / "in "
    p = p.replace(/^upon\s+renewal\s+in\s+/, "").replace(/^in\s+/, "");
    // Daily free quota: countdown to next midnight GMT (never a static "24h")
    if (p === "daily" || p === "today") {
        return formatAmpCountdownCompact(msUntilNextMidnightGMT());
    }
    var m = p.match(/^(\d+(?:\.\d+)?)\s*(month|months|mo|day|days|d|week|weeks|w|hour|hours|h|minute|minutes|min|m)\b/);
    if (m) {
        var n = m[1];
        var unit = m[2];
        if (unit.indexOf("month") === 0 || unit === "mo") return n + "mo";
        if (unit.indexOf("week") === 0 || unit === "w") return n + "w";
        if (unit.indexOf("day") === 0 || unit === "d") return n + "d";
        if (unit.indexOf("hour") === 0 || unit === "h") return n + "h";
        if (unit.indexOf("min") === 0 || unit === "m") return n + "m";
    }
    // Already compact-ish
    if (/^\d+(\.\d+)?(mo|w|d|h|m)$/i.test(p)) return p;
    return phrase;
}

/**
 * Rough ms estimate from a reset phrase for "soonest" comparisons.
 * daily → real ms until midnight GMT; N months/days/weeks → approximate duration.
 */
function estimateResetPhraseMs(phrase) {
    if (!phrase) return Number.MAX_SAFE_INTEGER;
    var p = String(phrase).trim().toLowerCase();
    p = p.replace(/^upon\s+renewal\s+in\s+/, "").replace(/^in\s+/, "");
    if (p === "daily" || p === "today") return msUntilNextMidnightGMT();
    var m = p.match(/^(\d+(?:\.\d+)?)\s*(month|months|mo|day|days|d|week|weeks|w|hour|hours|h|minute|minutes|min|m)\b/);
    if (!m) return Number.MAX_SAFE_INTEGER;
    var n = parseFloat(m[1]);
    var unit = m[2];
    if (unit.indexOf("month") === 0 || unit === "mo") return n * 30 * 24 * 3600000;
    if (unit.indexOf("week") === 0 || unit === "w") return n * 7 * 24 * 3600000;
    if (unit.indexOf("day") === 0 || unit === "d") return n * 24 * 3600000;
    if (unit.indexOf("hour") === 0 || unit === "h") return n * 3600000;
    if (unit.indexOf("min") === 0 || unit === "m") return n * 60000;
    return Number.MAX_SAFE_INTEGER;
}

function parseAmpMoney(s) {
    if (s === undefined || s === null || s === "") return NaN;
    return parseFloat(String(s).replace(/,/g, ""));
}

function formatAmpMoney(n) {
    var x = Number(n);
    if (isNaN(x)) return "$0.00";
    return "$" + x.toFixed(2);
}

/**
 * Parse the body of a subscription usage line (after "Name:").
 *
 * New CLI:
 *   agent usage $57.16 of $60 remaining (95%), orb usage 2,250h of 2,250h
 *   a1.small orb hours remaining (100%) - period ... resets upon renewal in 17 days
 * Legacy:
 *   95% other usage and 100% orb usage remaining
 *   80% remaining
 *
 * Agent remaining prefers $ amount; orb is always a percent.
 */
function parseAmpSubscriptionRest(rest) {
    var out = {
        remaining: 0,
        remainingIsPercent: true,
        remainingPercent: -1,
        otherRemaining: -1,
        orbRemaining: -1
    };
    if (!rest) return out;
    var r = String(rest);

    var agentDollar = r.match(/agent usage\s+\$([0-9,.]+)\s+of\s+\$([0-9,.]+)\s+remaining\s*\(([0-9.]+)%\)/i);
    if (agentDollar) {
        out.remaining = parseAmpMoney(agentDollar[1]);
        out.remainingIsPercent = false;
        out.remainingPercent = parseFloat(agentDollar[3]);
        out.otherRemaining = out.remainingPercent;
    } else {
        var agentPct = r.match(/agent usage\s+([0-9.]+)%/i);
        var dual = r.match(/([0-9.]+)%\s+other\s+usage\s+and\s+([0-9.]+)%\s+orb/i);
        var single = r.match(/([0-9.]+)%\s+remaining/i);
        if (agentPct) {
            out.remaining = parseFloat(agentPct[1]);
            out.remainingIsPercent = true;
            out.remainingPercent = out.remaining;
            out.otherRemaining = out.remaining;
        } else if (dual) {
            out.otherRemaining = parseFloat(dual[1]);
            out.orbRemaining = parseFloat(dual[2]);
            out.remaining = out.otherRemaining;
            out.remainingIsPercent = true;
            out.remainingPercent = out.remaining;
        } else if (single) {
            out.remaining = parseFloat(single[1]);
            out.remainingIsPercent = true;
            out.remainingPercent = out.remaining;
        }
    }

    var orbPct = r.match(/orb usage[\s\S]*?remaining\s*\(([0-9.]+)%\)/i)
        || r.match(/([0-9.]+)%\s+orb\s+usage/i);
    if (orbPct) {
        out.orbRemaining = parseFloat(orbPct[1]);
    }
    return out;
}

function makeAmpPlan(opts) {
    var remainingIsPercent = opts.remainingIsPercent !== false;
    var remainingPercent = opts.remainingPercent !== undefined ? opts.remainingPercent : -1;
    if (remainingPercent < 0 && remainingIsPercent) {
        remainingPercent = opts.remaining !== undefined ? opts.remaining : 0;
    }
    return {
        name: opts.name || "",
        kind: opts.kind || "subscription", // free | subscription | credits
        shortLabel: opts.shortLabel || ampPlanShortLabel(opts.name, opts.kind),
        remaining: opts.remaining !== undefined ? opts.remaining : 0,
        remainingIsPercent: remainingIsPercent,
        remainingPercent: remainingPercent,
        otherRemaining: opts.otherRemaining !== undefined ? opts.otherRemaining : -1,
        orbRemaining: opts.orbRemaining !== undefined ? opts.orbRemaining : -1,
        resetLabel: opts.resetLabel || "",
        resetCompact: opts.resetCompact || formatAmpResetPhraseCompact(opts.resetLabel || ""),
        resetCountdown: opts.resetCountdown || "",
        resetMsLeft: opts.resetMsLeft !== undefined ? opts.resetMsLeft : -1,
        hasActiveCountdown: !!opts.hasActiveCountdown,
        rechargeRate: opts.rechargeRate || 0
    };
}

/** Extract reset phrase from a line of amp usage text */
function extractAmpResetLabel(line) {
    // (resets daily) or (replenishes +$0.83/hour)
    var paren = line.match(/\((?:resets|replenishes)\s+([^)]+)\)/i);
    if (paren) return paren[1].trim();
    // "resets upon renewal in 1 month" / "resets in 15 days"
    var renew = line.match(/resets\s+(?:upon\s+renewal\s+)?in\s+([^-\n]+?)(?:\s*-\s*https?:\/\/|$)/i);
    if (renew) return renew[1].trim();
    var daily = line.match(/resets\s+(daily|today)\b/i);
    if (daily) return daily[1].toLowerCase();
    return "";
}

/**
 * Parse a single Amp usage line into a plan object, or null if not a plan line.
 *
 * Formats:
 *   Amp Free: 100% remaining today (resets daily) - https://...
 *   Amp Free: $10.71/$20 remaining (replenishes +$0.83/hour)
 *   Amp Megawatt Tier: agent usage $33.37 of $60 remaining (56%), orb usage 2,250h of 2,250h a1.small orb hours remaining (100%) - period 2026-08-18 to 2026-09-18, resets upon renewal in 8 days
 *   Amp Megawatt Subscription: agent usage $57.16 of $60 remaining (95%), orb usage 2,250h of 2,250h a1.small orb hours remaining (100%) - period 2026-08-18 to 2026-09-18, resets upon renewal in 17 days
 *   Amp Megawatt Subscription: 100% other usage and 100% orb usage remaining - resets upon renewal in 1 month
 *   Subscription Megawatt: 100% other usage and 100% orb usage remaining - resets upon renewal in 1 month
 *   Subscription Gigawatt: 80% remaining - resets upon renewal in 12 days
 *   Individual credits: $175.38 remaining (...)
 */
function parseAmpPlanLine(line) {
    if (!line || line.length < 5) return null;
    // Strip markdown emphasis the CLI may wrap around labels (**Amp Megawatt Tier:**)
    var trimmed = line.replace(/\*+/g, " ").replace(/\s+/g, " ").trim();

    // Individual credits: $175.38 remaining
    var creditMatch = trimmed.match(/^Individual\s+credits:\s*\$([0-9.]+)\s+remaining/i);
    if (creditMatch) {
        return makeAmpPlan({
            name: "Credits",
            kind: "credits",
            shortLabel: "",
            remaining: parseFloat(creditMatch[1]),
            remainingIsPercent: false,
            resetLabel: ""
        });
    }

    // Amp Free: 99% remaining today (resets daily)
    var freePct = trimmed.match(/^Amp\s+Free:\s*([0-9.]+)%\s+remaining/i);
    if (freePct) {
        var freeRemaining = parseFloat(freePct[1]);
        var freeReset = extractAmpResetLabel(trimmed) || "daily";
        return makeAmpPlan({
            name: "Free",
            kind: "free",
            shortLabel: "free",
            remaining: freeRemaining,
            remainingIsPercent: true,
            resetLabel: freeReset
        });
    }

    // Amp Free: $10.71/$20 remaining (replenishes +$0.83/hour)
    var freeDollar = trimmed.match(/^Amp\s+Free:\s*\$([0-9.]+)\/\$([0-9.]+)\s+remaining/i);
    if (freeDollar) {
        var rem = parseFloat(freeDollar[1]);
        var lim = parseFloat(freeDollar[2]);
        var resetLbl = extractAmpResetLabel(trimmed);
        var rate = 0;
        var rateMatch = trimmed.match(/\+\$([0-9.]+)\/hour/);
        if (rateMatch) rate = parseFloat(rateMatch[1]);
        return makeAmpPlan({
            name: "Free",
            kind: "free",
            shortLabel: "free",
            remaining: lim > 0 ? (rem / lim * 100) : 0,
            remainingIsPercent: true,
            // Keep dollar amounts in other/orb unused; remaining is % of free $
            resetLabel: resetLbl,
            rechargeRate: rate
        });
    }

    // Paid plan (Megawatt/Gigawatt/Other). CLI labels have changed over time:
    //   "Amp Megawatt Tier: agent usage $33.37 of $60 remaining (56%), orb usage ... (100%) - ..."
    //   "Amp Megawatt Subscription: agent usage $57.16 of $60 remaining (95%), orb usage ... (100%) - ..."
    //   "Subscription Megawatt: 80% remaining - ..." / "95% other usage and 100% orb usage"
    var subMatch = trimmed.match(/^Amp\s+(.+?)\s+(?:Subscription|Tier|Plan):\s*(.+)$/i)
        || trimmed.match(/^Subscription\s+([^:]+):\s*(.+)$/i)
        || trimmed.match(/^Amp\s+(?!Free\b)([^:]+):\s*(.+)$/i);
    if (subMatch) {
        var subName = subMatch[1].trim().replace(/\s+(?:Subscription|Tier|Plan)$/i, "").trim();
        var parsed = parseAmpSubscriptionRest(subMatch[2]);
        var subReset = extractAmpResetLabel(trimmed);
        return makeAmpPlan({
            name: subName,
            kind: "subscription",
            remaining: parsed.remaining,
            remainingIsPercent: parsed.remainingIsPercent,
            remainingPercent: parsed.remainingPercent,
            otherRemaining: parsed.otherRemaining,
            orbRemaining: parsed.orbRemaining,
            resetLabel: subReset
        });
    }

    return null;
}

function parseAmpPlansFromText(text) {
    var plans = [];
    var lines = String(text).split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
        var plan = parseAmpPlanLine(lines[i]);
        if (plan) plans.push(plan);
    }
    return plans;
}

/**
 * Whether a plan still has usable quota for tray "active plan" selection.
 *
 * Primary `remaining` is inference/other for dual MW/GW pools. Orb is shown in
 * the popup but does NOT keep a subscription active once other hits 0% — usage
 * then falls through to Credits (tray: "$175 (6d)").
 */
function ampPlanHasRemaining(plan) {
    if (!plan) return false;
    if (plan.kind === "credits") return (plan.remaining || 0) > 0;
    // Dual-pool: remaining is already set to other (inference); ignore orb here
    return (plan.remaining || 0) > 0;
}

/**
 * Pick the active plan: first plan in order with remaining > 0.
 * Plans are consumed top-to-bottom (Free → Subscription → Credits).
 */
function resolveAmpActivePlan(plans) {
    if (!plans || plans.length === 0) return null;
    for (var i = 0; i < plans.length; i++) {
        if (ampPlanHasRemaining(plans[i])) return plans[i];
    }
    // All exhausted — fall back to last plan (usually credits)
    return plans[plans.length - 1];
}

/** Mirror Free plan + credits into legacy fields used by older UI paths */
function applyAmpLegacyFields(result, plans) {
    var freePlan = null;
    var creditPlan = null;
    for (var i = 0; i < plans.length; i++) {
        if (plans[i].kind === "free" && !freePlan) freePlan = plans[i];
        if (plans[i].kind === "credits" && !creditPlan) creditPlan = plans[i];
    }

    if (freePlan) {
        result.freeIsPercent = freePlan.remainingIsPercent;
        result.freeLimit = 100;
        result.freeUsed = 100 - (freePlan.remaining || 0);
        result.freePercent = freePlan.remaining || 0;
        result.freeResets = freePlan.resetLabel || "";
        result.rechargeRate = freePlan.rechargeRate || 0;
    }

    if (creditPlan) {
        result.creditBalance = creditPlan.remaining || 0;
        result.creditCurrency = "USD";
    }

    var active = resolveAmpActivePlan(plans);
    if (active) {
        result.activePlanName = active.name || "";
        result.activePlanShort = active.shortLabel || "";
        result.activeRemaining = active.remaining || 0;
        result.activeIsPercent = !!active.remainingIsPercent;
        result.activeIsCredits = active.kind === "credits";
        result.activeRemainingPercent = active.remainingPercent !== undefined ? active.remainingPercent : -1;
        result.resetLabel = active.resetLabel || "";
        result.resetCompact = active.resetCompact || "";
        result.resetCountdown = active.resetCountdown || "";
        result.resetMsLeft = active.resetMsLeft !== undefined ? active.resetMsLeft : -1;
        result.hasActiveCountdown = !!active.hasActiveCountdown;
    }

    result.plansJson = makeBucketsJson(plans);
    return result;
}

function parseAmpConfig(stdout) {
    if (stdout.length < 5) return null;

    // Text output from `amp usage` (any of the optional plan lines)
    if (/Amp\s+Free:|Individual\s+credits:|Subscription\s+\S+:|Amp\s+\S+\s+(?:Subscription|Tier|Plan):/i.test(stdout)) {
        return parseAmpUsageText(stdout);
    }

    try {
        var data = JSON.parse(stdout);

        // New multi-plan JSON shape
        if (data.plans && data.plans.length) {
            var resultJson = makeAmpProviderBase();
            var plansFromJson = [];
            for (var j = 0; j < data.plans.length; j++) {
                var pj = data.plans[j];
                plansFromJson.push(makeAmpPlan({
                    name: pj.name || "",
                    kind: pj.kind || (String(pj.name).toLowerCase() === "credits" ? "credits"
                        : String(pj.name).toLowerCase() === "free" ? "free" : "subscription"),
                    remaining: pj.remaining !== undefined ? pj.remaining : (pj.quota_remaining !== undefined ? pj.quota_remaining : 0),
                    remainingIsPercent: pj.remaining_is_percent !== undefined ? pj.remaining_is_percent : (pj.kind !== "credits"),
                    remainingPercent: pj.remaining_percent !== undefined ? pj.remaining_percent : -1,
                    otherRemaining: pj.other_remaining !== undefined ? pj.other_remaining : -1,
                    orbRemaining: pj.orb_remaining !== undefined ? pj.orb_remaining : -1,
                    resetLabel: pj.reset || pj.reset_label || pj.resets_at || "",
                    resetCompact: pj.reset_compact || "",
                    resetCountdown: pj.reset_countdown || ""
                }));
            }
            return applyAmpLegacyFields(resultJson, plansFromJson);
        }

        // Legacy single free_quota + credits JSON
        var freeQuota = data.free_quota || {};
        var credits = data.credits || {};
        var freeUsed = freeQuota.used || 0;
        var freeLimit = freeQuota.limit || 10;
        var plans = [];

        if (freeQuota.limit !== undefined || freeQuota.used !== undefined || freeQuota.remaining !== undefined) {
            var remPct;
            if (freeQuota.remaining !== undefined && freeQuota.limit) {
                remPct = freeQuota.remaining / freeQuota.limit * 100;
            } else if (freeLimit > 0) {
                remPct = ((freeLimit - freeUsed) / freeLimit) * 100;
            } else {
                remPct = 0;
            }
            plans.push(makeAmpPlan({
                name: "Free",
                kind: "free",
                shortLabel: "free",
                remaining: remPct,
                remainingIsPercent: true,
                resetLabel: freeQuota.resets_at || "",
                rechargeRate: freeQuota.recharge_rate || 0
            }));
        }
        if (credits.balance !== undefined) {
            plans.push(makeAmpPlan({
                name: "Credits",
                kind: "credits",
                remaining: credits.balance || 0,
                remainingIsPercent: false
            }));
        }

        var result = makeAmpProviderBase();
        result.rechargeRate = freeQuota.recharge_rate || 0;
        result.creditCurrency = credits.currency || "USD";
        return applyAmpLegacyFields(result, plans);
    } catch (e) {
        return parseAmpUsageText(stdout);
    }
}

function parseAmpUsageText(text) {
    try {
        var plans = parseAmpPlansFromText(text);
        if (plans.length === 0) return null;
        var result = makeAmpProviderBase();
        return applyAmpLegacyFields(result, plans);
    } catch (e) {
        console.log("Amp: Failed to parse text usage:", e);
        return null;
    }
}

// Pad integer to two digits for HH:MM display
function pad2(n) {
    return (n < 10 ? "0" : "") + n;
}

// Format remaining ms as HH:MM countdown (duration, not clock time)
function formatAmpCountdownHHMM(msLeft) {
    if (msLeft <= 0) return "00:00";
    var totalMins = Math.floor(msLeft / 60000);
    var hours = Math.floor(totalMins / 60);
    var mins = totalMins % 60;
    // Cap display at 99:59 for pathological cases
    if (hours > 99) hours = 99;
    return pad2(hours) + ":" + pad2(mins);
}

// Compact tray/powerline form for Amp reset countdown (ALWAYS rounds up):
//   >= 3h          → whole hours, rounded UP ("23h1m" → "24h"; "23h0m" → "23h")
//   >= 1h and < 3h → quarter hours rounded UP with unicode ¼ ½ ¾
//                    ("2h45m" → "2¾h"; "2h46m" → "3h")
//   < 1h           → floor minutes, no round-up ("45m", "33m")
//
// Popup/tooltips use formatAmpCountdownHHMM (real HH:MM) — not this helper.
function formatAmpCountdownCompact(msLeft) {
    if (msLeft <= 0) return "0m";
    // Minute precision for round-up boundaries (partial minutes don't count)
    var totalMins = Math.floor(msLeft / 60000);
    if (totalMins <= 0) return "0m";

    // >= 3h: round UP to whole hours (daily free shows 24h until exactly 23h0m)
    if (totalMins >= 180) {
        return Math.ceil(totalMins / 60) + "h";
    }

    // >= 1h and < 3h: round UP to next quarter-hour (15-minute steps)
    if (totalMins >= 60) {
        var quarterMins = Math.ceil(totalMins / 15) * 15;
        if (quarterMins >= 180) {
            return "3h";
        }
        var whole = Math.floor(quarterMins / 60);
        var remMins = quarterMins % 60;
        var fracStr = "";
        if (remMins === 45) fracStr = "¾";
        else if (remMins === 30) fracStr = "½";
        else if (remMins === 15) fracStr = "¼";
        return whole + fracStr + "h";
    }

    // < 1h: exact floor minutes (no round-up)
    return totalMins + "m";
}

/** Six-hour window (ms) for showing Free upcoming-reset hint on non-Free active plans */
var AMP_FREE_UPCOMING_WINDOW_MS = 6 * 3600000;

/**
 * Fill tray reset fields for Amp plans.
 *
 * Amp Free "resets daily" → live countdown to next midnight GMT/UTC
 * (not a static "24h", and not a rolling window from last 100% edge).
 * Non-free plans use their phrase-based reset (1mo, 28d, …).
 * When active plan is Credits, show the soonest-resetting subscription's reset.
 *
 * @param {object} ampProv - provider object from parseAmpConfig/parseAmpUsageText
 * @param {object} config  - Plasmoid.configuration (optional; last-% still recorded for diagnostics)
 * @returns {object} ampProv with countdown fields filled in
 */
function applyAmpResetTracking(ampProv, config) {
    if (!ampProv) {
        return ampProv;
    }

    var plans = [];
    try {
        plans = JSON.parse(ampProv.plansJson || "[]");
    } catch (e) {
        plans = [];
    }

    // Locate free plan for daily midnight-GMT countdown
    var freeIdx = -1;
    for (var i = 0; i < plans.length; i++) {
        if (plans[i].kind === "free") {
            freeIdx = i;
            break;
        }
    }

    if (freeIdx >= 0 && plans[freeIdx].remainingIsPercent) {
        var remaining = plans[freeIdx].remaining || 0;
        if (config) {
            config.ampLastRemainingPercent = remaining;
        }
        ampProv.freePercent = remaining;

        var freeResetLabel = plans[freeIdx].resetLabel || "daily";
        plans[freeIdx].hasActiveCountdown = false;
        plans[freeIdx].resetMsLeft = -1;
        plans[freeIdx].resetCountdown = "";

        if (isAmpDailyResetLabel(freeResetLabel) || !plans[freeIdx].resetLabel) {
            // Live countdown to next midnight GMT — always, not only after 100% edge
            var msLeft = msUntilNextMidnightGMT();
            plans[freeIdx].hasActiveCountdown = true;
            plans[freeIdx].resetMsLeft = msLeft;
            plans[freeIdx].resetCountdown = formatAmpCountdownHHMM(msLeft);
            plans[freeIdx].resetCompact = formatAmpCountdownCompact(msLeft);
            if (!plans[freeIdx].resetLabel) {
                plans[freeIdx].resetLabel = "daily";
            }
        } else {
            plans[freeIdx].resetCompact = formatAmpResetPhraseCompact(freeResetLabel);
            plans[freeIdx].resetCountdown = plans[freeIdx].resetCompact;
        }

        // Mirror free plan into legacy fields
        ampProv.freeIsPercent = true;
        ampProv.freeLimit = 100;
        ampProv.freeUsed = 100 - remaining;
        ampProv.freeResets = plans[freeIdx].resetCountdown || plans[freeIdx].resetCompact || freeResetLabel;
    }

    // Ensure non-free plans have compact reset labels (daily → GMT if any slip through)
    for (var p = 0; p < plans.length; p++) {
        if (plans[p].kind === "credits") continue;
        if (plans[p].kind === "free" && plans[p].hasActiveCountdown) continue;

        if (isAmpDailyResetLabel(plans[p].resetLabel) || isAmpDailyResetLabel(plans[p].resetCompact)) {
            var dailyMs = msUntilNextMidnightGMT();
            plans[p].hasActiveCountdown = true;
            plans[p].resetMsLeft = dailyMs;
            plans[p].resetCountdown = formatAmpCountdownHHMM(dailyMs);
            plans[p].resetCompact = formatAmpCountdownCompact(dailyMs);
            continue;
        }

        if (!plans[p].resetCompact && plans[p].resetLabel) {
            plans[p].resetCompact = formatAmpResetPhraseCompact(plans[p].resetLabel);
        }
        if (!plans[p].resetCountdown && plans[p].resetCompact) {
            plans[p].resetCountdown = plans[p].resetCompact;
        }
    }

    // Re-resolve active plan after free countdown updates
    var active = resolveAmpActivePlan(plans);
    if (!active) {
        ampProv.plansJson = makeBucketsJson(plans);
        return ampProv;
    }

    ampProv.activePlanName = active.name || "";
    ampProv.activePlanShort = active.shortLabel || "";
    ampProv.activeRemaining = active.remaining || 0;
    ampProv.activeIsPercent = !!active.remainingIsPercent;
    ampProv.activeIsCredits = active.kind === "credits";
    ampProv.activeRemainingPercent = active.remainingPercent !== undefined ? active.remainingPercent : -1;

    // Display reset: for credits, use soonest-resetting non-credit subscription
    var displayPlan = active;
    if (active.kind === "credits") {
        var soonest = null;
        var soonestMs = Number.MAX_SAFE_INTEGER;
        for (var s = 0; s < plans.length; s++) {
            var pl = plans[s];
            if (pl.kind === "credits") continue;
            var est;
            if (pl.hasActiveCountdown && pl.resetMsLeft >= 0) {
                est = pl.resetMsLeft;
            } else {
                est = estimateResetPhraseMs(pl.resetLabel || pl.resetCompact || "");
            }
            if (est < soonestMs) {
                soonestMs = est;
                soonest = pl;
            }
        }
        if (soonest) displayPlan = soonest;
    }

    ampProv.hasActiveCountdown = !!displayPlan.hasActiveCountdown;
    ampProv.resetMsLeft = displayPlan.resetMsLeft !== undefined ? displayPlan.resetMsLeft : -1;
    ampProv.resetCountdown = displayPlan.resetCountdown || displayPlan.resetCompact || "";
    ampProv.resetCompact = displayPlan.resetCompact || displayPlan.resetCountdown || "";
    ampProv.resetLabel = displayPlan.resetLabel || ampProv.resetCompact || "";
    // Keep freeResets useful for tooltips
    if (ampProv.hasActiveCountdown && ampProv.resetCountdown) {
        ampProv.freeResets = ampProv.resetCountdown;
    }

    // Free upcoming-reset hint: only while on a paid subscription (MW/GW) with
    // remaining quota. When on Credits the main reset is already the soonest
    // sub/free time (e.g. "$175 (5h)"), so a second Free bracket would duplicate.
    ampProv.freeUpcomingCompact = "";
    ampProv.freeUpcomingMsLeft = -1;
    ampProv.showFreeUpcoming = false;
    if (freeIdx >= 0 && active.kind === "subscription") {
        var freePlan = plans[freeIdx];
        var freeMs = -1;
        if (freePlan.hasActiveCountdown && freePlan.resetMsLeft >= 0) {
            freeMs = freePlan.resetMsLeft;
        } else if (isAmpDailyResetLabel(freePlan.resetLabel) || isAmpDailyResetLabel(freePlan.resetCompact)) {
            freeMs = msUntilNextMidnightGMT();
        } else if (freePlan.resetLabel || freePlan.resetCompact) {
            freeMs = estimateResetPhraseMs(freePlan.resetLabel || freePlan.resetCompact);
            if (freeMs === Number.MAX_SAFE_INTEGER) freeMs = -1;
        }
        if (freeMs >= 0 && freeMs <= AMP_FREE_UPCOMING_WINDOW_MS) {
            ampProv.freeUpcomingMsLeft = freeMs;
            ampProv.freeUpcomingCompact = formatAmpCountdownCompact(freeMs);
            ampProv.showFreeUpcoming = ampProv.freeUpcomingCompact !== "";
        }
    }

    ampProv.plansJson = makeBucketsJson(plans);
    return ampProv;
}
