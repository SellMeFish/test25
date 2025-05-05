-- EasyBond - Simplified Bond Collector (ohne GUI)
-- Basierend auf Bond Collector mit minimalem Code

-- Globale Variablen für Kontrolle
_G.bondCollectorRunning = _G.bondCollectorRunning or false
_G.failedBonds = _G.failedBonds or {}
_G.queuedRestart = _G.queuedRestart or false
_G.isInRestart = _G.isInRestart or false
_G.hasStartedBefore = _G.hasStartedBefore or false

-- Skript-Ausführungs-Check
if _G.bondCollectorRunning then
    warn("Bond Collector läuft bereits - doppelte Ausführung verhindert")
    return
end

-- Markieren, dass das Skript jetzt läuft
_G.bondCollectorRunning = true

-- Optimiere für Performance
pcall(function()
    workspace.StreamingEnabled = false
    workspace.SimulationRadius = math.huge
end)

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorkspaceService = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")

-- Local Player
local player = Players.LocalPlayer

-- Remote-Setup
local remotesRoot = ReplicatedStorage:WaitForChild("Remotes")
local EndDecisionRemote = remotesRoot:WaitForChild("EndDecision")

-- Teleport-Queue (Synapse / Fluxus / KRNL / Electron / etc.)
local queue_on_tp = (syn and syn.queue_on_teleport) 
    or queue_on_teleport 
    or (fluxus and fluxus.queue_on_teleport)
    or (krnl and krnl.queue_on_teleport)
    or (Electron and Electron.queue_on_teleport)

-- Vorwärtsdeklarationen für Funktionen
local setupAutoRestart

-- Anti-AFK
player.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

-- Execution control flag
local finished = false

-- Konfiguration (vereinfacht)
local settings = {
    -- General Settings
    autoRestart = true,      -- Auto restart after round ends
    
    -- Scan-Einstellungen
    scanEnabled = true,      
    scanSteps = 100,        
    scanDelay = 0.3,         
    
    -- Anti-Stuck Einstellungen
    jumpOnStuck = true,      
    stuckTimeout = 2,        
    maxBondTime = 30,        
    skipStuckBonds = true,   
    maxAttemptsPerBond = 3,  
    globalStuckTimeout = 15, 
    
    -- Teleport-Einstellungen
    teleportHeight = 2.5,    
    teleportRetryDelay = 0.3,
    targetProximity = 6,     
    
    -- Failed Bonds Settings
    retryFailedBonds = true, -- Retry collecting failed bonds
    useNoClipForRetry = true, -- Use no-clip when retrying failed bonds
    maxFailedRetries = 2,    -- Maximum retries for failed bonds
    failedBondRetryDelay = 0.5, -- Delay between failed bond retries
    
    -- Bond-Aura-Einstellungen
    enableBondAura = true,   
    bondAuraRadius = 10,     
    bondAuraInterval = 0.1,  
    
    -- NoClip-Einstellungen
    smartNoClip = true,      
}

-- Sichere Remote-Aktivierung mit Fehlerbehandlung
local function safeActivateObject(item)
    if not item or not item.Parent then
        return false
    end
    
    local success = false
    pcall(function()
        local originalParent = item.Parent
        
        -- Prüfen, ob ActivatePromise definiert ist
        if _G.ActivatePromise then
            _G.ActivatePromise:InvokeServer(item)
        elseif game:GetService("ReplicatedStorage"):FindFirstChild("Shared") and 
               game:GetService("ReplicatedStorage"):FindFirstChild("Shared"):FindFirstChild("Network") and
               require(game:GetService("ReplicatedStorage").Shared.Network:FindFirstChild("RemotePromise")) then
            
            local RemotePromiseMod = require(game:GetService("ReplicatedStorage").Shared.Network.RemotePromise)
            local ActivatePromise = RemotePromiseMod.new("ActivateObject")
            _G.ActivatePromise = ActivatePromise
            ActivatePromise:InvokeServer(item)
        else
            return false
        end
        
        task.wait(0.4)
        
        -- Überprüfen, ob der Bond gesammelt wurde
        success = (not item or item.Parent ~= originalParent)
    end)
    return success
end

-- Smart NoClip Funktionen
local isNoClipActive = false

