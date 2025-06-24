local QBCore = exports['qb-core']:GetCoreObject()
local gangWarRunning = true -- Start immediately

local Config = {
    DespawnTime = 5 * 60 * 1000,
    PatrolRadius = 80,
    PatrolSpeed = 1.0,
    PatrolWait = 50000, -- wait 50 seconds between patrol moves
    NumberOfGuards = 30, -- Number of peds to spawn per zone
}

local attackRunning = false
local targetPlayerPed = nil
local zoneGuards = {} -- Indexed by zone number (1,2, etc.)
local zoneBlips = {}

-- For kill tracking during a war:
local gangKills = { [1] = 0, [2] = 0 }  -- [1]: first zone (e.g. Ballas), [2]: second zone (e.g. Families)
local pedDeathTracker = {} -- Table to mark which peds have already been counted as dead

local Zones = {
    {
        name = "Ballas Turf",
        points = {
            vector2(-155.81, -1788.56),
            vector2(42.12, -1685.72),
            vector2(247.81, -1858.94),
            vector2(126.01, -2041.45),
        },
        gangPedGroup = GetHashKey("AMBIENT_GANG_BALLAS"),
        ownerGang = "ballas"
    },
    {
        name = "Families Turf",
        points = {
            vector2(-178.76, -1769.37),
            vector2(87.4, -1441.99),
            vector2(-68.88, -1351.91),
            vector2(-319.2, -1642.4),
        },
        gangPedGroup = GetHashKey("AMBIENT_GANG_FAMILY"),
        ownerGang = "families"
    }
}

local playerInZone = false
local currentZone = nil

local function IsPointInPolygon(pt, poly)
    local x, y = pt.x, pt.y
    local inside, j = false, #poly
    for i = 1, #poly do
        local xi, yi = poly[i].x, poly[i].y
        local xj, yj = poly[j].x, poly[j].y
        if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

local function GetPedModelFromGroup(group)
    if group == GetHashKey("AMBIENT_GANG_BALLAS") then
        return `g_m_y_ballaeast_01`
    elseif group == GetHashKey("AMBIENT_GANG_FAMILY") then
        return `g_m_y_famfor_01`
    end
    return `g_m_y_mexgang_01`
end

