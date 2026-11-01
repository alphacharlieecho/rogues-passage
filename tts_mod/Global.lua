-- Rogue's Passage — Tabletop Simulator Global script
-- Phase 2 foundation: player registration, two-color selection, starter pools,
-- and persistent campaign metadata.
--
-- IMPORTANT: Set CATALOG_URL to the public raw URL of card_catalog/tts_catalog.json.

RP_CONFIG = {
    CATALOG_BASE_URL = "https://raw.githubusercontent.com/alphacharlieecho/rogues-passage/main/card_catalog/tts_catalogs/tts_catalog_",
    CARDS_PER_COLOR = 10,
    MAX_COPIES_PER_ORACLE_ID = 4,
    CARD_BACK_URL = nil, -- Optional; leave nil to use TTS's default card back.
}

RP_COLORS = {
    { code = "W", name = "White" },
    { code = "U", name = "Blue" },
    { code = "B", name = "Black" },
    { code = "R", name = "Red" },
    { code = "G", name = "Green" },
}

RP_campaign = {
    schema_version = 1,
    players = {},
    next_instance_id = 1,
}
RP_catalogs = {}
RP_catalog_loading = {}
RP_catalog_errors = {}
RP_catalog_queue = {}
RP_catalog_queued = {}
RP_catalog_active = nil
RP_catalog_request_id = 0

RP_PlayerManager = {}
RP_DeckManager = {}

local function rp_playerKey(player)
    if player == nil then return nil end
    return player.steam_id or ("seat:" .. tostring(player.color))
end

local function rp_colorName(code)
    for _, entry in ipairs(RP_COLORS) do
        if entry.code == code then return entry.name end
    end
    return tostring(code)
end

local function rp_contains(list, value)
    for _, item in ipairs(list or {}) do
        if item == value then return true end
    end
    return false
end

local function rp_escapeXml(value)
    value = tostring(value or "")
    value = value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    value = value:gsub('"', "&quot;"):gsub("'", "&apos;")
    return value
end

function RP_PlayerManager.register(player)
    local key = rp_playerKey(player)
    if not key then return nil end

    local record = RP_campaign.players[key] or {
        player_id = key,
        name = player.steam_name or player.name or player.color,
        color = player.color,
        selected_colors = {},
        starter_pool = nil,
        coins = 0,
        upgrades = {},
        progression = {},
    }
    record.name = player.steam_name or player.name or record.name or player.color
    record.color = player.color
    record.last_seen = os.time()
    RP_campaign.players[key] = record
    return record
end

function RP_PlayerManager.registerSeatedPlayers()
    for _, player in ipairs(Player.getPlayers()) do
        RP_PlayerManager.register(player)
    end
end

function RP_PlayerManager.toggleColor(player, code)
    local record = RP_PlayerManager.register(player)
    if not record then return false, "Could not identify this player." end
    if record.starter_pool then
        return false, "Your starter pool has already been generated."
    end

    local selected = record.selected_colors or {}
    if rp_contains(selected, code) then
        local updated = {}
        for _, current in ipairs(selected) do
            if current ~= code then table.insert(updated, current) end
        end
        record.selected_colors = updated
        return true
    end

    if #selected >= 2 then
        return false, "Choose exactly two colors. Deselect one before choosing another."
    end

    table.insert(selected, code)
    record.selected_colors = selected
    return true
end

function RP_PlayerManager.getRecord(player)
    local key = rp_playerKey(player)
    if not key then return nil end
    return RP_campaign.players[key]
end

function RP_DeckManager.shuffle(list)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

