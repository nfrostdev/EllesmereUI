if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUICdmBarGlows.lua
--  Bar Glows: Overlays glow effects on action bar / CDM bar buttons when
--  configured buff/aura spells become active (or inactive in MISSING mode).
--  v4: CDM bar assignments keyed by cooldownID for stability across reanchors.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...

-- Glow functions from main file (available after main file loads)
local StartNativeGlow = function(...) if ns.StartNativeGlow then return ns.StartNativeGlow(...) end end
local StopNativeGlow  = function(...) if ns.StopNativeGlow then return ns.StopNativeGlow(...) end end

-- Slot offsets per bar index (matches EllesmereUIActionBars BAR_SLOT_OFFSETS)
local BAR_OFFSETS = { 0, 60, 48, 24, 36, 144, 156, 168 }

-------------------------------------------------------------------------------
--  Button Lookup
-------------------------------------------------------------------------------

-- Action bar button lookup (stable slot-based)
local function GetActionBarButton(barIdx, btnIdx)
    local offset = BAR_OFFSETS[barIdx] or 0
    local slot = offset + btnIdx
    local btn = _G["EABButton" .. slot]
    if btn then return btn end
    local BLIZZ_PREFIXES = {
        "ActionButton",
        "MultiBarBottomLeftButton",
        "MultiBarBottomRightButton",
        "MultiBarRightButton",
        "MultiBarLeftButton",
        "MultiBar5Button",
        "MultiBar6Button",
        "MultiBar7Button",
    }
    if barIdx >= 1 and barIdx <= #BLIZZ_PREFIXES then
        btn = _G[BLIZZ_PREFIXES[barIdx] .. btnIdx]
    end
    return btn
end

-- CDM bar icon lookup by cooldownID (stable across reanchors).
-- Walks all CDM bars (default + extras) since the 1-spell-per-bar invariant
-- guarantees a cooldownID can only live on one bar at a time.
local function FindCDMButtonByCooldownID(cooldownID)
    if not ns.cdmBarIcons then return nil end
    for _, icons in pairs(ns.cdmBarIcons) do
        for i = 1, #icons do
            local icon = icons[i]
            if icon and icon.cooldownID == cooldownID then
                return icon
            end
        end
    end
    return nil
end

-------------------------------------------------------------------------------
--  Data Access
-------------------------------------------------------------------------------

--- Get barGlows data from SavedVariables (with lazy init)
function ns.GetBarGlows()
    local specKey = ns.GetActiveSpecKey and ns.GetActiveSpecKey()
    if not specKey then return { enabled = true, selectedBar = "cooldowns", assignments = {} } end
    -- Bar glows are spec-specific and per-profile: specProfiles[specKey].barGlows
    -- under the active profile's bucket (ns.GetActiveSpecProfiles).
    local sp = ns.GetActiveSpecProfiles and ns.GetActiveSpecProfiles()
    if not sp then return { enabled = true, selectedBar = "cooldowns", assignments = {} } end
    if not sp[specKey] then sp[specKey] = { barSpells = {} } end
    local prof = sp[specKey]
    if not prof.barGlows or not next(prof.barGlows) then
        prof.barGlows = {
            enabled = true,
            selectedBar = "cooldowns",
            assignments = {},
        }
    end
    -- Live migration: colorMode replaced classColor + "glowColor set" nil check
    if not prof.barGlows._colorModeMigrated then
        prof.barGlows._colorModeMigrated = true
        for _, buffList in pairs(prof.barGlows.assignments) do
            for _, entry in ipairs(buffList) do
                if not entry.colorMode then
                    if entry.classColor then
                        entry.colorMode = "class"
                    elseif entry.glowColor then
                        entry.colorMode = "custom"
                    else
                        entry.colorMode = "default"
                    end
                end
            end
        end
    end
    return prof.barGlows
end

--- Get assignments for an action bar button (index-based)
function ns.GetButtonAssignments(barIdx, btnIdx)
    local bg = ns.GetBarGlows()
    local key = barIdx .. "_" .. btnIdx
    return bg.assignments[key]
end

--- Get assignments for a CDM bar icon (cooldownID-based)
function ns.GetCDMButtonAssignments(cooldownID)
    local bg = ns.GetBarGlows()
    local key = "cdm_" .. cooldownID
    return bg.assignments[key]
end

--- Returns true if the user has at least one bar glow assignment
function ns.HasBarGlowAssignments()
    local bg = ns.GetBarGlows()
    if not bg or not bg.assignments then return false end
    for _, buffList in pairs(bg.assignments) do
        if buffList and #buffList > 0 then return true end
    end
    return false
end