-- Aktiviert intelligenten NoClip, der nur mit dem Boden kollidiert
local function enableSmartNoClip()
    if isNoClipActive then return end
    isNoClipActive = true
    
    -- Sicherstellung, dass der Spielercharakter existiert
    if not player.Character then return end
    
    -- Verbindung zur kontinuierlichen Überprüfung der Teile
    local noClipConnection = RunService.Heartbeat:Connect(function()
        if not player.Character then 
            noClipConnection:Disconnect()
            isNoClipActive = false
            return 
        end
        
        for _, part in pairs(player.Character:GetDescendants()) do
            if part:IsA("BasePart") then
                -- Bestimme, ob das Teil ein "Basisteil" ist (Füße, Beine, HRP)
                local isBasePart = part.Name == "HumanoidRootPart" or 
                                  part.Name:lower():find("foot") or 
                                  part.Name:lower():find("leg") or
                                  part.Name:lower():find("torso")
                
                -- Für Basisteile: Kollision nur mit dem Boden aktivieren
                if isBasePart then
                    -- Prüfe, ob unterhalb des Teils ein Bodenteil ist
                    local rayParams = RaycastParams.new()
                    rayParams.FilterType = Enum.RaycastFilterType.Blacklist
                    rayParams.FilterDescendantsInstances = {player.Character}
                    
                    local rayResult = workspace:Raycast(part.Position, Vector3.new(0, -10, 0), rayParams)
                    
                    -- Wenn ein Boden in der Nähe ist, Kollision aktivieren, sonst deaktivieren
                    if rayResult and rayResult.Distance < 5 then
                        part.CanCollide = true
                    else
                        part.CanCollide = false
                    end
                else
                    -- Alle anderen Teile haben keine Kollision
                    part.CanCollide = false
                end
            end
        end
    end)
    
    -- Rückgabe der Verbindung, damit sie später getrennt werden kann
    return noClipConnection
end

-- Deaktiviert NoClip und stellt normale Kollision wieder her
local function disableSmartNoClip(connection)
    if not isNoClipActive then return end
    isNoClipActive = false
    
    -- Trennung der NoClip-Verbindung
    if connection then
        connection:Disconnect()
    end
    
    -- Normale Kollision für alle Teile wiederherstellen
    if player.Character then
        for _, part in pairs(player.Character:GetDescendants()) do
            if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
                part.CanCollide = true
            end
        end
    end
end

-- Status-Updates in der Konsole
local collectedBonds = 0
local totalBonds = 0
local startTime = 0

local function updateStatus(status, collected, total)
    -- Ausgabe in der Konsole
    print(status)
    
    -- Aktualisiere Zähler
    if total and total > 0 then
        totalBonds = total
    end
    
    if collected then
        collectedBonds = collected
    end
    
    -- Fortschritt berechnen
    local percentage = totalBonds > 0 and math.floor((collectedBonds / totalBonds) * 100) or 0
    print("Bonds: " .. collectedBonds .. "/" .. totalBonds .. " (" .. percentage .. "%)")
    
    -- ETA berechnen
    if startTime > 0 and collectedBonds > 0 and collectedBonds < totalBonds then
        local elapsed = tick() - startTime
        local estimatedTotal = elapsed * (totalBonds / collectedBonds)
        local remaining = estimatedTotal - elapsed
        
        -- Format time
        local minutes = math.floor(remaining / 60)
        local seconds = math.floor(remaining % 60)
        
        print("Geschätzte Zeit: " .. minutes .. "m " .. seconds .. "s")
    end
end

