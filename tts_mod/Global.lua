-- Rogue's Passage — Tabletop Simulator Global script
-- Phase 2 foundation: player registration, two-color selection, starter pools,
-- and persistent campaign metadata.
--
-- TTS downloads only small, pre-generated one-color starter pools.

RP_CONFIG = {
    STARTER_POOL_BASE_URL = "https://raw.githubusercontent.com/alphacharlieecho/rogues-passage/main/card_catalog/tts_starter_pools/starter_pool_",
    CARDS_PER_COLOR = 10,
    STARTER_POOL_VARIANTS = 100,
    -- TEMPORARY image-host test: force known pools containing Aven Sunstriker and Psychic Overload.
    TEST_POOL_VARIANTS = { W = 88, U = 51 },
    RESET_CAMPAIGN_ON_LOAD = true, -- TEMPORARY: clear saved campaign state for the image-host test.
    CARD_BACK_URL = "https://backs.scryfall.io/normal/0/a/0aeebaf5-8c7d-4636-9e82-8c27447861f7.jpg", -- Standard Magic card back.
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
RP_player_color_pools = {}
RP_pool_loading = {}
RP_pool_errors = {}

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
        selected_pool_variants = {},
        starter_pool = nil,
        coins = 0,
        upgrades = {},
        progression = {},
    }
    record.name = player.steam_name or player.name or record.name or player.color
    record.color = player.color
    record.selected_pool_variants = record.selected_pool_variants or {}
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


function RP_DeckManager.spawnCard(card, playerColor, index, total)
    local player = Player[playerColor]
    if not player then
        print("[Rogue's Passage] Cannot spawn card " .. tostring(index) .. ": player seat is unavailable: " .. tostring(playerColor))
        return
    end

    local hand = player.getHandTransform()
    if not hand or not hand.position then
        print("[Rogue's Passage] Cannot spawn card " .. tostring(index) .. ": hand transform is unavailable for " .. tostring(playerColor))
        return
    end

    -- TTS card/deck artwork is currently oriented 180 degrees from the player's view.
    -- Rotate the deck around its vertical axis so both face and back read upright.
    local yaw = ((hand.rotation and hand.rotation.y) or 0) + 180
    local radians = math.rad(yaw)
    local cosYaw = math.cos(radians)
    local sinYaw = math.sin(radians)

    -- Place the pool just beyond the player's hand, rotating the layout to face the player.
    local baseLocalX, baseLocalZ = 0, 8
    local baseX = baseLocalX * cosYaw + baseLocalZ * sinYaw
    local baseZ = -baseLocalX * sinYaw + baseLocalZ * cosYaw

    local column = (index - 1) % 5
    local row = math.floor((index - 1) / 5)
    local localX = (column - 2) * 2.65
    local localZ = (row - 1.5) * 3.65
    local offsetX = localX * cosYaw + localZ * sinYaw
    local offsetZ = -localX * sinYaw + localZ * cosYaw

    local position = {
        x = hand.position.x + baseX + offsetX,
        y = 1.5,
        z = hand.position.z + baseZ + offsetZ,
    }
    local rotation = { 0, yaw, 0 }

    local custom = { face = card.image_url }
    if RP_CONFIG.CARD_BACK_URL and RP_CONFIG.CARD_BACK_URL ~= "" then
        custom.back = RP_CONFIG.CARD_BACK_URL
    end

    print(string.format(
        "[Rogue's Passage] Spawning card %d/%d: %s at (%.2f, %.2f, %.2f).",
        index, total, tostring(card.name or "Unknown Card"),
        position.x, position.y, position.z
    ))

    local ok, spawnedOrError = pcall(function()
        return spawnObject({
            type = "CardCustom",
            position = position,
            rotation = rotation,
            callback_function = function(object)
                if not object then
                    print("[Rogue's Passage] Spawn callback returned no object for card " .. tostring(index) .. ".")
                    return
                end
                local callbackOk, callbackError = pcall(function()
                    object.setName(card.name or "Unknown Card")
                    object.setDescription(card.oracle_text or "")
                    object.setVar("rp_oracle_id", card.oracle_id)
                    object.setVar("rp_instance_id", card.instance_id)
                    object.setVar("rp_owner_id", card.owner_id)
                    object.setVar("rp_color", card.color)
                    object.setVar("rp_card_type_line", card.type_line or "")
                    object.setVar("rp_mana_cost", card.mana_cost or "")
                    card.object_guid = object.getGUID()
                end)
                if callbackOk then
                    print("[Rogue's Passage] Spawned " .. tostring(card.name or "Unknown Card") .. " (GUID " .. tostring(card.object_guid) .. ").")
                else
                    print("[Rogue's Passage] Card callback error for " .. tostring(card.name) .. ": " .. tostring(callbackError))
                end
            end,
        })
    end)

    if not ok then
        print("[Rogue's Passage] spawnObject failed for " .. tostring(card.name) .. ": " .. tostring(spawnedOrError))
        return
    end

    if not spawnedOrError then
        print("[Rogue's Passage] spawnObject returned nil for " .. tostring(card.name) .. ".")
        return
    end

    local customOk, customError = pcall(function()
        spawnedOrError.setCustomObject(custom)
    end)
    if not customOk then
        print("[Rogue's Passage] setCustomObject failed for " .. tostring(card.name) .. ": " .. tostring(customError))
    end
