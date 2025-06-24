local QBCore = exports['qb-core']:GetCoreObject()

RegisterCommand("pedattack", function(source, args)
    if not args[1] then
        TriggerClientEvent('chat:addMessage', source, {
            args = {"System", "Usage: /pedattack [playerID]"}
        })
        return
    end

    local targetId = tonumber(args[1])
    if not targetId or not GetPlayerName(targetId) then
        TriggerClientEvent('chat:addMessage', source, {
            args = {"System", "Invalid player ID!"}
        })
        return
    end

    TriggerClientEvent("zaps:spawnBallasAttack", -1, targetId)
end, true)