-- Todeserkennung, vereinfacht
local diedConnection = nil
local function setupDeathDetection()
    if diedConnection then 
        diedConnection:Disconnect()
        diedConnection = nil
    end
    
    -- Sicherer Thread für Charakter-Gesundheitsprüfung
    task.spawn(function()
        while not finished do
            if player and player.Character then
                local humanoid = player.Character:FindFirstChild("Humanoid")
                if humanoid then
                    if humanoid.Health <= 0 then
                        print("Charakter ist gestorben (Gesundheit = 0)")
                        finished = true
                        
                        -- Verbindungen trennen
                        if diedConnection then
                            diedConnection:Disconnect()
                        end
                        
                        -- Direkt EndDecision feuern
                        pcall(function()
                            if EndDecisionRemote then
                                EndDecisionRemote:FireServer(false)
                            end
                        end)
                        
                        print("Tod erkannt! Beende Skript...")
                        scriptFinished() -- Wird später definiert
                        break
                    end
                end
            end
            task.wait(0.2)
        end
    end)
    
    -- Traditioneller Ansatz für Todeserkennung
    if player.Character then
        local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            diedConnection = humanoid.Died:Connect(function()
                print("Charakter gestorben")
                task.wait(0.5)
                scriptFinished()
            end)
        end
    end
    
    -- Auf neue Charaktere reagieren
    player.CharacterAdded:Connect(function(char)
        local humanoid = char:WaitForChild("Humanoid")
        diedConnection = humanoid.Died:Connect(function()
            print("Neuer Charakter gestorben")
            task.wait(0.5)
            scriptFinished()
        end)
    end)
end

-- Verbesserte Funktion für Teleport-Queue mit zusätzlicher Fehlerbehandlung
local function setupAutoRestart()
    -- Sichere Ausführung mit Fehlerbehandlung
    local success, errorMsg = pcall(function()
        -- Verhindern, dass die Queue mehrfach eingerichtet wird
        if _G.queuedRestart then 
            print("Auto-Restart ist bereits in der Queue - überspringe")
            return 
        end
        
        -- Queuing-Status auf true setzen
        _G.queuedRestart = true
        _G.isInRestart = true
            
        -- Erstelle den korrekten Aufruf für die Queue
        local restartCode = [[
-- Restart-Status zurücksetzen
_G.queuedRestart = false;
_G.isInRestart = false;

-- Vorherigen Start merken
_G.hasStartedBefore = true;

-- Lade direkten Link vom GitHub-Repository
loadstring(game:HttpGet("https://raw.githubusercontent.com/SellMeFish/test25/refs/heads/main/test.lua"))()
]]

        -- Sichere Ausführung mit mehreren Executor-Optionen
        local queueSuccess = false
        
        -- Versuche die Funktion direkt
        if queue_on_tp then
            pcall(function()
                queue_on_tp(restartCode)
                queueSuccess = true
                print("Auto-Restart-Code erfolgreich in die Queue gestellt")
            end)
        end
        
        -- Fallback für andere Executors
        if not queueSuccess then
            -- Versuche verschiedene bekannte Queue-Methoden
            if syn then
                pcall(function() 
                    syn.queue_on_teleport(restartCode)
                    queueSuccess = true
                    print("Auto-Restart via syn.queue_on_teleport")
                end)
            elseif fluxus then
                pcall(function() 
                    fluxus.queue_on_teleport(restartCode)
                    queueSuccess = true
                    print("Auto-Restart via fluxus.queue_on_teleport")
                end)
            elseif queue_on_teleport then
                pcall(function() 
                    queue_on_teleport(restartCode)
                    queueSuccess = true
                    print("Auto-Restart via queue_on_teleport")
                end)
            end
        end
        
        if not queueSuccess then
            warn("Queue-on-Teleport-Funktion nicht verfügbar oder fehlgeschlagen")
            -- Status zurücksetzen, da Queuing nicht funktioniert
            _G.queuedRestart = false
        end
    end)
    
    -- Fehlerbehandlung für den Fall von Problemen mit der Funktion
    if not success then
        warn("Fehler beim Einrichten des Auto-Restarts: " .. tostring(errorMsg))
        -- Statussicherung bei Fehler
        _G.queuedRestart = false
        _G.isInRestart = false
    end
end

local function scriptFinished()
    if finished then return end
    finished = true
    
    -- Markieren, dass das Skript nicht mehr läuft
    task.delay(2, function()
        _G.bondCollectorRunning = false
    end)
    
    -- Cleanup connections
    if diedConnection then
        diedConnection:Disconnect()
        diedConnection = nil
    end

    -- Fire EndDecision
    pcall(function()
        if EndDecisionRemote then
            EndDecisionRemote:FireServer(false)
        end
    end)

    print("Fertig! Warte auf nächste Runde...")
    
    -- Bereite automatischen Neustart vor, wenn aktiviert
    if settings.autoRestart then
        task.spawn(function()
            -- Richte sofort die Teleport-Queue ein
            setupAutoRestart()
            print("Auto-Restart vorbereitet")
        end)
    end