end

function RP_DeckManager.spawnStarterPool(player, record)
    if not record or not record.starter_pool then return end

    local cards = record.starter_pool.cards or {}
    if #cards == 0 then
        print("[Rogue's Passage] Cannot spawn an empty starter pool.")
        return
    end

    local hand = player.getHandTransform()
    if not hand or not hand.position then
        print("[Rogue's Passage] Cannot spawn starter deck: hand transform is unavailable for " .. tostring(player.color))
        return
    end

    -- Shuffle the physical deck order independently of the two selected color pools.
    RP_DeckManager.shuffle(cards)

    local yaw = (hand.rotation and hand.rotation.y) or 0
    local radians = math.rad(yaw)
    local position = {
        x = hand.position.x + 8 * math.sin(radians),
        y = 1.5,
        z = hand.position.z + 8 * math.cos(radians),
    }
    local rotation = { 0, yaw, 0 }

    -- A TTS custom deck maps each CardID to its own one-card image sheet.
    -- This lets every card retain an independent face URL and a shared back.
    local deckIDs = {}
    local containedObjects = {}
    local customDeck = {}

    for index, card in ipairs(cards) do
        local deckKey = tostring(index)
        local cardID = index * 100
        local customCard = {
            FaceURL = card.image_url,
            BackURL = RP_CONFIG.CARD_BACK_URL or "",
            NumWidth = 1,
            NumHeight = 1,
            BackIsHidden = true,
        }
        customDeck[deckKey] = customCard
        table.insert(deckIDs, cardID)

        local metadata = {
            rp_oracle_id = card.oracle_id,
            rp_instance_id = card.instance_id,
            rp_owner_id = card.owner_id,
            rp_color = card.color,
            rp_card_type_line = card.type_line or "",
            rp_mana_cost = card.mana_cost or "",
            rp_cmc = card.cmc or 0,
            rp_power = card.power,
            rp_toughness = card.toughness,
            rp_upgrades = card.upgrades or {},
        }

        table.insert(containedObjects, {
            Name = "Card",
            Nickname = card.name or "Unknown Card",
            Description = card.oracle_text or "",
            GMNotes = JSON.encode(metadata),
            Transform = {
                posX = 0, posY = 0, posZ = 0,
                rotX = 0, rotY = 0, rotZ = 0,
                scaleX = 1, scaleY = 1, scaleZ = 1,
            },
            CardID = cardID,
        })
    end

    local deckData = {
        Name = "DeckCustom",
        Nickname = tostring(record.name or player.steam_name or "Player") .. "'s Rogue's Passage Starter Pool",
        Description = "20-card starter pool. Individual card metadata is stored in each card's GM Notes.",
        Transform = {
            posX = position.x, posY = position.y, posZ = position.z,
            rotX = rotation[1], rotY = rotation[2], rotZ = rotation[3],
            scaleX = 1, scaleY = 1, scaleZ = 1,
        },
        DeckIDs = deckIDs,
        CustomDeck = customDeck,
        ContainedObjects = containedObjects,
    }

    local ok, result = pcall(function()
        return spawnObjectData({
            data = deckData,
            position = position,
            rotation = rotation,
            callback_function = function(object)
                if not object then
                    print("[Rogue's Passage] Starter deck spawn callback returned no object.")
                    return
                end
                record.starter_pool.deck_guid = object.getGUID()
                object.setName(tostring(record.name or player.steam_name or "Player") .. "'s Starter Pool")
                object.setDescription("20-card Rogue's Passage starter pool.")
                print("[Rogue's Passage] Spawned starter deck with " .. tostring(#cards)
                    .. " cards (GUID " .. tostring(record.starter_pool.deck_guid) .. ").")
            end,
        })
    end)

    if not ok then
        print("[Rogue's Passage] Starter deck spawn failed: " .. tostring(result))
    elseif not result then
        print("[Rogue's Passage] Starter deck spawn returned no object.")
    end
end

function RP_DeckManager.generateStarterPool(player)
    local record = RP_PlayerManager.register(player)
    if not record then return false, "Could not identify this player." end
    if record.starter_pool then return false, "Your starter pool has already been generated." end
    local selected = record.selected_colors or {}
    if #selected ~= 2 then return false, "Select exactly two colors before generating your pool." end

    local playerKey = rp_playerKey(player)
    local colorPools = RP_player_color_pools[playerKey] or {}
    local pool = {}
    for _, color in ipairs(selected) do
        local chosen = colorPools[color]
        if type(chosen) ~= "table" or #chosen ~= RP_CONFIG.CARDS_PER_COLOR then
            return false, "The " .. rp_colorName(color) .. " starter pool is still loading. Please try again shortly."
        end
        for _, source in ipairs(chosen) do
            local card = {
                instance_id = "rp-" .. tostring(RP_campaign.next_instance_id),
                oracle_id = source.oracle_id, name = source.name, color = source.color,
                mana_cost = source.mana_cost, cmc = source.cmc, type_line = source.type_line,
                oracle_text = source.oracle_text, power = source.power, toughness = source.toughness,
                image_url = source.image_url, scryfall_uri = source.scryfall_uri,
                owner_id = record.player_id, upgrades = {},
            }
            RP_campaign.next_instance_id = RP_campaign.next_instance_id + 1
            table.insert(pool, card)
        end
    end

    record.starter_pool = {
        generated_at = os.time(),
        colors = { selected[1], selected[2] },
        pool_variants = {
            [selected[1]] = record.selected_pool_variants[selected[1]],
            [selected[2]] = record.selected_pool_variants[selected[2]],
        },
        cards = pool,
    }
    RP_DeckManager.spawnStarterPool(player, record)
    return true, "Your 20-card starter pool has been generated."
end

function RP_loadPlayerColorPool(player, color)
    local record = RP_PlayerManager.getRecord(player)
    if not record then return end
    local playerKey = rp_playerKey(player)
    local requestKey = playerKey .. ":" .. color
    RP_player_color_pools[playerKey] = RP_player_color_pools[playerKey] or {}
    if RP_player_color_pools[playerKey][color] or RP_pool_loading[requestKey] then return end

    local variant = (RP_CONFIG.TEST_POOL_VARIANTS and RP_CONFIG.TEST_POOL_VARIANTS[color])
        or record.selected_pool_variants[color]
    if not variant then
        variant = math.random(1, RP_CONFIG.STARTER_POOL_VARIANTS)
    end
    record.selected_pool_variants[color] = variant
    local url = RP_CONFIG.STARTER_POOL_BASE_URL .. color .. "_" .. string.format("%03d", variant) .. ".json"
    RP_pool_loading[requestKey] = true
    RP_pool_errors[requestKey] = nil
    print("[Rogue's Passage] Downloading " .. rp_colorName(color) .. " starter pool variant " .. tostring(variant) .. ".")

    local ok, result = pcall(function()
        return WebRequest.get(url, function(request)
            RP_pool_loading[requestKey] = nil
            if request.is_error then
                local currentRecord = RP_PlayerManager.getRecord(player)
                if currentRecord and rp_contains(currentRecord.selected_colors, color)
                    and currentRecord.selected_pool_variants[color] ~= variant then
                    RP_loadPlayerColorPool(player, color)
                    return
                end
                RP_pool_errors[requestKey] = request.error or "Starter pool download failed."
                print("[Rogue's Passage] " .. tostring(RP_pool_errors[requestKey]))
                RP_refreshUI()
                return
            end
            local decodedOk, decoded = pcall(function() return JSON.decode(request.text or "") end)
            local validPool = decodedOk and type(decoded) == "table"
                and decoded.color == color and decoded.variant == variant
                and type(decoded.cards) == "table"
                and #decoded.cards == RP_CONFIG.CARDS_PER_COLOR
            if validPool then
                for _, card in ipairs(decoded.cards) do
                    if type(card) ~= "table" or card.color ~= color
                        or not card.oracle_id or not card.image_url then
                        validPool = false
                        break
                    end
                end
            end
            if not validPool then
                RP_pool_errors[requestKey] = "Starter pool file is invalid or has an unsupported schema."
                print("[Rogue's Passage] " .. RP_pool_errors[requestKey] .. " (" .. color .. ")")
                RP_refreshUI()
                return
            end
            local currentRecord = RP_PlayerManager.getRecord(player)
            if not currentRecord or not rp_contains(currentRecord.selected_colors, color) then return end
            if currentRecord.selected_pool_variants[color] ~= variant then
                RP_loadPlayerColorPool(player, color)
                return
            end
            RP_player_color_pools[playerKey][color] = decoded.cards
            RP_pool_errors[requestKey] = nil
            print(string.format("[Rogue's Passage] Loaded %d %s starter cards.", #decoded.cards, rp_colorName(color)))
            RP_refreshUI()
        end)
    end)
    if not ok then
        RP_pool_loading[requestKey] = nil
        RP_pool_errors[requestKey] = tostring(result)
        print("[Rogue's Passage] WebRequest.get failed: " .. tostring(result))
        RP_refreshUI()
    end
end

function RP_toggleColor(player, value, id)
    local colorCode = string.match(tostring(id or ""), "_([WUBRG])$")
    if not colorCode then
        print("[Rogue's Passage] Could not determine clicked color from UI element ID: " .. tostring(id))
        return
    end
    local record = RP_PlayerManager.getRecord(player)
    local wasSelected = record and rp_contains(record.selected_colors, colorCode)
    local ok, err = RP_PlayerManager.toggleColor(player, colorCode)
    if not ok then
        broadcastToColor(err, player.color, { 1, 0.35, 0.25 })
    else
        record = RP_PlayerManager.getRecord(player)
        local playerKey = rp_playerKey(player)
        RP_player_color_pools[playerKey] = RP_player_color_pools[playerKey] or {}
        local requestKey = playerKey .. ":" .. colorCode
        if wasSelected then
            record.selected_pool_variants[colorCode] = nil
            RP_player_color_pools[playerKey][colorCode] = nil
            RP_pool_errors[requestKey] = nil
        else
            record.selected_pool_variants[colorCode] = math.random(1, RP_CONFIG.STARTER_POOL_VARIANTS)
            RP_loadPlayerColorPool(player, colorCode)
        end
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
        local playerKey = rp_playerKey(player)
        local playerPools = RP_player_color_pools[playerKey] or {}
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
            local poolsReady = (#selected == 2)
            for _, color in ipairs(selected) do
                if not playerPools[color] then poolsReady = false end
            end
            local disabled = poolsReady and "" or " interactable=\"false\""
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
                    <Text text="Starter pools: %s" fontSize="10" color="#AAB2C0" alignment="MiddleCenter" />
                </VerticalLayout>
            </Panel>
        ]], player.color, player.color, rp_escapeXml(record.name), player.color,
            table.concat(buttons, "", 1, 3), table.concat(buttons, "", 4, 5),
            rp_escapeXml(status), confirmButton,
            (#selected == 0 and "select colors" or
                (RP_pool_errors[playerKey .. ":" .. (selected[1] or "")] or
                    RP_pool_errors[playerKey .. ":" .. (selected[2] or "")] or
                    ((#selected == 2 and playerPools[selected[1]] and playerPools[selected[2]]) and "ready" or "loading")))))
    end

    UI.setXml('<Panel id="rp_root">' .. table.concat(panels, "\n") .. '</Panel>')
end

function onLoad(saved_data)
    if RP_CONFIG.RESET_CAMPAIGN_ON_LOAD then
        RP_campaign = { schema_version = 1, players = {}, next_instance_id = 1 }
        print("[Rogue's Passage] TEST RESET: started a fresh campaign state.")
    elseif saved_data and saved_data ~= "" then
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
    RP_player_color_pools = {}
    RP_pool_loading = {}
    RP_pool_errors = {}
    RP_PlayerManager.registerSeatedPlayers()
    for _, player in ipairs(Player.getPlayers()) do
        local record = RP_PlayerManager.getRecord(player)
        for _, color in ipairs((record and record.selected_colors) or {}) do
            RP_loadPlayerColorPool(player, color)
        end
    end
    RP_refreshUI()
end

function onSave()
    return JSON.encode({
        schema_version = 1,
        campaign = RP_campaign,
    })
end

function onPlayerConnect(player)
    local record = RP_PlayerManager.register(player)
    for _, color in ipairs((record and record.selected_colors) or {}) do
        RP_loadPlayerColorPool(player, color)
    end
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


