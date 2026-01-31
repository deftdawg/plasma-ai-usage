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
                    { name: "Gemini 3 Pro", percent: -1, used: "N/A", limit: "N/A", reset: "" },
                    { name: "Gemini 3 Flash", percent: -1, used: "N/A", limit: "N/A", reset: "" }
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
            
            // 1. Claude / OpenAI Models (use Opus status)
            var opus = findModel("Opus") || findModel("Sonnet") || findModel("GPT-OSS") || {};
            
            // 2. Gemini 3 Pro (High)
            var geminiPro = findModel("Gemini 3 Pro (High)") || {};
            
            // 3. Gemini 3 Flash
            var geminiFlash = findModel("Gemini 3 Flash") || {};
            
            return {
                provider: "antigravity",
                name: "Antigravity",
                icon: "antigravity.svg",
                
                bucketsJson: makeBucketsJson([
                    {
                        name: "Claude / OpenAI",
                        percent: opus.remaining !== undefined ? opus.remaining : 0,
                        used: "N/A",
                        limit: "N/A",
                        reset: opus.reset || ""
                    },
                    {
                        name: "Gemini 3 Pro",
                        percent: geminiPro.remaining !== undefined ? geminiPro.remaining : 0,
                        used: "N/A",
                        limit: "N/A",
                        reset: geminiPro.reset || ""
                    },
                    {
                        name: "Gemini 3 Flash",
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

function parseAmpConfig(stdout) {
    if (stdout.length < 5) return null;
    
    // Check if it's the new text output format
    if (stdout.indexOf("Amp Free:") !== -1 || stdout.indexOf("Individual credits:") !== -1) {
        return parseAmpUsageText(stdout);
    }

    try {
        var data = JSON.parse(stdout);
        
        var freeQuota = data.free_quota || {};
        var credits = data.credits || {};
        
        var freeUsed = freeQuota.used || 0;
        var freeLimit = freeQuota.limit || 10;
        
        return {
            provider: "amp",
            name: "Amp",
            icon: "amp.svg",
            freeUsed: freeUsed,
            freeLimit: freeLimit,
            freePercent: freeLimit > 0 ? (freeUsed / freeLimit * 100) : 0,
            freeResets: freeQuota.resets_at || "",
            rechargeRate: freeQuota.recharge_rate || 0,
            creditBalance: credits.balance || 0.00,
            creditCurrency: credits.currency || "USD",
            isRemaining: true,
            valid: true,
            bucketsJson: makeBucketsJson([])
        };
    } catch (e) {
        // Fallback to text parsing if JSON fails
        return parseAmpUsageText(stdout);
    }
}

function parseAmpUsageText(text) {
    try {
        var result = {
            provider: "amp",
            name: "Amp",
            icon: "amp.svg",
            freeUsed: 0,
            freeLimit: 0,
            freePercent: 0,
            freeResets: "",
            creditBalance: 0,
            creditCurrency: "USD",
            isRemaining: true,
            valid: true,
            bucketsJson: makeBucketsJson([])
        };

        // Parse Amp Free: $10.71/$20 remaining (replenishes +$0.83/hour)
        var freeMatch = text.match(/Amp Free: \$([0-9.]+)\/\$([0-9.]+)\s+remaining/);
        if (freeMatch) {
            var remaining = parseFloat(freeMatch[1]);
            var limit = parseFloat(freeMatch[2]);
            result.freeLimit = limit;
            result.freeUsed = limit - remaining;
            result.freePercent = limit > 0 ? (result.freeUsed / limit * 100) : 0;
        }

        // Parse replenishes info
        var resetMatch = text.match(/\(replenishes ([^)]+)\)/);
        if (resetMatch) {
            result.freeResets = resetMatch[1];
            // Extract numeric rate (e.g. +$0.83/hour -> 0.83)
            var rateMatch = resetMatch[1].match(/\+\$([0-9.]+)\/hour/);
            if (rateMatch) {
                result.rechargeRate = parseFloat(rateMatch[1]);
            }
        }

        // Parse Individual credits: $77.57 remaining
        var creditMatch = text.match(/Individual credits: \$([0-9.]+)\s+remaining/);
        if (creditMatch) {
            result.creditBalance = parseFloat(creditMatch[1]);
        }

        return result;
    } catch (e) {
        console.log("Amp: Failed to parse text usage:", e);
        return null;
    }
}