--- Collect all tracked buff spells across all CDM buff bars
--- Returns tracked (displayed in CDM) and untracked (known but not displayed)
function ns.GetAllCDMBuffSpells()
    local ECME = ns.ECME
    if not ECME or not ECME.db then return {}, {} end
    local p = ECME.db.profile
    if not p or not p.cdmBars or not p.cdmBars.bars then return {}, {} end

    local trackedSet = {}
    local trackedOrder = {}

    for _, bar in ipairs(p.cdmBars.bars) do
        if ns.IsBarBuffFamily(bar) then
            local spells = ns.GetCDMSpellsForBar and ns.GetCDMSpellsForBar(bar.key)
            if spells then
                for _, sp in ipairs(spells) do
                    if sp.isKnown and sp.spellID and sp.spellID > 0 and not trackedSet[sp.spellID] then
                        local entry = {
                            spellID = sp.spellID,
                            cdID = sp.cdID,
                            name = sp.name,
                            icon = sp.icon,
                            barKey = bar.key,
                            barName = bar.name or bar.key,
                        }
                        trackedSet[sp.spellID] = entry
                        trackedOrder[#trackedOrder + 1] = entry
                    end
                end
            end
        end
    end

    local IsInViewer = ns.IsSpellInBuffBarViewer
    local tracked, untracked = {}, {}
    for _, entry in ipairs(trackedOrder) do
        local sid = entry.spellID
        if sid and IsInViewer and IsInViewer(sid) then
            tracked[#tracked + 1] = entry
        else
            untracked[#untracked + 1] = entry
        end
    end

    return tracked, untracked
end

-------------------------------------------------------------------------------
--  Overlay System
-------------------------------------------------------------------------------
-- [key] = overlay frame. STRONG, and it never deletes a key: an overlay that
-- falls out of assignment is stopped and hidden (see the end of SetupOverlays)
-- but stays in this table, ready to be reused if the same key comes back. That
-- is deliberate and is not a leak to "fix": a WoW Frame cannot be destroyed
-- once created, so releasing the reference would strand the frame rather than
-- reclaim it, and the key space is bounded by the assignment slots the user
-- has ever configured this session (a handful).
-- CONSEQUENCE THAT MATTERS ELSEWHERE, verified rather than assumed: because
-- this table pins every overlay for the session, the __mode = "k" on the Hide
-- On Cooldown tables below can never actually collect anything. Their
-- correctness rests entirely on the explicit prune in SetupOverlays, not on
-- weak collection. Anyone adding another overlay-keyed table must prune it
-- there too; a weak mode will not do it for them.
local overlayFrames = {}
local lastStates = {}     -- [key] = bool (last glow state for change detection)
local _cachedBG = nil     -- cached barGlows reference (refreshed on SetupOverlays)

-------------------------------------------------------------------------------
--  Stack-threshold gate (secret-safe)
--  Applications counts read SECRET even in open-world content, so the
--  threshold compare can never happen in Lua (a hard error on a secret).
--  Same trick -- and same 5-operator support -- as the per-icon Glow at
--  Stacks feature (EllesmereUICdmHooks.lua's StackGlow_Configure/Feed):
--  one-unit StatusBar windows perform lower/upper bounds C-side via
--  SetValue; equality intersects one of each (two gates). A fixed-size
--  CLAMPTOBLACKADDITIVE mask rides each gate's fill edge and is handed to
--  StartNativeGlow so the glow texture itself is cropped by the fill(s) --
--  Lua never reads the count, just forwards it.
-------------------------------------------------------------------------------
local stackGates = {}  -- [key] = { gate,mask,fill, gate2,mask2,fill2, pad, threshold, operator, closeValue, openValue, closeValue2 }

local function StackGateSize(overlay)
    local w, h = overlay:GetWidth(), overlay:GetHeight()
    if not w or w < 5 then w = 36 end
    if not h or h < 5 then h = w end
    return w, h
end

local function NewStackGate(overlay, pad)
    local gate = CreateFrame("StatusBar", nil, overlay)
    gate:SetPoint("TOPLEFT", overlay, "TOPLEFT", -pad, pad)
    gate:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", pad, -pad)
    gate:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    local fill = gate:GetStatusBarTexture()
    if fill then fill:SetAlpha(0) end
    gate:EnableMouse(false)
    local mask = gate:CreateMaskTexture()
    mask:SetTexture("Interface\\Buttons\\WHITE8x8",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE", "NEAREST")
    return gate, mask, fill
end

local function SizeStackGateMasks(st, width, height)
    local w, h = width + st.pad * 2, height + st.pad * 2
    st.mask:SetSize(w, h)
    if st.mask2 then st.mask2:SetSize(w, h) end
end

local function StackGlowMatches(value, operator, threshold)
    if operator == "lt" then return value < threshold end
    if operator == "lte" then return value <= threshold end
    if operator == "eq" then return value == threshold end
    if operator == "gt" then return value > threshold end
    return value >= threshold
end

local function EnsureStackGate(overlay, key)
    local st = stackGates[key]
    if not st then
        st = {}
        stackGates[key] = st
        local w, h = StackGateSize(overlay)
        local pad = math.ceil(math.max(w, h) * 0.4)
        if pad < 12 then pad = 12 end
        st.pad = pad
        st.gate, st.mask, st.fill = NewStackGate(overlay, pad)
        SizeStackGateMasks(st, w, h)
    end
    return st
end

-- (Re)configure the gate(s) for the current threshold/operator. Mirrors
-- StackGlow_Configure's edge math exactly: lower bounds park the mask left
-- and open at max; upper bounds open at min and park right; equality
-- intersects one lower + one upper gate (both masks applied to the glow).
local function ConfigureStackGate(overlay, key, threshold, operator)
    local st = EnsureStackGate(overlay, key)
    if st.threshold == threshold and st.operator == operator then return st end
    st.threshold, st.operator = threshold, operator

    local upper = operator == "lt" or operator == "lte"
    local edge = (operator == "gt" or operator == "lte") and threshold + 1 or threshold
    st.gate:SetMinMaxValues(edge - 1, edge)
    st.mask:ClearAllPoints()
    st.mask:SetPoint(upper and "LEFT" or "RIGHT", st.fill or st.gate, "RIGHT", 0, 0)
    st.closeValue = upper and edge or edge - 1
    st.openValue = upper and edge - 1 or edge

    if operator == "eq" and not st.gate2 then
        local w, h = StackGateSize(overlay)
        st.gate2, st.mask2, st.fill2 = NewStackGate(overlay, st.pad)
        SizeStackGateMasks(st, w, h)
    end
    if st.gate2 then
        local equality = operator == "eq"
        st.gate2:SetMinMaxValues(equality and threshold or 0, equality and threshold + 1 or 1)
        st.mask2:ClearAllPoints()
        st.mask2:SetPoint(equality and "LEFT" or "RIGHT", st.fill2 or st.gate2, "RIGHT", 0, 0)
        st.closeValue2 = equality and threshold + 1 or 0
    end
    return st
end

-------------------------------------------------------------------------------
--  Hide On Cooldown (per-entry opt-in: entry.hideOnCooldown)
--  While the entry's HOST spell -- the spell on the button the overlay rides
--  on, not the buff the entry watches -- is on its own cooldown, suppress the
--  glow. This file owns the suppression state; the CDM tick only reads it.
--
--  The start edge is UNIT_SPELLCAST_SUCCEEDED and NOT a cooldown read, because
--  in-game testing falsified both alternatives. isOnGCD reported "on GCD" for
--  1.2s after a cast while the real cooldown was already running, and gave no
--  usable reading at all on Summon Demonic Tyrant. isActive == true is also
--  true during the GCD, so gating on it suppressed the glow through nearly all
--  of combat; only isActive == false is trustworthy, and that is a CLEARING
--  signal, not a start edge. Do not reintroduce either.
--
--  GetSpellBaseCooldown decides ELIGIBILITY (does this spell own a cooldown at
--  all) and supplies the LENGTH that anchors the restore. It is static spell
--  data: an upper bound, never a question about the cooldown running now.
--
--  Clearing the suppression is a separate edge and is deliberately NOT here.
-------------------------------------------------------------------------------

-- Weak keys satisfy the project constraint, but nothing is actually reclaimed
-- here: overlayFrames holds every overlay it creates strongly, and no frame in
-- this feature is ever destroyed (overlays are hidden and reused; host buttons
-- outlive us). The shapes that DO arise -- an overlay re-bound to a different
-- host, an entry whose toggle was switched off -- are invisible to the
-- collector. Correctness therefore rests on the explicit prune and
-- host-identity clear in SetupOverlays and on nothing else, which is why every
-- overlay-keyed table below is cleared for an overlay in the same place,
-- together. Adding a table here adds work to that prune, not to the collector.
local hideCdWatch      = setmetatable({}, { __mode = "k" })  -- [overlay] = host spellID (base-normalized)
local hideCdSuppressed = setmetatable({}, { __mode = "k" })  -- [overlay] = true while suppressed
local hideCdFrame                 -- event shell, created on first actual use
local hideCdActive     = false    -- is the cast event currently registered
local hideCdBaseCache  = {}       -- [spellID] = base cooldown in ms, 0 == none
local hideCdHooked     = setmetatable({}, { __mode = "k" })  -- [host frame] = true, hooked once
local hideCdPending    = setmetatable({}, { __mode = "k" })  -- [overlay] = hostSid awaiting a verdict
local hideCdRecheckUntil   = 0      -- GetTime() deadline; the window is hard-bounded
local hideCdRecheckRunning = false  -- one timer chain at a time, never a standing poll
local hideCdWakeGen    = setmetatable({}, { __mode = "k" })  -- [overlay] = wake generation
local hideCdWakeEnd    = setmetatable({}, { __mode = "k" })  -- [overlay] = end this chain is AIMED at
local hideCdWakeHard   = setmetatable({}, { __mode = "k" })  -- [overlay] = that chain's deadline, never movable EARLIER

-- TWO end times per chain, NOT interchangeable -- conflating them was a defect:
--   * hideCdWakeHard is castTime + baseSeconds, from the two signals rated
--     reliable. It is the only provable UPPER bound on the cooldown and the only
--     thing the unconditional restore may judge against. Nothing derived from a
--     cooldown READ may replace it: one transient read (a charge or category
--     cooldown, the API handing back the GCD window) would pull the restore
--     permanently EARLIER and flash the glow back mid-cooldown -- the original
--     bug, reintroduced from the other side.
--     It is MONOTONICALLY NON-DECREASING, not constant: every arming path passes
--     it through untouched except the hard-deadline branch in HideCdWakeStep,
--     which may carry a strictly LATER one forward. Later can only postpone the
--     restore, so the property it rests on -- never earlier than the real end --
--     holds. Moving it EARLIER is the forbidden change, whatever its source.
--   * hideCdWakeEnd is only "the end this chain is currently AIMED at". The
--     SPELL_UPDATE_COOLDOWN re-anchor compares against THIS, so it moves the
--     wake time without touching the deadline, and termination is unaffected.

-- MODULE-SCOPE and MONOTONIC, deliberately not per-overlay. C_Timer.After cannot
-- be cancelled and HideCdTeardown wipes hideCdWakeGen, so a per-overlay counter
-- would restart at 0: disabling Bar Glows with a wake in flight (token 1), then
-- re-enabling and recasting, would stamp the new chain token 1 as well -- two
-- live chains, neither able to retire the other. An ever-incrementing number
-- cannot collide.
local hideCdWakeSeq    = 0

-- Forward declaration. The wake chain must be DEFINED below HideCdIsReady (it
-- reads the live cooldown) but is CALLED from the cast edge above it, and in
-- this file a local referenced above its declaration silently resolves to a nil
-- global -- no syntax error, no lint warning, the feature just quietly dies.
-- This line is what makes the later `function HideCdScheduleWake(...)` assign
-- the local rather than create a global.
local HideCdScheduleWake

-- Bounded re-check window for a clearing edge that could not be confirmed on the
-- spot. Two observed reasons a confirming read lags its edge: the cooldown API
-- can report the OLD state for a frame or two after the availability alert
-- lands, and isActive is also true for the GCD, so a cooldown expiring during a
-- GCD reads "active" until that GCD ends. The window must therefore outlast one
-- GCD; 1.7s covers a 1.5s GCD plus slack. Not a poll: it stops as soon as every
-- pending overlay has answered, and only runs while an edge is unresolved.
local HIDECD_RECHECK_STEP   = 0.1
local HIDECD_RECHECK_WINDOW = 1.7

-- Wake-at-the-end chain. The first wake is deliberately EARLY: the base cooldown
-- is an upper bound (haste and CDR only shorten), so waking at the full base
-- duration risks the one outcome that must not happen -- late. Half of base
-- costs at most one extra read and one reschedule. The slack is added to a
-- re-read remaining time so the next wake lands just PAST the end.
-- A cooldown cut by MORE than half is not rescued by the clearing edges alone:
-- SPELL_UPDATE_COOLDOWN fires at the moment of the CDR proc, while the cooldown
-- still runs, and nothing fires at the new shortened end. (A full RESET differs:
-- that same read is already ready and clears on the spot.) Hence the
-- re-anchoring in HideCdRequest.
local HIDECD_WAKE_EARLY = 0.5
local HIDECD_WAKE_MIN   = 0.1
local HIDECD_WAKE_SLACK = 0.05

-- Ceiling on a global cooldown, used ONLY at the hard deadline. The GCD is 1.5s
-- at zero haste and only shortens, so a remaining time ABOVE this cannot be a
-- GCD -- it must be a real cooldown outlasting the base-anchored deadline, which
-- happens when the cooldown does not start at the cast (a channel whose cooldown
-- begins at channel end, a cooldown that begins when its buff expires). So the
-- deadline must not restore blind. Anything at or below it is treated as the
-- GCD, which is what keeps the GCD-lock fix intact: a GCD-sized read can never
-- re-arm the chain.
local HIDECD_GCD_MAX    = 1.6

-- How much of the base cooldown must have elapsed before the availability alert
-- is believed WITHOUT a confirming read. See HideCdAlertIsTrustworthy.
local HIDECD_ALERT_TRUST = 0.9

-- HOW EARLY THE GLOW COMES BACK, and why early is correct here.
-- Restoring at the cooldown's exact end is ON TIME and still useless: the client
-- queues a cast pressed during the tail of a GCD, so by the time a glow appears
-- at the true end that decision window has passed and the player waits for the
-- next GCD. Measured: the restore was landing within 0.15s of the real end and
-- was still reported as a GCD late. That is this, not a timing error.
-- So the restore is pulled EARLIER by exactly the client's spell queue window --
-- the interval in which pressing the button actually works. The glow then means
-- "press this now and it will go off" rather than "this is off cooldown as of
-- this instant". Read from the CVar because the player owns that setting, and
-- clamped so a modified value cannot pull the restore arbitrarily early.
-- Memoised for the session: a player who changes the CVar mid-session keeps the
-- old lead until /reload, which is accepted rather than read it on every cast.
local HIDECD_QUEUE_LEAD_MAX = 0.5
local hideCdQueueLeadCache
local function HideCdQueueLead()
    if hideCdQueueLeadCache then return hideCdQueueLeadCache end
    local lead = 0
    local get = (C_CVar and C_CVar.GetCVar) or GetCVar
    if get then
        local ms = tonumber(get("SpellQueueWindow"))
        if ms and ms > 0 then lead = ms / 1000 end
    end
    if lead > HIDECD_QUEUE_LEAD_MAX then lead = HIDECD_QUEUE_LEAD_MAX end
    hideCdQueueLeadCache = lead
    return lead
end

-- Capped so the lead can never be a large share of a short cooldown: 400ms is a
-- rounding error on 15s and a quarter of the whole thing on 1.5s.
local function HideCdLeadFor(baseSeconds)
    local lead = HideCdQueueLead()
    local cap  = baseSeconds * 0.25
    if lead > cap then lead = cap end
    return lead
end

-- WHY A SUPPRESSION CHANGE HAS TO ASK FOR A REPAINT.
-- Clearing hideCdSuppressed only changes what the next visual pass would decide;
-- it paints nothing. That pass, UpdateOverlayVisuals, runs from the CDM's shared
-- aura tick under a generation gate: real aura or pool churn, else a 1s
-- staleness net. A suppression change is neither, so a perfectly timed restore
-- can sit invisible for up to a second, rescued early only by an unrelated aura
-- event. That was the residual "mostly right, sometimes still not lit".
-- DEFERRED one frame rather than called inline for two independent reasons: the
-- restore sites run inside a pairs() walk of the watch set and must not re-enter
-- the visual pass from within it, and several overlays can change on the same
-- tick, which this coalesces into one pass.
-- Resolved through `ns` at CALL time on purpose: UpdateOverlayVisuals is defined
-- far below, and a local used above its declaration becomes a nil global here.
local hideCdRepaintQueued = false
local function HideCdRepaint()
    if hideCdRepaintQueued then return end
    if not (C_Timer and C_Timer.After) then return end
    hideCdRepaintQueued = true
    C_Timer.After(0, function()
        hideCdRepaintQueued = false
        if ns.UpdateOverlayVisuals then ns.UpdateOverlayVisuals() end
    end)
end

-- Secret-safe numeric probe. The secret test MUST come first: a truthiness, nil
-- or relational test against a secret value hard-errors, so `v == nil` cannot be
-- asked first. type() never compares, so it is safe on anything.
local function HideCdCleanNumber(v)
    if issecretvalue and issecretvalue(v) then return false end
    return type(v) == "number"
end

-- Base form of a spell id, used to match a host against a cast. BOTH sides are
-- reduced to base because they can differ in EITHER direction:
-- ns.GetCanonicalSpellIDForFrame's first rung is frame:GetSpellID(), the active
-- variant under transforms, so a host id is frequently ALREADY the override
-- while the cast event reports the base, and C_SpellBook.FindSpellOverrideByID
-- maps base -> override only. ns.NormalizeToBase degrades to identity on a
-- secret/invalid id or a missing API, keeping this fail-open.
local function HideCdBaseOf(sid)
    if ns.NormalizeToBase then return ns.NormalizeToBase(sid) end
    return sid
end

-- Static spell data: never secret, never changes, so memoise it -- this is asked
-- on the cast event. Returns MILLISECONDS, 0 meaning "owns no cooldown of its
-- own". The cast edge needs only `> 0`; the duration comes along free and
-- anchors the wake timer. ELIGIBILITY-and-LENGTH only, never "is a cooldown
-- running right now".
--
-- UNVERIFIED ASSUMPTION, the only one left in this feature. "A GCD-only spell
-- must never be suppressed" rests ENTIRELY on GetSpellBaseCooldown answering 0
-- for such a spell rather than the GCD's 1500; the cast edge's `baseMs > 0` is
-- the whole test. If 1500 came back, a GCD-only host would suppress on cast and
-- restore ~1.5s later -- a blink on every cast, with nothing in the log. Never
-- exercised in game. If a GCD-only host is ever reported blinking, START HERE
-- and print what GetSpellBaseCooldown actually returns for it. Do NOT
-- pre-emptively add a `ms <= 1500 -> 0` rejection: it would wrongly disqualify
-- any real spell with a cooldown of 1.5s or less.
local function HideCdBaseCooldownMs(sid)
    local cached = hideCdBaseCache[sid]
    if cached then return cached end
    local ms = 0
    if GetSpellBaseCooldown then
        local raw = GetSpellBaseCooldown(sid)
        if HideCdCleanNumber(raw) and raw > 0 then ms = raw end
    end
    hideCdBaseCache[sid] = ms
    return ms
end

-- Host spell for the button an overlay rides on. The two host kinds resolve
-- differently and only SetupOverlays knows which kind an assignment key was, so
-- the caller passes isCDM. Fails OPEN: nil means the overlay is never watched.
local function HideCdResolveHostSpell(btn, isCDM)
    if not btn then return nil end
    if isCDM then
        -- Canonical id is what the picker STORED for this frame, so it matches
        -- the variant the user actually casts under transforms/overrides.
        local sid = ns.GetCanonicalSpellIDForFrame and ns.GetCanonicalSpellIDForFrame(btn)
        if not HideCdCleanNumber(sid) then
            -- `fc.spellID` is the ONLY usable field here. Do not reach for
            -- `fc.blizzChild`: its only assignment anywhere in the addon sets it
            -- to nil (EllesmereUICooldownManager.lua:7894), so it is dead code.
            -- It cost one review a wrong turn.
            local fc = ns._ecmeFC and ns._ecmeFC[btn]
            sid = fc and fc.spellID
        end
        if HideCdCleanNumber(sid) and sid > 0 then return HideCdBaseOf(sid) end
        return nil
    end
    -- Action button: read the slot via GetAttribute, NEVER btn.action -- the
    -- direct field taints in combat.
    local slot = btn.GetAttribute and btn:GetAttribute("action")
    if not HideCdCleanNumber(slot) then return nil end
    if not GetActionInfo then return nil end
    local actionType, id = GetActionInfo(slot)
    -- Probe before the string compare: an equality test on a secret errors.
    if issecretvalue and issecretvalue(actionType) then return nil end
    if actionType ~= "spell" then return nil end
    if HideCdCleanNumber(id) and id > 0 then return HideCdBaseOf(id) end
    return nil
end

-- UNIT_SPELLCAST_SUCCEEDED reports the id ACTUALLY cast, which can be the
-- override while the overlay resolved to the base or vice versa, so both sides
-- are compared in base form. Deliberately not memoised: the base/override
-- mapping changes with talents and forms, and this only walks watched overlays.
local function HideCdCastSucceeded(_, _, _, _, castSid)
    if not HideCdCleanNumber(castSid) then return end
    local castBase = HideCdBaseOf(castSid)
    for overlay, hostSid in pairs(hideCdWatch) do
        -- hostSid was already base-normalized when it was resolved.
        local match = (hostSid == castSid) or (hostSid == castBase)
        if not match and C_SpellBook and C_SpellBook.FindSpellOverrideByID then
            -- Only reachable when base normalization could not run (both sides
            -- degraded to identity): the base -> override map covers that one
            -- direction.
            local override = C_SpellBook.FindSpellOverrideByID(hostSid)
            match = HideCdCleanNumber(override) and override == castSid
        end
        -- Eligibility is asked of the CAST id, not the host id: it is the spell
        -- actually cast whose cooldown starts. Deliberate.
        --
        -- ACCEPTED GAP 1 (charges): a charge spell cast with a charge still
        -- banked is suppressed anyway. This edge deliberately does not read the
        -- live cooldown to count charges, because every signal that could answer
        -- was falsified in game. Self-correcting and short: a banked charge reads
        -- isActive == false, so the first clearing edge or wake restores the
        -- glow -- a flicker at most, never a stuck-dark glow. Do not fix it by
        -- consulting charge state at the cast; fix it, if ever, by asking whether
        -- the spell is castable RIGHT NOW, which has no reliable answer here.
        --
        -- ACCEPTED GAP 2 (login / reload): this cast edge is the ONLY thing that
        -- sets suppression, so a spell already on cooldown at login is not
        -- suppressed until its next cast. The glow just behaves as stock for one
        -- cooldown; the alternative is inferring a START from a READ, which the
        -- signal table forbids outright.
        if match then
            local baseMs = HideCdBaseCooldownMs(castSid)
            if baseMs > 0 then
                hideCdSuppressed[overlay] = true
                HideCdRepaint()
                -- This cast is the only moment the cooldown's START is known
                -- exactly, so the restore is anchored here rather than left
                -- waiting to be TOLD the cooldown ended.
                HideCdScheduleWake(overlay, hostSid, baseMs / 1000)
            end
        end
    end
end

-------------------------------------------------------------------------------
--  Hide On Cooldown: the CLEARING edge
--
--  The client dispatches NO event when a cooldown expires. Three signals drive
--  the re-check instead:
--    * TriggerAvailableAlert on the host frame -- Blizzard's own "this cooldown
--      just became available" edge, driven from the viewer's loop against the
--      REAL end time. Primary driver, and the same one the CD-ready sound uses
--      (EllesmereUICdmHooks.lua ~2161).
--    * OnCooldownDone on the host's cooldown widget -- backup, and the only
--      driver at all for hosts with no TriggerAvailableAlert method.
--    * SPELL_UPDATE_COOLDOWN -- further backup. It never sees the expiry itself
--      (that is the whole problem) but it covers RESETS and recurs often enough
--      to recover an edge that went unconfirmed.
--
--  Only ONE of them is a verdict, and only under a guard: see
--  HideCdAlertIsTrustworthy. The other two merely ask for a read, and only
--  isActive == false may clear on their behalf. That is not caution for its own
--  sake -- acting on either directly reintroduces bugs already found in game: a
--  CDM icon RE-SETS its cooldown swipe when its tracked buff drops and fires the
--  swipe-done edge with most of the cooldown left (observed: 34s on Summon
--  Demonic Tyrant), and a buff-family frame fires TriggerAvailableAlert on AURA
--  GAIN. Confirming with a read is also why neither frame kind needs excluding
--  by name: a bogus edge reads "still on cooldown" and changes nothing.
--
--  An unreadable (secret/missing) cooldown is not a verdict either and never
--  clears -- but it is not final, because SPELL_UPDATE_COOLDOWN keeps asking.
-------------------------------------------------------------------------------

-- The ONLY clearing VERDICT from a read: isActive == false. isActive == true is
-- meaningless (true through every GCD as well as a real cooldown) and isOnGCD is
-- falsified, so "true" is treated as "no answer yet", never as "on cooldown".
-- Resolves the override form first, because the host id is stored
-- base-normalized while the cooldown runs on the variant actually cast.
-- FAIL-DIRECTION: every other fail-open in this file means "show the glow"; here
-- `return false` means "not confirmed ready" and KEEPS THE GLOW HIDDEN -- the
-- opposite bias, and the correct one, since an unreadable cooldown must never
-- resurrect a suppressed glow, and SPELL_UPDATE_COOLDOWN keeps asking. Do not
-- "simplify" this to return true.
local function HideCdIsReady(hostSid)
    if not (C_Spell and C_Spell.GetSpellCooldown) then return false end
    local live = hostSid
    if C_SpellBook and C_SpellBook.FindSpellOverrideByID then
        local o = C_SpellBook.FindSpellOverrideByID(hostSid)
        if HideCdCleanNumber(o) and o > 0 then live = o end
    end
    local cd = C_Spell.GetSpellCooldown(live)
    if not cd then return false end
    -- Probe before comparing: an equality test against a secret hard-errors.
    -- A charge spell reads isActive == false while a charge is still in hand,
    -- which is the wanted answer here -- the spell is castable again, so the
    -- glow comes back.
    local act = cd.isActive
    if issecretvalue and issecretvalue(act) then return false end
    return act == false
end

-- DELIBERATE DIVERGENCE FROM THE CD-READY SOUND, written here because this is
-- where someone would "harmonise" the two and break the better one. The sound
-- (EllesmereUICdmHooks.lua) treats a charge spell as ready only at MAX charges;
-- this treats it as ready at the FIRST charge, because isActive reads false as
-- soon as one charge is banked. Both are correct for what they do: a sound
-- announces "this cooldown is fully back", a glow answers "can I press this
-- now", and at one charge the answer is yes. Making the glow wait for max
-- charges would keep it dark on a spell the player can cast. If the two are ever
-- unified, the SOUND is the side that moves. Neither is a bug.
-- (The mirror image -- suppressing on cast with a charge banked -- is accepted
-- gap 1, at the cast edge above.)

-------------------------------------------------------------------------------
--  Hide On Cooldown: the EXPIRY ANCHOR
--
--  The three edges above are the only way to be TOLD a cooldown ended, and none
--  can be trusted to say it on time: in a raid the restore landed 2-3 GCDs late
--  every time, because the frame-keyed edge either fired early (burning the 1.7s
--  window before the real expiry) or never fired for that host at all, leaving
--  the restore to the next SPELL_UPDATE_COOLDOWN -- which in combat means the
--  user's NEXT CAST.
--
--  So stop waiting to be told. The START is known exactly from the one reliable
--  edge (UNIT_SPELLCAST_SUCCEEDED) and the LENGTH from GetSpellBaseCooldown,
--  which is static and already read on that same path. Compute the end and wake
--  there.
--
--  This does NOT infer the cooldown's start from a cooldown read -- nothing here
--  reads a cooldown to find a start. Nor is it the standing poll an earlier
--  review rejected: that poll's flaw was a RECURRENT EVENT pushing a shared,
--  sliding deadline, so it re-armed forever. This chain is armed once per
--  suppression by a one-shot cast edge, and each step is anchored to a finite
--  deadline strictly later than the last, so it provably terminates -- typically
--  after ONE wake.
--
--  The three edges REMAIN as accelerators: a truthful TriggerAvailableAlert
--  still restores instantly, and SPELL_UPDATE_COOLDOWN still catches a RESET no
--  precomputed end could predict. This removes the DEPENDENCE, not the edges.
--
--  ON LATENESS, since this is what a report will be about. A cooldown expiring
--  during a GCD still reads isActive == true, and isOnGCD -- the API that would
--  separate the two -- is falsified. The restore therefore cannot be CONFIRMED
--  mid-GCD; it lands anyway, on the availability alert (trusted under guard, see
--  HideCdAlertIsTrustworthy) or on the hard deadline, both pulled in by the
--  spell queue window. What remains genuinely late is a cooldown that haste or
--  CDR shortened well below its base: nothing readable proves the end moved, so
--  it restores at the base-anchored deadline. Lateness is the safe direction.
--  "Came back two or three GCDs late, or only on my next cast" is NOT that --
--  that is the original bug and means the chain has stopped anchoring to the
--  cooldown's own end.
--
--  "Never more than a little late" holds ONLY because each wake carries a HARD
--  DEADLINE (hardEnd) and restores once past it, and because a read that says
--  the cooldown is PROVABLY over restores on the spot. Without those, the
--  reschedule would read the GCD's remaining as the spell's and re-arm just
--  after that GCD ends -- which, with spell queueing, is inside the NEXT GCD.
--  Under sustained casting that re-arms once per GCD forever and the glow stays
--  dark until the player stops: the exact symptom this feature exists to remove.
--
--  The deadline is the only thing the unconditional restore is judged against,
--  being the only end time derived purely from reliable signals rather than from
--  a cooldown read. It can move LATER but never EARLIER, and it is not applied
--  blind: one read at the deadline separates "this is the GCD" from a cooldown
--  that starts LATER than the cast. Both halves are load-bearing.
-------------------------------------------------------------------------------

-- THREE-VALUED in its FIRST return, and every caller must handle all three:
--   * a number > 0 -- seconds left on the host cooldown;
--   * 0            -- the read SUCCEEDED and says the cooldown is already over
--                     (PROVABLY over, not merely unconfirmed);
--   * nil          -- the cooldown could NOT be read at all.
-- SECOND return: the `duration` read, on both readable paths. It is free and it
-- is the only signal that can tell WHOSE cooldown was reported -- a GCD's
-- duration is at most 1.5s. See HideCdReadIsGCD.
-- These used to share nil, and that conflation was a Critical defect: the
-- terminal wake lands deliberately just PAST the computed end, so the common
-- case there is "provably over", and routing it down the unreadable path retired
-- the chain into the bounded window, which then closed without clearing because
-- a sustained cast keeps the read not-ready. The glow stayed dark until the
-- player took a break -- the exact bug the anchor exists to remove.
-- NOTE FOR CALLERS: 0 is TRUTHY in Lua. `if not remaining` catches ONLY nil --
-- test for 0 explicitly and FIRST.
-- Deliberately NOT folded into HideCdIsReady, which stays byte-for-byte as it is
-- (its inverted fail direction is load-bearing).
local function HideCdRemaining(hostSid)
    if not (C_Spell and C_Spell.GetSpellCooldown) then return nil end
    local live = hostSid
    if C_SpellBook and C_SpellBook.FindSpellOverrideByID then
        local o = C_SpellBook.FindSpellOverrideByID(hostSid)
        if HideCdCleanNumber(o) and o > 0 then live = o end
    end
    local cd = C_Spell.GetSpellCooldown(live)
    if not cd then return nil end
    local startTime, duration = cd.startTime, cd.duration
    if not (HideCdCleanNumber(startTime) and HideCdCleanNumber(duration)) then return nil end
    -- UNREADABLE, not "over": callers only reach this while the spell has already
    -- read NOT ready, so a zero-length cooldown alongside that is self-
    -- contradictory, not evidence the cooldown finished. Keep it on the nil path
    -- so it gets the backstop rather than an immediate restore.
    -- Safe ONLY because HideCdWakeStep's nil branch arms a backstop wake at the
    -- hard deadline as well as handing off to the bounded window. Remove that
    -- backstop and this line silently becomes a way to lose the restore, so
    -- anyone touching either must revisit the other.
    if duration <= 0 then return nil end
    local remaining = (startTime + duration) - GetTime()
    -- PROVABLY OVER, distinct from nil: start and duration read cleanly and their
    -- sum is in the past. Whatever still reads "active" is not this cooldown.
    if remaining <= 0 then return 0, duration end
    return remaining, duration
end

-- Is the cooldown just read provably NOT the host's own?
--
-- THE ONE CONTRADICTION THIS FILE CANNOT RESOLVE: for a spell OFF its own
-- cooldown but GCD-locked, C_Spell.GetSpellCooldown either
--   (A) reports THE GCD -- a fresh start and a duration of at most 1.5s; or
--   (B) keeps reporting the spell's own expired cooldown -- so the arithmetic in
--       HideCdRemaining goes negative and it answers 0.
-- Which this client does is UNKNOWN and cannot be settled by reading code. The
-- chain does not depend on knowing: under (B) the `remaining == 0` branch in
-- HideCdWakeStep is live, under (A) this test is, and BOTH are kept for that
-- reason. The code MUST remain correct under both -- a hard requirement, not a
-- nicety, because each model leaves the other's branch looking like an easy
-- deletion, and deleting either breaks the feature as a LATE restore under
-- sustained casting on whichever client the other model holds.
--
-- CURRENT STATUS, measured and recorded rather than acted on: on this client the
-- duration field is a SECRET VALUE, so HideCdRemaining can never return a number
-- and every branch discriminating on a reported duration -- this one included --
-- is unreachable. Kept DELIBERATELY: it costs nothing, it is correct if those
-- fields are ever unsealed or another client differs, and removing it is a
-- separate decision from the one that made it dormant.
--
-- N3 -- THE ONE RESIDUAL EARLY-RESTORE SURFACE IN THIS FILE. The proof below is
-- a GCD CEILING: no GCD runs longer than HIDECD_GCD_MAX, so a duration at or
-- below it on a host whose base is longer cannot be the host's, and if the
-- host's own cooldown is no longer being reported then it is OVER. The proof
-- fails for a host that LEGITIMATELY reports an own-cooldown duration <= 1.6s
-- while its BASE exceeds 1.6s -- self-contradictory for a normal cooldown, which
-- is why no reachable shape was found across four review rounds. If one exists,
-- this restores the glow up to ~1.5s early. GROUND TRUTH IF EVER REPORTED: the
-- CDM cooldown swipe. A glow returning while the swipe still runs is the
-- observable, and this is the first place to look.
--
-- SELF-DISABLING when the host's base is itself GCD-sized: there the two
-- durations are indistinguishable, so this answers false and nothing is lost --
-- the hard deadline is at most 1.6s away anyway.
-- Fails CLOSED in every uncertain case: false means "no proof", i.e. do not
-- restore on this.
local function HideCdReadIsGCD(dur, baseSeconds)
    -- Probe before any comparison: a relational test on a secret hard-errors.
    if not (HideCdCleanNumber(dur) and HideCdCleanNumber(baseSeconds)) then return false end
    if dur > HIDECD_GCD_MAX then return false end          -- too long to be a GCD
    if baseSeconds <= HIDECD_GCD_MAX then return false end -- no proof available
    return true
end

-- Mutual recursion between the arming helper and the step it arms, so the step
-- is forward-declared for the same nil-global reason noted at the top.
local HideCdWakeStep
-- Forward-declared for the SAME reason: HideCdWakeStep hands an unreadable
-- cooldown off to the bounded re-check window, and HideCdQueue is defined
-- further down (it needs HideCdRecheckTick).
local HideCdQueue

-- Retire this overlay's chain, whatever the reason. All three tables must go
-- together: a leftover end time with no generation would let the re-anchor path
-- compare against, or inherit, a dead chain's deadline. Anything that clears an
-- overlay out of the watch set -- the SetupOverlays prune and the host-identity
-- clear included -- must go through HERE rather than clearing tables by hand, so
-- a fourth wake table could never be forgotten on one path and cleared on
-- another. Declared before HideCdArmWake because its bail-out calls it.
local function HideCdWakeRetire(overlay)
    hideCdWakeGen[overlay]  = nil
    hideCdWakeEnd[overlay]  = nil
    hideCdWakeHard[overlay] = nil
end

-- One C_Timer.After per wake. Timers cannot be cancelled, so a stale one is
-- retired by the generation token rather than chased down: only the wake
-- carrying the overlay's CURRENT generation may act. hardEnd travels WITH the
-- wake rather than being looked up when it fires, so a wake always judges itself
-- against the deadline of the chain that armed IT, and a re-aim cannot
-- retroactively move a wake already in flight.
-- baseSeconds travels the same way, as an argument rather than a fourth weak
-- table: it is static per host, and a fourth table would be one more thing every
-- teardown path has to clear in step with the other three.
local function HideCdArmWake(overlay, hostSid, gen, hardEnd, aimEnd, delay, baseSeconds)
    -- No timer API means no chain can exist. Retire rather than return: every
    -- caller has ALREADY stamped hideCdWakeGen, so a bare return would leave a
    -- generation with no end times behind it -- the half-armed shape
    -- HideCdWakeRetire exists to prevent, which the re-anchor would read as a
    -- live chain. Unreachable in the client; this is consistency, not a guard.
    if not (C_Timer and C_Timer.After) then
        HideCdWakeRetire(overlay)
        return
    end
    -- Mirrors for the SPELL_UPDATE_COOLDOWN re-anchor, which has no other way to
    -- see either value.
    hideCdWakeEnd[overlay]  = aimEnd
    hideCdWakeHard[overlay] = hardEnd
    C_Timer.After(delay, function()
        HideCdWakeStep(overlay, hostSid, gen, hardEnd, baseSeconds)
    end)
end

-- Wake at (or just before) the expected end. Five ways this stops for good, so it
-- can never become a standing poll: a newer cast bumped the generation; the
-- suppression is already gone; the host spell changed under the overlay; the
-- cooldown reads ready; or the cooldown reads PROVABLY OVER (HideCdRemaining
-- returned 0, or a DURATION provably not this host's) or the hard deadline has
-- passed.
-- The UNREADABLE case is NOT equivalent to those and must not be read as though
-- it were: it hands off to the bounded re-check window, and that window can close
-- with the glow still suppressed. It is the only stop that can end with the
-- suppression still standing, so it is the only one that also re-arms a backstop
-- wake at the hard deadline -- without that, a handoff whose window expires
-- unconfirmed leaves NOTHING armed and the restore falls back to the user's next
-- cast, the bug this exists to kill.
-- Only "still running, before the deadline, and we can see its real end" re-arms
-- the normal chain, and it re-arms to THAT end -- strictly later and finite --
-- which is what self-corrects for haste and CDR.
function HideCdWakeStep(overlay, hostSid, gen, hardEnd, baseSeconds)
    if hideCdWakeGen[overlay] ~= gen then return end
    if not hideCdSuppressed[overlay] or hideCdWatch[overlay] ~= hostSid then
        HideCdWakeRetire(overlay)
        return
    end
    if HideCdIsReady(hostSid) then
        hideCdSuppressed[overlay] = nil
        hideCdPending[overlay]    = nil
        HideCdRepaint()
        HideCdWakeRetire(overlay)
        return
    end
    local now = GetTime()
    -- HARD DEADLINE. This read said "not ready", but isActive is true for the GCD
    -- as well, and the API reports the GCD for a spell that is OFF its own
    -- cooldown. Past hardEnd the spell's own cooldown has almost certainly
    -- finished -- hardEnd is anchored to the base duration and nothing lengthens
    -- it -- so a not-ready read here is the GCD, and rescheduling on it would
    -- re-arm once per GCD for as long as the player keeps casting.
    --
    -- But do NOT restore blind. The deadline assumes the cooldown STARTS at
    -- UNIT_SPELLCAST_SUCCEEDED, which is false for a host whose cooldown begins
    -- later (a channel whose cooldown starts at channel end, one that starts when
    -- its buff expires). There the real end is genuinely later than castTime +
    -- base, and restoring would show the glow mid-cooldown with no recovery path.
    -- So take ONE read and ask whether it can be a GCD at all. Two independent
    -- proofs that it cannot: REMAINING above HIDECD_GCD_MAX (more time left than
    -- any GCD can have), or DURATION above it (longer than any GCD can be).
    -- The duration half is load-bearing: testing only the remaining was a latent
    -- EARLY restore, since a late-starting cooldown in its final <= 1.6s is
    -- indistinguishable from a GCD by remaining alone. Anything else -- GCD-sized
    -- on both counts, a provably-over 0, or an unreadable nil -- restores as
    -- before, so a real GCD read still can never re-arm the chain.
    --
    -- UNCAPPED RE-ARM, deliberately. Termination rests on the reported end
    -- strictly receding: each pass sleeps past the end this read reported, so
    -- re-arming again requires the cooldown to report a NEW later end, i.e. it was
    -- genuinely restarted or extended, in which case waiting is correct. One timer
    -- per reported cooldown, never one per GCD. A cap was considered and rejected:
    -- any constant is a guess, and one set too short restores the glow
    -- mid-cooldown -- the bug class this branch exists to prevent.
    if now >= hardEnd then
        local late, lateDur = HideCdRemaining(hostSid)
        -- `late and late > 0` first: 0 is TRUTHY, and a provably-over read must
        -- fall through to the restore below, never into the re-arm.
        if late and late > 0
           and (late > HIDECD_GCD_MAX
                or (HideCdCleanNumber(lateDur) and lateDur > HIDECD_GCD_MAX)) then
            -- Same queue-window lead as the original deadline. Safe without a
            -- floor check: reachable only when `late` exceeds HIDECD_GCD_MAX,
            -- several times the largest possible lead.
            local newEnd = now + late - HideCdLeadFor(baseSeconds)
            -- Sleep to the LEAD-ADJUSTED end: waking after newEnd would land past
            -- the deadline and restore there, throwing the lead away.
            HideCdArmWake(overlay, hostSid, gen, newEnd, newEnd,
                          (newEnd - now) + HIDECD_WAKE_SLACK, baseSeconds)
            return
        end
        hideCdSuppressed[overlay] = nil
        hideCdPending[overlay]    = nil
        HideCdRepaint()
        HideCdWakeRetire(overlay)
        return
    end
    local remaining, dur = HideCdRemaining(hostSid)
    -- PROVABLY OVER, tested FIRST because 0 is truthy and would otherwise fall
    -- through to the re-arm as a zero-length delay. This is the terminal wake's
    -- common case for a hasted or shortened cooldown: the real end precedes the
    -- base-anchored deadline, so the wake fires while the deadline is still ahead
    -- and the branch above does not run. The cooldown's own arithmetic end has
    -- passed, so whatever still reads active is the GCD. Restore.
    -- Routing this to the handoff instead was a Critical defect: with a GCD
    -- running continuously the window could never confirm, so it closed with
    -- nothing armed and the glow stayed dark past the real end.
    -- *** THIS BRANCH IS MODEL (B). DO NOT DELETE IT. *** See the two-model note
    -- at HideCdReadIsGCD. Under model (A) it is near-dead and the duration test
    -- below carries the same case -- which is exactly why it looks removable and
    -- is not. The pair is the correctness argument; neither half stands alone.
    if remaining == 0 then
        hideCdSuppressed[overlay] = nil
        hideCdPending[overlay]    = nil
        HideCdRepaint()
        HideCdWakeRetire(overlay)
        return
    end
    if not remaining then
        -- GENUINELY UNREADABLE (secret, missing API, or a self-contradictory
        -- table), and nothing else: see HideCdRemaining's three-valued contract.
        -- Do NOT retry blindly on a step of our own -- that IS the rejected poll
        -- -- but do not DROP the chain either: that hands the restore back to the
        -- next-cast path this section exists to eliminate, and out of combat it
        -- can stick indefinitely (no casts, no procs, and a placeholder host has
        -- neither frame-keyed edge). Hand off to the bounded window instead.
        -- This is the SECOND caller of HideCdQueue and does NOT reintroduce the
        -- rejected poll: that poll's flaw was a RECURRENT EVENT shoving a shared
        -- SLIDING deadline forward forever, while a wake is one-shot and terminal,
        -- so one suppression can push hideCdRecheckUntil at most once.
        HideCdQueue(overlay, hostSid)
        -- ...and the window closing unconfirmed is why the handoff cannot be the
        -- end of the story. Keep ONE final wake pointed at the hard deadline so an
        -- unreadable cooldown still has a backstop instead of nothing armed at
        -- all. It cannot chain (the wake lands AT the deadline, where the branch
        -- above takes over) and the generation is unchanged, so this is still one
        -- chain. backstop is positive on every path that reaches here; the guard
        -- is kept so that moving the deadline check can never turn this into a
        -- zero-delay timer that re-enters on the same frame.
        local backstop = hardEnd - now
        if backstop > 0 then
            HideCdArmWake(overlay, hostSid, gen, hardEnd, hardEnd, backstop, baseSeconds)
        else
            HideCdWakeRetire(overlay)
        end
        return
    end
    -- A POSITIVE remaining, BEFORE the hard deadline -- where the once-per-GCD
    -- re-arm is born. Under model (A) a wake landing just past a shortened end
    -- reads the GCD: positive, so the arm at the bottom re-aims 50ms past that
    -- GCD, which with spell queueing is inside the NEXT one, and it repeats every
    -- GCD until the hard deadline bails it out -- late by the whole CDR delta plus
    -- a GCD, the reported bug.
    -- So ask what the remaining alone cannot answer: could this cooldown be the
    -- host's at all? A duration at or below HIDECD_GCD_MAX on a host whose base is
    -- longer proves it is not, hence the host's own cooldown is over. Restore,
    -- exactly as `remaining == 0` does. NOT an early restore and NOT the deadline
    -- moved earlier: it is a proof about WHOSE cooldown was read, asked where the
    -- bad re-arm originates. Self-disables on a GCD-sized base.
    -- *** THIS BRANCH IS MODEL (A). DO NOT DELETE IT. *** Twin of the
    -- `remaining == 0` branch: that one is live under (B), this under (A), and
    -- nobody knows which holds here. It also carries N3, the file's one residual
    -- early-restore surface -- both written out at HideCdReadIsGCD.
    if HideCdReadIsGCD(dur, baseSeconds) then
        hideCdSuppressed[overlay] = nil
        hideCdPending[overlay]    = nil
        HideCdRepaint()
        HideCdWakeRetire(overlay)
        return
    end
    HideCdArmWake(overlay, hostSid, gen, hardEnd, now + remaining, remaining + HIDECD_WAKE_SLACK, baseSeconds)
end

-- Arm the chain for a fresh suppression. Assigns the local forward-declared at
-- the top of this section -- do not add `local` here or the cast edge above will
-- call a nil global. Taking a fresh token first retires any chain still in flight
-- for this overlay (a recast while suppressed), so there is only ever one.
function HideCdScheduleWake(overlay, hostSid, baseSeconds)
    hideCdWakeSeq = hideCdWakeSeq + 1
    local gen = hideCdWakeSeq
    hideCdWakeGen[overlay] = gen
    -- The hard deadline for the whole chain: the cast is happening NOW and the
    -- base duration is an upper bound on the cooldown it starts. This is where it
    -- ORIGINATES; from here it is monotonically non-decreasing (see the note at
    -- hideCdWakeHard). Nothing may move it EARLIER -- that is the half the
    -- unconditional restore rests on.
    -- Pulled in by the spell queue window so the glow lands while the player can
    -- still act on it (see HideCdQueueLead). A CONSTANT subtraction made once, at
    -- origination, so every monotonicity guarantee still holds: the deadline is
    -- simply anchored a fraction of a second before the cooldown's end.
    local lead = HideCdLeadFor(baseSeconds)
    local hardEnd = GetTime() + baseSeconds - lead
    local delay = baseSeconds * HIDECD_WAKE_EARLY
    if delay < HIDECD_WAKE_MIN then delay = HIDECD_WAKE_MIN end
    HideCdArmWake(overlay, hostSid, gen, hardEnd, hardEnd, delay, baseSeconds)
end

-- SPELL_UPDATE_COOLDOWN re-anchor: the ONE case the precomputed end cannot see.
-- A partial CDR proc shortens a running cooldown; the event fires at the moment
-- of the proc, while the cooldown still runs, so the read is not-ready and clears
-- nothing, and nothing fires at the new, earlier end. So re-aim the wake, once,
-- from the live remaining. Not the rejected sliding window: this is anchored to a
-- REAL end read off the cooldown, and it arms a timer only when that end is
-- actually EARLIER than the one already aimed at.
-- HOW OFTEN IT ARMS, since "it arms nothing" is wrong: the chain starts aimed at
-- castTime + base, while the live end of a hasted cooldown is earlier, so the
-- FIRST event after such a cast arms once. After that the chain is aimed at a real
-- read, and a cooldown merely ticking down never moves that end earlier, so every
-- later recurrence arms nothing. One extra timer per suppression, not zero.
-- It re-aims the WAKE, never the DEADLINE: hardEnd is read back and passed
-- through. A live read must not become what the unconditional restore is judged
-- against.
local function HideCdReanchorWake(overlay, hostSid)
    local gen = hideCdWakeGen[overlay]
    if not gen then return end            -- no live chain to re-aim
    local hardEnd = hideCdWakeHard[overlay]
    if not hardEnd then return end        -- no deadline to carry: leave it alone
    local remaining = HideCdRemaining(hostSid)
    -- Three-valued. nil is unreadable and 0 is "already over": neither gives an
    -- end to re-aim AT, and neither is this path's job -- the caller has taken the
    -- ready verdict, and the wake in flight handles an expiry on its own terms.
    if not remaining or remaining <= 0 then return end
    local aimEnd = GetTime() + remaining
    local armed = hideCdWakeEnd[overlay]
    -- Only a MEANINGFUL move earlier is worth a timer. A later end is ignored: it
    -- could only delay the restore, and the deadline is not this path's to extend.
    if not armed or aimEnd > (armed - HIDECD_WAKE_SLACK) then return end
    hideCdWakeSeq = hideCdWakeSeq + 1
    local newGen = hideCdWakeSeq
    hideCdWakeGen[overlay] = newGen
    -- baseSeconds is not carried in any table (see HideCdArmWake), so it is
    -- re-derived from the same static, memoised source. Asked of the HOST id,
    -- which is the right question: it only decides whether the HOST's own cooldown
    -- is longer than a GCD.
    -- N1, KNOWN AND ACCEPTED: the cast edge derives it from the CAST id instead,
    -- and for a base/override pair with differing base cooldowns the two disagree.
    -- Harmless: the value feeds nothing but HideCdReadIsGCD, which only enables or
    -- disables a proof. Too large merely makes the proof available (and the proof
    -- must still see a GCD-sized duration); too small or unreadable yields 0 and
    -- turns it off, which is the safe direction. Do not "fix" it by threading the
    -- cast id down here -- that is not what this test asks about.
    HideCdArmWake(overlay, hostSid, newGen, hardEnd, aimEnd, remaining + HIDECD_WAKE_SLACK,
                  HideCdBaseCooldownMs(hostSid) / 1000)
end

-- One step of the bounded re-check window. Self-stopping in both directions: it
-- re-arms only while something is genuinely pending AND the deadline has not
-- passed, so it can never become a standing poll. Entries that stopped being
-- suppressed, or whose host changed underneath them, drop out here.
local function HideCdRecheckTick()
    hideCdRecheckRunning = false
    local stillPending = false
    for overlay, hostSid in pairs(hideCdPending) do
        if not hideCdSuppressed[overlay] or hideCdWatch[overlay] ~= hostSid then
            hideCdPending[overlay] = nil
        elseif HideCdIsReady(hostSid) then
            hideCdSuppressed[overlay] = nil
            hideCdPending[overlay] = nil
            HideCdRepaint()
        else
            stillPending = true
        end
    end
    if not stillPending then return end
    if GetTime() < hideCdRecheckUntil and C_Timer and C_Timer.After then
        hideCdRecheckRunning = true
        C_Timer.After(HIDECD_RECHECK_STEP, HideCdRecheckTick)
    else
        -- Window closed without an answer. Give up on THIS edge rather than
        -- keep polling; the glow stays suppressed and the next request edge
        -- (SPELL_UPDATE_COOLDOWN at worst) retries from scratch.
        wipe(hideCdPending)
    end
end

-- Park an unconfirmed overlay in the window and make sure the chain is running.
-- The deadline is shared and only ever pushed forward, so overlapping edges
-- cannot stack timer chains.
-- Assigns the local forward-declared above HideCdWakeStep -- do NOT add `local`
-- here, or that call site would resolve to a nil global. Two callers only: the
-- frame-keyed clearing edges, and a wake whose cooldown read failed (one-shot
-- and terminal, see the note at that call site). A RECURRENT event must never
-- be added as a third -- that is what turned this window into a standing poll.
function HideCdQueue(overlay, hostSid)
    hideCdPending[overlay] = hostSid
    local until_ = GetTime() + HIDECD_RECHECK_WINDOW
    if until_ > hideCdRecheckUntil then hideCdRecheckUntil = until_ end
    if not hideCdRecheckRunning and C_Timer and C_Timer.After then
        hideCdRecheckRunning = true
        C_Timer.After(HIDECD_RECHECK_STEP, HideCdRecheckTick)
    end
end

-- A clearing edge arrived. KEYING (settled, do not re-litigate): suppression is
-- keyed by OVERLAY while every edge arrives keyed by HOST FRAME, and several
-- overlays can share one button. Rather than maintain a second frame-keyed
-- index, this walks the watch set and matches on the overlay's own parent --
-- SetupOverlays parents every overlay to its host. The set only holds overlays
-- that opted in, so the walk is tiny.
-- frame == nil means "every watched overlay" (the SPELL_UPDATE_COOLDOWN case).
-- Only a real frame -- one of the two one-shot exact-frame edges -- may QUEUE an
-- unresolved overlay into the re-check window. SPELL_UPDATE_COOLDOWN still
-- clears anything that reads ready, but never queues, because it RECURS: it does
-- not tick through a long cooldown (which is why it never sees an expiry) but it
-- fires on every cast, charge refund and CDR proc, at least once a GCD in combat.
-- Parking its failed reads would shove hideCdRecheckUntil forward forever and
-- turn the bounded window into a standing 10Hz poll.
-- What it does instead, on a not-ready read, is re-aim the pending wake: that
-- covers the partial-CDR case nothing else sees, and arms a timer only when the
-- end actually moved earlier. Cost is one cooldown read per suppressed overlay
-- per EVENT, never on the CDM tick.
--
-- WHY THE ALERT IS EVER BELIEVED WITHOUT CONFIRMATION.
-- On this client EVERY cooldown timing field is a SECRET VALUE -- startTime,
-- duration and modRate on C_Spell.GetSpellCooldown, both values from the cooldown
-- widget, and the global GetSpellCooldown is gone entirely. Only `isActive` is
-- readable. So an addon CANNOT compute when a cooldown really ends; Blizzard's UI
-- can, reading those secrets internally, which is why TriggerAvailableAlert lands
-- on the true end when our arithmetic cannot.
-- The confirming read is `isActive == false`, and a RUNNING GCD keeps isActive
-- true, so an alert firing at the true end mid-GCD can never be confirmed. The
-- old code parked it in the re-check window until the GCD ended -- up to a full
-- GCD late, which defeats the point: the glow exists to be seen in time to QUEUE
-- the next cast.
-- So the alert is a VERDICT, not a request -- but only here and only under this
-- guard, because it is not unconditionally honest: a buff-family CDM frame fires
-- it on AURA GAIN, at an arbitrary point in the host's real cooldown.
-- THE CUTOFF is two rules, and the TIGHTER wins:
--   * base * (1 - HIDECD_ALERT_TRUST) -- proportional, so a short cooldown is not
--     judged by a window as long as itself.
--   * HIDECD_GCD_MAX -- absolute. The case being rescued is "honest alert, GCD in
--     the way", and a GCD is at most this long, so no more slop is ever NEEDED.
--     On a long cooldown the proportional rule alone would leave seconds of
--     exposure to a spurious aura-gain alert (60s base, 10% = 6s).
-- The error directions are not symmetric: rejecting an honest alert costs
-- lateness (the wake chain still restores), while accepting a spurious one puts a
-- glow on a button that cannot be pressed -- the defect this feature exists to
-- remove. Bias toward rejecting.
-- CONSEQUENCE, accepted knowingly: a cooldown shortened well below its base by
-- haste or CDR still restores late, since its true end falls before the cutoff
-- and nothing readable proves the end moved. The safe direction.
local function HideCdAlertIsTrustworthy(overlay, hostSid)
    local hardEnd = hideCdWakeHard[overlay]
    if not hardEnd then return false end
    local baseSeconds = HideCdBaseCooldownMs(hostSid) / 1000
    if baseSeconds <= 0 then return false end
    local slop = baseSeconds * (1 - HIDECD_ALERT_TRUST)
    if slop > HIDECD_GCD_MAX then slop = HIDECD_GCD_MAX end
    return GetTime() >= (hardEnd - slop)
end

-- `trusted` is passed ONLY by the TriggerAvailableAlert hook. OnCooldownDone must
-- never pass it: that is the edge caught firing with ~34s of real cooldown left on
-- Summon Demonic Tyrant when its tracked buff dropped and the CDM icon re-set its
-- own swipe. It stays a request that needs confirming.
local function HideCdRequest(frame, trusted)
    if not hideCdActive then return end
    for overlay, hostSid in pairs(hideCdWatch) do
        if hideCdSuppressed[overlay] and (frame == nil or overlay:GetParent() == frame) then
            if HideCdIsReady(hostSid) then
                hideCdSuppressed[overlay] = nil
                hideCdPending[overlay] = nil
                HideCdRepaint()
            elseif trusted and HideCdAlertIsTrustworthy(overlay, hostSid) then
                hideCdSuppressed[overlay] = nil
                hideCdPending[overlay]    = nil
                HideCdWakeRetire(overlay)
                HideCdRepaint()
            elseif frame then
                HideCdQueue(overlay, hostSid)
            else
                HideCdReanchorWake(overlay, hostSid)
            end
        end
    end
end

-- Arm the per-host edges, once per host frame and only for a host that actually
-- carries a watched overlay -- nothing is hooked at all when no entry opted in.
-- Post-hooks only (hooksecurefunc / HookScript), so nothing is tainted and
-- nothing Blizzard does is replaced.
local function HideCdWireHost(btn)
    if hideCdHooked[btn] then return end
    hideCdHooked[btn] = true
    -- Existence-guarded: our own CDM icons and plain action buttons do not have
    -- this method, and for them the widget edge below is the only driver.
    if type(btn.TriggerAvailableAlert) == "function" then
        hooksecurefunc(btn, "TriggerAvailableAlert", function()
            -- The one edge allowed to restore without a confirming read, and
            -- only past the cutoff -- see HideCdAlertIsTrustworthy.
            HideCdRequest(btn, true)
        end)
    end
    -- Cooldown widget, in the same order the rest of the addon resolves it.
    local fd = ns._hookFrameData and ns._hookFrameData[btn]
    local cd = (fd and fd.cooldown) or btn._cooldown or btn.cooldown or btn.Cooldown
    if cd and cd.HookScript then
        cd:HookScript("OnCooldownDone", function()
            HideCdRequest(btn)
        end)
    end
end

-- ACCEPTED GAP 4: a HOSTED-BUFF PLACEHOLDER host gets NEITHER edge above. Such a
-- frame can win the FindCDMButtonByCooldownID lookup, has no
-- TriggerAvailableAlert method, and its cooldown widget is permanently Clear()ed
-- so OnCooldownDone never fires. Both hooks no-op and the host leans ENTIRELY on
-- the wake chain -- which is why the anchor is not optional, and why replacing it
-- with "just listen for the edges" would leave this host kind with nothing.
-- READ THIS BEFORE "FIXING" IT. The obvious repair -- let SPELL_UPDATE_COOLDOWN
-- queue these overlays into the window -- REINTRODUCES THE STANDING 10Hz POLL
-- that was found and rejected: it fires at least once a GCD in combat, so parking
-- its failed reads shoves the shared deadline forward every time and the window
-- never closes. The rule is absolute: only a ONE-SHOT edge may call HideCdQueue.
-- Keeping the gap is bounded; breaking the rule is a permanent poll.

-- Both edges the event frame carries. The cast edge (Task 2) is untouched;
-- SPELL_UPDATE_COOLDOWN rides the same frame and only ever requests a re-check.
local function HideCdOnEvent(self, event, ...)
    if event == "SPELL_UPDATE_COOLDOWN" then
        HideCdRequest(nil)
    else
        HideCdCastSucceeded(self, event, ...)
    end
end

-- Register the cast event only while at least one overlay is watched, and drop
-- it the moment none is: no events at all when no entry opted in.
local function HideCdSetActive(active)
    if active then
        if not hideCdFrame then
            hideCdFrame = (ns.TakeShell and ns.TakeShell()) or CreateFrame("Frame")
            hideCdFrame:SetScript("OnEvent", HideCdOnEvent)
        end
        if not hideCdActive then
            -- Player-only: no other unit's casts can ever reach the handler.
            hideCdFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
            -- Not a unit event; backs up the expiry edge and covers resets.
            hideCdFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
            hideCdActive = true
        end
    elseif hideCdActive then
        hideCdFrame:UnregisterAllEvents()
        hideCdActive = false
    end
end

-- Full teardown for the disabled path: no state, no event registration.
local function HideCdTeardown()
    wipe(hideCdWatch)
    wipe(hideCdSuppressed)
    -- The re-check chain has nothing left to confirm and stops on its next step.
    wipe(hideCdPending)
    -- The window's DEADLINE is reset with it. Without this, disabling and
    -- re-enabling inside 1.7s handed the next edge a deadline it never asked for.
    -- SCOPE: this is the ONLY place hideCdRecheckUntil is reset, and only the
    -- disabled path reaches it. Turning off the LAST hideOnCooldown toggle while
    -- Bar Glows stays ENABLED goes through the SetupOverlays prune instead, so
    -- that route inherits a stale deadline for up to 1.7s. Harmless by
    -- construction, not by luck: the prune clears hideCdPending for every overlay
    -- it drops, so an in-flight tick finds nothing pending and returns without
    -- re-arming, whatever the deadline says. Do not "fix" it by resetting the
    -- deadline from the prune without re-reading the note below -- the two are
    -- not independent.
    hideCdRecheckUntil = 0
    -- hideCdRecheckRunning is DELIBERATELY NOT cleared, and that is not an
    -- oversight. It means "a timer for this chain is already in flight", and a
    -- C_Timer.After cannot be cancelled. Clearing it would let the next
    -- HideCdQueue arm a SECOND chain alongside the one still ticking. Leaving it
    -- true is self-correcting: the in-flight tick sets it false at its own top,
    -- finds hideCdPending empty and returns without re-arming, so the flag is
    -- honest again within one step. A stale true delays an arm by at most one
    -- step; a stale false duplicates a chain. Fail towards the harmless side.
    -- Same for the wake chains: wiping the generations means no pending wake can
    -- still match its token, so each returns immediately and the chain dies. Safe
    -- ONLY because hideCdWakeSeq is module-scope, monotonic and NOT wiped here, so
    -- a chain armed after a re-enable can never be handed a token a wake still in
    -- flight also carries.
    wipe(hideCdWakeGen)
    wipe(hideCdWakeEnd)
    wipe(hideCdWakeHard)
    HideCdSetActive(false)
end

--- Rebuild overlay frames from assignments
local function SetupOverlays()
    local bg = ns.GetBarGlows()
    _cachedBG = bg
    if not bg or not bg.enabled then
        for key, overlay in pairs(overlayFrames) do
            StopNativeGlow(overlay)
            overlay:Hide()
        end
        ns._barGlowStackSids = nil
        HideCdTeardown()
        return
    end

    -- Whether the buff-tick's aura pool-walk should bother reading applications
    -- at all (EllesmereUICdmHooks.lua): the set of spellIDs stack-gated
    -- entries name, nil when there are none. Only frames resolving to one of
    -- these ids pay the applications read; no gated entry = no reads at all.
    local stackSids

    -- Hide On Cooldown watch set is rebuilt here; it only ever holds overlays
    -- whose entry has the toggle ON and whose host spell resolved cleanly.
    -- Empty set == the cast event stays unregistered. It is NOT wiped up front:
    -- the previous pass's host per overlay is what tells us below whether an
    -- overlay's host spell CHANGED, so it has to survive into this pass and is
    -- pruned against hideCdSeen afterwards instead.
    local hideCdSeen = {}
    local hideCdAny = false

    local activeKeys = {}
    for assignKey, buffList in pairs(bg.assignments) do
        if buffList and #buffList > 0 then
            local btn

            -- CDM bar assignment: "cdm_<cooldownID>"
            local cdID = assignKey:match("^cdm_(%d+)$")
            if cdID then
                cdID = tonumber(cdID)
                -- Find which CDM bar has this cooldownID (walks all bars)
                btn = FindCDMButtonByCooldownID(cdID)
            else
                -- Action bar assignment: "<barIdx>_<btnIdx>"
                local barIdx, btnIdx = assignKey:match("^(%d+)_(%d+)$")
                barIdx = tonumber(barIdx)
                btnIdx = tonumber(btnIdx)
                if barIdx and btnIdx then
                    btn = GetActionBarButton(barIdx, btnIdx)
                end
            end

            if btn then
                -- Resolved at most once per button, and only if some entry on
                -- it actually opted in. false == resolution already failed.
                local hostSid
                for i, entry in ipairs(buffList) do
                    local key = assignKey .. "_" .. i
                    local overlay = overlayFrames[key]
                    if not overlay then
                        overlay = CreateFrame("Frame", "ECME_Glow_" .. key, btn)
                        overlayFrames[key] = overlay
                    end
                    if overlay:GetParent() ~= btn then
                        overlay:SetParent(btn)
                    end
                    overlay:SetAllPoints(btn)
                    overlay:SetFrameLevel(btn:GetFrameLevel() + 15)
                    overlay:SetAlpha(1)
                    overlay._assignEntry = entry
                    overlay:Show()
                    activeKeys[key] = true
                    local sid = entry.stackEnabled and entry.spellID
                    if sid and sid > 0 then
                        stackSids = stackSids or {}
                        stackSids[sid] = true
                    end
                    if entry.hideOnCooldown then
                        if hostSid == nil then
                            hostSid = HideCdResolveHostSpell(btn, cdID ~= nil) or false
                        end
                        if hostSid then
                            -- HOST IDENTITY, not key identity, owns the
                            -- suppressed flag. Action-bar overlay keys are
                            -- stable across a CONTENT change, so a bar page flip
                            -- or spec swap reuses the same overlay object with a
                            -- NEW host, and the prune below (which only drops
                            -- overlays that left the watch set) would keep the
                            -- old spell's flag and kill a glow the player never
                            -- cast for. Any change of host clears it: fails OPEN.
                            if hideCdWatch[overlay] ~= hostSid then
                                hideCdSuppressed[overlay] = nil
                                -- The chain in flight was armed for the OLD
                                -- host, so its state is meaningless now. The
                                -- wake retires itself, but its table entries
                                -- would linger with no chain behind them -- and
                                -- a lingering hideCdWakeGen is what
                                -- HideCdReanchorWake reads as a live chain.
                                HideCdWakeRetire(overlay)
                                hideCdPending[overlay] = nil
                            end
                            hideCdWatch[overlay] = hostSid
                            hideCdSeen[overlay] = true
                            hideCdAny = true
                            -- Arm the clearing edges on this host (once per
                            -- frame); reached only for an overlay that opted
                            -- in and whose host resolved.
                            HideCdWireHost(btn)
                        end
                    end
                end
            end
        end
    end
    ns._barGlowStackSids = stackSids

    -- Drop overlays watched last pass but not this one (toggle off, assignment
    -- removed, button gone): suppression, pending re-check and wake chain go
    -- with them. TURNING THE TOGGLE OFF ARRIVES HERE -- Refresh() runs
    -- SetupOverlays and the entry no longer opts in -- which is why this clears
    -- more than hideCdWatch. It is also what stops the wake tables accumulating
    -- one dead entry per overlay per toggle cycle: overlayFrames never releases
    -- an overlay, so nothing here is collected on our behalf.
    for overlay in pairs(hideCdWatch) do
        if not hideCdSeen[overlay] then
            hideCdWatch[overlay] = nil
            hideCdSuppressed[overlay] = nil
            hideCdPending[overlay] = nil
            HideCdWakeRetire(overlay)
        end
    end

    -- Suppression survives a rebuild only for overlays still being watched with
    -- the SAME host (a rebuild must not silently resurrect a glow mid-cooldown,
    -- and a changed host was already cleared above); everything else is
    -- dropped, which fails OPEN.
    for overlay in pairs(hideCdSuppressed) do
        if not hideCdWatch[overlay] then
            hideCdSuppressed[overlay] = nil
            -- Belt to the prune's braces: an overlay that is suppressed while
            -- unwatched should be unreachable, so if one ever does appear its
            -- chain must not be the thing that survives it.
            hideCdPending[overlay] = nil
            HideCdWakeRetire(overlay)
        end
    end
    HideCdSetActive(hideCdAny)

    -- Hide overlays that are no longer assigned
    for key, overlay in pairs(overlayFrames) do
        if not activeKeys[key] then
            StopNativeGlow(overlay)
            overlay:Hide()
            lastStates[key] = nil
        end
    end

    -- Force re-evaluation on next tick
    wipe(lastStates)
end

--- Update glow visuals based on current aura state.
--- Called each CDM tick (~10Hz from BuffTicker).
local function UpdateOverlayVisuals()
    local bg = _cachedBG
    if not bg or not bg.enabled then return end

    for key, overlay in pairs(overlayFrames) do
        if overlay:IsShown() and overlay._assignEntry then
            local entry = overlay._assignEntry
            local spellID = entry.spellID
            local mode = entry.mode or "ACTIVE"
            local onlyInCombat = entry.onlyInCombat == true

            local auraActive = false
            if spellID and spellID > 0 then
                local cache = ns._tickBlizzActiveCache
                if cache and cache[spellID] then
                    auraActive = true
                end
            end

            local shouldGlow
            if mode == "MISSING" then
                shouldGlow = not auraActive
            else
                shouldGlow = auraActive
            end

            if shouldGlow and onlyInCombat then
                shouldGlow = (InCombatLockdown and InCombatLockdown()) or UnitAffectingCombat("player") or false
            end

            -- At Stacks (ACTIVE mode only): fed to the gate(s) every tick
            -- regardless of state-change dedupe below, so the mask tracks a
            -- live stack count while the glow keeps running. A KNOWN count
            -- that fails the comparison stops the glow outright (Lua-side,
            -- cheap); an UNKNOWN/SECRET count never blocks it -- the gate's
            -- open value / the engine-side clamp decide instead.
            local gateSt
            if shouldGlow and mode ~= "MISSING" and entry.stackEnabled and spellID and spellID > 0 then
                local threshold = tonumber(entry.stackThreshold) or 2
                local operator = entry.stackOperator or "gte"
                gateSt = ConfigureStackGate(overlay, key, threshold, operator)
                -- Same sid/baseSID/linked resolution as auraActive above, so
                -- this matches whatever spellID the entry was saved against
                -- (a raw GetPlayerAuraBySpellID(spellID) query missed on the
                -- override/linked-id drift these tracked buffs can have).
                local stacks = ns._tickBlizzAuraStacks and ns._tickBlizzAuraStacks[spellID]
                -- Secret probe FIRST: any truthy/nil/relational test on a
                -- secret value hard-errors, not just `<`/`>=`.
                local secret = issecretvalue and issecretvalue(stacks)
                local feedValue
                if secret then
                    feedValue = stacks
                elseif stacks == nil then
                    feedValue = gateSt.openValue
                elseif not StackGlowMatches(stacks, operator, threshold) then
                    shouldGlow = false
                else
                    feedValue = stacks
                end
                if shouldGlow then
                    gateSt.gate:SetValue(feedValue)
                    if gateSt.gate2 then
                        -- Explicit branch: an `and feedValue or 1` form would test
                        -- a secret feedValue's truthiness and hard-error.
                        if operator == "eq" then
                            gateSt.gate2:SetValue(feedValue)
                        else
                            gateSt.gate2:SetValue(1)
                        end
                    end
                end
            end

            -- Hide On Cooldown: the FINAL gate, and it can only ever take a
            -- glow away. It reads the stored boolean and nothing else -- a
            -- live cooldown read here would allocate a table on every one of
            -- these ~10Hz ticks, and the cooldown flags it would have to read
            -- were falsified in testing anyway (see the section comment).
            if shouldGlow and entry.hideOnCooldown and hideCdSuppressed[overlay] then
                shouldGlow = false
            end

            -- Only update start/stop on state change (avoids restarting animations)
            if shouldGlow ~= lastStates[key] then
                lastStates[key] = shouldGlow
                if shouldGlow then
                    StopNativeGlow(overlay)
                    local style = entry.glowStyle or 1
                    -- Force Custom Shape Glow for custom-shaped icons
                    local glowParent = overlay:GetParent()
                    local gpfc = glowParent and ns._ecmeFC and ns._ecmeFC[glowParent]
                    local shapeName = gpfc and gpfc.shapeName
                    if shapeName and shapeName ~= "square" and shapeName ~= "csquare" and shapeName ~= "none" then
                        style = 2
                    end
                    local cr, cg, cb
                    if entry.colorMode == "class" then
                        local cc = EllesmereUI.GetClassColor(EllesmereUI._playerClass)
                        cr, cg, cb = cc.r, cc.g, cc.b
                    elseif entry.colorMode == "custom" and entry.glowColor then
                        cr = entry.glowColor.r or 1
                        cg = entry.glowColor.g or 0.788
                        cb = entry.glowColor.b or 0.137
                    end
                    if gateSt then
                        -- Both gate masks travel as data (mask2 is nil unless the
                        -- operator needs the upper gate): the Show Glows Only in
                        -- Combat replay restarts from the recorded opts, so a mask
                        -- bound out here would be missing on every texture that
                        -- replay creates fresh.
                        StartNativeGlow(overlay, style, cr, cg, cb, { maskWith = gateSt.mask, maskWith2 = gateSt.mask2 })
                    else
                        StartNativeGlow(overlay, style, cr, cg, cb)
                    end
                else
                    StopNativeGlow(overlay)
                end
            end
        end
    end
end
ns.UpdateOverlayVisuals = UpdateOverlayVisuals

--- Rebuild overlays and force a visual update
function ns.RequestBarGlowUpdate()
    SetupOverlays()
    UpdateOverlayVisuals()
end
-- Alias for backward compatibility with options code
ns.RequestUpdate = ns.RequestBarGlowUpdate

-------------------------------------------------------------------------------
--  Integration: called from main file's UpdateAllCDMBars tick
-------------------------------------------------------------------------------

-- Called once during CDMFinishSetup
function ns.InitBarGlows()
    SetupOverlays()
end