local function CalculateCentroid(points)
    local x, y = 0, 0
    for _, point in ipairs(points) do
        x = x + point.x
        y = y + point.y
    end
    return vector3(x / #points, y / #points, 0)
end

-- Returns true if the coord is on a sidewalk (not road)
local function IsSafeCoord(x, y, z)
    local streetHash = GetStreetNameAtCoord(x, y, z)
    local onRoad = IsPointOnRoad(x, y, z, 0)
    return (streetHash ~= 0) and not onRoad
end

local function PatrolPed(ped, centerPos)
    CreateThread(function()
        while DoesEntityExist(ped) and not IsEntityDead(ped) do
            local offsetX, offsetY, destX, destY, destZ
            local attempts = 0
            repeat
                offsetX = (math.random() - 0.5) * 2 * Config.PatrolRadius
                offsetY = (math.random() - 0.5) * 2 * Config.PatrolRadius
                destX = centerPos.x + offsetX
                destY = centerPos.y + offsetY
                local found, groundZ = GetGroundZFor_3dCoord(destX, destY, centerPos.z + 50.0, false)
                destZ = found and groundZ or centerPos.z
                attempts = attempts + 1
                Wait(0)
            until (IsSafeCoord(destX, destY, destZ) or attempts > 10)

            TaskGoStraightToCoord(ped, destX, destY, destZ, Config.PatrolSpeed, -1, 0.0, 0.0)

            local waitTime = 0
            while waitTime < Config.PatrolWait and DoesEntityExist(ped) and not IsEntityDead(ped) do
                Wait(1000)
                waitTime = waitTime + 1000
            end
        end
    end)
end

local function SpawnZoneGuards()
    for zoneIndex, zone in ipairs(Zones) do
        if zoneGuards[zoneIndex] then
            for _, ped in ipairs(zoneGuards[zoneIndex]) do
                if DoesEntityExist(ped) then DeleteEntity(ped) end
            end
        end

        zoneGuards[zoneIndex] = {}
        local model = GetPedModelFromGroup(zone.gangPedGroup)
        RequestModel(model)
        while not HasModelLoaded(model) do Wait(50) end

        local count = Config.NumberOfGuards
        local tries = 0

        -- Calculate bounding box for spawning
        local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
        for _, pt in ipairs(zone.points) do
            minX = math.min(minX, pt.x)
            minY = math.min(minY, pt.y)
            maxX = math.max(maxX, pt.x)
            maxY = math.max(maxY, pt.y)
        end

        while count > 0 and tries < 3000 do
            tries = tries + 1
            local randX = math.random() * (maxX - minX) + minX
            local randY = math.random() * (maxY - minY) + minY

            if IsPointInPolygon(vector2(randX, randY), zone.points) then
                local found, z = GetGroundZFor_3dCoord(randX, randY, 1000.0, false)
                if found and IsSafeCoord(randX, randY, z) then
                    local ped = CreatePed(4, model, randX, randY, z, math.random(0, 360), true, false)
                    SetPedRelationshipGroupHash(ped, zone.gangPedGroup)
                    SetEntityAsMissionEntity(ped, true, true)
                    SetPedArmour(ped, 50)
                    SetPedDropsWeaponsWhenDead(ped, false)
                    GiveWeaponToPed(ped, `WEAPON_PISTOL`, 100, false, true)

                    if attackRunning and targetPlayerPed then
                        SetPedAsEnemy(ped, true)
                        TaskCombatPed(ped, targetPlayerPed, 0, 16)
                    else
                        local anims = {
                            "WORLD_HUMAN_HANG_OUT_STREET",
                            "WORLD_HUMAN_SMOKING",
                            "WORLD_HUMAN_DRINKING"
                        }
                        TaskStartScenarioInPlace(ped, anims[math.random(#anims)], 0, true)
                        PatrolPed(ped, GetEntityCoords(ped))
                    end

                    table.insert(zoneGuards[zoneIndex], ped)

                    CreateThread(function()
                        while DoesEntityExist(ped) and not IsEntityDead(ped) do
                            if HasEntityBeenDamagedByAnyPed(ped) then
                                ClearEntityLastDamageEntity(ped)
                                local attacker = PlayerPedId()
                                for _, other in ipairs(zoneGuards[zoneIndex]) do
                                    if DoesEntityExist(other) and not IsPedDeadOrDying(other) then
                                        ClearPedTasksImmediately(other)
                                        SetPedAsEnemy(other, true)
                                        TaskCombatPed(other, attacker, 0, 16)
                                        PlayAmbientSpeech1(other, "GENERIC_INSULT_HIGH", "SPEECH_PARAMS_FORCE")
                                    end
                                end
                                break
                            end
                            Wait(100)
                        end
                    end)

                    count = count - 1
                end
            end
            Wait(0)
        end
    end
end

local function CreateZoneBlips()
    for _, blip in ipairs(zoneBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    zoneBlips = {}

    for _, zone in ipairs(Zones) do
        for _, pt in ipairs(zone.points) do
            local found, z = GetGroundZFor_3dCoord(pt.x, pt.y, 1000.0, false)
            if found then
                local blip = AddBlipForCoord(pt.x, pt.y, z)
                SetBlipSprite(blip, 1) -- small dot
                SetBlipDisplay(blip, 4)
                SetBlipScale(blip, 0.6)
                SetBlipAsShortRange(blip, true)
                SetBlipColour(blip, zone.gangPedGroup == GetHashKey("AMBIENT_GANG_BALLAS") and 27 or 2)
                BeginTextCommandSetBlipName("STRING")
                AddTextComponentString(zone.name)
                EndTextCommandSetBlipName(blip)
                table.insert(zoneBlips, blip)
            end
        end
    end
end

local function GetPlayerGang()
    local pd = QBCore.Functions.GetPlayerData()
    return pd and pd.metadata and pd.metadata.gang and pd.metadata.gang.name or nil
end

local function cleanupAttack()
    for _, zoneList in pairs(zoneGuards) do
        for _, guardPed in ipairs(zoneList) do
            if DoesEntityExist(guardPed) then DeleteEntity(guardPed) end
        end
    end
    zoneGuards = {}
    attackRunning = false
    targetPlayerPed = nil

    Citizen.Wait(3000)
    SpawnZoneGuards()
end

local function startAttack(targetId)
    if attackRunning then return end
    attackRunning = true
    local targetPlayer = GetPlayerFromServerId(targetId)
    if targetPlayer == -1 then attackRunning = false return end
    targetPlayerPed = GetPlayerPed(targetPlayer)

    -- Aggressive attack loop: Keep attacking until player dies or attack is stopped
    CreateThread(function()
        while attackRunning and DoesEntityExist(targetPlayerPed) and not IsEntityDead(targetPlayerPed) do
            for _, zoneList in pairs(zoneGuards) do
                for _, ped in ipairs(zoneList) do
                    if DoesEntityExist(ped) and not IsPedDeadOrDying(ped) then
                        SetPedAsEnemy(ped, true)
                        local currentTarget = GetEntityCombatTarget(ped)
                        if currentTarget ~= targetPlayerPed then
                            ClearPedTasksImmediately(ped)
                            TaskCombatPed(ped, targetPlayerPed, 0, 16)
                        end
                    end
                end
            end
            Wait(1000)
        end
        if attackRunning then
            cleanupAttack()
        end
    end)
end

-- Detect player shooting in turf zone and trigger an attack + immediate aggression from all zone peds
CreateThread(function()
    while true do
        Wait(300)
        local ped = PlayerPedId()
        if IsPedShooting(ped) then
            local pos = GetEntityCoords(ped)
            local gang = GetPlayerGang()
            for zoneIndex, zone in pairs(Zones) do
                if IsPointInPolygon(vector2(pos.x, pos.y), zone.points) and gang ~= zone.ownerGang then
                    if not attackRunning then
                        startAttack(GetPlayerServerId(PlayerId()))
                    end

                    local playerPed = ped
                    if zoneGuards[zoneIndex] then
                        for _, guardPed in ipairs(zoneGuards[zoneIndex]) do
                            if DoesEntityExist(guardPed) and not IsPedDeadOrDying(guardPed) then
                                ClearPedTasksImmediately(guardPed)
                                SetPedAsEnemy(guardPed, true)
                                TaskCombatPed(guardPed, playerPed, 0, 16)
                                PlayAmbientSpeech1(guardPed, "GENERIC_INSULT_HIGH", "SPEECH_PARAMS_FORCE")
                            end
                        end
                    end

                    break
                end
            end
        end
    end
end)

RegisterNetEvent("zaps:spawnBallasAttack", function(targetId)
    startAttack(targetId)
end)

-- Detect player entering/leaving turf zones and notify
CreateThread(function()
    local lastZone = nil
    while true do
        Wait(1000)
        local pos = GetEntityCoords(PlayerPedId())
        local inAnyZone = false

        for _, zone in pairs(Zones) do
            if IsPointInPolygon(vector2(pos.x, pos.y), zone.points) then
                inAnyZone = true
                if lastZone ~= zone.name then
                    lastZone = zone.name
                    exports.ox_lib:notify({
                        title = zone.name,
                        description = "You’ve entered " .. zone.ownerGang .. " territory. Proceed with caution.",
                        type = "inform",
                        position = "top",
                        duration = 7000
                    })
                end
                break
            end
        end

        if not inAnyZone and lastZone ~= nil then
            exports.ox_lib:notify({
                title = "Zone Left",
                description = "You’ve left gang territory.",
                type = "inform",
                position = "top",
                duration = 5000
            })
            lastZone = nil
        end
    end
end)

local function EnterVehicle(ped, vehicle)
    TaskEnterVehicle(ped, vehicle, -1, -1, 1.5, 1, 0)
    local timeout = 0
    while not IsPedInVehicle(ped, vehicle, false) and timeout < 5000 do
        Wait(100)
        timeout = timeout + 100
    end
end

-- Make peds from one zone attack another using drive-bys
local function initiateZoneAttack(fromZoneIndex, toZoneIndex)
    local fromZone = Zones[fromZoneIndex]
    local toZone = Zones[toZoneIndex]

    if not zoneGuards[fromZoneIndex] or #zoneGuards[fromZoneIndex] == 0 then return end

    local attackCenter = CalculateCentroid(toZone.points)

    for i = 1, #zoneGuards[fromZoneIndex], 4 do
        local driver = zoneGuards[fromZoneIndex][i]
        if DoesEntityExist(driver) and not IsPedDeadOrDying(driver) then
            local model = `baller2`
            RequestModel(model)
            while not HasModelLoaded(model) do Wait(50) end

            local vehCoords = GetEntityCoords(driver)
            local heading = GetEntityHeading(driver)
            local vehicle = CreateVehicle(model, vehCoords.x, vehCoords.y, vehCoords.z, heading, true, false)
            SetVehicleDoorsLocked(vehicle, 1)

            SetPedIntoVehicle(driver, vehicle, -1)

            for j = 1, 3 do
                local ped = zoneGuards[fromZoneIndex][i + j]
                if ped and DoesEntityExist(ped) and not IsPedDeadOrDying(ped) then
                    SetPedIntoVehicle(ped, vehicle, j)
                end
            end

            CreateThread(function()
                TaskVehicleDriveToCoord(driver, vehicle, attackCenter.x, attackCenter.y, attackCenter.z, 50.0, 0, GetEntityModel(vehicle), 16777216, 2.0)
                Wait(3000)

                for seat = -1, 2 do
                    local seatPed = GetPedInVehicleSeat(vehicle, seat)
                    if seatPed and DoesEntityExist(seatPed) and not IsPedDeadOrDying(seatPed) then
                        TaskVehicleShootAtCoord(seatPed, attackCenter.x, attackCenter.y, attackCenter.z, 100, `WEAPON_MICROSMG`)
                    end
                end

                Wait(20000)
                if DoesEntityExist(vehicle) then DeleteEntity(vehicle) end
            end)
        end
    end
end

---------------------------
-- GANG WAR WITH KILL TRACKING
---------------------------
local function startGangWarCycle()
    -- Already started at top with gangWarRunning = true

    exports.ox_lib:notify({title = "Gang War", description = "Gang war cycle started. Zones will now attack each other every 60 minutes.", type = "success"})

    local nextAttack = 1

    while gangWarRunning do
        -- Reset kill counts and death tracker:
        gangKills = { [1] = 0, [2] = 0 }
        pedDeathTracker = {}

        -- Start attack
        initiateZoneAttack(nextAttack, nextAttack == 1 and 2 or 1)
        exports.ox_lib:notify({
            title = "Gang War",
            description = string.format("%s are attacking %s!", Zones[nextAttack].ownerGang:gsub("^%l", string.upper), Zones[nextAttack == 1 and 2 or 1].ownerGang:gsub("^%l", string.upper)),
            type = "warning"
        })

        local attackDuration = 20 * 60 * 1000 -- 20 minutes in milliseconds
        local attackStartTime = GetGameTimer()

        -- War monitoring thread
        while GetGameTimer() - attackStartTime < attackDuration and gangWarRunning do
            for zoneIndex, guards in ipairs(zoneGuards) do
                for _, ped in ipairs(guards) do
                    if not DoesEntityExist(ped) or IsPedDeadOrDying(ped) then
                        if ped and not pedDeathTracker[ped] then
                            pedDeathTracker[ped] = true
                            local killerZone = (zoneIndex == 1) and 2 or 1
                            gangKills[killerZone] = gangKills[killerZone] + 1
                            exports.ox_lib:notify({
                                title = "Gang War",
                                description = string.format("Kill by %s! Score %d - %d", Zones[killerZone].ownerGang:gsub("^%l", string.upper), gangKills[1], gangKills[2]),
                                type = "info"
                            })
                        end
                    end
                end
            end
            Wait(2000)
        end

        -- War ended, determine winner
        local winnerZone = nil
        if gangKills[1] > gangKills[2] then
            winnerZone = 1
        elseif gangKills[2] > gangKills[1] then
            winnerZone = 2
        end

        if winnerZone then
            exports.ox_lib:notify({
                title = "Gang War",
                description = string.format("%s have won the turf war! Reward: $25,000", Zones[winnerZone].ownerGang:gsub("^%l", string.upper)),
                type = "success"
            })
            TriggerServerEvent("qb-banking:server:addMoney", "cash", 25000)
        else
            exports.ox_lib:notify({
                title = "Gang War",
                description = "The gang war ended in a draw!",
                type = "inform"
            })
        end

        cleanupAttack()

        -- Wait for 60 minutes before next war
        local cycleWait = 60 * 60 * 1000 -- 60 minutes
        local cycleStart = GetGameTimer()
        while GetGameTimer() - cycleStart < cycleWait and gangWarRunning do
            Wait(1000)
        end

        nextAttack = nextAttack == 1 and 2 or 1
    end
end

RegisterCommand("gangwarscore", function()
    if gangWarRunning then
        local scoreText = string.format(
            "Gang War Score:\n%s: %d kills\n%s: %d kills",
            Zones[1].ownerGang:gsub("^%l", string.upper), gangKills[1],
            Zones[2].ownerGang:gsub("^%l", string.upper), gangKills[2]
        )
        exports.ox_lib:notify({
            title = "Gang War Score",
            description = scoreText,
            type = "inform",
            position = "top",
            duration = 8000
        })
    else
        exports.ox_lib:notify({
            title = "Gang War",
            description = "No gang war is currently running.",
            type = "error",
            position = "top",
            duration = 6000
        })
    end
end)

CreateThread(function()
    SpawnZoneGuards()
    CreateZoneBlips()
    Wait(5000)
    startGangWarCycle()
end)