end

-- Hauptfunktion zum Ausführen des Bond-Sammlers
local function run()
    -- Set up death detection immediately 
    setupDeathDetection()
    
    -- Character & Humanoid
    print("Warte auf Charakter...")
    local char = player.Character or player.CharacterAdded:Wait()
    local hrp = char:WaitForChild("HumanoidRootPart")
    local humanoid = char:WaitForChild("Humanoid")
    
    -- Remote-Setup
    print("Lade Remote-Services...")
    local networkFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network")
    local RemotePromiseMod = require(networkFolder:WaitForChild("RemotePromise"))
    local ActivatePromise = RemotePromiseMod.new("ActivateObject")
    
    -- Globalen Zugriff auf ActivatePromise einrichten
    _G.ActivatePromise = ActivatePromise
    
    -- Bond Aura Setup
    local bondAuraConnection = nil
    if settings.enableBondAura then
        -- Funktion zum Einsammeln von Bonds in der Nähe
        local function collectNearbyBonds()
            if not player.Character or not player.Character:FindFirstChild("HumanoidRootPart") then
                return
            end
            
            local hrpPos = player.Character.HumanoidRootPart.Position
            local runtime = WorkspaceService:FindFirstChild("RuntimeItems")
            
            if runtime then
                for _, item in ipairs(runtime:GetChildren()) do
                    if item.Name:match("Bond") then
                        local part = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart")
                        if part and part.Parent then
                            local distance = (hrpPos - part.Position).Magnitude
                            
                            if distance <= settings.bondAuraRadius then
                                local success = safeActivateObject(item)
                                if success then
                                    collectedBonds = collectedBonds + 1
                                    updateStatus("Bond automatisch mit Aura gesammelt!", collectedBonds, totalBonds)
                                end
                            end
                        end
                    end
                end
            end
        end
        
        -- Bond-Aura regelmäßig aktivieren
        bondAuraConnection = RunService.Heartbeat:Connect(function()
            local currentTime = tick()
            if not _G.lastBondAuraTime or (currentTime - _G.lastBondAuraTime) >= settings.bondAuraInterval then
                _G.lastBondAuraTime = currentTime
                collectNearbyBonds()
            end
        end)
        
        print("Bond Aura aktiviert - Radius: " .. settings.bondAuraRadius .. " Studs")
    end
    
    -- Cleanup-Funktion für die Bond-Aura
    local function cleanupBondAura()
        if bondAuraConnection then
            bondAuraConnection:Disconnect()
            bondAuraConnection = nil
            print("Bond Aura deaktiviert")
        end
    end

    -- Bond collection
    local bondData = {}
    local seenKeys = {}
    local function recordBonds()
        local runtime = WorkspaceService:WaitForChild("RuntimeItems")
        for _, item in ipairs(runtime:GetChildren()) do
            if item.Name:match("Bond") then
                local part = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart")
                if part then
                    local key = ("%.1f_%.1f_%.1f"):format(
                        part.Position.X, part.Position.Y, part.Position.Z
                    )
                    if not seenKeys[key] then
                        seenKeys[key] = true
                        table.insert(bondData, { item = item, pos = part.Position, key = key })
                    end
                end
            end
        end
    end

    -- Scan map
    if settings.scanEnabled then
        updateStatus("Scanne Karte nach Bonds...", 0, 0)
        local scanTarget = CFrame.new(-424.448975, 26.055481, -49040.6562, -1,0,0, 0,1,0, 0,0,-1)
        for i = 1, settings.scanSteps do
            local progress = math.floor((i / settings.scanSteps) * 100)
            updateStatus("Scanne Karte: " .. progress .. "%", 0, 0)
            hrp.CFrame = hrp.CFrame:Lerp(scanTarget, i/settings.scanSteps)
            task.wait(0.3)
            recordBonds()
            task.wait(0.1)
        end
        hrp.CFrame = scanTarget
        task.wait(0.3)
        recordBonds()
    else
        updateStatus("Kartenscanning deaktiviert, sammle bekannte Bonds...", 0, 0)
        recordBonds()
    end

    print(("→ %d Bonds gefunden"):format(#bondData))
    updateStatus("Scan abgeschlossen", 0, #bondData)
    
    if #bondData == 0 then
        warn("Keine Bonds gefunden – prüfe RuntimeItems")
        updateStatus("Keine Bonds gefunden!", 0, 0)
        return scriptFinished()
    end

    -- VEHICLESEAT-TELEPORT VIA MaximGun
    updateStatus("Suche nach MaximGun...", 0, #bondData)
    local itemsFolder = WorkspaceService:WaitForChild("RuntimeItems")
    local maximGun = itemsFolder:FindFirstChild("MaximGun")
    if not maximGun then
        updateStatus("Fehler: MaximGun nicht gefunden!", 0, #bondData)
        return scriptFinished()
    end
    
    local vehicleSeat = maximGun:FindFirstChildWhichIsA("VehicleSeat")
    if not vehicleSeat then
        updateStatus("Fehler: VehicleSeat nicht gefunden!", 0, #bondData)
        return scriptFinished()
    end

    local function atTarget(pos, tol)
        return (hrp.Position - pos).Magnitude <= (tol or 6)
    end

    -- Starte Sammlung - Setze Startzeit für ETA
    startTime = tick()
    
    -- Variable für Timeout/Lag-Handling hinzufügen
    local consecutiveFailures = 0
    local maxConsecutiveFailures = 5

    -- Teleport-Loop durch alle Bonds
    for idx, entry in ipairs(bondData) do
        -- Reset global stuck detection on every new bond
        globalStuckTimer = tick()
        globalStuckPosition = hrp.Position
        
        -- Bond-specific timeout timer and attempt counter
        local bondStartTime = tick()
        local bondAttempts = 0
        
        -- Einfacher Check, ob Charakter existiert
        if not player.Character then
            return scriptFinished()
        end
        
        updateStatus("Sammle Bond " .. idx, idx - 1, #bondData)
        
        -- Reset consecutive failures count if we had a successful collection previously
        if consecutiveFailures > 0 and idx > 1 and not bondData[idx-1].item.Parent then
            consecutiveFailures = 0
        end
        
        -- If we've had too many consecutive failures, try to reset by jumping
        if consecutiveFailures >= maxConsecutiveFailures then
            updateStatus("Zu viele Fehlversuche, setze Charakterposition zurück...", idx - 1, #bondData)
            
            -- Dismount from seat if seated
            if humanoid.SeatPart then
                humanoid.Jump = true
                task.wait(0.5)
            end
            
            -- Wait a bit longer to ensure we're fully reset
            task.wait(1)
            consecutiveFailures = 0
        end
        
        -- Reset Stuck Detection für neuen Bond
        lastPosition = hrp.Position
        stuckTimer = tick()
        stuckCheckEnabled = true
        
        -- Teleportiere zum Bond
        local destCFrame = CFrame.new(entry.pos + Vector3.new(0, settings.teleportHeight, 0))
        vehicleSeat:PivotTo(destCFrame)
        RunService.Heartbeat:Wait()

        -- Versuche auf den Sitz zu setzen
        local t0 = tick()
        while humanoid.SeatPart ~= vehicleSeat and tick() - t0 < 1 do
            vehicleSeat:Sit(humanoid)
            task.wait(0.05)
            
            -- Prüfe, ob wir festsitzen
            if settings.jumpOnStuck and stuckCheckEnabled and (hrp.Position - lastPosition).Magnitude < 0.1 then
                if tick() - stuckTimer > settings.stuckTimeout then
                    print("Charakter feststeckend, versuche zu springen...")
                    humanoid.Jump = true
                    task.wait(0.2)
                    stuckTimer = tick()
                    hrp.CFrame = hrp.CFrame * CFrame.new(0, 0.5, 0)
                    task.wait(0.3)
                    
                    -- If we've been trying to get onto the seat for too long, force a more drastic measure
                    if (tick() - t0) > 5 and settings.skipStuckBonds then
                        -- After 5 seconds of trying to sit, assume something is wrong
                        updateStatus("Konnte nicht auf VehicleSeat sitzen, versuche Notfall-Teleport...", idx - 1, #bondData)
                        
                        -- Try to teleport directly to the bond
                        pcall(function()
                            hrp.CFrame = CFrame.new(entry.pos + Vector3.new(0, 3, 0))
                        end)
                        
                        -- Exit the sitting loop early since our position has changed drastically
                        break
                    end
                end
            else
                lastPosition = hrp.Position
                stuckTimer = tick()
            end
        end

        -- Deaktiviere Stuck-Check während wir auf dem Sitz sind
        stuckCheckEnabled = false

        -- Warte, bis wir das Ziel erreicht haben
        local t1 = tick()
        local wasNearTarget = false
        repeat 
            RunService.Heartbeat:Wait()
            
            -- Prüfe, ob wir Fortschritt zum Ziel machen
            if settings.jumpOnStuck and (tick() - t1) > 0.8 and not wasNearTarget then
                if atTarget(entry.pos, 15) then
                    wasNearTarget = true  -- Wir sind nahe, warte länger
                else
                    -- Teleport funktioniert nicht, zurücksetzen
                    updateStatus("TP funktioniert nicht, setze zurück...", idx - 1, #bondData)
                    humanoid.Jump = true
                    task.wait(0.3)
                    
                    -- Increment attempt counter
                    bondAttempts = bondAttempts + 1
                    
                    -- If we've tried too many times on this bond, skip it
                    if bondAttempts >= settings.maxAttemptsPerBond and settings.skipStuckBonds then
                        updateStatus("Bond " .. idx .. " übersprungen (zu viele Versuche)", idx - 1, #bondData)
                        break
                    end
                    
                    -- Versuche unterschiedliche Höhen für den Teleport
                    for offsetY = 4, 7, 1 do
                        vehicleSeat:PivotTo(CFrame.new(entry.pos + Vector3.new(0, offsetY, 0)))
                        task.wait(0.1)
                        
                        if humanoid.SeatPart ~= vehicleSeat then
                            vehicleSeat:Sit(humanoid)
                            task.wait(0.1)
                        end
                        
                        if (hrp.Position - entry.pos).Magnitude < 15 then
                            break
                        end
                    end
                    
                    t1 = tick()  -- Reset timer
                end
            end
        until atTarget(entry.pos) or (tick() - t1) > 1.2

        -- Prüfe, ob wir das Ziel erreicht haben
        local reachedTarget = atTarget(entry.pos)
        if not reachedTarget and humanoid.SeatPart == vehicleSeat then
            humanoid.Jump = true
            task.wait(0.3)
        end
        
        -- Function to check if a bond is collectible
        local function isBondCollectible(bondItem)
            -- Wenn das Item nicht mehr existiert, ist es nicht sammelbar
            if not bondItem or not bondItem.Parent then
                return false
            end
            
            -- Prüfe, ob der Bond noch richtig mit der Welt verbunden ist
            local primaryPart = bondItem.PrimaryPart or bondItem:FindFirstChildWhichIsA("BasePart")
            if not primaryPart then
                return false
            end
            
            -- Prüfe, ob der Bond zu weit entfernt ist (könnte durch Map-Änderungen abweichen)
            local distance = (hrp.Position - primaryPart.Position).Magnitude
            if distance > 100 then
                return false
            end
            
            return true
        end
        
        -- Versuche Bond zu sammeln, wenn wir nahe genug sind
        local collectSuccess = false
        if reachedTarget and isBondCollectible(entry.item) then
            collectSuccess = safeActivateObject(entry.item)
        end

        if collectSuccess then
            collectedBonds = collectedBonds + 1
            updateStatus("Bond " .. idx .. " gesammelt", idx, #bondData)
            lastBondCompletionTime = tick()
            consecutiveFailures = 0
        else
            -- Check if we've spent too much time on this bond
            local bondTime = tick() - bondStartTime
            if settings.skipStuckBonds and bondTime > settings.maxBondTime then
                updateStatus("Bond " .. idx .. " übersprungen (Timeout: " .. math.floor(bondTime) .. "s)", idx - 1, #bondData)
                consecutiveFailures = consecutiveFailures + 1
                
                -- Speichern des fehlgeschlagenen Bonds für späteren Versuch
                if settings.retryFailedBonds and isBondCollectible(entry.item) then
                    table.insert(_G.failedBonds, {
                        item = entry.item,
                        pos = entry.pos,
                        key = entry.key,
                        retryCount = 0,
                        lastRetryTime = tick()
                    })
                    print("Bond " .. idx .. " zur Wiederholungsliste hinzugefügt")
                end
            else
                updateStatus("Bond " .. idx .. " konnte nicht gesammelt werden", idx - 1, #bondData)
                consecutiveFailures = consecutiveFailures + 1
                
                -- Speichern des fehlgeschlagenen Bonds für späteren Versuch
                if settings.retryFailedBonds and isBondCollectible(entry.item) then
                    table.insert(_G.failedBonds, {
                        item = entry.item,
                        pos = entry.pos,
                        key = entry.key,
                        retryCount = 0,
                        lastRetryTime = tick()
                    })
                    print("Bond " .. idx .. " zur Wiederholungsliste hinzugefügt")
                end
            end
        end
        
        -- Enhanced global stuck detection
        if (hrp.Position - globalStuckPosition).Magnitude < 10 then
            -- Verbesserte Funktion für Pattern-Erkennung
            local function isStuckInPattern()
                -- Wir prüfen ob wir uns zwischen denselben Positionen hin und her bewegen
                if lastPositionHistory and #lastPositionHistory > 6 then
                    -- Prüfen, ob wir uns zwischen denselben Positionen hin und her bewegen
                    local posSet = {}
                    for _, pos in ipairs(lastPositionHistory) do
                        local posKey = string.format("%.1f,%.1f,%.1f", pos.X, pos.Y, pos.Z)
                        posSet[posKey] = (posSet[posKey] or 0) + 1
                        
                        -- Wenn wir dieselbe Position mehrmals besuchen, stecken wir wahrscheinlich in einem Muster fest
                        if posSet[posKey] >= 3 then
                            return true
                        end
                    end
                end
                return false
            end
            
            -- Wenn wir in ein Muster verstrickt sind oder keinen Fortschritt machen
            -- Versuche den Charakter zu befreien
            if isStuckInPattern() then
                updateStatus("Charakter in Bewegungsmuster gefangen, befreie...", idx, #bondData)
                
                -- Sicherstellen, dass wir vom VehicleSeat aussteigen
                if humanoid.SeatPart then
                    humanoid.Jump = true
                    task.wait(0.5)
                end
                
                -- Versuche, den Charakter mit zufälligen Bewegungen zu befreien
                for i = 1, 3 do
                    -- Zufällige Richtung
                    local angle = math.random() * math.pi * 2
                    local direction = Vector3.new(math.cos(angle), 0.5, math.sin(angle)) * (5 + math.random() * 3)
                    
                    pcall(function()
                        hrp.CFrame = CFrame.new(hrp.Position + direction)
                    end)
                    
                    humanoid.Jump = true
                    task.wait(0.3)
                end
                
                -- Historie zurücksetzen nach Befreiungsversuch
                lastPositionHistory = {}
            end
        else
            globalStuckPosition = hrp.Position
        end
        
        -- Kurze Pause vor nächstem Bond
        task.wait(0.5)
    end

    -- Fehlgeschlagene Bonds erneut versuchen, wenn aktiviert
    if settings.retryFailedBonds and #_G.failedBonds > 0 then
        updateStatus("Versuche fehlgeschlagene Bonds erneut zu sammeln...", collectedBonds, totalBonds)
        
        local failedBondsCount = #_G.failedBonds
        local retrySuccessCount = 0
        
        -- Neue Funktion für No-Clip-Teleport
        local function teleportWithNoClip(pos)
            if settings.useNoClipForRetry then
                -- Smart No-Clip temporär aktivieren
                local noClipConnection = nil
                
                if settings.smartNoClip then
                    noClipConnection = enableSmartNoClip()
                else
                    -- Klassisches No-Clip aktivieren (alle Kollisionen deaktivieren)
                    pcall(function()
                        for _, part in pairs(player.Character:GetDescendants()) do
                            if part:IsA("BasePart") then
                                part.CanCollide = false
                            end
                        end
                    end)
                end
                
                -- Direkt zum Bond teleportieren
                pcall(function()
                    hrp.CFrame = CFrame.new(pos)
                end)
                
                task.wait(0.3)
                
                -- No-Clip wieder deaktivieren
                if settings.smartNoClip then
                    disableSmartNoClip(noClipConnection)
                else
                    pcall(function()
                        for _, part in pairs(player.Character:GetDescendants()) do
                            if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
                                part.CanCollide = true
                            end
                        end
                    end)
                end
            else
                -- Herkömmlicher Teleport mit dem Fahrzeug
                local destCFrame = CFrame.new(pos + Vector3.new(0, 2, 0))
                vehicleSeat:PivotTo(destCFrame)
                RunService.Heartbeat:Wait()
                
                local t0 = tick()
                while humanoid.SeatPart ~= vehicleSeat and tick() - t0 < 1 do
                    vehicleSeat:Sit(humanoid)
                    task.wait(0.05)
                end
                
                task.wait(0.5)
                
                if humanoid.SeatPart == vehicleSeat then
                    humanoid.Jump = true
                    task.wait(0.2)
                end
            end
        end
        
        -- Versuche jeden fehlgeschlagenen Bond erneut
        for i = #_G.failedBonds, 1, -1 do
            local failedBond = _G.failedBonds[i]
            
            -- Prüfen, ob der Bond noch existiert und sammelbar ist
            if not failedBond.item or not failedBond.item.Parent then
                table.remove(_G.failedBonds, i)
                print("Fehlgeschlagener Bond existiert nicht mehr, entferne von der Liste")
            else
                -- Erhöhe den Retry-Counter
                failedBond.retryCount = failedBond.retryCount + 1
                
                -- Überprüfen, ob maximale Anzahl an Versuchen erreicht ist
                if failedBond.retryCount > settings.maxFailedRetries then
                    updateStatus("Maximale Wiederholungen für Bond überschritten, wird übersprungen", collectedBonds, totalBonds)
                    table.remove(_G.failedBonds, i)
                else
                    updateStatus("Versuche fehlgeschlagenen Bond " .. i .. "/" .. failedBondsCount, collectedBonds, totalBonds)
                    
                    -- Teleportiere direkt zum Bond mit No-Clip
                    teleportWithNoClip(failedBond.pos)
                    
                    -- Versuch, den Bond zu sammeln
                    local collectSuccess = safeActivateObject(failedBond.item)
                    if collectSuccess then
                        updateStatus("Fehlgeschlagener Bond erfolgreich gesammelt!", collectedBonds + 1, totalBonds)
                        collectedBonds = collectedBonds + 1
                        retrySuccessCount = retrySuccessCount + 1
                        table.remove(_G.failedBonds, i)
                    else
                        updateStatus("Erneuter Versuch fehlgeschlagen", collectedBonds, totalBonds)
                        -- Aktualisiere die letzte Versuchszeit
                        failedBond.lastRetryTime = tick()
                    end
                    
                    -- Kurze Pause zwischen den Versuchen
                    task.wait(settings.failedBondRetryDelay)
                end
            end
        end
        
        updateStatus("Wiederholungsversuch abgeschlossen. " .. retrySuccessCount .. " von " .. failedBondsCount .. " erfolgreich gesammelt.", collectedBonds, totalBonds)
    end

    -- Normale Beendigung: Humanoid töten & finalisieren
    updateStatus("Alle Bonds gesammelt!", collectedBonds, totalBonds)
    
    -- Bond Aura aufräumen
    cleanupBondAura()
    
    pcall(function()
        local charHum = player.Character and player.Character:FindFirstChild("Humanoid")
        if charHum then
            charHum:TakeDamage(999999)
        end
    end)

    return scriptFinished()
end

-- Sofort starten
print("EasyBond Collector gestartet")
task.spawn(function()
    local success, errorMsg = pcall(run)
    if not success then
        warn("Fehler beim Ausführen des Bond Collectors: " .. tostring(errorMsg))
        _G.bondCollectorRunning = false
    end
end)

-- Einfache Benutzeroberfläche für Konsolenausgabe
print("EasyBond Collector läuft... Drücke F9 für Konsolenausgabe.")
