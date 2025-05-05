-- EasyBond - Ultra-Schneller Bond Collector (Turbo-Modus)
-- Optimierte Version für maximale Farm-Geschwindigkeit

-- Globale Variablen für Kontrolle
_G.bondCollectorRunning = _G.bondCollectorRunning or false
_G.failedBonds = _G.failedBonds or {}
_G.queuedRestart = _G.queuedRestart or false
_G.isInRestart = _G.isInRestart or false
_G.hasStartedBefore = _G.hasStartedBefore or false
_G.turboMode = true -- Neue Flagge für Turbo-Modus

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
    
    -- Scan-Einstellungen - AUSFÜHRLICH
    scanEnabled = true,      
    scanSteps = 70,          -- Mehr Schritte für gründlicheren Scan
    scanDelay = 0.08,        -- Optimale Verzögerung für Balance aus Geschwindigkeit und Gründlichkeit
    
    -- Anti-Stuck Einstellungen - OPTIMIERT
    jumpOnStuck = true,      
    stuckTimeout = 1,        -- Schnellere Stuck-Erkennung
    maxBondTime = 15,        -- Kürzeres Timeout für Bonds
    skipStuckBonds = true,   
    maxAttemptsPerBond = 2,  -- Weniger Versuche pro Bond
    globalStuckTimeout = 10, -- Kürzeres globales Timeout
    
    -- Teleport-Einstellungen - BESCHLEUNIGT
    teleportHeight = 2.5,    
    teleportRetryDelay = 0.1, -- Schnellere Wiederholungsversuche
    targetProximity = 8,     -- Größerer Proximity-Radius für schnelleres Sammeln
    
    -- Failed Bonds Settings - OPTIMIERT
    retryFailedBonds = true,
    useNoClipForRetry = true,
    maxFailedRetries = 1,    -- Nur ein Wiederholversuch für fehlgeschlagene Bonds
    failedBondRetryDelay = 0.2, -- Schnellerer Retry
    
    -- Bond-Aura-Einstellungen - VERBESSERT
    enableBondAura = true,   
    bondAuraRadius = 15,     -- Größerer Radius
    bondAuraInterval = 0.05, -- Häufigere Checks
    
    -- NoClip-Einstellungen
    smartNoClip = true,      
}

-- Sichere Remote-Aktivierung mit Fehlerbehandlung - OPTIMIERT
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
        
        -- Verkürzte Wartezeit für schnellere Verarbeitung
        task.wait(0.2)
        
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