function RP_DeckManager.chooseCards(color)
    local colorCatalog = RP_catalogs[color]
    if not colorCatalog or type(colorCatalog.cards) ~= "table" then
        return nil, "The " .. rp_colorName(color) .. " card catalog has not loaded yet."
    end

    local eligible = {}
    for _, card in ipairs(colorCatalog.cards) do
        if card.color == color and card.image_url and card.oracle_id then
            table.insert(eligible, card)
        end
    end

    if #eligible < RP_CONFIG.CARDS_PER_COLOR then
        return nil, string.format("Only %d usable %s cards were found; %d are required.",
            #eligible, rp_colorName(color), RP_CONFIG.CARDS_PER_COLOR)
    end

    RP_DeckManager.shuffle(eligible)
    local chosen = {}
    local copies = {}
    for _, card in ipairs(eligible) do
        local count = copies[card.oracle_id] or 0
        if count < RP_CONFIG.MAX_COPIES_PER_ORACLE_ID then
            table.insert(chosen, card)
            copies[card.oracle_id] = count + 1
            if #chosen == RP_CONFIG.CARDS_PER_COLOR then break end
        end
    end

    if #chosen ~= RP_CONFIG.CARDS_PER_COLOR then
        return nil, string.format("Could not select %d %s cards within the copy limit.",
            RP_CONFIG.CARDS_PER_COLOR, rp_colorName(color))
    end
    return chosen
end

function RP_DeckManager.spawnCard(card, playerColor, index, total)
    local player = Player[playerColor]
    if not player then
        print("[Rogue's Passage] Cannot spawn cards: player seat is unavailable: " .. tostring(playerColor))
        return
    end

    local hand = player.getHandTransform()
    local yaw = (hand.rotation and hand.rotation.y) or 0
    local rotation = { 0, yaw, 0 }
    local base = hand.position + Vector(0, 0, 8):rotate(rotation)
    local column = (index - 1) % 5
    local row = math.floor((index - 1) / 5)
    local offset = Vector((column - 2) * 2.65, 0, (row - 1.5) * 3.65):rotate(rotation)
    local rawPosition = base + offset
    local position = Vector(rawPosition.x, 1.5, rawPosition.z)

    spawnObject({
        type = "CardCustom",
        position = position,
        rotation = rotation,
        callback_function = function(object)
            if not object then return end
            local custom = { face = card.image_url }
            if RP_CONFIG.CARD_BACK_URL and RP_CONFIG.CARD_BACK_URL ~= "" then
                custom.back = RP_CONFIG.CARD_BACK_URL
            end
            object.setCustomObject(custom)
            object.setName(card.name or "Unknown Card")
            object.setDescription(card.oracle_text or "")
            object.setVar("rp_oracle_id", card.oracle_id)
            object.setVar("rp_instance_id", card.instance_id)
            object.setVar("rp_owner_id", card.owner_id)
            object.setVar("rp_color", card.color)
            object.setVar("rp_card_type_line", card.type_line or "")
            object.setVar("rp_mana_cost", card.mana_cost or "")
            card.object_guid = object.getGUID() -- Convenience pointer only; campaign data does not depend on it.
        end,
    })
end

function RP_DeckManager.spawnStarterPool(player, record)
    if not record or not record.starter_pool then return end
    local cards = record.starter_pool.cards or {}
    for index, card in ipairs(cards) do
        RP_DeckManager.spawnCard(card, player.color, index, #cards)
    end
end

function RP_DeckManager.generateStarterPool(player)
    local record = RP_PlayerManager.register(player)
    if not record then return false, "Could not identify this player." end
    if record.starter_pool then return false, "Your starter pool has already been generated." end
    local selected = record.selected_colors or {}
    if #selected ~= 2 then return false, "Select exactly two colors before generating your pool." end
    for _, color in ipairs(selected) do
        if not RP_catalogs[color] then
            return false, "The " .. rp_colorName(color) .. " card catalog is still loading. Please try again shortly."
        end
    end

    local pool = {}
    for _, color in ipairs(selected) do
        local chosen, err = RP_DeckManager.chooseCards(color)
        if not chosen then return false, err end
        for _, source in ipairs(chosen) do
            local card = {
                instance_id = "rp-" .. tostring(RP_campaign.next_instance_id),
                oracle_id = source.oracle_id,
                name = source.name,
                color = source.color,
                mana_cost = source.mana_cost,
                cmc = source.cmc,
                type_line = source.type_line,
                oracle_text = source.oracle_text,
                power = source.power,
                toughness = source.toughness,
                image_url = source.image_url,
                scryfall_uri = source.scryfall_uri,
                owner_id = record.player_id,
                upgrades = {},
            }
            RP_campaign.next_instance_id = RP_campaign.next_instance_id + 1
            table.insert(pool, card)
        end
    end

    record.starter_pool = {
        generated_at = os.time(),
        colors = { selected[1], selected[2] },
        cards = pool,
    }
    RP_DeckManager.spawnStarterPool(player, record)
    return true, "Your 20-card starter pool has been generated."
end

function RP_toggleColor(player, value, id)
    -- TTS UI Button.value can arrive as -1; the element ID reliably includes
    -- the color code as its final underscore-delimited segment (rp_<seat>_<code>).
    local colorCode = string.match(tostring(id or ""), "_([WUBRG])$")
    if not colorCode then
        print("[Rogue's Passage] Could not determine clicked color from UI element ID: " .. tostring(id))
        return
    end

    local ok, err = RP_PlayerManager.toggleColor(player, colorCode)
    if not ok then
        broadcastToColor(err, player.color, { 1, 0.35, 0.25 })
    else
        -- Automatic catalog loading is disabled during this diagnostic test.
    end
    RP_refreshUI()
end

function RP_generateStarterPool(player, value, id)
    local ok, message = RP_DeckManager.generateStarterPool(player)
    if ok then
        broadcastToColor(message, player.color, { 0.35, 1, 0.45 })
    else
        broadcastToColor(message, player.color, { 1, 0.35, 0.25 })
    end
    RP_refreshUI()
end

function RP_refreshUI()
    local panels = {}
    local seated = Player.getPlayers()
    for _, player in ipairs(seated) do
        local record = RP_PlayerManager.register(player)
        local selected = record.selected_colors or {}
        local buttons = {}
        for _, color in ipairs(RP_COLORS) do
            local isSelected = rp_contains(selected, color.code)
            local label = (isSelected and "[X] " or "[ ] ") .. color.name
            local disabled = record.starter_pool and " interactable=\"false\"" or ""
            table.insert(buttons, string.format(
                '<Button id="rp_%s_%s" text="%s" value="%s" onClick="RP_toggleColor" function_owner="Global" width="112" height="34"%s />',
                player.color, color.code, rp_escapeXml(label), color.code, disabled))
        end

        local status
        local confirmButton = ""
        if record.starter_pool then
            status = "Starter pool generated: " .. tostring(#(record.starter_pool.cards or {})) .. " cards."
        else
            status = string.format("Choose exactly two colors (%d/2).", #selected)
            local catalogsReady = (#selected == 2)
            for _, color in ipairs(selected) do
                if not RP_catalogs[color] then catalogsReady = false end
            end
            local disabled = catalogsReady and "" or " interactable=\"false\""
            confirmButton = '<Button id="rp_confirm_' .. player.color .. '" text="Generate 20-card starter pool" onClick="RP_generateStarterPool" function_owner="Global" width="250" height="42"' .. disabled .. ' />'
        end

        table.insert(panels, string.format([[
            <Panel id="rp_panel_%s" visibility="%s" width="390" height="255" rectAlignment="UpperLeft" offsetXY="18 -18" color="#171923" outline="#737987" outlineSize="1">
                <VerticalLayout padding="12 12 12 12" spacing="6">
                    <Text text="ROGUE'S PASSAGE" fontSize="20" color="#FFFFFF" alignment="MiddleCenter" />
                    <Text text="%s — %s" fontSize="14" color="#D7DCE5" alignment="MiddleCenter" />
                    <HorizontalLayout spacing="5">%s</HorizontalLayout>
                    <HorizontalLayout spacing="5">%s</HorizontalLayout>
                    <Text text="%s" fontSize="13" color="#FFFFFF" alignment="MiddleCenter" />
                    %s
                    <Text text="Catalog: %s" fontSize="10" color="#AAB2C0" alignment="MiddleCenter" />
                </VerticalLayout>
            </Panel>
        ]], player.color, player.color, rp_escapeXml(record.name), player.color,
            table.concat(buttons, "", 1, 3), table.concat(buttons, "", 4, 5),
            rp_escapeXml(status), confirmButton,
            (#selected == 0 and "select colors" or
                (RP_catalog_errors[selected[1]] or RP_catalog_errors[selected[2]] or
                    ((#selected == 2 and RP_catalogs[selected[1]] and RP_catalogs[selected[2]]) and "loaded" or "loading")))))
    end

    UI.setXml('<Panel id="rp_root">' .. table.concat(panels, "\n") .. '</Panel>')
end

-- Process one catalog request at a time to avoid overlapping downloads/parses.
function RP_processNextCatalog()
    if RP_catalog_active or #RP_catalog_queue == 0 then return end

    local color = table.remove(RP_catalog_queue, 1)
    RP_catalog_queued[color] = nil
    if RP_catalogs[color] then
        RP_processNextCatalog()
        return
    end

    RP_catalog_request_id = RP_catalog_request_id + 1
    local requestId = RP_catalog_request_id
    local url = RP_CONFIG.CATALOG_BASE_URL .. color .. ".json"
    RP_catalog_active = { color = color, id = requestId }
    RP_catalog_loading[color] = true
    RP_catalog_errors[color] = nil

    print("[Rogue's Passage] DIAG 1: preparing " .. rp_colorName(color) .. " request.")
    print("[Rogue's Passage] DIAG 2: URL = " .. url)

    local callback = function(request)
        print("[Rogue's Passage] DIAG 5: " .. rp_colorName(color) .. " WebRequest callback entered.")
        if not RP_catalog_active or RP_catalog_active.id ~= requestId then
            print("[Rogue's Passage] Ignoring late " .. rp_colorName(color) .. " catalog response.")
            return
        end

        if request.is_error then
            RP_catalog_errors[color] = request.error or "Web request failed."
            print("[Rogue's Passage] " .. rp_colorName(color) .. " catalog download failed: " .. tostring(RP_catalog_errors[color]))
        else
            local response = request.text or ""
            print("[Rogue's Passage] DIAG 6: response received (" .. tostring(#response) .. " characters).")
            print("[Rogue's Passage] DIAG 7: starting JSON decode.")
            local ok, decoded = pcall(function() return JSON.decode(response) end)
            print("[Rogue's Passage] DIAG 8: JSON decode returned (success=" .. tostring(ok) .. ").")
            if not ok or type(decoded) ~= "table" or type(decoded.cards) ~= "table" or decoded.color ~= color then
                RP_catalog_errors[color] = "Color catalog JSON is invalid or has an unsupported schema."
                print("[Rogue's Passage] " .. RP_catalog_errors[color] .. " (" .. color .. ")")
            else
                RP_catalogs[color] = decoded
                print(string.format("[Rogue's Passage] Loaded %d %s cards.", #decoded.cards, rp_colorName(color)))
            end
        end

        RP_catalog_loading[color] = nil
        RP_catalog_active = nil
        print("[Rogue's Passage] DIAG 9: refreshing UI.")
        RP_refreshUI()
        print("[Rogue's Passage] DIAG 10: UI refresh returned.")
        RP_processNextCatalog()
    end

    print("[Rogue's Passage] DIAG 3: calling WebRequest.get now.")
    local ok, result = pcall(function()
        return WebRequest.get(url, callback)
    end)
    print("[Rogue's Passage] DIAG 4: WebRequest.get returned (success=" .. tostring(ok) .. ").")
    if not ok then
        RP_catalog_loading[color] = nil
        RP_catalog_active = nil
        RP_catalog_errors[color] = tostring(result)
        print("[Rogue's Passage] WebRequest.get raised an error: " .. tostring(result))
        RP_refreshUI()
        RP_processNextCatalog()
        return
    end

    -- Diagnostic timeout: if no callback arrives, this should identify a stalled request.
    Wait.time(function()
        if RP_catalog_active and RP_catalog_active.id == requestId then
            RP_catalog_active = nil
            RP_catalog_loading[color] = nil
            RP_catalog_errors[color] = "Catalog request timed out after 30 seconds."
            print("[Rogue's Passage] " .. rp_colorName(color) .. " catalog request timed out without a callback.")
            RP_refreshUI()
            RP_processNextCatalog()
        end
    end, 30)
end

function RP_loadColorCatalog(color)
    if RP_catalogs[color] or RP_catalog_loading[color] or RP_catalog_queued[color] then return end
    if not RP_CONFIG.CATALOG_BASE_URL or RP_CONFIG.CATALOG_BASE_URL == "" then
        RP_catalog_errors[color] = "Catalog base URL is not configured."
        print("[Rogue's Passage] Set RP_CONFIG.CATALOG_BASE_URL in Global.lua.")
        RP_refreshUI()
        return
    end

    RP_catalog_queued[color] = true
    table.insert(RP_catalog_queue, color)
    print("[Rogue's Passage] Queued " .. rp_colorName(color) .. " card catalog (queue: " .. tostring(#RP_catalog_queue) .. ").")
    RP_processNextCatalog()
end

function onLoad(saved_data)
    if saved_data and saved_data ~= "" then
        local ok, saved = pcall(function() return JSON.decode(saved_data) end)
        if ok and type(saved) == "table" and type(saved.campaign) == "table" then
            RP_campaign = saved.campaign
            RP_campaign.players = RP_campaign.players or {}
            RP_campaign.next_instance_id = RP_campaign.next_instance_id or 1
        else
            print("[Rogue's Passage] Saved campaign data could not be read; starting a new campaign state.")
        end
    end

    math.randomseed(os.time())
    RP_PlayerManager.registerSeatedPlayers()
    -- Automatic catalog loading is disabled during this diagnostic test.
    RP_refreshUI()
end

function onSave()
    return JSON.encode({
        schema_version = 1,
        campaign = RP_campaign,
    })
end

function onPlayerConnect(player)
    RP_PlayerManager.register(player)
    RP_refreshUI()
end

function onPlayerChangeColor(player_color)
    local player = Player[player_color]
    if player then RP_PlayerManager.register(player) end
    RP_refreshUI()
end

function onPlayerDisconnect(player)
    RP_refreshUI()
end


-- Fourth diagnostic: verify that TTS JSON decoding works on a tiny payload.
-- This performs no network request and does not modify campaign/catalog state.
function RP_testTinyJsonDecode()
    local sample = '{"color":"W","cards":[{"oracle_id":"test-001","name":"Test Card","rarity":"common"}]}'
    print("[RP TEST 4] Starting tiny JSON decode.")
    local ok, decoded = pcall(function()
        return JSON.decode(sample)
    end)
    print("[RP TEST 4] JSON.decode returned; success=" .. tostring(ok) .. ".")
    if not ok then
        print("[RP TEST 4] Decode error: " .. tostring(decoded))
        return
    end
    print("[RP TEST 4] Decoded value type: " .. tostring(type(decoded)))
    print("[RP TEST 4] Color: " .. tostring(decoded.color))
    print("[RP TEST 4] Cards type: " .. tostring(type(decoded.cards)))
    print("[RP TEST 4] Card count: " .. tostring(#decoded.cards))
    print("[RP TEST 4] Tiny JSON decode complete.")
end

-- Fifth diagnostic: decode a synthetic catalog with representative card fields.
-- Starts with only 25 records to keep the test deliberately small.
function RP_testSmallCatalogDecode()
    local cardJson = [[{"oracle_id":"sample-oracle-id","name":"Sample Card","color":"W","mana_cost":"{1}{W}","cmc":2,"type_line":"Creature — Human Soldier","oracle_text":"Vigilance\\nWhen this creature enters the battlefield, draw a card.","power":"2","toughness":"2","image_url":"https://cards.scryfall.io/normal/front/sample.jpg","scryfall_uri":"https://scryfall.com/card/sample"}]]
    local cards = {}
    for index = 1, 25 do
        cards[index] = cardJson
    end
    local payloadPrefix = [[{"project_name":"Rogue's Passage","schema_version":1,"generated_by":"RoguesPassageCardCatalog/0.3","color":"W","cards":[
    ]]
    local payload = payloadPrefix .. table.concat(cards, ",") .. "]}"

    print("[RP TEST 5] Starting representative catalog decode.")
    print("[RP TEST 5] Payload size: " .. tostring(#payload) .. " characters; records: 25.")
    local ok, decoded = pcall(function()
        return JSON.decode(payload)
    end)
    print("[RP TEST 5] JSON.decode returned; success=" .. tostring(ok) .. ".")
    if not ok then
        print("[RP TEST 5] Decode error: " .. tostring(decoded))
        return
    end
    print("[RP TEST 5] Decoded cards: " .. tostring(#decoded.cards))
    print("[RP TEST 5] First card name: " .. tostring(decoded.cards[1].name))
    print("[RP TEST 5] Representative catalog decode complete.")
end

-- Third diagnostic: test TTS JSON decoding independently of the catalog loader.
function RP_testCatalogDecode()
    local url = RP_CONFIG.CATALOG_BASE_URL .. "W.json"
    print("[RP TEST 3] Starting catalog download for JSON decode test.")

    WebRequest.get(url, function(request)
        print("[RP TEST 3] Download callback entered.")
        if request.is_error then
            print("[RP TEST 3] Download failed: " .. tostring(request.error))
            return
        end

        local response = request.text or ""
        print("[RP TEST 3] Response received: " .. tostring(#response) .. " characters.")
        print("[RP TEST 3] Starting JSON.decode.")
        local ok, decoded = pcall(function()
            return JSON.decode(response)
        end)
        print("[RP TEST 3] JSON.decode returned; success=" .. tostring(ok) .. ".")
        if not ok then
            print("[RP TEST 3] Decode error: " .. tostring(decoded))
            return
        end

        print("[RP TEST 3] Decoded value type: " .. tostring(type(decoded)))
        print("[RP TEST 3] Cards field type: " .. tostring(type(decoded.cards)))
        print("[RP TEST 3] Color field: " .. tostring(decoded.color))
        if type(decoded.cards) == "table" then
            print("[RP TEST 3] Card count: " .. tostring(#decoded.cards))
        end
        print("[RP TEST 3] Decode test complete.")
    end)

    print("[RP TEST 3] WebRequest.get returned.")
end

-- Second diagnostic: reproduce the loader's local callback and pcall wrapper,
-- but deliberately omit queue state, JSON parsing, UI refresh, and timeout logic.
function RP_testCatalogLoaderCallback()
    local color = "W"
    local requestId = 999
    local url = RP_CONFIG.CATALOG_BASE_URL .. color .. ".json"

    print("[RP TEST 2] Preparing local callback for " .. rp_colorName(color) .. ".")
    local callback = function(request)
        print("[RP TEST 2] LOCAL CALLBACK ENTERED for " .. rp_colorName(color) .. " (id=" .. tostring(requestId) .. ").")
        print("[RP TEST 2] Is error: " .. tostring(request.is_error))
        local response = request.text or ""
        print("[RP TEST 2] Response length: " .. tostring(#response) .. " characters.")
        print("[RP TEST 2] Callback complete.")
    end

    print("[RP TEST 2] Calling WebRequest.get through pcall.")
    local ok, result = pcall(function()
        return WebRequest.get(url, callback)
    end)
    print("[RP TEST 2] WebRequest.get returned (success=" .. tostring(ok) .. ").")
    if not ok then
        print("[RP TEST 2] Request call error: " .. tostring(result))
    end
end

-- TEMPORARY DIAGNOSTIC:
-- Run RP_testCatalogRequest() from the TTS scripting console after loading.
-- This uses the known-good standalone request while the full mod is loaded.
function RP_testCatalogRequest()
    local url = RP_CONFIG.CATALOG_BASE_URL .. "W.json"
    print("[Rogue's Passage TEST] Starting standalone request from full mod.")
    print("[Rogue's Passage TEST] URL: " .. url)

    WebRequest.get(url, function(request)
        print("[Rogue's Passage TEST] CALLBACK RECEIVED.")
        print("[Rogue's Passage TEST] Is error: " .. tostring(request.is_error))
        print("[Rogue's Passage TEST] Error message: " .. tostring(request.error))
        local response = request.text or ""
        print("[Rogue's Passage TEST] Response length: " .. tostring(#response) .. " characters.")
        if #response > 0 then
            print("[Rogue's Passage TEST] First 100 characters: " .. string.sub(response, 1, 100))
        end
        print("[Rogue's Passage TEST] Test complete.")
    end)

    print("[Rogue's Passage TEST] WebRequest.get returned.")
end