-- Status-Updates in der Konsole mit präzisen Zahlen
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
    
    if collected and collected >= 0 then
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
        
        -- Ergänze Sammelgeschwindigkeit
        local bondsPerMinute = collectedBonds / (elapsed / 60)
        print("Geschwindigkeit: " .. string.format("%.1f", bondsPerMinute) .. " Bonds/min")
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
            
        -- Erstelle den korrekten Aufruf für die Queue - Mit Turbo-Modus-Erhaltung
        local restartCode = [[
-- Restart-Status zurücksetzen
_G.queuedRestart = false;
_G.isInRestart = false;

-- Vorherigen Start und Turbo-Modus merken
_G.hasStartedBefore = true;
_G.turboMode = true;

-- Lade direkten Link vom GitHub-Repository
loadstring(game:HttpGet("https://raw.githubusercontent.com/SellMeFish/test25/refs/heads/main/test.lua"))()
]]

        -- Sichere Ausführung mit mehreren Executor-Optionen
        local queueSuccess = false
        
        -- Multi-Executor-Unterstützung für höchstmögliche Kompatibilität
        local queueFunctions = {
            ["syn"] = function() syn.queue_on_teleport(restartCode) end,
            ["fluxus"] = function() fluxus.queue_on_teleport(restartCode) end,
            ["krnl"] = function() krnl.queue_on_teleport(restartCode) end,
            ["Electron"] = function() Electron.queue_on_teleport(restartCode) end,
            ["queue_on_teleport"] = function() queue_on_teleport(restartCode) end,
            ["queue_on_tp"] = function() queue_on_tp(restartCode) end
        }
        
        -- Versuche alle bekannten Queue-Methoden
        for name, func in pairs(queueFunctions) do
            if queueSuccess then break end
            
            pcall(function()
                -- Prüfe, ob die Funktion oder Variable existiert
                if name ~= "queue_on_teleport" and name ~= "queue_on_tp" and not _G[name] and not getgenv()[name] then
                    return
                end
                
                func()
                queueSuccess = true
                print("Auto-Restart via " .. name .. " eingerichtet")
            end)
        end
        
        -- Fallback-Sicherheit für unbekannte Executors
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
    
    -- Bond Aura Setup - HOCHLEISTUNGS-VERSION
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
                -- Geordnete Sammlung - zuerst die näheren Bonds
                local nearbyBonds = {}
                
                for _, item in ipairs(runtime:GetChildren()) do
                    if item.Name:match("Bond") then
                        local part = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart")
                        if part and part.Parent then
                            local distance = (hrpPos - part.Position).Magnitude
                            
                            if distance <= settings.bondAuraRadius then
                                table.insert(nearbyBonds, {item = item, distance = distance})
                            end
                        end
                    end
                end
                
                -- Sortiere nach Entfernung (nächste zuerst)
                table.sort(nearbyBonds, function(a, b)
                    return a.distance < b.distance
                end)
                
                -- Sammle die 3 nächsten Bonds parallel
                local maxParallelCollections = 3
                local auraCollected = 0
                
                for i = 1, math.min(maxParallelCollections, #nearbyBonds) do
                    if nearbyBonds[i] then
                        task.spawn(function()
                            local success = safeActivateObject(nearbyBonds[i].item)
                            if success then
                                collectedBonds = collectedBonds + 1
                                auraCollected = auraCollected + 1
                                updateStatus("Bond automatisch mit Aura gesammelt!", collectedBonds, totalBonds)
                            end
                        end)
                    end
                end
                
                -- Wenn Bonds über Aura gesammelt wurden, kleine Verzögerung
                if auraCollected > 0 then
                    task.wait(0.05 * auraCollected)
                end
                
                return auraCollected
            end
            
            return 0
        end
        
        -- Bond-Aura regelmäßig aktivieren mit Erfolgsüberprüfung
        bondAuraConnection = RunService.Heartbeat:Connect(function()
            local currentTime = tick()
            if not _G.lastBondAuraTime or (currentTime - _G.lastBondAuraTime) >= settings.bondAuraInterval then
                _G.lastBondAuraTime = currentTime
                local collected = collectNearbyBonds()
                
                -- Nur melden, wenn tatsächlich Bonds gesammelt wurden
                if collected > 0 then
                    updateStatus(collected .. " Bond(s) automatisch mit Aura gesammelt!", collectedBonds, totalBonds)
                end
            end
        end)
        
        print("Hochleistungs-Bond-Aura aktiviert - Radius: " .. settings.bondAuraRadius .. " Studs")
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

    -- Scan map - OPTIMIERT FÜR AUSFÜHRLICHEREN SCAN (5-8 Sekunden)
    if settings.scanEnabled then
        updateStatus("Gründlicher Bond-Scan wird gestartet...", 0, 0)
        local scanTarget = CFrame.new(-424.448975, 26.055481, -49040.6562, -1,0,0, 0,1,0, 0,0,-1)
        
        -- Anpassung für gründlicheren Scan
        local scanSteps = 70 -- Mehr Schritte für gründlicheren Scan
        local scanDelay = 0.08 -- Reduzierte Verzögerung für schnelleren Scan, aber ausreichend für Stabilität
        local threadsFinished = 0
        
        -- Zusätzliche Sektoren für gründlicheren Scan
        local scanSectors = {
            {from = hrp.CFrame, to = scanTarget},
            {from = hrp.CFrame, to = CFrame.new(-424.448975, 40.055481, -49040.6562, -1,0,0, 0,1,0, 0,0,-1)}, -- Höhere Ebene
            {from = hrp.CFrame, to = CFrame.new(-400.448975, 26.055481, -49040.6562, -1,0,0, 0,1,0, 0,0,-1)}, -- Leicht versetzt
        }
        
        -- Scan in verschiedenen Sektoren für bessere Abdeckung
        for sectorIndex, sector in ipairs(scanSectors) do
            task.spawn(function()
                updateStatus("Scanne Sektor " .. sectorIndex .. "...", 0, 0)
                
                -- Scan innerhalb dieses Sektors
                for i = 1, scanSteps do
                    local progress = math.floor((i / scanSteps) * 100)
                    local lerpFactor = i/scanSteps
                    
                    -- Teleportiere sicher zum Scan-Punkt
                    pcall(function()
                        hrp.CFrame = sector.from:Lerp(sector.to, lerpFactor)
                    end)
                    
                    -- Warte kurz und sammle Bonds
                    task.wait(scanDelay)
                    pcall(recordBonds)
                end
                
                threadsFinished = threadsFinished + 1
                updateStatus("Sektor " .. sectorIndex .. " abgeschlossen", 0, #bondData)
            end)
            
            -- Warte kurz zwischen dem Start der Sektoren
            task.wait(0.2)
        end
        
        -- Warte, bis alle Sektoren gescannt wurden (mit Timeout)
        local scanStart = tick()
        while threadsFinished < #scanSectors do
            task.wait(0.1)
            if tick() - scanStart > 15 then -- Timeout nach 15 Sekunden
                break
            end
        end
        
        -- Letzter Scan am Ziel für vollständige Abdeckung
        pcall(function()
            hrp.CFrame = scanTarget
        end)
        task.wait(0.3)
        recordBonds()
        
        -- Zusätzlicher Scan in zentraler Position
        pcall(function()
            hrp.CFrame = CFrame.new(-424.448975, 30.055481, -49040.6562, -1,0,0, 0,1,0, 0,0,-1)
        end)
        task.wait(0.3)
        recordBonds()
        
        updateStatus("Ausführlicher Scan abgeschlossen!", 0, #bondData)
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
    
    -- Teleport-Loop durch alle Bonds - TURBO-MODUS
    local collectedInRun = 0
    local skipped = 0
    local batchSize = 10 -- Sammle in Batches für Fortschrittsanzeige
    
    -- Sortiere Bonds nach Position für optimierte Sammlung
    table.sort(bondData, function(a, b)
        return (a.pos - hrp.Position).Magnitude < (b.pos - hrp.Position).Magnitude
    end)
    
    for i = 1, #bondData, batchSize do
        local endIdx = math.min(i + batchSize - 1, #bondData)
        updateStatus("Sammle Bonds " .. i .. "-" .. endIdx .. " (" .. collectedInRun .. " bisher)", collectedInRun, #bondData)
        
        -- Sammle einen Batch von Bonds
        for idx = i, endIdx do
            local entry = bondData[idx]
            
            -- Einfacher Check, ob Charakter existiert
            if not player.Character then
                return scriptFinished()
            end
            
            -- Reset Stuck Detection für neuen Bond
            lastPosition = hrp.Position
            stuckTimer = tick()
            
            -- Schneller Teleport zum Bond
            local destCFrame = CFrame.new(entry.pos + Vector3.new(0, settings.teleportHeight, 0))
            vehicleSeat:PivotTo(destCFrame)
            task.wait(0.05) -- Reduzierte Wartezeit
            
            -- Schnelleres Sitzen
            vehicleSeat:Sit(humanoid)
            task.wait(0.05)
            
            -- Warte kurz auf Teleport
            local t1 = tick()
            repeat 
                RunService.Heartbeat:Wait()
            until atTarget(entry.pos) or (tick() - t1) > 0.7 -- Kürzere Wartezeit
            
            -- Spring ab, wenn wir am Ziel sind
            if humanoid.SeatPart == vehicleSeat then
                humanoid.Jump = true
            end
            
            -- Funktion zum Prüfen, ob ein Bond sammelbar ist
            local function isBondCollectible(bondItem)
                return bondItem and bondItem.Parent and 
                       (bondItem.PrimaryPart or bondItem:FindFirstChildWhichIsA("BasePart")) and
                       (hrp.Position - entry.pos).Magnitude < 15
            end
            
            -- Sofortiger Sammelversuch
            local collectSuccess = false
            if isBondCollectible(entry.item) then
                collectSuccess = safeActivateObject(entry.item)
            end
            
            if collectSuccess then
                collectedInRun = collectedInRun + 1
                collectedBonds = collectedBonds + 1
                updateStatus("Bond " .. idx .. " erfolgreich gesammelt!", collectedInRun, #bondData)
            else
                skipped = skipped + 1
                
                -- Speichern des fehlgeschlagenen Bonds für späteren Versuch
                if settings.retryFailedBonds and isBondCollectible(entry.item) then
                    table.insert(_G.failedBonds, {
                        item = entry.item,
                        pos = entry.pos,
                        key = entry.key,
                        retryCount = 0,
                        lastRetryTime = tick()
                    })
                end
            end
            
            -- Minimale Pause vor nächstem Bond
            task.wait(0.1)
        end
        
        -- Batch-Update
        updateStatus("Batch abgeschlossen: " .. collectedInRun .. " gesammelt, " .. skipped .. " übersprungen", collectedInRun, #bondData)
        
        -- Kurze Pause zwischen Batches für Stabilitätserhöhung
        task.wait(0.3)
    end

    -- Fehlgeschlagene Bonds erneut versuchen - BESCHLEUNIGT
    if settings.retryFailedBonds and #_G.failedBonds > 0 then
        updateStatus("Schnell-Verarbeitung fehlgeschlagener Bonds (" .. #_G.failedBonds .. ")...", collectedBonds, totalBonds)
        
        local failedBondsCount = #_G.failedBonds
        local retrySuccessCount = 0
        
        -- Aktiviere NoClip für alle Retry-Versuche auf einmal
        local noClipConnection = nil
        if settings.useNoClipForRetry and settings.smartNoClip then
            noClipConnection = enableSmartNoClip()
        elseif settings.useNoClipForRetry then
            -- Klassisches No-Clip aktivieren
            pcall(function()
                for _, part in pairs(player.Character:GetDescendants()) do
                    if part:IsA("BasePart") then
                        part.CanCollide = false
                    end
                end
            end)
        end
        
        -- Sortiere fehlgeschlagene Bonds nach Entfernung
        table.sort(_G.failedBonds, function(a, b)
            return (a.pos - hrp.Position).Magnitude < (b.pos - hrp.Position).Magnitude
        end)
        
        -- Parallele Verarbeitung von fehlgeschlagenen Bonds
        local processingThreads = 0
        local maxParallelThreads = 3
        local threadsFinished = 0
        
        -- Threadfunktion für Retry
        local function processFailedBond(index)
            processingThreads = processingThreads + 1
            local failedBond = _G.failedBonds[index]
            
            -- Teleportiere direkt zum Bond
            pcall(function() 
                hrp.CFrame = CFrame.new(failedBond.pos)
            end)
            task.wait(0.1)
            
            -- Versuch, den Bond zu sammeln
            local collectSuccess = safeActivateObject(failedBond.item)
            if collectSuccess then
                collectedBonds = collectedBonds + 1
                retrySuccessCount = retrySuccessCount + 1
                updateStatus("Fehlgeschlagener Bond " .. index .. " erfolgreich gesammelt!", collectedBonds, totalBonds)
                
                -- Entferne erfolgreichen Bond aus der Liste (Markierung für später)
                failedBond.success = true
            else
                -- Verbleibende fehlgeschlagene Bonds maximal einmal wiederholen
                failedBond.retryCount = (failedBond.retryCount or 0) + 1
                failedBond.lastRetryTime = tick()
            end
            
            processingThreads = processingThreads - 1
            threadsFinished = threadsFinished + 1
        end
        
        -- Starte Threads für parallele Verarbeitung
        for i = 1, #_G.failedBonds do
            -- Warte, wenn zu viele Threads aktiv sind
            while processingThreads >= maxParallelThreads do
                task.wait(0.05)
            end
            
            -- Starte Thread für diesen Bond
            task.spawn(function()
                processFailedBond(i)
            end)
            
            task.wait(0.1) -- Kurze Verzögerung zwischen Thread-Starts
        end
        
        -- Warte auf Abschluss aller Threads
        while threadsFinished < #_G.failedBonds do
            task.wait(0.1)
        end
        
        -- Entferne erfolgreiche Bonds aus der Liste
        for i = #_G.failedBonds, 1, -1 do
            if _G.failedBonds[i].success or 
               _G.failedBonds[i].retryCount > settings.maxFailedRetries or
               not _G.failedBonds[i].item or
               not _G.failedBonds[i].item.Parent then
                table.remove(_G.failedBonds, i)
            end
        end
        
        -- Deaktiviere NoClip
        if settings.useNoClipForRetry and settings.smartNoClip and noClipConnection then
            disableSmartNoClip(noClipConnection)
        elseif settings.useNoClipForRetry then
            pcall(function()
                for _, part in pairs(player.Character:GetDescendants()) do
                    if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
                        part.CanCollide = true
                    end
                end
            end)
        end
        
        updateStatus("Schnell-Wiederholung abgeschlossen. " .. retrySuccessCount .. " von " .. failedBondsCount .. " gesammelt.", collectedBonds, totalBonds)
    end

    -- Normale Beendigung: Optimierte Finalisierung für Turbo-Modus
    local totalRun = tick() - startTime
    local minutes = math.floor(totalRun / 60)
    local seconds = math.floor(totalRun % 60)
    
    updateStatus("Alle Bonds gesammelt!", collectedBonds, totalBonds)
    print("===== SAMMLUNG ABGESCHLOSSEN =====")
    print("Gesammelte Bonds: " .. collectedBonds)
    print("Gesamtzeit: " .. minutes .. "m " .. seconds .. "s")
    print("Durchschnitt: " .. string.format("%.2f", collectedBonds / (totalRun / 60)) .. " Bonds pro Minute")
    print("==============================")
    
    -- Bond Aura aufräumen
    cleanupBondAura()
    
    -- Schneller Selbsttod-Mechanismus für sofortigen Neustart
    pcall(function()
        local charHum = player.Character and player.Character:FindFirstChild("Humanoid")
        if charHum then
            -- Bereite Auto-Restart VOR dem Tod vor für schnelleren Übergang
            if settings.autoRestart then
                task.spawn(function()
                    setupAutoRestart()
                    print("Turbo-Auto-Restart vorbereitet")
                end)
            end
            
            -- Setze Position auf Spawn für schnelleren Neustart der nächsten Runde
            pcall(function()
                hrp.CFrame = CFrame.new(0, 100, 0)
            end)
            
            -- Anschließend Selbsttod
            task.wait(0.1)
            charHum:TakeDamage(999999)
        end
    end)

    print("=== Turbo-Sammlung abgeschlossen! ===")
    return scriptFinished()
end

-- Sofort starten
print("===== TURBO-MODE - EasyBond Ultra Fast Collector =====")
print("- Paralleles Scanning aktiviert")
print("- Beschleunigte Teleport-Routine")
print("- Multi-Bond-Sammlung mit Aura")
print("- Optimierte Executor-Kompatibilität")
print("- Drücke F9 für Fortschrittsinformationen")
print("=====================================================")

task.spawn(function()
    local success, errorMsg = pcall(run)
    if not success then
        warn("Fehler beim Ausführen des Bond Collectors: " .. tostring(errorMsg))
        _G.bondCollectorRunning = false
    end
end)

-- Einfache Benutzeroberfläche für Konsolenausgabe
print("EasyBond Collector läuft... Drücke F9 für Konsolenausgabe.")
